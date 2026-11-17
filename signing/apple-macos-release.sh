#!/bin/bash
set -euo pipefail
set +x
umask 077

: "${WM_WORK:?}" "${WM_TEAM_ID:?}"
[[ "$WM_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]
keychain="$WM_WORK/apple-signing.keychain-db"
password="$(openssl rand -hex 32)"

cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -f "$WM_WORK/identity.p12"
}
trap cleanup EXIT
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"

case "${1:-}" in
  sign)
    : "${WM_MAC_P12:?}" "${WM_MAC_P12_PASSWORD:?}"
    printf '%s' "$WM_MAC_P12" | base64 -D >"$WM_WORK/identity.p12"
    security import "$WM_WORK/identity.p12" -k "$keychain" -f pkcs12 \
      -P "$WM_MAC_P12_PASSWORD" -T /usr/bin/codesign
    unset WM_MAC_P12 WM_MAC_P12_PASSWORD
    rm -f "$WM_WORK/identity.p12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain"
    security list-keychains -d user -s "$keychain"
    identity="$(security find-identity -v -p codesigning "$keychain" | awk -v team="($WM_TEAM_ID)" '
      /Developer ID Application:/ && index($0, team) { n++; identity=$2 }
      END { if (n == 1) print identity; else exit 1 }
    ')"
    [[ "$identity" =~ ^[0-9A-F]{40}$ ]]
    for target in darwin-amd64 darwin-arm64; do
      binary="$WM_WORK/$target-wheelmaker"
      case "$target" in
        darwin-amd64) arch=x86_64 ;;
        darwin-arm64) arch=arm64 ;;
      esac
      [[ "$(lipo -archs "$binary")" == "$arch" ]]
      codesign --force --options runtime --timestamp --identifier com.wheelmaker.hub \
        --keychain "$keychain" --sign "$identity" "$binary"
      codesign --verify --strict --verbose=2 "$binary"
      details="$(codesign -dv --verbose=4 "$binary" 2>&1)"
      grep -Fxq "TeamIdentifier=$WM_TEAM_ID" <<<"$details"
      grep -Fq 'Authority=Developer ID Application:' <<<"$details"
      grep -q '^flags=.*runtime' <<<"$details" || grep -q 'flags=.*runtime' <<<"$details"
      grep -q '^Timestamp=' <<<"$details"
    done
    ;;
  notarize)
    : "${WM_NOTARY_APPLE_ID:?}" "${WM_NOTARY_PASSWORD:?}"
    xcrun notarytool store-credentials wheelmaker-release --keychain "$keychain" \
      --apple-id "$WM_NOTARY_APPLE_ID" --team-id "$WM_TEAM_ID" --password "$WM_NOTARY_PASSWORD"
    unset WM_NOTARY_APPLE_ID WM_NOTARY_PASSWORD
    mkdir "$WM_WORK/notarization"
    cp "$WM_WORK/darwin-amd64-wheelmaker" "$WM_WORK/darwin-arm64-wheelmaker" "$WM_WORK/notarization/"
    ditto -c -k --keepParent "$WM_WORK/notarization" "$WM_WORK/notarization.zip"
    xcrun notarytool submit "$WM_WORK/notarization.zip" --keychain-profile wheelmaker-release \
      --keychain "$keychain" --wait --timeout 45m --output-format json >"$WM_WORK/notary.json"
    if [[ "$(plutil -extract status raw -o - "$WM_WORK/notary.json")" != Accepted ]]; then
      submission="$(plutil -extract id raw -o - "$WM_WORK/notary.json")"
      xcrun notarytool log "$submission" --keychain-profile wheelmaker-release --keychain "$keychain" || true
      exit 1
    fi
    python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["WM_WORK"])
receipt = json.loads((root / "notary.json").read_text())
(root / "evidence.json").write_text(json.dumps({
    "status": receipt["status"],
    "submissionID": receipt["id"],
    "teamID": os.environ["WM_TEAM_ID"],
}))
PY
    ;;
  *)
    exit 64
    ;;
esac
