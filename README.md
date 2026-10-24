# Keel

A calm, native Redis client for macOS by Bearstouch. Keel browses millions of keys with SCAN only, edits every core
type, has a redis-cli-style console and a server overview, keeps production safe with read-only connections and
typed confirmations.

Supports Redis 6.0+, Valkey and Dragonfly on macOS 14 or later.

> **Status:** early development. The package scaffold is in place; features are being built story by story.

## Documentation

- [Specifications](specs/README.md): the behavior contract (overview, architecture, requirements,
  integrations, macOS support, design).
- [Stories and plan](specs/stories/README.md): implementation stories, sprint plan and definition of done.
- [CLAUDE.md](CLAUDE.md): contributor and agent guidance.

## Building

Requires Xcode 26 (Swift 6.2) on macOS 14 or later.

```sh
swift build                                   # warning-free build
swift test                                    # XCTest suite
swift format lint --strict -r Sources Tests ThirdParty   # must print nothing
swift run Keel                                # run the app (development identity)
swift run Keel --state-directory /abs/path    # use a separate state folder
python3 scripts/bench-browser.py --redis-server "$(which redis-server)"   # performance benchmarks, evidence in .build/bench/
```

## License

Not yet chosen; all rights reserved until a license file is added.
