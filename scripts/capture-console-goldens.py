#!/usr/bin/env python3
"""Capture the console golden fixtures (Tests/Fixtures/Console) from a real redis-cli (FR-CO03, NFR-QA04).

The script starts its own throwaway `redis-server` on a free loopback port in a temporary directory (debug commands
enabled, no persistence) — it never talks to a user's server. For every case and protocol it records:

    <name>.resp   the raw reply bytes, read from a plain socket (after `HELLO 3` for RESP3)
    <name>.txt    what `redis-cli -2|-3 --no-raw <args>` prints for the same command (redis-cli's TTY format)

and writes `cases.txt` (one `name<TAB>arguments` line per case) plus `VERSION` (the redis-cli that produced them).
Run it with the redis-cli whose output the fixtures should match, e.g.:

    python3 -I scripts/capture-console-goldens.py --redis-server /path/redis-server --redis-cli /path/redis-cli
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Tests", "Fixtures", "Console")

# Data every case reads; sent over the socket so binary values are exact.
SETUP = [
    ["SET", "plain", "hello"],
    ["SET", "bin", b"a\x00b"],
    ["SET", "escapes", b"q\"uote\\ \n\r\t\x07\x08 \xc3\xa9 \x7f"],
    ["SET", "empty", ""],
    ["RPUSH", "list"] + [f"item-{i}" for i in range(1, 13)],
    ["HSET", "hash", "f1", "v1", "f2", b"v\x002"],
    ["SADD", "set", "only"],
    ["ZADD", "zset", "1", "one", "1.5", "one-and-half", "inf", "infinite", "-2.25", "negative", "1e20", "huge", "0.000001", "tiny"],
    ["ZADD", "zsum", "0.1", "m"],
    ["ZINCRBY", "zsum", "0.2", "m"],
] + [["XADD", "stream", f"{i}-1", "field", f"value-{i}"] for i in range(1, 11)]

# name, arguments. Every reply must be deterministic for a fixed SETUP (no ids, clocks or addresses).
CASES = [
    ("status", ["PING"]),
    ("status-ok", ["SET", "scratch", "1"]),
    ("integer", ["DBSIZE"]),
    ("integer-negative", ["TTL", "plain"]),
    ("bulk", ["GET", "plain"]),
    ("bulk-binary", ["GET", "bin"]),
    ("bulk-escapes", ["GET", "escapes"]),
    ("bulk-empty", ["GET", "empty"]),
    ("nil", ["GET", "missing"]),
    ("error", ["INCR", "plain"]),
    ("error-wrongtype", ["LLEN", "plain"]),
    ("error-unknown", ["NOSUCHCOMMAND", "a", "b"]),
    ("empty-array", ["LRANGE", "missing", "0", "-1"]),
    ("array-padded", ["LRANGE", "list", "0", "-1"]),
    ("array-short", ["LRANGE", "list", "0", "2"]),
    ("hash", ["HGETALL", "hash"]),
    ("empty-hash", ["HGETALL", "missing"]),
    ("set", ["SMEMBERS", "set"]),
    ("empty-set", ["SMEMBERS", "missing"]),
    ("score-integral", ["ZSCORE", "zset", "one"]),
    ("score-fraction", ["ZSCORE", "zset", "one-and-half"]),
    ("score-inf", ["ZSCORE", "zset", "infinite"]),
    ("score-sum", ["ZSCORE", "zsum", "m"]),
    ("withscores", ["ZRANGE", "zset", "0", "-1", "WITHSCORES"]),
    ("nested", ["XRANGE", "stream", "-", "+"]),
    ("nested-deep", ["XINFO", "STREAM", "stream", "FULL"]),
    ("mget", ["MGET", "plain", "missing", "bin"]),
    ("command-docs", ["COMMAND", "DOCS", "GET"]),
    ("proto-true", ["DEBUG", "PROTOCOL", "true"]),
    ("proto-false", ["DEBUG", "PROTOCOL", "false"]),
    ("proto-double", ["DEBUG", "PROTOCOL", "double"]),
    ("proto-bignum", ["DEBUG", "PROTOCOL", "bignum"]),
    ("proto-null", ["DEBUG", "PROTOCOL", "null"]),
    ("proto-map", ["DEBUG", "PROTOCOL", "map"]),
    ("proto-set", ["DEBUG", "PROTOCOL", "set"]),
    ("proto-verbatim", ["DEBUG", "PROTOCOL", "verbatim"]),
    ("proto-attrib", ["DEBUG", "PROTOCOL", "attrib"]),
]


def encode(args):
    out = b"*%d\r\n" % len(args)
    for arg in args:
        data = arg if isinstance(arg, bytes) else arg.encode()
        out += b"$%d\r\n%s\r\n" % (len(data), data)
    return out


class Reader:
    """Reads exactly one RESP2/RESP3 reply and returns its raw bytes."""

    def __init__(self, sock):
        self.sock, self.buffer = sock, b""

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise EOFError("server closed the connection")
        self.buffer += chunk

    def _line(self):
        while b"\r\n" not in self.buffer:
            self._fill()
        line, self.buffer = self.buffer.split(b"\r\n", 1)
        return line + b"\r\n"

    def _exact(self, count):
        while len(self.buffer) < count:
            self._fill()
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def reply(self):
        line = self._line()
        kind, body = line[:1], line[1:-2]
        if kind in b"$!=" and body != b"-1":
            return line + self._exact(int(body) + 2)
        if kind in b"*~>" and body != b"-1":
            return line + b"".join(self.reply() for _ in range(int(body)))
        if kind in b"%|":
            return line + b"".join(self.reply() for _ in range(2 * int(body))) + (self.reply() if kind == b"|" else b"")
        return line


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--redis-server", required=True)
    parser.add_argument("--redis-cli", required=True)
    parser.add_argument("--out", default=OUTPUT)
    options = parser.parse_args()

    version = subprocess.run([options.redis_cli, "--version"], capture_output=True, check=True, text=True).stdout.strip()
    port, workdir = free_port(), tempfile.mkdtemp(prefix="keel-goldens-")
    server = subprocess.Popen(
        [options.redis_server, "--port", str(port), "--bind", "127.0.0.1", "--dir", workdir, "--save", "", "--appendonly", "no",
         "--enable-debug-command", "yes"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                connection = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                time.sleep(0.05)
        else:
            sys.exit("redis-server didn't start")
        reader = Reader(connection)
        for command in SETUP:
            connection.sendall(encode(command))
            reader.reply()
        connection.close()

        for protocol in (2, 3):
            folder = os.path.join(options.out, f"resp{protocol}")
            shutil.rmtree(folder, ignore_errors=True)
            os.makedirs(folder)
            for name, args in CASES:
                with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                    reader = Reader(sock)
                    if protocol == 3:
                        sock.sendall(encode(["HELLO", "3"]))
                        reader.reply()
                    sock.sendall(encode(args))
                    raw = reader.reply()
                printed = subprocess.run([options.redis_cli, "-p", str(port), f"-{protocol}", "--no-raw"] + args, capture_output=True, check=False)
                # redis-cli 7.2 exits on RESP3 big numbers ("Unknown reply type") and attributes; no golden for those.
                if printed.returncode != 0:
                    print(f"skipped resp{protocol}/{name}: {printed.stderr.decode(errors='replace').strip()}", file=sys.stderr)
                    continue
                with open(os.path.join(folder, name + ".resp"), "wb") as handle:
                    handle.write(raw)
                with open(os.path.join(folder, name + ".txt"), "wb") as handle:
                    handle.write(printed.stdout)
        with open(os.path.join(options.out, "cases.txt"), "w", encoding="utf-8") as handle:
            handle.writelines(f"{name}\t{' '.join(args)}\n" for name, args in CASES)
        with open(os.path.join(options.out, "VERSION"), "w", encoding="utf-8") as handle:
            handle.write(version + "\n")
    finally:
        server.terminate()
        server.wait()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
