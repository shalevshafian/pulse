#!/bin/zsh
# Builds build/Pulse.app. Pass --install to copy it to /Applications and relaunch.
set -euo pipefail
cd "${0:A:h}"
swift build -c release
app="build/Pulse.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Pulse "$app/Contents/MacOS/Pulse"
cat > "$app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.pulse.menubar</string>
  <key>CFBundleName</key><string>Pulse</string>
  <key>CFBundleExecutable</key><string>Pulse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force --sign - "$app"
echo "built $app"
if [[ "${1:-}" == "--install" ]]; then
  # Only the menu bar app. `Pulse --mcp` processes belong to open Claude sessions.
  for pid in $(pgrep -x Pulse); do
    [[ "$(ps -o args= -p $pid)" == *"--mcp"* ]] || kill $pid
  done
  rm -rf /Applications/Pulse.app
  cp -R "$app" /Applications/Pulse.app
  open /Applications/Pulse.app
  echo "installed and opened /Applications/Pulse.app"
fi
