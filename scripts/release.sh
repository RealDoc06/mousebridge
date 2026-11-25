#!/bin/sh
# Publishes a GitHub release that installed copies pick up through Sparkle.
# Usage: scripts/release.sh 0.2.0
# Needs: gh auth, the Sparkle EdDSA key in SPARKLE_KEY (default ~/.config/mousebridge/sparkle_ed25519),
# and a notarytool keychain profile in NOTARY_PROFILE (default "mousebridge"; empty skips notarizing).
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
OUT=build/release
ZIP="$OUT/MouseBridge-$VERSION.zip"
SPARKLE_KEY="${SPARKLE_KEY:-$HOME/.config/mousebridge/sparkle_ed25519}"
NOTARY_PROFILE="${NOTARY_PROFILE-mousebridge}"

git diff --quiet HEAD || { echo "commit your changes first"; exit 1; }
scripts/build-app.sh "$VERSION"

rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent build/MouseBridge.app "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/MouseBridge.app
  rm "$ZIP" && ditto -c -k --keepParent build/MouseBridge.app "$ZIP"
fi

.build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file "$SPARKLE_KEY" \
  --download-url-prefix "https://github.com/RealDoc06/mousebridge/releases/download/$TAG/" "$OUT"

git tag "$TAG" && git push origin HEAD "$TAG"
# Created first, assets after, with retries: creating right after the tag push has hit GitHub 500s.
for attempt in 1 2 3 4 5; do
  gh release view "$TAG" >/dev/null 2>&1 && break
  gh release create "$TAG" --title "$TAG" --generate-notes || sleep 5
done
gh release upload "$TAG" "$ZIP" "$OUT/appcast.xml" --clobber
