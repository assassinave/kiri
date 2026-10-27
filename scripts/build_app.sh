#!/bin/bash
# Builds build/kiri.app.
#
# Signing identity, first match wins:
#   1. $KIRI_SIGN_IDENTITY
#   2. a code-signing identity named "kiri" in the keychain, trusted or not (see APP_CONTEXT.md › Permissions)
#   3. ad-hoc ("-")
# macOS ties privacy permissions to the signature. A certificate keeps them across rebuilds. Ad-hoc
# ties them to this one build's hash, so every rebuild leaves stale entries in System Settings; in
# that case this script clears kiri's entries (tccutil reset All) so the next launch asks fresh.
# Set KIRI_KEEP_TCC=1 to skip that reset.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="dev.kiri.app"
IDENTITY="${KIRI_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # Not -v: a self-signed certificate shows as CSSMERR_TP_NOT_TRUSTED but signs fine, and the
    # signature still pins the requirement to this certificate. Use its hash to avoid name ambiguity.
    IDENTITY="$(security find-identity -p codesigning | awk '$3 == "\"kiri\"" { print $2; exit }')"
fi
IDENTITY="${IDENTITY:--}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/kiri"

APP="build/kiri.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/kiri"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    # Hardened runtime + secure timestamp: required for notarization with a Developer ID certificate.
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
        --options runtime --timestamp --entitlements Resources/kiri.entitlements "$APP"
fi
echo "Built $APP (signed: $([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "$IDENTITY"))"

if [[ "$IDENTITY" == "-" && "${KIRI_KEEP_TCC:-0}" != "1" ]]; then
    if tccutil reset All "$BUNDLE_ID"; then
        echo "Ad-hoc build: cleared kiri's privacy permissions; quit and reopen kiri, then allow them again."
    else
        echo "Ad-hoc build: couldn't clear kiri's privacy permissions (tccutil failed)." >&2
    fi
fi
