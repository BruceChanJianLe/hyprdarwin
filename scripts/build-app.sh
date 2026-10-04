#!/bin/sh
# Build build/hyprdarwin.app (release, arm64) and sign it.
#
# Signing: a stable identity keeps the Accessibility grant across rebuilds
# (TCC pins the grant to the signing certificate). The identity is taken from
# $HYPRDARWIN_SIGN_IDENTITY (default "hyprdarwin-local"), searched in
# $HYPRDARWIN_KEYCHAIN if set, else in your default keychains. Without it the
# app is ad-hoc signed and macOS asks for Accessibility again after every
# rebuild. scripts/make-signing-identity.sh creates the identity.
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/hyprdarwin.app"
IDENTITY=${HYPRDARWIN_SIGN_IDENTITY:-hyprdarwin-local}
VERSION=${HYPRDARWIN_VERSION:-0.1.0}
BUILD=${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/hyprdarwin" "$APP/Contents/MacOS/hyprdarwin"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Sources/CLua/LICENSE "$APP/Contents/Resources/LICENSE-lua.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

set -- --force --timestamp=none --identifier io.github.brucechanjianle.hyprdarwin
if [ -n "${HYPRDARWIN_KEYCHAIN:-}" ]; then
    set -- "$@" --keychain "$HYPRDARWIN_KEYCHAIN"
    FIND_IN="$HYPRDARWIN_KEYCHAIN"
else
    FIND_IN=""
fi
# shellcheck disable=SC2086
if security find-certificate -c "$IDENTITY" $FIND_IN >/dev/null 2>&1; then
    codesign "$@" --sign "$IDENTITY" "$APP"
    echo "signed with \"$IDENTITY\""
else
    codesign "$@" --sign - "$APP"
    echo "warning: signing identity \"$IDENTITY\" not found; ad-hoc signed (Accessibility must be re-granted after each rebuild)" >&2
fi
codesign --verify --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
echo "built $APP"
