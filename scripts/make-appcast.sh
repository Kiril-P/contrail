#!/usr/bin/env bash
# Writes dist/appcast.xml for the zip in ./dist, signed with Contrail's
# Sparkle EdDSA key. Run after scripts/build-release.sh.
#
#   scripts/make-appcast.sh                    # key from the login keychain (account "contrail")
#   SPARKLE_ED_KEY_FILE=key scripts/make-appcast.sh   # key from a file (CI)
#
# Needs Sparkle's tools: set SPARKLE_BIN, or they are downloaded (pinned).
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

ZIP="$(ls dist/Contrail-*.zip | head -1)"
VERSION="$(basename "$ZIP" .zip)"; VERSION="${VERSION#Contrail-}"

if [[ -z "${SPARKLE_BIN:-}" ]]; then
  tools="build/sparkle-$SPARKLE_VERSION"
  if [[ ! -x "$tools/bin/generate_appcast" ]]; then
    mkdir -p "$tools"
    curl -fsSL -o "$tools.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $tools.tar.xz" | shasum -a 256 -c -
    tar -xf "$tools.tar.xz" -C "$tools"
  fi
  SPARKLE_BIN="$tools/bin"
fi

stage="build/appcast"
rm -rf "$stage"; mkdir -p "$stage"
cp "$ZIP" "$stage/"

key_args=(--account contrail)
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  key_args=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi

"$SPARKLE_BIN/generate_appcast" "${key_args[@]}" \
  --download-url-prefix "https://github.com/Kiril-P/contrail/releases/download/v$VERSION/" \
  --link "https://github.com/Kiril-P/contrail" \
  --maximum-deltas 0 \
  -o dist/appcast.xml \
  "$stage"

grep -q 'sparkle:edSignature=' dist/appcast.xml || { echo "appcast has no EdDSA signature" >&2; exit 1; }
grep -q "Contrail-$VERSION.zip" dist/appcast.xml || { echo "appcast doesn't point at Contrail-$VERSION.zip" >&2; exit 1; }
echo "Wrote dist/appcast.xml for $VERSION"
