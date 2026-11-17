#!/bin/bash
set -euo pipefail
set +x
umask 077

: "${WM_WORK:?}" "${WM_TEAM_ID:?}" "${WM_IOS_P12:?}" "${WM_IOS_P12_PASSWORD:?}" "${WM_IOS_PROFILE:?}"
[[ "$WM_TEAM_ID" =~ ^[A-Z0-9]{10}$ && "${WM_VERSION:-}" =~ ^v1\.[1-9][0-9]*$ ]]
keychain="$WM_WORK/ios-signing.keychain-db"
password="$(openssl rand -hex 32)"
profile_path=
legacy_profile_path=
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  if [[ -n "$profile_path" ]]; then rm -f "$profile_path" "$legacy_profile_path"; fi
  rm -f "$WM_WORK/identity.p12" "$WM_WORK/profile.mobileprovision" "$WM_WORK/profile.plist"
}
trap cleanup EXIT

printf '%s' "$WM_IOS_P12" | base64 -D >"$WM_WORK/identity.p12"
printf '%s' "$WM_IOS_PROFILE" | base64 -D >"$WM_WORK/profile.mobileprovision"
unset WM_IOS_P12 WM_IOS_PROFILE
security cms -D -i "$WM_WORK/profile.mobileprovision" >"$WM_WORK/profile.plist"
profile_id="$(python3 - <<'PY'
import datetime
import os
import plistlib
import uuid
from pathlib import Path

root = Path(os.environ["WM_WORK"])
profile = plistlib.loads((root / "profile.plist").read_bytes())
team = os.environ["WM_TEAM_ID"]
bundle = "com.wheelmaker.ios"
if (profile.get("TeamIdentifier") != [team] or
    profile["Entitlements"].get("application-identifier") != f"{team}.{bundle}" or
    profile["Entitlements"].get("get-task-allow") or profile.get("ProvisionsAllDevices") or
    len(set(profile.get("ProvisionedDevices", []))) < 2 or
    profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc)):
    raise ValueError("Expected a current Ad Hoc profile with registered iPhone and iPad devices")
profile_id = str(uuid.UUID(profile["UUID"])).upper()
(root / "ExportOptions.plist").write_bytes(plistlib.dumps({
    "method": "release-testing",
    "signingStyle": "manual",
    "signingCertificate": "Apple Distribution",
    "teamID": team,
    "manageAppVersionAndBuildNumber": False,
    "provisioningProfiles": {bundle: profile_id},
}))
print(profile_id)
PY
)"

security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$WM_WORK/identity.p12" -k "$keychain" -P "$WM_IOS_P12_PASSWORD" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security
unset WM_IOS_P12_PASSWORD
rm -f "$WM_WORK/identity.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain"
security list-keychains -d user -s "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -F 'Apple Distribution:'

profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
legacy_profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profile_dir" "$legacy_profile_dir"
profile_path="$profile_dir/$profile_id.mobileprovision"
legacy_profile_path="$legacy_profile_dir/$profile_id.mobileprovision"
cp "$WM_WORK/profile.mobileprovision" "$profile_path"
cp "$WM_WORK/profile.mobileprovision" "$legacy_profile_path"

archive="$WM_WORK/WheelMaker.xcarchive"
xcodebuild -project "$WM_WORK/source/mobile/ios/WheelMaker.xcodeproj" -scheme WheelMaker \
  -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$WM_WORK/DerivedData" \
  -archivePath "$archive" "DEVELOPMENT_TEAM=$WM_TEAM_ID" "MARKETING_VERSION=${WM_VERSION#v}" \
  "CURRENT_PROJECT_VERSION=${WM_VERSION#v1.}" CODE_SIGN_STYLE=Manual 'CODE_SIGN_IDENTITY=Apple Distribution' \
  "PROVISIONING_PROFILE_SPECIFIER=$profile_id" archive
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$WM_WORK/ExportOptions.plist" -exportPath "$WM_WORK/export"

shopt -s nullglob
packages=("$WM_WORK"/export/*.ipa)
[[ "${#packages[@]}" == 1 ]]
unzip -tq "${packages[0]}"
unzip -q "${packages[0]}" -d "$WM_WORK/ipa"
app="$WM_WORK/ipa/Payload/WheelMaker.app"
codesign --verify --deep --strict "$app"
details="$(codesign -dv --verbose=4 "$app" 2>&1)"
grep -Fxq "TeamIdentifier=$WM_TEAM_ID" <<<"$details"
grep -Fq 'Authority=Apple Distribution:' <<<"$details"
cmp "$app/embedded.mobileprovision" "$WM_WORK/profile.mobileprovision"
python3 - <<'PY'
import json
import os
import plistlib
from pathlib import Path

root = Path(os.environ["WM_WORK"])
info = plistlib.loads((root / "ipa/Payload/WheelMaker.app/Info.plist").read_bytes())
version = os.environ["WM_VERSION"]
if (info.get("CFBundleIdentifier") != "com.wheelmaker.ios" or
    info.get("CFBundleShortVersionString") != version[1:] or
    info.get("CFBundleVersion") != version[3:] or
    sorted(info.get("UIDeviceFamily", [])) != [1, 2]):
    raise ValueError("Signed IPA identity or device families do not match the requested release")
(root / "evidence.json").write_text(json.dumps({
    "bundleID": info["CFBundleIdentifier"],
    "bundleVersion": info["CFBundleShortVersionString"],
    "buildNumber": info["CFBundleVersion"],
    "deviceFamilies": [1, 2],
    "teamID": os.environ["WM_TEAM_ID"],
}))
PY
cp "${packages[0]}" "$WM_WORK/WheelMaker.ipa"
