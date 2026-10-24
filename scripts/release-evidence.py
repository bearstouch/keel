#!/usr/bin/env python3
"""Writes and checks dist/release-evidence.json for scripts/package-release.sh (MAC-10, MAC-11, KEEL-052).

  python3 -I scripts/release-evidence.py write --checks FILE --sums FILE --out FILE [--bench FILE] [--identity NAME]
  python3 -I scripts/release-evidence.py check FILE

`--checks` holds one check per line, `id<TAB>status<TAB>detail`, status passed, failed or skipped. `write` adds the
benchmark evidence under `performance`, the checksums from SHA256SUMS.txt and the channel, then checks the result.
Both commands exit 1 when the evidence can't be published as it says. The rules are ReleaseChecklist's in
Sources/KeelRelease/ReleaseEvidence.swift; ReleaseChecklistTests runs both on the same evidence.
"""
import argparse
import datetime
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATUSES = ("passed", "failed", "skipped")


def manifest():
    with open(os.path.join(ROOT, "release", "manifest.json"), encoding="utf-8") as handle:
        return json.load(handle)


def channel(checks):
    """A release only when every check passed; anything skipped is at most a pre-release."""
    return "release" if all(check["status"] == "passed" for check in checks) else "prerelease"


def problems(evidence, record):
    found = []
    if evidence.get("version") != record["version"]:
        found.append(f"Evidence is for {evidence.get('version')}, the manifest is {record['version']}.")
    checks = evidence.get("checks", [])
    ids = [check.get("id") for check in checks]
    found += [f"Missing check {name}." for name in record["releaseChecks"] if name not in ids]
    found += [f"Check {name} is recorded more than once." for name in set(ids) if ids.count(name) > 1]
    found += [f"Unknown check {name}." for name in ids if name not in record["releaseChecks"]]
    found += [f"Check {check['id']} failed: {check.get('detail', '')}" for check in checks if check.get("status") == "failed"]
    if evidence.get("channel") == "release" and channel(checks) != "release":
        found.append("A build with skipped checks can only be a pre-release.")
    if not evidence.get("artifacts"):
        found.append("No artifact checksums recorded.")
    return sorted(found)


def read_checks(path):
    checks = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            name, status, detail = (line.rstrip("\n").split("\t", 2) + ["", ""])[:3]
            if status not in STATUSES:
                sys.exit(f"release-evidence: check {name} has status {status!r}")
            checks.append({"id": name, "status": status, "detail": detail})
    return checks


def read_sums(path):
    sums = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                digest, _, name = line.strip().partition("  ")
                if digest and name:
                    sums[name] = digest
    return sums


def report(found):
    for problem in found:
        print(f"release-evidence: {problem}", file=sys.stderr)
    return 1 if found else 0


def write(options):
    record = manifest()
    checks = read_checks(options.checks)
    performance = None
    if options.bench and os.path.exists(options.bench):
        with open(options.bench, encoding="utf-8") as handle:
            performance = json.load(handle)
    evidence = {
        "schema": 1,
        "story": "KEEL-052",
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "version": record["version"],
        "bundleIdentifier": record["bundleIdentifier"],
        "signingIdentity": "ad-hoc (not distributable)" if options.identity in (None, "", "-") else options.identity,
        "channel": channel(checks),
        "checks": checks,
        "artifacts": read_sums(options.sums),
        # The latest scripts/bench-browser.py evidence (KEEL-047), as the release verification matrix asks.
        "performance": performance,
    }
    with open(options.out, "w", encoding="utf-8") as handle:
        json.dump(evidence, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return report(problems(evidence, record))


def check(options):
    with open(options.file, encoding="utf-8") as handle:
        return report(problems(json.load(handle), manifest()))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    writer = commands.add_parser("write")
    writer.add_argument("--checks", required=True)
    writer.add_argument("--sums", required=True)
    writer.add_argument("--out", required=True)
    writer.add_argument("--bench")
    writer.add_argument("--identity")
    checker = commands.add_parser("check")
    checker.add_argument("file")
    options = parser.parse_args()
    return write(options) if options.command == "write" else check(options)


if __name__ == "__main__":
    sys.exit(main())
