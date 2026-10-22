#!/bin/sh
# Regenerates the KEEL-007 TLS fixtures. Unit tests evaluate trust at a fixed date (2026-10-01), so these files
# never expire for them; the integration fixture server makes its own short-lived copies at run time.
# Passphrase for the encrypted key and the .p12: "keel-fixture".
set -eu
cd "$(dirname "$0")"
days=800   # Apple rejects TLS server certificates valid for more than 825 days, even under a private CA.
start=20260901000000Z; end=20281101000000Z
ca() { # name subject
    openssl req -x509 -new -newkey rsa:2048 -nodes -keyout "$1.key" -subj "$2" -sha256 \
        -not_before "$start" -not_after 20360901000000Z -addext basicConstraints=critical,CA:true \
        -addext keyUsage=critical,keyCertSign,cRLSign -out "$1.pem" 2>/dev/null
}
leaf() { # name subject san eku ca
    openssl req -new -newkey rsa:2048 -nodes -keyout "$1.key" -subj "$2" -out "$1.csr" 2>/dev/null
    printf 'subjectAltName=%s\nextendedKeyUsage=%s\nbasicConstraints=CA:false\nkeyUsage=critical,digitalSignature,keyEncipherment\n' "$3" "$4" > "$1.ext"
    openssl x509 -req -in "$1.csr" -CA "$5.pem" -CAkey "$5.key" -CAcreateserial -sha256 \
        -not_before "$start" -not_after "$end" -extfile "$1.ext" -out "$1.pem" 2>/dev/null
    rm -f "$1.csr" "$1.ext" "$5.srl"
}
ca keel-ca "/O=Keel Fixtures/CN=Keel Fixture CA"
ca other-ca "/O=Other Fixtures/CN=Other Fixture CA"
leaf server "/CN=redis.keel.test" "DNS:redis.keel.test" serverAuth keel-ca
leaf client "/CN=keel-client" "DNS:keel-client" clientAuth keel-ca
openssl req -x509 -new -newkey rsa:2048 -nodes -keyout self-signed.key -subj "/CN=self-signed.keel.test" -sha256 \
    -not_before "$start" -not_after "$end" -addext subjectAltName=DNS:self-signed.keel.test,DNS:localhost,IP:127.0.0.1 \
    -addext extendedKeyUsage=serverAuth -out self-signed.pem 2>/dev/null
# Client key variants for the importer: PKCS#8 (from req), PKCS#1, encrypted PKCS#8 (PBES2/AES-256), EC pair, .p12.
openssl pkey -in client.key -traditional -out client-pkcs1.key 2>/dev/null
openssl pkcs8 -topk8 -in client.key -v2 aes-256-cbc -v2prf hmacWithSHA256 -passout pass:keel-fixture -out client-encrypted.key
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout client-ec.key -subj "/CN=keel-client-ec" -out client-ec.csr 2>/dev/null
printf 'extendedKeyUsage=clientAuth\n' > client-ec.ext
openssl x509 -req -in client-ec.csr -CA keel-ca.pem -CAkey keel-ca.key -CAcreateserial -sha256 -not_before "$start" -not_after "$end" -extfile client-ec.ext -out client-ec.pem 2>/dev/null
rm -f client-ec.csr client-ec.ext keel-ca.srl
openssl pkcs12 -export -in client.pem -inkey client.key -certfile keel-ca.pem -name keel-client -passout pass:keel-fixture \
    -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 -out client.p12
cat keel-ca.pem other-ca.pem > bundle.pem
# The CA keys are only needed to sign the files above; keeping them out of the repository means no one can mint more.
rm -f keel-ca.key other-ca.key
