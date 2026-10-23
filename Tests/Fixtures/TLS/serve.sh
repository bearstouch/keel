#!/bin/sh
# Starts the KEEL-007 TLS fixture servers on loopback until KEEL-048's container matrix replaces them:
#   6380 private CA (server cert for redis.keel.test only), 6381 the same with client certificates required,
#   6382 self-signed. Needs a TLS-enabled redis-server (Homebrew's is). Stop with: serve.sh stop
# Then: KEEL_INTEGRATION=1 swift test --filter KeelIntegrationTests.TLSIntegrationTests
set -eu
cd "$(dirname "$0")"
run="${TMPDIR:-/tmp}/keel-tls-fixtures"
if [ "${1:-}" = stop ]; then
    for pid in "$run"/*.pid; do [ -f "$pid" ] && kill "$(cat "$pid")" 2>/dev/null || true; done
    rm -rf "$run"; exit 0
fi
mkdir -p "$run"
serve() { # port cert key client-auth
    redis-server --port 0 --tls-port "$1" --bind 127.0.0.1 --tls-cert-file "$PWD/$2" --tls-key-file "$PWD/$3" \
        --tls-ca-cert-file "$PWD/keel-ca.pem" --tls-auth-clients "$4" --save "" --appendonly no \
        --daemonize yes --pidfile "$run/$1.pid" --logfile "$run/$1.log"
}
serve 6380 server.pem server.key no
serve 6381 server.pem server.key yes
serve 6382 self-signed.pem self-signed.key no
echo "TLS fixtures on 6380 (private CA), 6381 (client auth), 6382 (self-signed); start a disposable plain server and pass its port as KEEL_INTEGRATION_REDIS_PORT"
