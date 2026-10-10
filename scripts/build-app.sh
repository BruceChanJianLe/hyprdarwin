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
# VERSION is the one place the version lives; CI adds its run number
VERSION=$(tr -d '[:space:]' < VERSION)
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
    BUILD=$GITHUB_RUN_NUMBER
    ORIGIN=run
else
    BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
    ORIGIN=local
fi
COMMIT=$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/hyprdarwin" "$APP/Contents/MacOS/hyprdarwin"
# the command line client; the Homebrew cask links it into the PATH
cp "$BIN/hyprdarwinctl" "$APP/Contents/MacOS/hyprdarwinctl"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__COMMIT__/$COMMIT/" -e "s/__ORIGIN__/$ORIGIN/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
cp Sources/CLua/LICENSE "$APP/Contents/Resources/LICENSE-lua.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# app icon from the SVG; the menu bar icon is drawn from its SVG at runtime
rm -rf build/AppIcon.iconset
swift scripts/render-icon.swift Resources/hyprdarwin-icon.svg build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/hyprdarwin-menubar.svg "$APP/Contents/Resources/MenuBarIcon.svg"

set -- --force --timestamp=none
if [ -n "${HYPRDARWIN_KEYCHAIN:-}" ]; then
    set -- "$@" --keychain "$HYPRDARWIN_KEYCHAIN"
    FIND_IN="$HYPRDARWIN_KEYCHAIN"
else
    FIND_IN=""
fi
# shellcheck disable=SC2086
if security find-certificate -c "$IDENTITY" $FIND_IN >/dev/null 2>&1; then
    SIGN_AS=$IDENTITY
else
    SIGN_AS=-
    echo "warning: signing identity \"$IDENTITY\" not found; ad-hoc signed (Accessibility must be re-granted after each rebuild)" >&2
fi
# nested code first: the bundle's signature seals hyprdarwinctl's
codesign "$@" --identifier io.github.brucechanjianle.hyprdarwinctl --sign "$SIGN_AS" "$APP/Contents/MacOS/hyprdarwinctl"
codesign "$@" --identifier io.github.brucechanjianle.hyprdarwin --sign "$SIGN_AS" "$APP"
[ "$SIGN_AS" = - ] || echo "signed with \"$IDENTITY\""
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
"$APP/Contents/MacOS/hyprdarwinctl" --help >/dev/null
echo "built $APP: $("$APP/Contents/MacOS/hyprdarwin" --version), with hyprdarwinctl"
