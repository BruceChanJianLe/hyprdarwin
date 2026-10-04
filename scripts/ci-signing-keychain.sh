#!/bin/sh
# CI only: put a code-signing identity in a temporary keychain for
# scripts/build-app.sh.
#
# With the HYPRDARWIN_SIGNING_P12 (base64) and HYPRDARWIN_SIGNING_PASSWORD
# secrets set, that stable identity is used and the Accessibility grant
# survives updates. Without them a throwaway identity is generated, so the
# signing path is still exercised, but each build then needs Accessibility
# granted again (like an ad-hoc build).
#
# Exports HYPRDARWIN_KEYCHAIN and HYPRDARWIN_SIGN_IDENTITY through $GITHUB_ENV.
set -eu

NAME=hyprdarwin-local
WORK=${RUNNER_TEMP:-/tmp}/hyprdarwin-signing
KEYCHAIN="$WORK/ci.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
rm -rf "$WORK"
mkdir -p "$WORK"

if [ -n "${HYPRDARWIN_SIGNING_P12:-}" ]; then
    printf '%s' "$HYPRDARWIN_SIGNING_P12" | base64 --decode > "$WORK/identity.p12"
    P12_PASSWORD=${HYPRDARWIN_SIGNING_PASSWORD:-}
    echo "using the stored signing identity"
else
    cat > "$WORK/req.cnf" <<EOF
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
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -config "$WORK/req.cnf" \
        -keyout "$WORK/identity.key" -out "$WORK/identity.crt" 2>/dev/null
    P12_PASSWORD=$(openssl rand -hex 16)
    if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=-legacy; else LEGACY=; fi
    # shellcheck disable=SC2086
    openssl pkcs12 -export $LEGACY -inkey "$WORK/identity.key" -in "$WORK/identity.crt" -name "$NAME" \
        -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD"
    echo "::warning::HYPRDARWIN_SIGNING_P12 is not set; signed with a throwaway identity (Accessibility must be re-granted for this build)"
fi

# the certificate alone, for the trust setting
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=-legacy; else LEGACY=; fi
# shellcheck disable=SC2086
openssl pkcs12 $LEGACY -in "$WORK/identity.p12" -passin "pass:$P12_PASSWORD" -nokeys -clcerts -out "$WORK/identity.pem"
IDENTITY=$(openssl x509 -in "$WORK/identity.pem" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# codesign only finds identities on the search list, and only trusted ones
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$WORK/identity.pem"
security find-identity -v -p codesigning "$KEYCHAIN"

{
    echo "HYPRDARWIN_KEYCHAIN=$KEYCHAIN"
    echo "HYPRDARWIN_SIGN_IDENTITY=$IDENTITY"
} >> "${GITHUB_ENV:-/dev/null}"
