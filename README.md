# Keel

A calm, native client for Redis, Valkey and Dragonfly on macOS by Bearstouch. Keel browses millions of keys with
SCAN only, edits every core type, has a redis-cli-style console and a server overview, keeps production safe with
read-only connections and typed confirmations.

| Server | Versions | Support |
| --- | --- | --- |
| Redis | 6.0+ | Full |
| Valkey | 7.2 – 9.x | Full, first-class |
| Dragonfly | 1.x | Common command set; capability probes cover differences |

Requires macOS 14 or later. See [Integrations](docs/integrations.md) for details.

> **Status:** v1 in release qualification; see [Project status](docs/project/status.md).

## Documentation

Contributor documentation lives in [`docs/`](docs/index.md) and builds into a site with MkDocs
(`pip install mkdocs-material && mkdocs serve`):

- [Product overview](docs/overview.md) and [Architecture](docs/architecture.md)
- [Requirements](docs/requirements/index.md): the behavior contract, with stable requirement IDs
- [Integrations](docs/integrations.md), [macOS support](docs/macos.md) and [Design](docs/design/index.md)
- [API reference](docs/api/index.md) for each module
- [Development](docs/development/getting-started.md): rules, testing, change workflow and releasing
- [CLAUDE.md](CLAUDE.md): agent guidance

## Building

Requires Xcode 26 (Swift 6.2) on macOS 14 or later; CI and releases build with Xcode 26.0.1.

```sh
swift build                                   # warning-free build
swift test                                    # XCTest suite
swift format lint --strict -r Sources Tests ThirdParty   # must print nothing
swift run Keel                                # run the app (development identity)
swift run Keel --state-directory /abs/path    # use a separate state folder
python3 scripts/bench-browser.py --redis-server "$(which redis-server)"   # performance benchmarks, evidence in .build/bench/
python3 -I scripts/integration-matrix.py   # integration matrix against pinned Redis/Valkey/Dragonfly containers (needs Docker)
scripts/package-release.sh                    # Universal 2 DMG and release evidence in dist/ (ad-hoc unless signing is configured)
```

Releasing (signing, notarization, Sparkle keys, the appcast) is described in [release/README.md](release/README.md).

## License

Keel is released under the [MIT License](LICENSE). Bundled third-party components keep their own licenses: Sparkle
(MIT) and the Inter and JetBrains Mono fonts (SIL Open Font License 1.1).
