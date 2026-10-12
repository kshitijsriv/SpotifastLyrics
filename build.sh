#!/bin/bash
# Builds SpotifastLyrics.app. Pass --install to copy it into /Applications and launch it,
# or --zip to also make build/SpotifastLyrics.zip for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SpotifastLyrics.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal binary so the same app runs on Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" Sources/main.swift -o "build/SpotifastLyrics-$arch"
done
lipo -create build/SpotifastLyrics-arm64 build/SpotifastLyrics-x86_64 -output "$APP/Contents/MacOS/SpotifastLyrics"
rm build/SpotifastLyrics-arm64 build/SpotifastLyrics-x86_64
cp Sources/nowplaying.js "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SpotifastLyrics</string>
  <key>CFBundleIdentifier</key><string>io.github.kshitijsriv.SpotifastLyrics</string>
  <key>CFBundleExecutable</key><string>SpotifastLyrics</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--zip" ]]; then
  ditto -c -k --keepParent "$APP" build/SpotifastLyrics.zip
  echo "Zipped build/SpotifastLyrics.zip"
fi
if [[ "${1:-}" == "--install" ]]; then
  pkill -x SpotifastLyrics || true
  rm -rf /Applications/SpotifastLyrics.app
  cp -R "$APP" /Applications/
  open /Applications/SpotifastLyrics.app
  echo "Installed and launched /Applications/SpotifastLyrics.app"
fi
