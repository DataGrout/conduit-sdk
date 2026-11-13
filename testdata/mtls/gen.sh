#!/usr/bin/env bash
# Regenerates the test-only mTLS fixtures. Valid for 100 years so they never
# expire under a test suite; nothing here is trusted outside these tests.
set -euo pipefail
cd "$(dirname "$0")"

p256() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1"; }

p256 ca-key.pem
openssl req -x509 -new -key ca-key.pem -days 36500 \
  -subj "/CN=conduit-sdk test CA (not for production)" \
  -config /dev/null -extfile ext.cnf -extensions ca -out ca.pem

for who in server client; do
  p256 "$who-key.pem"
  openssl req -new -key "$who-key.pem" -subj "/CN=conduit-sdk test $who" -out "$who.csr"
  openssl x509 -req -in "$who.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
    -days 36500 -extfile ext.cnf -extensions "$who" -out "$who.pem"
  rm "$who.csr"
done
rm -f ca.srl
openssl verify -CAfile ca.pem server.pem client.pem
