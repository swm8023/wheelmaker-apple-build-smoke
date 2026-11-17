#!/bin/bash
set -euo pipefail

input="${1:?Pass the directory containing darwin-amd64 and darwin-arm64}"
output="${2:?Pass a fresh output directory}"
test ! -e "$output"
mode="${3:-local}"
case "$mode" in
  local)
    identity=-
    timestamp=--timestamp=none
    ;;
  developer-id)
    : "${MAC_SIGN_IDENTITY:?Set the Developer ID Application identity in the keychain}"
    : "${NOTARY_PROFILE:?Set the stored notarytool keychain profile}"
    identity="$MAC_SIGN_IDENTITY"
    timestamp=--timestamp
    ;;
  *)
    printf 'Unknown mode %s\n' "$mode" >&2
    exit 2
    ;;
esac

mkdir -p "$output"
for platform in darwin-amd64 darwin-arm64; do
  mkdir -p "$output/$platform"
  signed="$output/$platform/wheelmaker"
  install -m 0755 "$input/$platform/wheelmaker" "$signed"
  codesign --force --options runtime --identifier com.wheelmaker.hub "$timestamp" --sign "$identity" "$signed"
  codesign --verify --strict --verbose=2 "$signed"
  file "$signed"
done

if [[ "$mode" == developer-id ]]; then
  submission="$output/notarization.zip"
  submission_dir=$(mktemp -d "${TMPDIR:-/tmp}/wheelmaker-notary.XXXXXX")
  trap 'rm -f "$submission_dir/input.zip"; rmdir "$submission_dir"' EXIT
  ditto -c -k --sequesterRsrc --keepParent "$output" "$submission_dir/input.zip"
  mv "$submission_dir/input.zip" "$submission"
  receipt="$output/notarization.plist"
  xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist >"$receipt"
  test "$(plutil -extract status raw -o - "$receipt")" = Accepted
fi
