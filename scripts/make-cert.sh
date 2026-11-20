#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity "Sidekick Self-Signed" in the
# login keychain. Every Sidekick build is signed with it so macOS keeps microphone
# and accessibility permissions across rebuilds and updates. Idempotent.
set -euo pipefail
NAME="Sidekick Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity '$NAME' already exists."
  exit 0
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/cert.cnf" 2>/dev/null
PASS="sidekick-$(uuidgen)"
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -name "$NAME" -out "$DIR/id.p12" -passout pass:"$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -name "$NAME" -out "$DIR/id.p12" -passout pass:"$PASS"

security import "$DIR/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created '$NAME'."
security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME" || true
