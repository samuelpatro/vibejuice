#!/usr/bin/env bash
# Create a self-signed code-signing certificate in the login keychain so VibeJuice keeps
# a stable identity across rebuilds. Keychain "Always Allow" then survives new builds.
# Idempotent: exits if the identity already exists.
set -euo pipefail
NAME="${1:-VibeJuice Dev}"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "identity \"$NAME\" already exists"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
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
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout pass:vibejuice -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout pass:vibejuice

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P vibejuice -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Trust it for code signing in the user's trust domain (may show a password dialog once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME" && echo "created identity \"$NAME\""
