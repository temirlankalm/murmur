#!/usr/bin/env bash
# Builds Murmur.app and wraps it in a DMG for handing to someone else.
#
# The app is signed with whatever certificate build.sh found, which for a local
# self-signed one means nothing to anybody else's Mac: Gatekeeper will refuse
# it until they clear the quarantine flag. See "Installing" in the README.
# Proper distribution needs an Apple Developer Program membership so the app
# can be signed with a Developer ID and notarised.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/Murmur.app/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
STAGING="$(mktemp -d)"
DMG="$ROOT/dist/Murmur-$VERSION.dmg"

"$ROOT/build.sh" --release

# Re-read the version: build.sh may have just written a new Info.plist.
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/Murmur.app/Contents/Info.plist")"
DMG="$ROOT/dist/Murmur-$VERSION.dmg"

mkdir -p "$ROOT/dist"
rm -f "$DMG"

cp -R "$ROOT/Murmur.app" "$STAGING/"
# The usual drag-to-install target.
ln -s /Applications "$STAGING/Applications"

cp "$ROOT/INSTALL.txt" "$STAGING/Read me first.txt" 2>/dev/null || true

hdiutil create \
    -volname "Murmur $VERSION" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGING"

echo "Built $DMG"
echo "  $(du -h "$DMG" | cut -f1)"
shasum -a 256 "$DMG" | awk '{print "  sha256 " $1}'
