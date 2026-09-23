#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing identity in your login
# keychain for fork developer apps. Signing every rebuild with the same identity
# gives the app a stable designated requirement, so Keychain "Always Allow"
# survives rebuilds instead of prompting again.
#
# Run it yourself; macOS asks for your password when the certificate is marked
# trusted for code signing. The identity is only used for local builds.
set -euo pipefail

name="TypeWhisper Fork Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"$name\""; then
  echo "[signing] identity \"$name\" already exists"
  security find-identity -v -p codesigning | grep -F "\"$name\""
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$tmp/cert.cnf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
p12_pass="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$name" -out "$tmp/identity.p12" -passout "pass:$p12_pass"

# Only codesign may use the private key without asking.
security import "$tmp/identity.p12" -k "$keychain" -P "$p12_pass" -T /usr/bin/codesign
echo "[signing] marking the certificate trusted for code signing (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"

security find-identity -v -p codesigning | grep -F "\"$name\"" \
  || { echo "[signing] error: identity was imported but is not valid for code signing" >&2; exit 1; }
echo "[signing] done. scripts/fork/build-main-app.sh now signs with \"$name\"."
