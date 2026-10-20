#!/bin/sh
# Builds Meetings.app into ./build. Ad-hoc signed so macOS remembers calendar access.
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
APP=build/Meetings.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Meetings</string>
  <key>CFBundleExecutable</key><string>Meetings</string>
  <key>CFBundleIdentifier</key><string>com.cipolla.meetings</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your next meeting in the menu bar.</string>
  <key>NSCalendarsUsageDescription</key><string>Shows your next meeting in the menu bar.</string>
</dict></plist>
PLIST

swiftc -O -parse-as-library -o "$APP/Contents/MacOS/Meetings" Sources/MeetingApp.swift
codesign --force --sign - "$APP"
echo "built $APP"
