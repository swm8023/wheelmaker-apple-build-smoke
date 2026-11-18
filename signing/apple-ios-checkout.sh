#!/bin/bash
set -euo pipefail
set +x
umask 077

: "${WM_WORK:?}" "${WM_IOS_DEPLOY_KEY:?}"
[[ "${WM_SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]]
key="$WM_WORK/source-deploy-key"
trap 'rm -f "$key"' EXIT
printf '%s\n' "$WM_IOS_DEPLOY_KEY" >"$key"
unset WM_IOS_DEPLOY_KEY
cat >"$WM_WORK/github-known-hosts" <<'KEY'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
KEY
export GIT_SSH_COMMAND="ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 -o UserKnownHostsFile=\"$WM_WORK/github-known-hosts\" -i \"$key\""
source="$WM_WORK/source"
git clone --depth=1 --branch main --filter=blob:none --no-checkout git@github.com:swm8023/WheelMaker.git "$source"
git -C "$source" fetch --depth=1 --filter=blob:none origin "$WM_SOURCE_SHA"
ios_dir=mobile/ios
if git -C "$source" cat-file -e "$WM_SOURCE_SHA:platform/ios/WheelMaker.xcodeproj/project.pbxproj"; then
  ios_dir=platform/ios
fi
project_file="$ios_dir/WheelMaker.xcodeproj/project.pbxproj"
project_source="$(git -C "$source" show "$WM_SOURCE_SHA:$project_file")"
sparse=("/$ios_dir/" /platform/assets/ /server/internal/nativeprompt/assets/ /server/internal/nativewebtheme/assets/)
build_go=false
if [[ "$ios_dir" == platform/ios && "$project_source" == *Mobilebind.xcframework* ]]; then
  build_go=true
  sparse+=(/platform/shared/ /scripts/build-native-go.mjs)
fi
git -C "$source" sparse-checkout set --no-cone "${sparse[@]}"
printf 'WM_IOS_BUILD_GO=%s\n' "$build_go" >>"$GITHUB_ENV"
git -C "$source" checkout --detach "$WM_SOURCE_SHA"
[[ "$(git -C "$source" rev-parse HEAD)" == "$WM_SOURCE_SHA" ]]
test -f "$source/$ios_dir/WheelMaker.xcodeproj/project.pbxproj"
printf 'WM_IOS_PROJECT=%s\n' "$source/$ios_dir/WheelMaker.xcodeproj" >>"$GITHUB_ENV"
