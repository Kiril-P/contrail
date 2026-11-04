#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64), ad-hoc signed Contrail.app and packages
# it as a zip and a dmg with SHA-256 checksums.
#
#   scripts/build-release.sh            # version from the Xcode project
#   VERSION=0.2.0 scripts/build-release.sh
#
# Output goes to ./dist. The app is NOT notarized; see README for how to open it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
BUILD="$ROOT/build/release"

VERSION="${VERSION:-$(xcodebuild -project Contrail.xcodeproj -scheme Contrail -showBuildSettings -configuration Release 2>/dev/null | awk '/MARKETING_VERSION/ {print $3; exit}')}"
echo "Building Contrail $VERSION"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

xcodebuild \
  -project Contrail.xcodeproj \
  -scheme Contrail \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD/DerivedData" \
  -archivePath "$BUILD/Contrail.xcarchive" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  -quiet \
  archive

APP="$BUILD/Contrail.xcarchive/Products/Applications/Contrail.app"
if [[ ! -d "$APP" ]]; then
  echo "error: archive did not produce Contrail.app" >&2
  exit 1
fi

# Re-sign the whole bundle ad hoc so the signature is consistent.
codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/Contrail"

ZIP="$DIST/Contrail-$VERSION.zip"
DMG="$DIST/Contrail-$VERSION.dmg"

ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Contrail" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt)
cat "$DIST/SHA256SUMS.txt"
echo "Done: $DIST"
