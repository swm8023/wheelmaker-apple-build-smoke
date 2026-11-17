#!/bin/bash
set -euo pipefail
set +x
umask 077

root="$(pwd)"
work="$(mktemp -d "$RUNNER_TEMP/wheelmaker-adhoc.XXXXXX")"
log="$work/build.log"
keychain="$work/signing.keychain-db"
profile_path=
legacy_profile_path=
ipa=
touch "$log"

finish() {
  status=$?
  trap - EXIT
  set +e
  if [[ -f "$work/return.key" ]]; then
    files=("$log")
    if [[ -n "$ipa" && -f "$ipa" && "$status" == 0 ]]; then
      cp "$ipa" "$work/WheelMaker-iPad.ipa"
      files+=("$work/WheelMaker-iPad.ipa")
    fi
    if ! zip -jq "$work/result.zip" "${files[@]}" ||
       ! xcrun swift "$root/signing/seal-result.swift" "$work/return.key" "$work/result.zip" "$RUNNER_TEMP/WheelMaker-iPad-build.enc" >>"$log" 2>&1; then
      printf 'Could not encrypt the build result.\n' >&2
      status=1
    fi
  fi
  if [[ -n "$profile_path" ]]; then rm -f "$profile_path" "$legacy_profile_path"; fi
  if [[ -f "$keychain" ]]; then security delete-keychain "$keychain" >/dev/null 2>&1; fi
  rm -rf "$work"
  exit "$status"
}
trap finish EXIT

export WM_SIGNING_TEMP="$work"
python3 - <<'PY' >>"$log" 2>&1
import base64
import json
import os
from pathlib import Path

data = json.loads(os.environ["WM_ADHOC_SETTINGS"])
root = Path(os.environ["WM_SIGNING_TEMP"])
for field, name in [
    ("return_key", "return.key"), ("identity", "certificate.p12"), ("profile", "profile.mobileprovision")
]:
    (root / name).write_bytes(base64.b64decode(data[field], validate=True))
(root / "password").write_text(data["password"])
(root / "selected_device").write_text(data["selected_device"])
PY
unset WM_ADHOC_SETTINGS

security cms -D -i "$work/profile.mobileprovision" >"$work/profile.plist" 2>>"$log"
python3 - <<'PY' >>"$log" 2>&1
import os
import plistlib
from pathlib import Path

root = Path(os.environ["WM_SIGNING_TEMP"])
with (root / "profile.plist").open("rb") as stream:
    profile = plistlib.load(stream)
team, = profile["TeamIdentifier"]
bundle_id = "com.wheelmaker.ios"
device = (root / "selected_device").read_text().upper()
if {item.upper() for item in profile.get("ProvisionedDevices", [])} != {device}:
    raise ValueError("Profile device list does not match the selected device")
if profile["Entitlements"]["application-identifier"] != f"{team}.{bundle_id}":
    raise ValueError("Profile app identifier does not match")
if profile["Entitlements"].get("get-task-allow") or profile.get("ProvisionsAllDevices"):
    raise ValueError("Expected an Ad Hoc distribution profile")
(root / "team").write_text(team)
(root / "uuid").write_text(profile["UUID"])
with (root / "ExportOptions.plist").open("wb") as stream:
    plistlib.dump(
        {
            "method": "release-testing",
            "signingStyle": "manual",
            "signingCertificate": "Apple Distribution",
            "teamID": team,
            "provisioningProfiles": {bundle_id: profile["UUID"]},
        },
        stream,
    )
PY

team="$(cat "$work/team")"
uuid="$(cat "$work/uuid")"
keychain_password="$(openssl rand -hex 32)"

(
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 7200 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$work/certificate.p12" -k "$keychain" -P "$(cat "$work/password")" -f pkcs12 \
    -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain"
  security list-keychains -d user -s "$keychain"
  security find-identity -v -p codesigning "$keychain" | tee "$work/identities"
  grep -q 'Apple Distribution' "$work/identities"
) >>"$log" 2>&1

profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
legacy_profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profile_dir" "$legacy_profile_dir"
profile_path="$profile_dir/$uuid.mobileprovision"
legacy_profile_path="$legacy_profile_dir/$uuid.mobileprovision"
cp "$work/profile.mobileprovision" "$profile_path"
cp "$work/profile.mobileprovision" "$legacy_profile_path"
rm -f "$work/certificate.p12" "$work/password"
printf 'Apple signing identity and target device profile validated.\n'

archive="$work/WheelMaker.xcarchive"
if ! xcodebuild -project ios-smoke/WheelMakerSmoke.xcodeproj -scheme WheelMakerSmoke \
  -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$work/DerivedData" \
  -archivePath "$archive" "DEVELOPMENT_TEAM=$team" PRODUCT_BUNDLE_IDENTIFIER=com.wheelmaker.ios \
  PRODUCT_NAME=WheelMaker INFOPLIST_KEY_CFBundleDisplayName=WheelMaker 'TARGETED_DEVICE_FAMILY=1,2' \
  'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad=UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight' \
  CODE_SIGN_STYLE=Manual 'CODE_SIGN_IDENTITY=Apple Distribution' \
  "PROVISIONING_PROFILE_SPECIFIER=$uuid" archive >>"$log" 2>&1; then
  printf 'Signed archive failed. Diagnostic log is encrypted.\n' >&2
  exit 1
fi
if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
  -exportPath "$work/export" >>"$log" 2>&1; then
  printf 'Ad Hoc export failed. Diagnostic log is encrypted.\n' >&2
  exit 1
fi

shopt -s nullglob
packages=("$work"/export/*.ipa)
if [[ "${#packages[@]}" != 1 ]]; then
  printf 'Expected one Ad Hoc IPA.\n' >&2
  exit 1
fi
ipa="${packages[0]}"
unzip -tq "$ipa" >>"$log" 2>&1
unzip -q "$ipa" -d "$work/ipa" >>"$log" 2>&1
app="$work/ipa/Payload/WheelMaker.app"
codesign --verify --deep --strict "$app" >>"$log" 2>&1
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" | grep -Fxq com.wheelmaker.ios
cmp "$app/embedded.mobileprovision" "$work/profile.mobileprovision" >>"$log" 2>&1
printf 'Ad Hoc IPA exported. Signature, Bundle ID, and embedded device profile verified.\n'
