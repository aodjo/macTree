#!/bin/bash
# Publishes a signed and notarized MacTree release from this Mac.
#
#   scripts/release.sh v1.2.3
#
# Tags main's HEAD (if the tag does not exist yet) and pushes the tag. Then it
# builds a universal app and signs it with the Developer ID Application
# identity (hardened runtime + secure timestamp). The app is notarized with
# notarytool and the ticket stapled. Finally it creates the GitHub release with
# MacTree-<tag>.zip (or replaces the zip if the release exists) and prints the
# SHA-256 for the Homebrew cask.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials macTree --apple-id <Apple ID> --team-id <Team ID>
# NOTARY_PROFILE selects another profile, SIGN_IDENTITY another identity.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release.sh vX.Y.Z}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Tag must look like v1.2.3." >&2; exit 1; }
VERSION="${TAG#v}"
PROFILE="${NOTARY_PROFILE:-macTree}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
if ! xcrun notarytool history --keychain-profile "$PROFILE" > /dev/null 2>&1; then
    echo "Notary profile '$PROFILE' is missing. Create it once with:" >&2
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id <Team ID>" >&2
    exit 1
fi

[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Check out an up-to-date main first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || { echo "$TAG exists but is not HEAD." >&2; exit 1; }
else
    git tag -a "$TAG" -m "MacTree $VERSION"
fi
git push -q origin "$TAG"

UNIVERSAL=1 VERSION="$VERSION" BUILD_NUMBER="$(git rev-list --count HEAD)" SIGN_IDENTITY="$IDENTITY" \
    ./scripts/build-app.sh

APP=build/MacTree.app
ZIP="build/MacTree-$TAG.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json > build/notary.json
if [ "$(plutil -extract status raw build/notary.json)" != "Accepted" ]; then
    xcrun notarytool log "$(plutil -extract id raw build/notary.json)" --keychain-profile "$PROFILE" >&2
    exit 1
fi
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

NOTES=$(mktemp)
cat > "$NOTES" <<'NOTES'
WizTree-style disk space analyzer for macOS 15 or later (Apple silicon and Intel), signed with Developer ID and notarized by Apple.

**Install:** `brew install --cask aodjo/tap/mactree`, or unzip and move `MacTree.app` to Applications.

For complete results, allow **Full Disk Access** when MacTree asks.
NOTES
if gh release view "$TAG" > /dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --clobber
else
    gh release create "$TAG" "$ZIP" --title "MacTree $TAG" --notes-file "$NOTES" --generate-notes
fi
rm -f "$NOTES"
echo "SHA-256 for the cask: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
