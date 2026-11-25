#!/bin/sh
# Publishes a GitHub release that installed copies pick up through Sparkle.
# Usage: scripts/release.sh 0.2.0
# Needs: the Sparkle EdDSA key in the login keychain (account "mousebridge"), gh auth.
# Optional: NOTARY_PROFILE=<notarytool keychain profile> to notarize and staple.
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
OUT=build/release
ZIP="$OUT/MouseBridge-$VERSION.zip"

git diff --quiet HEAD || { echo "commit your changes first"; exit 1; }
scripts/build-app.sh "$VERSION"

rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent build/MouseBridge.app "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/MouseBridge.app
  rm "$ZIP" && ditto -c -k --keepParent build/MouseBridge.app "$ZIP"
fi

.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account mousebridge \
  --download-url-prefix "https://github.com/RealDoc06/mousebridge/releases/download/$TAG/" "$OUT"

git tag "$TAG" && git push origin HEAD "$TAG"
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --title "$TAG" --generate-notes
