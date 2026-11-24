#!/bin/zsh
# Builds build/Pulse.app for Apple silicon and Intel.
#   ./build.sh              signed for this Mac only (ad hoc)
#   ./build.sh --install    also copies it to /Applications and opens it
#   SIGN_IDENTITY="Developer ID Application: ..." ./build.sh    signed for other Macs
set -euo pipefail
cd "${0:A:h}"
version=$(<VERSION)
swift build -c release --arch arm64 --arch x86_64
app="build/Pulse.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/apple/Products/Release/Pulse "$app/Contents/MacOS/Pulse"
cp Resources/Pulse.icns "$app/Contents/Resources/Pulse.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
# Grows with every commit, and needs no one to remember it.
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD 2>/dev/null || echo 1)" "$app/Contents/Info.plist"
strip -x "$app/Contents/MacOS/Pulse"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --strict --deep "$app"
echo "built $app $version ($(lipo -archs "$app/Contents/MacOS/Pulse"))"
if [[ "${1:-}" == "--install" ]]; then
  # Only the menu bar app. `Pulse --mcp` processes belong to open agent sessions.
  for pid in $(pgrep -x Pulse); do
    [[ "$(ps -o args= -p $pid)" == *"--mcp"* ]] || kill $pid
  done
  rm -rf /Applications/Pulse.app
  cp -R "$app" /Applications/Pulse.app
  open /Applications/Pulse.app
  echo "installed and opened /Applications/Pulse.app"
fi
