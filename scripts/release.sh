#!/usr/bin/env bash
# Build, package and publish one version. GitHub Actions runs this on every `v*` tag
# (.github/workflows/release.yml). It also works locally: scripts/release.sh 0.3.0
#
# Needs: gh authenticated for the source repo (GH_TOKEN in CI), and TAP_TOKEN or push rights
# for the tap repo. Without tap access the release is still published; only the cask is skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
SOURCE_REPO="samuelpatro/vibejuice"
TAP_REPO="samuelpatro/homebrew-vibejuice"
DMG="build/VibeJuice-$VERSION.dmg"

# Ad hoc signature: users right-click > Open once, or install through the cask.
VERSION="$VERSION" CODESIGN_ID="__adhoc__" scripts/bundle.sh --no-open >/dev/null

# DMG with the app and an Applications shortcut, the usual drag-to-install layout.
STAGE="$(mktemp -d)"
cp -R build/VibeJuice.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "VibeJuice" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "built $DMG ($SHA)"

# GitHub Release on the source repo: create it, or replace the asset if the tag already has one.
NOTES="Open the DMG, drag VibeJuice to Applications, right-click > Open the first time. Or: brew install --cask samuelpatro/vibejuice/vibejuice"
if gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --repo "$SOURCE_REPO" --clobber >/dev/null
else
  gh release create "$TAG" "$DMG" --repo "$SOURCE_REPO" --title "VibeJuice $VERSION" --notes "$NOTES" --generate-notes >/dev/null
fi
echo "released https://github.com/$SOURCE_REPO/releases/tag/$TAG"

# Cask in the tap repo, pointing at the release above.
TAP_URL="https://github.com/$TAP_REPO.git"
[[ -n "${TAP_TOKEN:-}" ]] && TAP_URL="https://x-access-token:${TAP_TOKEN}@github.com/$TAP_REPO.git"
TAPDIR="$(mktemp -d)"
if ! git clone -q "$TAP_URL" "$TAPDIR" 2>/dev/null; then
  echo "tap: cannot clone $TAP_REPO, skipping cask update"; exit 0
fi
mkdir -p "$TAPDIR/Casks"
cat > "$TAPDIR/Casks/vibejuice.rb" <<RUBY
cask "vibejuice" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$SOURCE_REPO/releases/download/v#{version}/VibeJuice-#{version}.dmg"
  name "VibeJuice"
  desc "One-click account switcher for Claude Code, Codex CLI and Grok CLI"
  homepage "https://github.com/$SOURCE_REPO"

  depends_on macos: :tahoe

  app "VibeJuice.app"

  zap trash: [
    "~/Library/Application Support/VibeJuice",
    "~/Library/Logs/VibeJuice",
    "~/Library/Preferences/dev.samuel.vibejuice.plist",
  ]
end
RUBY
git -C "$TAPDIR" add Casks/vibejuice.rb
if git -C "$TAPDIR" diff --cached --quiet; then
  echo "tap: cask already at $VERSION"
elif git -C "$TAPDIR" -c user.name="vibejuice-release" -c user.email="release@vibejuice.invalid" commit -q -m "vibejuice $VERSION" \
     && git -C "$TAPDIR" push -q 2>/dev/null; then
  echo "tap updated: brew install --cask samuelpatro/vibejuice/vibejuice"
else
  echo "tap: push failed (no TAP_TOKEN?), cask not updated"
fi
rm -rf "$TAPDIR"
