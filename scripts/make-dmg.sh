#!/bin/bash
# Builds a Release JuiceTracker.app and packs it into dist/JuiceTracker.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

# Version shown in the app: $VERSION if set, else the latest v* tag (v1.4 -> 1.4). Build number: commit count.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo 0.0)}"
VERSION="${VERSION#v}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "Building JuiceTracker $VERSION ($BUILD)"

rm -rf dist
xcodebuild -project JuiceTracker.xcodeproj -scheme JuiceTracker -configuration Release \
  -derivedDataPath build/DerivedData CONFIGURATION_BUILD_DIR="$PWD/build/Release" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build

# Themed DMG window (background, icon positions) via dmgbuild, kept in a local venv under build/.
venv=build/.venv-dmg
[ -x "$venv/bin/dmgbuild" ] || { python3 -m venv "$venv" && "$venv/bin/pip" install -q dmgbuild==1.6.5; }
tiffutil -cathidpicheck design/dmg-background.png design/dmg-background@2x.png -out build/dmg-background.tiff >/dev/null
mkdir -p dist
"$venv/bin/dmgbuild" -s scripts/dmg-settings.py -D app=build/Release/JuiceTracker.app -D background=build/dmg-background.tiff \
  "Juice Tracker" dist/JuiceTracker.dmg
echo "Wrote dist/JuiceTracker.dmg"
