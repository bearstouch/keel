# KEEL-048 sshd fixture: a bastion with Redis on its own loopback, reached only through `ssh -N` with a Unix-socket
# forward. scripts/integration-matrix.py builds it from the pinned base in Tests/Fixtures/Integration/matrix.json and
# mounts a fresh host key and authorized_keys at /fixture; key auth only, no passwords.
ARG BASE
FROM ${BASE}
RUN apk add --no-cache openssh-server redis \
    && adduser -D -s /bin/sh keel \
    # A locked account (`!`) is refused by sshd even with a key; `*` keeps password login impossible but allows keys.
    && sed -i 's/^keel:!/keel:*/' /etc/shadow
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
