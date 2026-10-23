#!/usr/bin/env python3
"""Generate Keel's bundled command catalog (Sources/KeelCore/Resources/Commands/commands.json).

The catalog is built from the official `src/commands/*.json` sources of Redis 7.4 and Valkey 8, then checked
against Valkey 9 (INT-03, 02 Architecture -> Safety policy). Download the three trees first, e.g.:

    curl -sSL https://codeload.github.com/redis/redis/tar.gz/refs/tags/7.4.11 \
        | tar -xz -C redis-7.4 --strip-components=3 '*/src/commands/'

then run:

    python3 -I scripts/generate-command-catalog.py \
        --redis redis-7.4 7.4.11 --valkey valkey-8.1 8.1.10 --check valkey-9.0 9.0.6

The check fails (exit 1) when Valkey 9 gives a catalog command a safety flag the catalog lacks; Valkey 9 commands
missing from the catalog are recorded in the output (they stay unknown, so they fail closed).
"""

import argparse
import json
import os
import sys

FORMAT_VERSION = 1
# Keel's safety flags (CommandFlags). `dangerous` follows Redis's implicit ACL rule: ADMIN implies @dangerous.
SAFETY_FLAGS = ["write", "readonly", "admin", "dangerous", "blocking", "pubsub"]
# A server may add these but never remove them; `readonly` only relaxes, so it isn't merged up.
RESTRICTIVE = {"write", "admin", "dangerous", "blocking", "pubsub"}
OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "KeelCore", "Resources", "Commands", "commands.json")


def load_tree(path):
    commands = {}
    for file in sorted(os.listdir(path)):
        if not file.endswith(".json"):
            continue
        with open(os.path.join(path, file), encoding="utf-8") as handle:
            for key, spec in json.load(handle).items():
                # Sentinel-only commands never run on a data server.
                if "ONLY_SENTINEL" in spec.get("command_flags", []):
                    continue
                name = (spec["container"] + "|" + key if "container" in spec else key).lower()
                commands[name] = spec
    # Subcommands of a dropped container (`SENTINEL`) go with it.
    return {n: s for n, s in commands.items() if "|" not in n or n.split("|")[0] in commands}


def flags_of(spec):
    command_flags = set(spec.get("command_flags", []))
    acl = set(spec.get("acl_categories", []))
    flags = set()
    if "WRITE" in command_flags: flags.add("write")
    if "READONLY" in command_flags: flags.add("readonly")
    if "ADMIN" in command_flags: flags.update(("admin", "dangerous"))
    if "DANGEROUS" in acl: flags.add("dangerous")
    if "BLOCKING" in command_flags: flags.add("blocking")
    if "PUBSUB" in command_flags: flags.add("pubsub")
    return flags


def legacy_range(spec):
    """(first, last, step, movable) as `COMMAND` reports them; a port of Redis's populateCommandLegacyRangeSpec."""
    specs = spec.get("key_specs", [])
    if not specs:
        return 0, 0, 0, False

    def plain(ks):
        return "index" in ks.get("begin_search", {}) and "range" in ks.get("find_keys", {})

    def report(pos, lastkey, step):
        return pos, (lastkey if lastkey < 0 else pos + lastkey), step

    if len(specs) == 1 and plain(specs[0]):
        ks = specs[0]; rng = ks["find_keys"]["range"]
        first, last, step = report(ks["begin_search"]["index"]["pos"], rng["lastkey"], rng["step"])
        return first, last, step, "INCOMPLETE" in ks.get("flags", [])
    first, last, prev_last, movable = None, 0, 0, False
    for ks in specs:
        if not plain(ks):
            movable = True; continue
        pos = ks["begin_search"]["index"]["pos"]; rng = ks["find_keys"]["range"]
        if rng["step"] != 1 or (prev_last and prev_last != pos - 1):
            movable = True; continue
        if "INCOMPLETE" in ks.get("flags", []):
            movable = True
        first = pos if first is None else min(first, pos)
        absolute = rng["lastkey"] if rng["lastkey"] < 0 else rng["lastkey"] + pos
        # Redis compares as unsigned, so a negative (to-the-end) last key wins over any positive one.
        last = absolute if (absolute & 0xFFFFFFFF) > (last & 0xFFFFFFFF) else last
        prev_last = last
    if first is None:
        return 0, 0, 0, True
    return first, last, 1, movable


def compact_argument(arg):
    out = {"name": arg["name"], "type": arg["type"]}
    if "token" in arg: out["token"] = arg["token"]
    if "display" in arg: out["display"] = arg["display"]
    if arg.get("optional"): out["optional"] = True
    if arg.get("multiple"): out["multiple"] = True
    if arg.get("multiple_token"): out["multipleToken"] = True
    if arg.get("arguments"): out["arguments"] = [compact_argument(a) for a in arg["arguments"]]
    return out


def entry(name, spec, flags):
    first, last, step, movable = legacy_range(spec)
    out = {"name": name, "arity": spec["arity"], "flags": [f for f in SAFETY_FLAGS if f in flags],
           "firstKey": first, "lastKey": last, "step": step}
    if movable: out["movableKeys"] = True
    for field in ("group", "since", "summary", "complexity"):
        if field in spec: out[field] = spec[field]
    if spec.get("arguments"): out["arguments"] = [compact_argument(a) for a in spec["arguments"]]
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--redis", nargs=2, metavar=("DIR", "VERSION"), required=True)
    parser.add_argument("--valkey", nargs=2, metavar=("DIR", "VERSION"), required=True)
    parser.add_argument("--check", nargs=2, metavar=("DIR", "VERSION"), required=True)
    parser.add_argument("--output", default=OUTPUT)
    args = parser.parse_args()

    redis, valkey, check = load_tree(args.redis[0]), load_tree(args.valkey[0]), load_tree(args.check[0])
    commands = []
    for name in sorted(set(redis) | set(valkey)):
        # Redis 7.4 is the base for arity, keys and docs; flags are the union, so either server's restriction holds.
        base = redis.get(name) or valkey[name]
        flags = flags_of(base)
        for other in (redis.get(name), valkey.get(name)):
            if other is not None:
                flags |= flags_of(other) & RESTRICTIVE
        commands.append(entry(name, base, flags))

    by_name = {c["name"]: c for c in commands}
    missing = sorted(set(check) - set(by_name))
    weaker = []
    for name, spec in sorted(check.items()):
        if name in by_name:
            lacking = (flags_of(spec) & RESTRICTIVE) - set(by_name[name]["flags"])
            if lacking:
                weaker.append(f"{name}: {', '.join(sorted(lacking))}")

    catalog = {
        "version": FORMAT_VERSION,
        "generatedFrom": [f"redis {args.redis[1]}", f"valkey {args.valkey[1]}"],
        "checkedAgainst": f"valkey {args.check[1]}",
        "missingFromCheck": missing,
        "commands": commands,
    }
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, separators=(",", ":"), ensure_ascii=False)
        handle.write("\n")
    print(f"{len(commands)} commands -> {args.output}")
    print(f"valkey {args.check[1]} commands not in the catalog (fail closed): {', '.join(missing) or 'none'}")
    if weaker:
        print(f"valkey {args.check[1]} has safety flags the catalog lacks:\n  " + "\n  ".join(weaker), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
