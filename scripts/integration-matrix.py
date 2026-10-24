#!/usr/bin/env python3
"""Keel's integration matrix (KEEL-048, NFR-QA03, INT-01): KeelIntegrationTests against pinned containers.

Starts every server in Tests/Fixtures/Integration/matrix.json (Redis 6.0, 6.2, 7.4, 8.x, Valkey 7.2, 8.x, 9.x,
Dragonfly 1.x, each pinned by image digest), a Redis 5 container that must be refused, three TLS servers (private
CA, client certificate required, self-signed; Tests/Fixtures/TLS) and an sshd bastion with Redis on its own loopback
(Tests/Fixtures/SSH/Dockerfile, fresh keys per run). Every port is published on 127.0.0.1 only and the tests receive
ports, never hosts, so nothing outside these containers is reached (AC3). Then it runs

    swift test --filter KeelIntegrationTests

with KEEL_INTEGRATION=1 and KEEL_INTEGRATION_REQUIRED=1, so a missing fixture fails instead of skipping. Containers,
keys and the temporary folder are removed afterwards, also on failure or Ctrl-C. A summary of the images and the
outcome goes to .build/integration/evidence.json. The exit status is the test run's (1 when setup fails).

    python3 scripts/integration-matrix.py                       # the whole matrix (needs Docker)
    python3 scripts/integration-matrix.py --servers redis-7.4,valkey-9.x --filter ServerMatrixTests
"""

import argparse
import datetime
import json
import os
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MATRIX = os.path.join(ROOT, "Tests", "Fixtures", "Integration", "matrix.json")
TLS_FIXTURES = os.path.join(ROOT, "Tests", "Fixtures", "TLS")
SSH_FIXTURES = os.path.join(ROOT, "Tests", "Fixtures", "SSH")
OUT = os.path.join(ROOT, ".build", "integration", "evidence.json")
LABEL = "com.bearstouch.keel.integration=1"
# The server the KEEL-005…007 tests (pipelining, ACL handshake, TLS-to-plain) use when the matrix runs them.
LEGACY_SERVER = "redis-7.4"
# Redis/Valkey arguments for an ephemeral container: nothing on disk, since snapshots would only cost time.
NO_PERSISTENCE = ["--save", "", "--appendonly", "no"]
TLS_FILES = ["server.pem", "server.key", "self-signed.pem", "self-signed.key", "keel-ca.pem", "client.pem", "client.key"]


def docker(*arguments, check=True, timeout=None):
    return subprocess.run(["docker", *arguments], capture_output=True, text=True, check=check, timeout=timeout)


class Matrix:
    """Everything this run started: containers, the sshd image tag and the temporary folder."""

    def __init__(self):
        # Under the checkout, not $TMPDIR: Colima shares only the home folder with its VM, so a bind mount from
        # /var/folders would arrive empty (Docker Desktop shares /Users too).
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        self.containers, self.workdir = [], tempfile.mkdtemp(prefix="run-", dir=os.path.dirname(OUT))
        os.chmod(self.workdir, 0o700)

    def run(self, name, image, arguments, container_port, mounts=()):
        """One container with `container_port` published on a free loopback port; returns that port."""
        command = ["run", "-d", "--rm", "--label", LABEL, "--name", f"keel-it-{name}-{os.getpid()}", "-p", f"127.0.0.1::{container_port}"]
        for source, target in mounts:
            command += ["-v", f"{source}:{target}:ro"]
        container = docker(*command, image, *arguments).stdout.strip()
        self.containers.append(container)
        mapping = docker("port", container, f"{container_port}/tcp").stdout
        # `docker port` may list an IPv6 line too; the IPv4 loopback one is what was asked for.
        _, port = next(line.rsplit(":", 1) for line in mapping.splitlines() if line.startswith("127.0.0.1:"))
        return int(port)

    def logs(self, container):
        return docker("logs", "--tail", "40", container, check=False).stdout

    def stop(self):
        # Also by name: a container whose `docker run` was interrupted before its id came back.
        named = docker("ps", "-aq", "--filter", f"label={LABEL}", "--filter", f"name=keel-it-.*-{os.getpid()}$", check=False).stdout.split()
        for container in dict.fromkeys(self.containers + named):
            docker("rm", "-f", container, check=False)
        self.containers = []
        shutil.rmtree(self.workdir, ignore_errors=True)


def wait_until(probe, what, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if probe():
                return
        except OSError:
            pass
        time.sleep(0.2)
    raise RuntimeError(f"{what} didn't become ready within {seconds} s")


def ping(port, tls=None):
    """True once the server answers PING (+PONG); for TLS, with the fixture client certificate and no verification."""
    with socket.create_connection(("127.0.0.1", port), timeout=2) as raw:
        stream = tls.wrap_socket(raw) if tls else raw
        stream.sendall(b"*1\r\n$4\r\nPING\r\n")
        return stream.recv(64).startswith(b"+PONG")


def ssh_banner(port):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as stream:
        return stream.recv(64).startswith(b"SSH-")


def start_servers(matrix, manifest, names):
    """The engines under test plus the refused Redis 5; returns `[{name, kind, version, port}]` and Redis 5's port."""
    servers = []
    for server in manifest["servers"]:
        if names and server["name"] not in names:
            continue
        # Dragonfly takes its own flags: no snapshot file, and two threads.
        arguments = ["--proactor_threads=2", "--dbfilename="] if server["kind"] == "dragonfly" else NO_PERSISTENCE
        port = matrix.run(server["name"], server["image"], arguments, 6379)
        servers.append({"name": server["name"], "kind": server["kind"], "version": server["version"], "port": port})
    refused = manifest["refused"]
    refused_port = matrix.run(refused["name"], refused["image"], NO_PERSISTENCE, 6379)
    for server in servers + [{"name": refused["name"], "port": refused_port}]:
        wait_until(lambda: ping(server["port"]), server["name"])
    return servers, refused_port


def start_tls(matrix, manifest):
    """Three TLS servers from the KEEL-007 fixtures: private CA, the same requiring a client certificate, self-signed."""
    folder = os.path.join(matrix.workdir, "tls")
    os.mkdir(folder)
    for name in TLS_FILES:
        # World-readable copies: the image runs Redis as its own user, which can't read the checkout's files on Linux.
        shutil.copy(os.path.join(TLS_FIXTURES, name), folder)
        os.chmod(os.path.join(folder, name), 0o644)
    os.chmod(folder, 0o755)

    def tls_server(name, cert, key, client_auth):
        arguments = ["--port", "0", "--tls-port", "6380", "--tls-cert-file", f"/tls/{cert}", "--tls-key-file", f"/tls/{key}",
                     "--tls-ca-cert-file", "/tls/keel-ca.pem", "--tls-auth-clients", client_auth, *NO_PERSISTENCE]
        return matrix.run(name, manifest["tls"]["image"], arguments, 6380, mounts=[(folder, "/tls")])

    ports = {
        "KEEL_INTEGRATION_TLS_PORT": tls_server("tls-ca", "server.pem", "server.key", "no"),
        "KEEL_INTEGRATION_TLS_CLIENT_AUTH_PORT": tls_server("tls-client-auth", "server.pem", "server.key", "yes"),
        "KEEL_INTEGRATION_TLS_SELF_SIGNED_PORT": tls_server("tls-self-signed", "self-signed.pem", "self-signed.key", "no"),
    }
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname, context.verify_mode = False, ssl.CERT_NONE
    context.load_cert_chain(os.path.join(folder, "client.pem"), os.path.join(folder, "client.key"))
    for name, port in ports.items():
        wait_until(lambda: ping(port, context), name)
    return ports


def start_sshd(matrix, manifest):
    """The bastion: fresh host and client keys, the host key pinned in the fixture's own known_hosts (never ~/.ssh)."""
    folder, mount = os.path.join(matrix.workdir, "ssh"), os.path.join(matrix.workdir, "ssh-mount")
    os.mkdir(folder, 0o700)
    os.mkdir(mount, 0o755)
    for key in ["host_key", "client_key"]:
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "keel-integration", "-f", os.path.join(folder, key)], check=True)
    shutil.copy(os.path.join(folder, "host_key"), os.path.join(mount, "host_key"))
    shutil.copy(os.path.join(folder, "client_key.pub"), os.path.join(mount, "authorized_keys"))
    # The entrypoint installs the host key 0600 for sshd; the mounted copy only has to be readable by it.
    for name in ["host_key", "authorized_keys"]:
        os.chmod(os.path.join(mount, name), 0o644)

    sshd = manifest["sshd"]
    tag = "keel-integration-sshd:" + sshd["base"].rsplit(":", 1)[-1][:12]
    built = subprocess.run(["docker", "build", "-q", "-t", tag, "--build-arg", f"BASE={sshd['base']}", SSH_FIXTURES], capture_output=True, text=True)
    if built.returncode != 0:
        raise RuntimeError("building the sshd fixture failed:\n" + built.stderr)
    port = matrix.run("sshd", tag, [], 22, mounts=[(mount, "/fixture")])
    wait_until(lambda: ssh_banner(port), "sshd")

    host_key = open(os.path.join(folder, "host_key.pub")).read().split()[:2]
    with open(os.path.join(folder, "known_hosts"), "w") as known:
        known.write(f"[127.0.0.1]:{port} {' '.join(host_key)}\n")
    common = "  User keel\n  IdentitiesOnly yes\n"
    with open(os.path.join(folder, "client_config"), "w") as config:
        config.write(f"Host *\n  UserKnownHostsFile \"{folder}/known_hosts\"\n  GlobalKnownHostsFile /dev/null\n  BatchMode yes\n{common}")
    # KEEL-010: the host key is unknown here, so ssh asks through Keel's askpass.
    open(os.path.join(folder, "prompt_known_hosts"), "w").close()
    with open(os.path.join(folder, "prompt_config"), "w") as config:
        config.write(f"Host *\n  UserKnownHostsFile \"{folder}/prompt_known_hosts\"\n  GlobalKnownHostsFile /dev/null\n{common}")
    # sshd accepts connections before the entrypoint's Redis may be listening: wait for it through the container.
    container = matrix.containers[-1]
    wait_until(lambda: docker("exec", container, "redis-cli", "-p", "6379", "PING", check=False).stdout.strip() == "PONG", "Redis behind sshd")
    return {"KEEL_INTEGRATION_SSH_FIXTURE": folder, "KEEL_INTEGRATION_SSH_PORT": str(port), "KEEL_INTEGRATION_SSH_REDIS_PORT": "6379",
            "KEEL_INTEGRATION_SSH_USER": "keel"}


def write_evidence(path, manifest, servers, status, filter_):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    evidence = {
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "filter": filter_,
        "servers": [{**server, "image": next(s["image"] for s in manifest["servers"] if s["name"] == server["name"])} for server in servers],
        "refused": manifest["refused"]["image"],
        "tls": manifest["tls"]["image"],
        "sshd": manifest["sshd"]["base"],
        "status": "passed" if status == 0 else "failed",
    }
    with open(path, "w") as out:
        json.dump(evidence, out, indent=2)
        out.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--servers", help="comma-separated server names from matrix.json (default: all)")
    parser.add_argument("--filter", default="KeelIntegrationTests", help="swift test --filter (default KeelIntegrationTests)")
    parser.add_argument("--out", default=OUT)
    options = parser.parse_args()
    with open(MATRIX) as file:
        manifest = json.load(file)
    names = set(options.servers.split(",")) if options.servers else set()
    unknown = names - {server["name"] for server in manifest["servers"]}
    if unknown:
        parser.error(f"unknown servers: {', '.join(sorted(unknown))}")
    if shutil.which("docker") is None:
        sys.exit("docker isn't installed")
    try:
        docker("info", timeout=30)
    except (subprocess.SubprocessError, OSError):
        sys.exit("the Docker daemon isn't answering; start it first")

    # SIGTERM (a cancelled CI job) unwinds through `finally` like Ctrl-C, so no container outlives the run.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    matrix, status, servers = Matrix(), 1, []
    try:
        print("Starting containers…", flush=True)
        servers, refused_port = start_servers(matrix, manifest, names)
        environment = dict(os.environ)
        environment.update({
            "KEEL_INTEGRATION": "1",
            "KEEL_INTEGRATION_REQUIRED": "1",
            "KEEL_INTEGRATION_SERVERS": json.dumps(servers),
            "KEEL_INTEGRATION_REFUSED_PORT": str(refused_port),
        })
        # Prefer redis-7.4 for the older single-server tests; any engine will do when --servers leaves it out.
        legacy = next((server for server in servers if server["name"] == LEGACY_SERVER), servers[0] if servers else None)
        if legacy:
            environment["KEEL_INTEGRATION_REDIS_PORT"] = str(legacy["port"])
        environment.update(start_tls(matrix, manifest))
        environment.update(start_sshd(matrix, manifest))
        for server in servers:
            print(f"  {server['name']:<14} {server['kind']} {server['version']} on 127.0.0.1:{server['port']}")
        # keel-askpass must exist for the prompt relay tests, and `swift test` alone doesn't build executables.
        if subprocess.run(["swift", "build"], cwd=ROOT, check=False).returncode != 0:
            raise RuntimeError("swift build failed")
        print(f"Running swift test --filter {options.filter}…", flush=True)
        status = subprocess.run(["swift", "test", "--filter", options.filter], cwd=ROOT, env=environment, check=False).returncode
    except KeyboardInterrupt:
        print("interrupted; removing containers", file=sys.stderr)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        # A failed `docker` call carries its stderr; dump the containers' logs too, since readiness timeouts say little.
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else ""
        print(f"matrix setup failed: {error}\n{detail}", file=sys.stderr)
        for container in matrix.containers:
            print(matrix.logs(container), file=sys.stderr)
    finally:
        matrix.stop()
    write_evidence(options.out, manifest, servers, status, options.filter)
    print(f"Evidence: {os.path.relpath(options.out, ROOT)} ({'passed' if status == 0 else 'failed'})")
    sys.exit(status)


if __name__ == "__main__":
    main()
