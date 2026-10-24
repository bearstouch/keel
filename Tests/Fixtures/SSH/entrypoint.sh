#!/bin/sh
# Copies the mounted keys with the modes sshd insists on, starts Redis on the container's loopback only, then sshd.
set -eu
install -m 600 /fixture/host_key /etc/ssh/keel_host_key
install -m 644 /fixture/authorized_keys /etc/ssh/keel_authorized_keys
redis-server --bind 127.0.0.1 --port 6379 --save "" --appendonly no --daemonize yes --logfile /tmp/redis.log
exec /usr/sbin/sshd -D -e
