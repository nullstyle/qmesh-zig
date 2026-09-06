#!/usr/bin/env bash
# Regenerates tests/data test PKI: one CA plus per-node leaf certs.
# Every node cert carries the shared cluster SAN (DNS:qmesh-test), so
# peers can dial each other by verifying against ca.pem with
# server_name="qmesh-test" — the interim posture until quic-zig grows
# a verify-against-CA-without-name-check mode (README gap 2).
set -euo pipefail
cd "$(dirname "$0")/../tests/data"

openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 3650 \
  -subj "/CN=QMesh Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out ca.pem

# NOTE: a/b SPKI digests are pinned in tests/quic_session_test.zig and
# c/d in tests/quic_mesh_test.zig. Regenerating rotates every node's
# PeerId — update those constants together with the certs.
for n in a b c d e f g h i j k l; do
  openssl ecparam -name prime256v1 -genkey -noout -out "node-$n.key"
  openssl req -new -key "node-$n.key" -subj "/CN=qmesh-node-$n" -out "node-$n.csr"
  printf 'subjectAltName=DNS:qmesh-test,DNS:qmesh-node-%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth,clientAuth\n' "$n" > "node-$n.ext"
  openssl x509 -req -in "node-$n.csr" -CA ca.pem -CAkey ca.key -CAcreateserial \
    -sha256 -days 3650 -extfile "node-$n.ext" -out "node-$n.pem"
done

rm -f ./*.csr ./*.ext ./*.srl
echo "regenerated: ca.pem node-a.pem node-b.pem (+ keys)"
