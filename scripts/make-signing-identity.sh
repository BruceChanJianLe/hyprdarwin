#!/bin/sh
# Create a self-signed code-signing identity for hyprdarwin builds.
#
#   scripts/make-signing-identity.sh [output-dir]
#
# Writes <output-dir>/hyprdarwin-local.p12 (default ./build/signing) with a
# random password next to it, imports the identity into your login keychain
# so scripts/build-app.sh can sign local builds, and prints the two commands
# that store it as GitHub Actions secrets so CI builds are signed with the
# same certificate. Builds signed with one certificate keep their
# Accessibility grant across rebuilds. Run it once; keep the .p12 private.
set -eu

NAME=${HYPRDARWIN_SIGN_IDENTITY:-hyprdarwin-local}
OUT=${1:-build/signing}
mkdir -p "$OUT"
chmod 700 "$OUT"
KEY="$OUT/$NAME.key"
CERT="$OUT/$NAME.crt"
P12="$OUT/$NAME.p12"
PASSWORD_FILE="$OUT/$NAME.password"

if [ -e "$P12" ]; then
    echo "$P12 already exists; delete it first to make a new identity" >&2
    exit 1
fi

CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT
cat > "$CONFIG" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$CONFIG" -keyout "$KEY" -out "$CERT" 2>/dev/null
PASSWORD=$(openssl rand -hex 16)
printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$KEY" "$PASSWORD_FILE"
# -legacy keeps the PKCS#12 readable by `security import` when openssl is 3.x
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=-legacy; else LEGACY=; fi
# shellcheck disable=SC2086
openssl pkcs12 -export $LEGACY -inkey "$KEY" -in "$CERT" -name "$NAME" -out "$P12" -passout "pass:$PASSWORD"
rm -f "$KEY"

LOGIN="$HOME/Library/Keychains/login.keychain-db"
security import "$P12" -k "$LOGIN" -P "$PASSWORD" -T /usr/bin/codesign
# codesign only uses trusted identities; macOS asks for your password here
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN" "$CERT"
echo
echo "Imported and trusted \"$NAME\" in the login keychain; scripts/build-app.sh now signs with it."
echo
echo "To sign CI builds with the same certificate:"
echo "  base64 -i \"$P12\" | gh secret set HYPRDARWIN_SIGNING_P12"
echo "  gh secret set HYPRDARWIN_SIGNING_PASSWORD < \"$PASSWORD_FILE\""
