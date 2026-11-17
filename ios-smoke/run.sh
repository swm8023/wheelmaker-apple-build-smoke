#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
output="$PWD/build"
mkdir -p "$output"
project=(-project WheelMakerSmoke.xcodeproj -scheme WheelMakerSmoke -configuration Release -derivedDataPath "$output/DerivedData")
if [[ "${1:-}" == "adhoc" ]]; then
  : "${IOS_TEAM_ID:?Set the Apple Developer Team ID}"
  : "${IOS_BUNDLE_ID:?Set the registered Bundle ID}"
  : "${IOS_PROFILE_NAME:?Set the installed Ad Hoc profile name or UUID}"
  archive="$output/WheelMakerSmoke-signed.xcarchive"
  xcodebuild "${project[@]}" -destination 'generic/platform=iOS' -archivePath "$archive" \
    "DEVELOPMENT_TEAM=$IOS_TEAM_ID" "PRODUCT_BUNDLE_IDENTIFIER=$IOS_BUNDLE_ID" \
    CODE_SIGN_IDENTITY='Apple Distribution' \
    "PROVISIONING_PROFILE_SPECIFIER=$IOS_PROFILE_NAME" archive
  xcodebuild -help >"$output/xcodebuild-help.log" 2>&1 || true
  export_method=ad-hoc
  if grep -q 'release-testing' "$output/xcodebuild-help.log"; then export_method=release-testing; fi
  plist="$output/ExportOptions.plist"
  rm -f "$plist"
  plutil -create xml1 "$plist"
  plutil -insert method -string "$export_method" "$plist"
  plutil -insert signingStyle -string manual "$plist"
  plutil -insert signingCertificate -string 'Apple Distribution' "$plist"
  plutil -insert teamID -string "$IOS_TEAM_ID" "$plist"
  plutil -insert provisioningProfiles -xml '<dict/>' "$plist"
  profile_key=${IOS_BUNDLE_ID//./\\.}
  plutil -insert "provisioningProfiles.$profile_key" -string "$IOS_PROFILE_NAME" "$plist"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$plist" -exportPath "$output/export"
  found_ipa=("$output"/export/*.ipa)
  test -f "${found_ipa[0]}"
  unzip -t "${found_ipa[0]}"
else
  xcodebuild "${project[@]}" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  xcodebuild "${project[@]}" -destination 'generic/platform=iOS' \
    -archivePath "$output/WheelMakerSmoke-unsigned.xcarchive" CODE_SIGNING_ALLOWED=NO archive
  test -x "$output/WheelMakerSmoke-unsigned.xcarchive/Products/Applications/WheelMakerSmoke.app/WheelMakerSmoke"
fi
