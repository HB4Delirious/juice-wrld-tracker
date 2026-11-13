#!/bin/bash
# Builds a Release JuiceTracker.app and packs it into dist/JuiceTracker.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

# Version shown in the app: $VERSION if set, else the latest v* tag (v1.4 -> 1.4). Build number: commit count.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo 0.0)}"
VERSION="${VERSION#v}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "Building JuiceTracker $VERSION ($BUILD)"

rm -rf build/Release-dmg dist
xcodebuild -project JuiceTracker.xcodeproj -scheme JuiceTracker -configuration Release \
  -derivedDataPath build/DerivedData CONFIGURATION_BUILD_DIR="$PWD/build/Release" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build

stage=build/Release-dmg
mkdir -p "$stage" dist
cp -R build/Release/JuiceTracker.app "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Juice Tracker" -srcfolder "$stage" -ov -format UDZO dist/JuiceTracker.dmg
echo "Wrote dist/JuiceTracker.dmg"
