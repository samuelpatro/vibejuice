#!/usr/bin/env bash
# Cut a release: build, sign ad hoc, wrap in a DMG, publish to GitHub Releases, update the cask.
#   scripts/release.sh 0.1.0
#
# The DMG is published on the public tap repo (samuelpatro/homebrew-vibejuice) so `brew install` can
# fetch it while the source repo stays private. The same release is mirrored on the source repo.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
SOURCE_REPO="samuelpatro/vibejuice"
TAP_REPO="samuelpatro/homebrew-vibejuice"
DMG="build/VibeJuice-$VERSION.dmg"

# Ad hoc signature for distribution: no Keychain dialog, and a self-signed cert would not help
# Gatekeeper anyway. Users right-click > Open once, or install through the cask.
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

# Cask formula in this repo; the tap repo gets a copy.
mkdir -p Casks
cat > Casks/vibejuice.rb <<RUBY
cask "vibejuice" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$TAP_REPO/releases/download/v#{version}/VibeJuice-#{version}.dmg"
  name "VibeJuice"
  desc "Menu bar quota meter and account switcher for Claude Code and Codex CLI"
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

git add Casks/vibejuice.rb scripts/bundle.sh
git diff --cached --quiet || git commit -q -m "release: $VERSION"
git tag -f "$TAG" >/dev/null
git push -q origin main
git push -q -f origin "$TAG"

NOTES="VibeJuice $VERSION. Open the DMG, drag VibeJuice to Applications, right-click > Open the first time. Or: brew install --cask samuelpatro/vibejuice/vibejuice"
gh release create "$TAG" "$DMG" --repo "$SOURCE_REPO" --title "VibeJuice $VERSION" --notes "$NOTES" >/dev/null 2>&1 \
  || gh release upload "$TAG" "$DMG" --repo "$SOURCE_REPO" --clobber >/dev/null
echo "released https://github.com/$SOURCE_REPO/releases/tag/$TAG"

# Public tap: cask + the DMG brew downloads.
if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
  TAPDIR="$(mktemp -d)"
  gh repo clone "$TAP_REPO" "$TAPDIR" -- -q
  mkdir -p "$TAPDIR/Casks"
  cp Casks/vibejuice.rb "$TAPDIR/Casks/vibejuice.rb"
  git -C "$TAPDIR" add Casks/vibejuice.rb
  git -C "$TAPDIR" diff --cached --quiet || git -C "$TAPDIR" commit -q -m "vibejuice $VERSION"
  git -C "$TAPDIR" push -q
  gh release create "$TAG" "$DMG" --repo "$TAP_REPO" --title "VibeJuice $VERSION" --notes "$NOTES" >/dev/null 2>&1 \
    || gh release upload "$TAG" "$DMG" --repo "$TAP_REPO" --clobber >/dev/null
  rm -rf "$TAPDIR"
  echo "tap updated: brew install --cask samuelpatro/vibejuice/vibejuice"
else
  echo "tap repo $TAP_REPO not found; create it (public) and rerun to enable brew install"
fi
