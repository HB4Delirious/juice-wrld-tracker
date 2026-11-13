#!/bin/bash
# Builds a Release JuiceTracker.app and packs it into dist/JuiceTracker.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf build/Release-dmg dist
xcodebuild -project JuiceTracker.xcodeproj -scheme JuiceTracker -configuration Release \
  -derivedDataPath build/DerivedData CONFIGURATION_BUILD_DIR="$PWD/build/Release" build

stage=build/Release-dmg
mkdir -p "$stage" dist
cp -R build/Release/JuiceTracker.app "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Juice Tracker" -srcfolder "$stage" -ov -format UDZO dist/JuiceTracker.dmg
echo "Wrote dist/JuiceTracker.dmg"
