#!/bin/zsh
# Makes build/Pulse-<version>.dmg: both architectures, signed, notarized, stapled and checked.
#
# Needs, once on this Mac:
#   a "Developer ID Application" certificate in the keychain
#   xcrun notarytool store-credentials pulse-notary --apple-id <apple id> --team-id <team>
#
#   scripts/release.sh                    the real thing
#   scripts/release.sh --skip-notarize    everything but Apple's check; other Macs will refuse it
# SIGN_IDENTITY and NOTARY_PROFILE override the certificate found and the profile name.
set -euo pipefail
cd "${0:A:h:h}"
profile="${NOTARY_PROFILE:-pulse-notary}"
notarize=1; [[ "${1:-}" == "--skip-notarize" ]] && notarize=0

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  found=("${(@f)$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)}")
  [[ ${#found} == 1 && -n "$found[1]" ]] || { echo "set SIGN_IDENTITY: found ${#found} Developer ID Application certificates"; exit 1 }
  SIGN_IDENTITY="$found[1]"
fi
export SIGN_IDENTITY
# A missing password costs seconds here, and a whole build later.
if (( notarize )); then
  xcrun notarytool history --keychain-profile "$profile" >/dev/null || { echo "no notary profile called $profile; see the top of this file"; exit 1 }
  [[ -z "$(git status --porcelain)" ]] || { echo "commit first: a release is built from a commit"; exit 1 }
fi

swift test
./build.sh
version=$(<VERSION); app=build/Pulse.app; dmg="build/Pulse-$version.dmg"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait | tee "$work/notary.txt"
  grep -q 'status: Accepted' "$work/notary.txt" || {
    xcrun notarytool log "$(awk '/ id:/{print $2; exit}' "$work/notary.txt")" --keychain-profile "$profile"; exit 1 }
}

if (( notarize )); then
  ditto -c -k --keepParent "$app" "$work/Pulse.zip"
  notarize "$work/Pulse.zip"
  xcrun stapler staple "$app"
fi

mkdir "$work/image"
ditto "$app" "$work/image/Pulse.app"
ln -s /Applications "$work/image/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Pulse $version" -srcfolder "$work/image" -fs HFS+ -format UDZO "$dmg"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
if (( notarize )); then
  notarize "$dmg"
  xcrun stapler staple "$dmg"
fi

# What a user gets, checked from inside the image.
mkdir "$work/mount"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$work/mount" "$dmg"
trap 'hdiutil detach -quiet "$work/mount" || true; rm -rf "$work"' EXIT
inside="$work/mount/Pulse.app"
codesign --verify --strict --deep "$inside"
[[ "$(lipo -archs "$inside/Contents/MacOS/Pulse")" == "x86_64 arm64" ]] || { echo "not universal"; exit 1 }
if (( notarize )); then
  xcrun stapler validate "$inside"
  xcrun stapler validate "$dmg"
  spctl -a -vv -t exec "$inside"
  spctl -a -vv -t open --context context:primary-signature "$dmg"
else
  spctl -a -vv -t exec "$inside" || true
fi
shasum -a 256 "$dmg"
