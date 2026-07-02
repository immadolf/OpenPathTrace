#!/usr/bin/env bash
set -euo pipefail

identity="OpenPathTrace Local Code Signing"
keychain="${HOME}/Library/Keychains/login.keychain-db"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

if security find-identity -p codesigning -v | sed -n 's/.*"\(.*\)".*/\1/p' | grep -Fxq "${identity}"; then
  echo "Code signing identity already exists: ${identity}"
  exit 0
fi

security delete-certificate -c "${identity}" "${keychain}" 2>/dev/null || true

openssl req \
  -newkey rsa:2048 \
  -nodes \
  -x509 \
  -days 3650 \
  -subj "/CN=${identity}/" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "${workdir}/identity.key" \
  -out "${workdir}/identity.crt"

openssl pkcs12 \
  -export \
  -inkey "${workdir}/identity.key" \
  -in "${workdir}/identity.crt" \
  -name "${identity}" \
  -out "${workdir}/identity.p12" \
  -passout pass:openpathtrace

security add-trusted-cert -r trustRoot -p codeSign -k "${keychain}" "${workdir}/identity.crt"
security import "${workdir}/identity.p12" -k "${keychain}" -P "openpathtrace" -T /usr/bin/codesign -T /usr/bin/security
security find-identity -p codesigning -v
