#!/usr/bin/env python3
"""Keel's performance benchmarks (KEEL-047, NFR-PF01–PF08, NFR-RS01) with evidence and a regression gate.

Three groups, each in an optimized build (`-c release -Xswiftc -enable-testing`), repeated `--runs` times (median):

  xctest  KeelCoreTests performance tests over in-memory fake servers: SCAN ingestion and tree build of 1M keys,
          local filter, first page of huge values, console formatting, index memory per key.
  live    KeelIntegrationTests.BrowserBenchmarkTests against a disposable server this script starts and seeds:
          1M and 10M keys in db 0 (SCAN ingestion, tree rebuild and expand, filter, editor header, memory) and large
          values in db 1 (hash 1M fields, list 10M items, set, sorted set and stream of 1M, 64 MiB string).
  launch  The release app launched with 200 saved profiles (`--state-directory`), timed from process start to the
          first sidebar render (`KEEL_LAUNCH_METRICS`); the first launch after a build (macOS checks a new binary
          once) is recorded apart. Needs a logged-in GUI session; skip it with --skip-launch.

The server is a container (`--image`, Docker) or a local binary (`--redis-server PATH`); either listens on loopback
only, keeps nothing on disk and is removed afterwards. The script never connects to any other server.

Evidence goes to .build/bench/evidence.json (and a timestamped copy): machine, server, every metric with its samples,
NFR target, baseline and change, the checks still pending by hand, and the verdict. The job fails (exit 1) when a
metric misses its NFR target, a benchmark test fails, or a metric regressed by more than --threshold (20%) against
release/bench-baseline.json for this architecture. --update-baseline records this run as the new baseline. Gate on
the default median of 3 runs: a single run (--quick, --runs 1) can swing more than 20% on a busy machine.

    python3 scripts/bench-browser.py --redis-server /opt/homebrew/bin/redis-server
    python3 scripts/bench-browser.py --quick --skip-launch          # 1M keys only, one run, container server
"""

import argparse
import datetime
import json
import os
import platform
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, ".build", "bench")
BASELINE = os.path.join(ROOT, "release", "bench-baseline.json")
SWIFT_FLAGS = ["-c", "release", "-Xswiftc", "-enable-testing"]
SIZES = {"1m": 1_000_000, "10m": 10_000_000}
MIB = 1_048_576

XCTEST_FILTER = (r"KeelCoreTests\.((ScanIngestion|TreeBuild|ValueOpen|LocalFilter|NamespaceTree|ConsoleRender)PerformanceTests"
                 r"|KeyIndexMemoryTests)")

# metric (or prefix ending in "_") -> (NFR, target). Targets are for Apple silicon at 1M keys on a local server;
# metrics without one (the 10M runs, heap growth) are recorded for the regression check only.
TARGETS = {
    "launch.first_sidebar_render_200_profiles": ("NFR-PF01", 1.0),
    "live.1m.row_header": ("NFR-PF02", 0.1),
    "xctest.scan_ingestion_1m": ("NFR-PF03", 15.0),
    "live.1m.scan_ingestion": ("NFR-PF03", 15.0),
    "xctest.tree_rebuild_1m": ("NFR-PF04", 2.0),
    "xctest.namespace_tree_build_1m": ("NFR-PF04", 2.0),
    "live.1m.tree_rebuild": ("NFR-PF04", 2.0),
    "xctest.tree_expand_1m": ("NFR-PF04", 0.2),
    "xctest.namespace_tree_expand_1m": ("NFR-PF04", 0.2),
    "live.1m.tree_expand": ("NFR-PF04", 0.2),
    "xctest.filter_first_results_1m": ("NFR-PF05", 0.15),
    "live.1m.filter_first_results": ("NFR-PF05", 0.15),
    "xctest.filter_complete_1m": ("NFR-PF05", 1.0),
    "live.1m.filter_complete": ("NFR-PF05", 1.0),
    "xctest.value_open_": ("NFR-PF06", 0.3),
    "live.value_open_": ("NFR-PF06", 0.3),
    "xctest.console_render_10k": ("NFR-PF08", 0.5),
    "xctest.index_overhead_per_key": ("NFR-RS01", 120),
    "live.1m.index_overhead_per_key": ("NFR-RS01", 120),
    "live.10m.index_overhead_per_key": ("NFR-RS01", 120),
    "xctest.index_and_tree_1m_projected": ("NFR-RS01", 200 * MIB),
    "live.1m.index_and_tree_bytes": ("NFR-RS01", 200 * MIB),
}
# Intel's launch budget (NFR-PF01); every other target is the same on both.
INTEL_TARGETS = {"launch.first_sidebar_render_200_profiles": 2.0}
# Changes smaller than this are timer noise, not regressions, whatever the percentage (a 2 ms open going to 3 ms).
NOISE_FLOOR = {"s": 0.005, "bytes": 0.0}
# Recorded for the evidence only: macOS's first-run check of a new binary varies too much to gate on.
INFORMATIONAL = {"launch.first_after_build"}

PENDING = [
    {"nfr": "NFR-PF02", "check": "Scrolling 1M keys (flat and tree) holds frame rate: Instruments Animation Hitches, hitch ratio < 5 ms/s."},
    {"nfr": "NFR-PF03", "check": "Main-thread work < 8 ms per frame while 1M keys stream in (Instruments Time Profiler / hitches)."},
    {"nfr": "NFR-PF07", "check": "Idle protocol trace: 60 s of an idle connected tab sends no commands (MONITOR on the server)."},
    {"nfr": "NFR-PF08", "check": "MONITOR at 50,000 lines/s doesn't freeze the UI; the console text view lays out a 10,000-element reply."},
]
# Launch evidence is from fresh state but a warm file cache; a true cold launch (after a restart or `sudo purge`) is by hand.
LAUNCH_PENDING = {"nfr": "NFR-PF01", "check": "Cold launch with an empty file cache (after a restart or `sudo purge`), 200 profiles: < 1.0 s."}

# One Lua script seeds everything, a batch per EVAL so no single call blocks the server for long. Keys in db 0 are the
# shape the XCTest fakes use: half in one wide folder, half over 1,000 × 10 nested folders, ~30 bytes each.
SEED = """
local kind, key, a, b = ARGV[1], ARGV[2], tonumber(ARGV[3]), tonumber(ARGV[4])
if kind == 'keys' then
  for i = a, b - 1 do
    if i % 2 == 0 then redis.call('SET', string.format('session:%09d:token', i), '1')
    else redis.call('SET', string.format('user:%04d:%02d:cart:%09d', i % 1000, i % 10, i), '1') end
  end
  return b - a
end
local chunk = {}
local command = ({hash = 'HSET', list = 'RPUSH', set = 'SADD', zset = 'ZADD'})[kind]
local function flush()
  if #chunk > 0 then redis.call(command, key, unpack(chunk)); chunk = {} end
end
for i = a, b - 1 do
  if kind == 'hash' then chunk[#chunk + 1] = 'field:' .. i; chunk[#chunk + 1] = 'value:' .. i
  elseif kind == 'list' then chunk[#chunk + 1] = 'item:' .. i
  elseif kind == 'set' then chunk[#chunk + 1] = 'member:' .. i
  elseif kind == 'zset' then chunk[#chunk + 1] = i; chunk[#chunk + 1] = 'member:' .. i
  elseif kind == 'stream' then redis.call('XADD', key, (i + 1) .. '-1', 'field', 'value:' .. i) end
  if #chunk >= 1000 then flush() end
end
flush()
return b - a
"""
VALUES = [("hash", "bench:hash", 1_000_000), ("list", "bench:list", 10_000_000), ("set", "bench:set", 1_000_000),
          ("zset", "bench:zset", 1_000_000), ("stream", "bench:stream", 1_000_000)]
BATCH = 100_000


# MARK: - A minimal RESP client for seeding


def encode(args):
    out = b"*%d\r\n" % len(args)
    for arg in args:
        data = arg if isinstance(arg, bytes) else str(arg).encode()
        out += b"$%d\r\n%s\r\n" % (len(data), data)
    return out


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=600)
        self.buffer = b""

    def _line(self):
        while b"\r\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("server closed the connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\r\n", 1)
        return line

    def _exact(self, count):
        while len(self.buffer) < count + 2:
            chunk = self.sock.recv(max(65536, count))
            if not chunk:
                raise EOFError("server closed the connection")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count + 2:]
        return data

    def _reply(self):
        line = self._line()
        kind, body = line[:1], line[1:]
        if kind == b"-":
            raise RuntimeError(body.decode(errors="replace"))
        if kind == b":":
            return int(body)
        if kind == b"$":
            return None if body == b"-1" else self._exact(int(body))
        if kind == b"*":
            return None if body == b"-1" else [self._reply() for _ in range(int(body))]
        return body

    def call(self, *args):
        self.sock.sendall(encode(args))
        return self._reply()

    def close(self):
        self.sock.close()


# MARK: - Server


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for(port, process=None):
    for _ in range(200):
        if process is not None and process.poll() is not None:
            break  # it exited (the port was taken in the meantime?): never fall back to whatever answers there
        client = None
        try:
            client = Client(port)
            if client.call("PING") == b"PONG":
                return client
            client.close()
        except (OSError, EOFError, RuntimeError):
            if client is not None:
                client.close()
            time.sleep(0.05)
    sys.exit(f"the benchmark server on port {port} didn't start")


class Server:
    """A throwaway server on loopback: a local binary in a temporary folder, or a Docker container."""

    def __init__(self, options):
        self.process = self.container = self.workdir = None
        try:
            self._start(options)
        except BaseException:
            self.stop()  # a failed or interrupted start leaves no server, container or folder behind
            raise

    def _start(self, options):
        if options.redis_server:
            self.port, self.workdir = free_port(), tempfile.mkdtemp(prefix="keel-bench-")
            self.process = subprocess.Popen(
                [options.redis_server, "--port", str(self.port), "--bind", "127.0.0.1", "--dir", self.workdir, "--save", "",
                 "--appendonly", "no"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.description = options.redis_server
        else:
            if shutil.which("docker") is None:
                sys.exit("docker isn't installed; pass --redis-server PATH to use a local redis-server instead")
            try:
                subprocess.run(["docker", "info"], capture_output=True, check=True, timeout=20)
            except (subprocess.SubprocessError, OSError):
                sys.exit("the Docker daemon isn't answering; start it or pass --redis-server PATH")
            self.container = subprocess.run(
                ["docker", "run", "-d", "--rm", "-p", "127.0.0.1::6379", options.image, "--save", "", "--appendonly", "no"],
                capture_output=True, check=True, text=True).stdout.strip()
            mapping = subprocess.run(["docker", "port", self.container, "6379/tcp"], capture_output=True, check=True, text=True).stdout
            self.port = int(mapping.splitlines()[0].rsplit(":", 1)[1])
            self.description = options.image
        client = wait_for(self.port, self.process)
        info = client.call("INFO", "server").decode()
        client.close()
        fields = dict(line.split(":", 1) for line in info.splitlines() if ":" in line)
        # The seeding sends FLUSHDB: make sure the server on this port is the one started here, not another that took it.
        if self.process and fields.get("process_id", "").strip() != str(self.process.pid):
            sys.exit(f"port {self.port} is answered by a server this script didn't start; not touching it")
        self.version = fields.get("valkey_version") or fields.get("redis_version") or "unknown"

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.container:
            subprocess.run(["docker", "rm", "-f", self.container], capture_output=True, check=False)
        if self.workdir:
            shutil.rmtree(self.workdir, ignore_errors=True)


def seed(client, kind, key, total):
    for start in range(0, total, BATCH):
        client.call("EVAL", SEED, 0, kind, key, start, min(start + BATCH, total))


def seed_keys(port, count):
    started = time.monotonic()
    client = Client(port)
    client.call("FLUSHDB")
    seed(client, "keys", "", count)
    if client.call("DBSIZE") != count:
        sys.exit(f"seeding left {client.call('DBSIZE'):,} keys in db 0, expected {count:,}")
    client.close()
    print(f"  seeded {count:,} keys in {time.monotonic() - started:.1f} s")


def seed_values(port):
    started = time.monotonic()
    client = Client(port)
    client.call("SELECT", 1)
    client.call("FLUSHDB")
    for kind, key, total in VALUES:
        seed(client, kind, key, total)
    client.call("SETRANGE", "bench:string", 64 * MIB - 1, "x")
    client.close()
    print(f"  seeded large values in db 1 in {time.monotonic() - started:.1f} s")


# MARK: - Running the benchmarks


def swift_test(filter_, env, label):
    """Runs one filtered `swift test` in the optimized build; returns the metrics it recorded and whether it passed."""
    fd, path = tempfile.mkstemp(prefix="keel-bench-", suffix=".jsonl")
    os.close(fd)
    try:
        result = subprocess.run(["swift", "test", *SWIFT_FLAGS, "--skip-build", "--filter", filter_], cwd=ROOT,
                                env={**os.environ, **env, "KEEL_BENCH_OUTPUT": path}, capture_output=True, text=True, check=False)
        with open(path, encoding="utf-8") as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
    finally:
        os.unlink(path)
    if result.returncode != 0:
        failures = [line for line in result.stdout.splitlines() if "error:" in line or "failed" in line]
        print(f"  {label}: swift test failed\n    " + "\n    ".join(failures[-20:]), file=sys.stderr)
    return lines, result.returncode == 0


def launch_once(binary, template):
    """One launch with a fresh copy of the 200-profile state; the seconds to the first sidebar render, or None."""
    state = tempfile.mkdtemp(prefix="keel-launch-")
    report = os.path.join(tempfile.mkdtemp(prefix="keel-launch-report-"), "launch.json")
    try:
        shutil.rmtree(state)  # mkdtemp only reserved a unique name: copytree needs the target absent
        shutil.copytree(template, state)
        os.chmod(state, 0o700)
        app = subprocess.Popen([binary, "--state-directory", state], env={**os.environ, "KEEL_LAUNCH_METRICS": report},
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 30
            while not os.path.exists(report) and time.monotonic() < deadline and app.poll() is None:
                time.sleep(0.05)
        finally:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
        if not os.path.exists(report):
            return None
        with open(report, encoding="utf-8") as handle:
            return json.load(handle)["first_sidebar_render_seconds"]
    finally:
        shutil.rmtree(state, ignore_errors=True)
        shutil.rmtree(os.path.dirname(report), ignore_errors=True)


# MARK: - Evidence


def target_for(metric, arch):
    if arch == "x86_64" and metric in INTEL_TARGETS:
        return TARGETS[metric][0], INTEL_TARGETS[metric]
    if metric in TARGETS:
        return TARGETS[metric]
    for prefix, value in TARGETS.items():
        if prefix.endswith("_") and metric.startswith(prefix):
            return value
    return None, None


def command_output(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, check=True, cwd=ROOT).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return None


def machine():
    memory = command_output("sysctl", "-n", "hw.memsize")
    return {
        "arch": platform.machine(),
        "model": command_output("sysctl", "-n", "hw.model"),
        "cpu": command_output("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_bytes": int(memory) if memory else None,
        "macos": command_output("sw_vers", "-productVersion"),
    }


def evaluate(samples, units, arch, baseline, threshold):
    metrics, failures = {}, []
    for name in sorted(samples):
        values, unit = samples[name], units[name]
        value = statistics.median(values)
        nfr, target = target_for(name, arch)
        within = None if target is None else value < target
        base = baseline.get(name)
        change = None if not base else value / base - 1
        regression = name not in INFORMATIONAL and bool(base) and value > base * (1 + threshold) and value - base > NOISE_FLOOR.get(unit, 0)
        metrics[name] = {"value": value, "unit": unit, "samples": values, "nfr": nfr, "target": target, "within_target": within,
                         "baseline": base, "change": change, "regression": regression}
        if within is False:
            failures.append(f"{name}: {value:.4g} {unit} misses the {nfr} target {target:.4g} {unit}")
        if regression:
            failures.append(f"{name}: {value:.4g} {unit} is {change:+.0%} against the baseline {base:.4g} {unit}")
    return metrics, failures


def groups_run(options, sizes):
    """Metric-name prefixes this invocation measures."""
    groups = [] if options.skip_xctest else ["xctest."]
    if not options.skip_live:
        groups += [f"live.{size}." for size in sizes] + ["live.value_open_"]
    return tuple(groups + ([] if options.skip_launch else ["launch."]))


def missing_metrics(samples, baseline, groups):
    """Metrics this run should have measured (an NFR target or a baseline in a group it ran) but didn't: a renamed,
    skipped or crashed benchmark must fail the job, not slip past the targets and the regression check."""
    expected = {name for name in [*baseline, *(n for n in TARGETS if not n.endswith("_"))] if name not in INFORMATIONAL}
    return sorted(name for name in expected if name.startswith(groups) and name not in samples) if groups else []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--quick", action="store_true", help="1M keys only and a single run")
    parser.add_argument("--runs", type=int, help="repetitions per benchmark (median); default 3, 1 with --quick")
    parser.add_argument("--sizes", default=None, help="comma-separated key counts from 1m,10m; default both, 1m with --quick")
    server = parser.add_mutually_exclusive_group()
    server.add_argument("--redis-server", help="local redis-server/valkey-server binary instead of a container")
    server.add_argument("--image", default="redis:7.4", help="container image for the live benchmarks (default redis:7.4)")
    parser.add_argument("--skip-xctest", action="store_true")
    parser.add_argument("--skip-live", action="store_true")
    parser.add_argument("--skip-launch", action="store_true", help="no app launch (headless CI)")
    parser.add_argument("--threshold", type=float, default=0.20, help="regression that fails the job (default 0.20)")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--update-baseline", action="store_true", help="record this run as this architecture's baseline")
    parser.add_argument("--out", default=OUT)
    options = parser.parse_args()
    runs = options.runs or (1 if options.quick else 3)
    sizes = (options.sizes or ("1m" if options.quick else "1m,10m")).split(",")
    if any(size not in SIZES for size in sizes):
        parser.error(f"--sizes takes {', '.join(SIZES)}")
    arch = platform.machine()

    print("Building (release, testable)…")
    if subprocess.run(["swift", "build", *SWIFT_FLAGS, "--build-tests"], cwd=ROOT, check=False).returncode != 0:
        sys.exit("the optimized build failed")
    samples, units, test_failures, server_description, launch_samples = {}, {}, [], None, []

    def collect(lines):
        for line in lines:
            samples.setdefault(line["metric"], []).append(line["value"])
            units[line["metric"]] = line["unit"]

    if not options.skip_xctest:
        for run in range(runs):
            print(f"xctest run {run + 1}/{runs}…")
            lines, passed = swift_test(XCTEST_FILTER, {}, "xctest")
            collect(lines)
            if not passed:
                test_failures.append(f"xctest run {run + 1}: a performance test failed")

    if not options.skip_live:
        bench = Server(options)
        server_description = f"{bench.description} ({bench.version})"
        try:
            print(f"Live benchmarks against {server_description} on 127.0.0.1:{bench.port}")
            for index, size in enumerate(sizes):
                seed_keys(bench.port, SIZES[size])
                if index == 0:
                    seed_values(bench.port)
                env = {"KEEL_BENCH": "1", "KEEL_BENCH_REDIS_PORT": str(bench.port), "KEEL_BENCH_KEYS": str(SIZES[size]),
                       "KEEL_BENCH_LABEL": size, "KEEL_BENCH_VALUES": "1" if index == 0 else "0"}
                for run in range(runs):
                    print(f"live {size} run {run + 1}/{runs}…")
                    lines, passed = swift_test(r"KeelIntegrationTests\.BrowserBenchmarkTests", env, f"live {size}")
                    collect(lines)
                    if not passed:
                        test_failures.append(f"live {size} run {run + 1}: a benchmark test failed")
        finally:
            bench.stop()

    if not options.skip_launch:
        bin_path = command_output("swift", "build", *SWIFT_FLAGS, "--show-bin-path")
        if not bin_path:
            sys.exit("couldn't find the optimized build's binary folder")
        binary = os.path.join(bin_path, "Keel")
        template = tempfile.mkdtemp(prefix="keel-launch-state-")
        try:
            os.chmod(template, 0o700)
            _, passed = swift_test(r"KeelIntegrationTests\.LaunchStateBenchmarkTests", {"KEEL_BENCH_LAUNCH_STATE": template}, "launch state")
            if not passed or not os.path.exists(os.path.join(template, "connections.json")):
                test_failures.append("launch: writing the 200-profile state failed")
            else:
                # The first launch of a freshly linked binary includes macOS's one-time check of a new executable
                # (~1 s, once per build, not per launch); it is recorded on its own without a target. NFR-PF01 is
                # judged on the slowest of the launches after it, with nothing of Keel's cached between them.
                launches = []
                for run in range(runs + 2):
                    print(f"launch {run + 1}/{runs + 2}…")
                    seconds = launch_once(binary, template)
                    if seconds is None:
                        test_failures.append(f"launch {run + 1}: no sidebar render within 30 s")
                    else:
                        launches.append(seconds)
                if launches:
                    samples["launch.first_after_build"], units["launch.first_after_build"] = launches[:1], "s"
                if len(launches) > 1:
                    samples["launch.first_sidebar_render_200_profiles"] = [max(launches[1:])]
                    units["launch.first_sidebar_render_200_profiles"] = "s"
                    launch_samples = launches
        finally:
            shutil.rmtree(template, ignore_errors=True)

    try:
        with open(options.baseline, encoding="utf-8") as handle:
            baselines = json.load(handle)
    except FileNotFoundError:
        baselines = {"schema": 1, "machines": {}}
    baseline = (baselines.get("machines", {}).get(arch) or {}).get("metrics", {})
    metrics, failures = evaluate(samples, units, arch, baseline, options.threshold)
    groups = groups_run(options, sizes)
    missing = missing_metrics(samples, baseline, groups)
    failures = test_failures + failures + [f"{name}: not measured in this run (it has an NFR target or a baseline)" for name in missing]

    pending = list(PENDING) + ([] if options.skip_launch else [LAUNCH_PENDING])
    if arch != "x86_64":
        pending.append({"nfr": "NFR-PF01–PF08", "check": "Intel reference Mac (16 GB): run this script there; pending until hardware is available."})
    for skipped, what in ((options.skip_xctest, "xctest"), (options.skip_live, "live"), (options.skip_launch, "launch (NFR-PF01)")):
        if skipped:
            pending.append({"nfr": "-", "check": f"{what} benchmarks were skipped in this run."})
    dirty = command_output("git", "status", "--porcelain")
    evidence = {
        "schema": 1,
        "story": "KEEL-047",
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "git": {"commit": command_output("git", "rev-parse", "HEAD"), "dirty": bool(dirty)},
        "machine": machine(),
        "server": server_description,
        "sizes": sizes if not options.skip_live else [],
        "runs": runs,
        "launch_samples": launch_samples,
        "threshold": options.threshold,
        "baseline": os.path.relpath(options.baseline, ROOT) if baseline else None,
        "metrics": metrics,
        "pending": pending,
        "missing": missing,
        "failures": failures,
        "result": "fail" if failures else "pass",
    }
    os.makedirs(options.out, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    for name in ("evidence.json", f"evidence-{stamp}.json"):
        with open(os.path.join(options.out, name), "w", encoding="utf-8") as handle:
            json.dump(evidence, handle, indent=2, sort_keys=True)
            handle.write("\n")

    if options.update_baseline:
        baselines.setdefault("machines", {})[arch] = {
            "machine": evidence["machine"], "recorded": evidence["generated"], "commit": evidence["git"]["commit"],
            # Groups this run skipped (--quick, --skip-*) keep their previous baseline rather than losing their gate.
            "metrics": {**{name: value for name, value in baseline.items() if not name.startswith(groups)},
                        **{name: metric["value"] for name, metric in metrics.items()}}}
        with open(options.baseline, "w", encoding="utf-8") as handle:
            json.dump(baselines, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print(f"Baseline for {arch} updated in {os.path.relpath(options.baseline, ROOT)}")

    print(f"\n{'metric':48} {'median':>12} {'target':>10} {'change':>8}")
    for name, metric in metrics.items():
        if metric["unit"] == "s":
            scale, suffix = 1, " s"
        elif metric["value"] > MIB:
            scale, suffix = 1 / MIB, " MiB"
        else:
            scale, suffix = 1, " B"
        target = "" if metric["target"] is None else f"{metric['target'] * scale:.4g}"
        change = "" if metric["change"] is None else f"{metric['change']:+.0%}"
        print(f"{name:48} {metric['value'] * scale:>10.4g}{suffix:2} {target:>10} {change:>8}{'  REGRESSION' if metric['regression'] else ''}")
    if not baseline:
        print(f"\nNo baseline for {arch} in {os.path.relpath(options.baseline, ROOT)}: nothing to compare (record one with --update-baseline).")
    print(f"\nEvidence: {os.path.relpath(os.path.join(options.out, 'evidence.json'), ROOT)}")
    if failures:
        print("FAILED:\n  " + "\n  ".join(failures), file=sys.stderr)
        sys.exit(1)
    print("All benchmarks within their targets and the regression threshold.")


if __name__ == "__main__":
    main()
