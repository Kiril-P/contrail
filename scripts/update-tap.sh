#!/usr/bin/env bash
# scripts/update-tap.sh <version> — copy a published release's cask into the tap.
#
# The release workflow attaches contrail.rb (version and sha256 filled in) to
# every release. This puts that file in Kiril-P/homebrew-tap as Casks/contrail.rb
# and pushes, so `brew install --cask Kiril-P/tap/contrail` gets the new version.
set -euo pipefail
VERSION="${1:?usage: scripts/update-tap.sh <version>}"
TAP="${CONTRAIL_TAP_REPO:-Kiril-P/homebrew-tap}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
gh release download "v$VERSION" --repo Kiril-P/contrail --pattern contrail.rb --dir "$work"
grep -q "version \"$VERSION\"" "$work/contrail.rb" || { echo "cask in v$VERSION does not say version $VERSION" >&2; exit 1; }
grep -qE 'sha256 "[0-9a-f]{64}"' "$work/contrail.rb" || { echo "cask in v$VERSION has no sha256" >&2; exit 1; }

gh repo clone "$TAP" "$work/tap" -- --quiet
mkdir -p "$work/tap/Casks"
cp "$work/contrail.rb" "$work/tap/Casks/contrail.rb"
cd "$work/tap"
if [ -z "$(git status --porcelain)" ]; then
  echo "tap already has contrail $VERSION"; exit 0
fi
git add Casks/contrail.rb
git commit -qm "contrail $VERSION"
git push -q
echo "tap updated: contrail $VERSION"
