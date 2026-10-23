#!/bin/sh
# Starts the KEEL-009 tunnel fixture until KEEL-053's sshd container replaces it: an unprivileged OpenSSH server on
# 127.0.0.1:22422 (fresh host and client keys, key auth only) and a disposable redis-server on 127.0.0.1:26399 that is
# reached only through the tunnel. Writes a client ssh_config with the host key pinned in its own known_hosts file
# (never ~/.ssh). Stop with: serve.sh stop
# Then: KEEL_INTEGRATION=1 KEEL_INTEGRATION_SSH_FIXTURE="${TMPDIR:-/tmp}/keel-ssh-fixture" \
#       swift test --filter KeelIntegrationTests.TunnelIntegrationTests
set -eu
run="${TMPDIR:-/tmp}/keel-ssh-fixture"
if [ "${1:-}" = stop ]; then
    for pid in "$run"/*.pid; do [ -f "$pid" ] && kill "$(cat "$pid")" 2>/dev/null || true; done
    rm -rf "$run"; exit 0
fi
rm -rf "$run"; mkdir -m 700 "$run"
ssh-keygen -q -t ed25519 -N '' -f "$run/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$run/client_key"
cp "$run/client_key.pub" "$run/authorized_keys"
cat > "$run/sshd_config" <<CONFIG
Port 22422
ListenAddress 127.0.0.1
HostKey $run/host_key
AuthorizedKeysFile $run/authorized_keys
PidFile $run/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowTcpForwarding yes
CONFIG
echo "[127.0.0.1]:22422 $(cut -d' ' -f1-2 "$run/host_key.pub")" > "$run/known_hosts"
printf 'Host *\n  UserKnownHostsFile %s/known_hosts\n  IdentitiesOnly yes\n  BatchMode yes\n' "$run" > "$run/client_config"
/usr/sbin/sshd -f "$run/sshd_config" -E "$run/sshd.log"
redis-server --port 26399 --bind 127.0.0.1 --save "" --appendonly no --daemonize yes --pidfile "$run/redis.pid" --logfile "$run/redis.log"
echo "sshd on 127.0.0.1:22422, Redis behind it on 26399; fixture folder $run"
