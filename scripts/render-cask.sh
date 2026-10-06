#!/bin/sh
# Render the Homebrew cask from packaging/homebrew/hyprdarwin.rb.
#   scripts/render-cask.sh VERSION SHA256 > Casks/hyprdarwin.rb
set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 VERSION SHA256" >&2
    exit 2
fi
VERSION=$1
SHA256=$2
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: version '$VERSION' is not X.Y.Z" >&2
    exit 1
fi
if ! printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "error: '$SHA256' is not a sha256 hex digest" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA256/" packaging/homebrew/hyprdarwin.rb
