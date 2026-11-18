#!/bin/bash
set -euo pipefail
set +x
umask 077

: "${WM_WORK:?}" "${WM_IOS_PROJECT:?}" "${WM_TEAM_ID:?}" "${WM_IOS_P12:?}" "${WM_IOS_P12_PASSWORD:?}" "${WM_IOS_PROFILE:?}"
[[ "$WM_TEAM_ID" =~ ^[A-Z0-9]{10}$ && "${WM_VERSION:-}" =~ ^v1\.[1-9][0-9]*$ ]]

keychain="$WM_WORK/ios-signing.keychain-db"
password="$(openssl rand -hex 32)"
profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
legacy_profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
profile_id=
widget_profile_id=
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  for installed_id in "$profile_id" "$widget_profile_id"; do
    if [[ -n "$installed_id" ]]; then
      rm -f "$profile_dir/$installed_id.mobileprovision" "$legacy_profile_dir/$installed_id.mobileprovision"
    fi
  done
  rm -f "$WM_WORK/identity.p12" "$WM_WORK/profile.mobileprovision" "$WM_WORK/profile.plist" \
    "$WM_WORK/widget.mobileprovision" "$WM_WORK/widget.plist"
}
trap cleanup EXIT

# Older source revisions use a single app target with no embedded extension.
mode=legacy
if grep -Fq 'WM_IOS_WIDGET_PROFILE_ID' "$WM_IOS_PROJECT/project.pbxproj"; then
  mode=live
  : "${WM_IOS_WIDGET_PROFILE:?Missing Widget Ad Hoc profile in apple-ios-release environment}"
  printf '%s' "$WM_IOS_WIDGET_PROFILE" | base64 -D >"$WM_WORK/widget.mobileprovision"
  security cms -D -i "$WM_WORK/widget.mobileprovision" >"$WM_WORK/widget.plist"
fi
unset WM_IOS_WIDGET_PROFILE
printf '%s' "$WM_IOS_P12" | base64 -D >"$WM_WORK/identity.p12"
printf '%s' "$WM_IOS_PROFILE" | base64 -D >"$WM_WORK/profile.mobileprovision"
unset WM_IOS_P12 WM_IOS_PROFILE
security cms -D -i "$WM_WORK/profile.mobileprovision" >"$WM_WORK/profile.plist"
profile_ids="$(python3 signing/apple-ios-release-metadata.py prepare "$mode")"
read -r profile_id widget_profile_id <<<"$profile_ids"

security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$WM_WORK/identity.p12" -k "$keychain" -P "$WM_IOS_P12_PASSWORD" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security
unset WM_IOS_P12_PASSWORD
rm -f "$WM_WORK/identity.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain"
security list-keychains -d user -s "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -F 'Apple Distribution:'

mkdir -p "$profile_dir" "$legacy_profile_dir"
install_profile() {
  local name="$1" id="$2"
  cp "$WM_WORK/$name.mobileprovision" "$profile_dir/$id.mobileprovision"
  cp "$WM_WORK/$name.mobileprovision" "$legacy_profile_dir/$id.mobileprovision"
}
install_profile profile "$profile_id"
if [[ "$mode" == live ]]; then
  install_profile widget "$widget_profile_id"
  signing_profiles=("WM_IOS_APP_PROFILE_ID=$profile_id" "WM_IOS_WIDGET_PROFILE_ID=$widget_profile_id")
else
  signing_profiles=("PROVISIONING_PROFILE_SPECIFIER=$profile_id")
fi

archive="$WM_WORK/WheelMaker.xcarchive"
xcodebuild -project "$WM_IOS_PROJECT" -scheme WheelMaker \
  -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$WM_WORK/DerivedData" \
  -archivePath "$archive" "DEVELOPMENT_TEAM=$WM_TEAM_ID" "MARKETING_VERSION=${WM_VERSION#v}.0" \
  "CURRENT_PROJECT_VERSION=${WM_VERSION#v1.}" CODE_SIGN_STYLE=Manual 'CODE_SIGN_IDENTITY=Apple Distribution' \
  "${signing_profiles[@]}" archive
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$WM_WORK/ExportOptions.plist" -exportPath "$WM_WORK/export"

shopt -s nullglob
packages=("$WM_WORK"/export/*.ipa)
[[ "${#packages[@]}" == 1 ]]
unzip -tq "${packages[0]}"
unzip -q "${packages[0]}" -d "$WM_WORK/ipa"
app="$WM_WORK/ipa/Payload/WheelMaker.app"
codesign --verify --deep --strict "$app"
verify_identity() {
  local bundle="$1" profile="$2" details
  details="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
  grep -Fxq "TeamIdentifier=$WM_TEAM_ID" <<<"$details"
  grep -Fq 'Authority=Apple Distribution:' <<<"$details"
  cmp "$bundle/embedded.mobileprovision" "$WM_WORK/$profile.mobileprovision"
}
verify_identity "$app" profile
if [[ "$mode" == live ]]; then
  widget="$app/PlugIns/WheelMakerSessionActivity.appex"
  codesign --verify --strict "$widget"
  verify_identity "$widget" widget
fi
python3 signing/apple-ios-release-metadata.py verify "$mode"
cp "${packages[0]}" "$WM_WORK/WheelMaker.ipa"
