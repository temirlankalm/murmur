#!/usr/bin/env bash
# Builds Murmur.app. Pass --release for an optimised build.
# Set MURMUR_SIGN_ID to a real signing identity (see `security find-identity -v
# -p codesigning`) to keep macOS permission grants across rebuilds; otherwise we
# ad-hoc sign, and you may have to re-approve Accessibility after each build.
set -euo pipefail

CONFIG=debug
[[ "${1:-}" == "--release" ]] && CONFIG=release

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Murmur.app"

# Pick a signing identity. A stable one matters more than it sounds: macOS ties
# the Accessibility grant to the code signature, and an ad-hoc signature changes
# on every build — so the permission silently stops working after each rebuild
# even though the checkbox stays ticked.
#
# Order: an explicit MURMUR_SIGN_ID, then a local self-signed certificate, then
# ad-hoc as a last resort.
SIGN_ID="${MURMUR_SIGN_ID:-}"
IDENTITY_FILE="$ROOT/.signing-identity"

# Pin the certificate by SHA-1 rather than by name. Two reasons: a self-signed
# root made by Certificate Assistant is untrusted, so `find-identity -v` won't
# list it and signing by name fails — but signing by hash works fine, and local
# use doesn't need the trust. And pinning keeps the *same* certificate across
# builds even when several share a name, which is what keeps the designated
# requirement — and therefore the Accessibility grant — stable.
if [[ -z "$SIGN_ID" && -f "$IDENTITY_FILE" ]]; then
    candidate="$(cat "$IDENTITY_FILE")"
    if security find-identity -p codesigning | grep -q "$candidate"; then
        SIGN_ID="$candidate"
    else
        echo "note: pinned signing certificate is gone; picking another." >&2
        rm -f "$IDENTITY_FILE"
    fi
fi

if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
        | grep '"Murmur Local Signing"' | head -1 | awk '{print $2}')"
    [[ -n "$SIGN_ID" ]] && echo "$SIGN_ID" > "$IDENTITY_FILE"
fi

if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="-"
    echo "warning: no 'Murmur Local Signing' certificate — using ad-hoc." >&2
    echo "         Accessibility will need re-granting after every build." >&2
    echo "         See README: 'Making permissions stick'." >&2
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Murmur"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Murmur</string>
    <key>CFBundleDisplayName</key>       <string>Murmur</string>
    <key>CFBundleExecutable</key>        <string>Murmur</string>
    <key>CFBundleIdentifier</key>        <string>com.murmur.dictation</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>LSUIElement</key>               <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>com.murmur.dictation</string>
            <key>CFBundleURLSchemes</key>
            <array><string>murmur</string></array>
        </dict>
    </array>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur listens to your microphone while you hold the dictation key, and transcribes it on-device.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Murmur transcribes your speech on-device to type it for you.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_ID" --identifier com.murmur.dictation "$APP"

echo "Built $APP  (signed: ${SIGN_ID})"
