# Testing

Keel uses XCTest. Tests assert **observable behavior and failure safety**: the previous state is kept on error, and a
blocked command sends nothing. Design background is in
[Architecture → Testing and injection](../architecture.md#testing-and-injection).

## Test targets

| Target | Covers | Runs against |
| --- | --- | --- |
| `KeelRESPTests` | Codec, `RedisConnection`, handshake, TLS configuration | In-memory transports, including fragmented and malformed frames |
| `KeelSSHTests` | Tunnel arguments, `TunnelManager`, askpass broker and prompt relay, host library | Fake process launcher; a local unprivileged sshd fixture for some cases |
| `KeelCoreTests` | Data path, safety policy, catalog, sessions, profiles, persistence, key index, editors, console | Fake connections, Keychain and filesystem |
| `KeelUITests` | View models, AppKit lists and console, shortcuts, design tokens, accessibility audit, keyboard navigation | In-process models with fakes |
| `KeelReleaseTests` | Release manifest, `Info.plist`, update policy, data-removal plan, icon assets | Files in `release/` |
| `KeelIntegrationTests` | End-to-end behavior per server, TLS, ACL, tunnels, benchmarks | Pinned containers (skipped by default) |

## Conventions

- One test class per area, with descriptive names (`testBlockedCommandSendsNothing`). Extras that come out of a review
  go in `*ReviewTests.swift`.
- Inject time, the filesystem, the Keychain, processes and transports. Never sleep in a test: drive timeouts through
  the injected `sleep`/clock.
- Test protocol code against in-memory fake servers first, then against real containers in `KeelIntegrationTests`.
- RESP codec, URL parser, safety policy and command catalog have exhaustive table tests
  ([NFR-QA02](../requirements/non-functional.md#quality-and-maintainability)).
- Never test against a user's servers.

```sh
swift test                                            # everything that needs no server
swift test --filter KeelCoreTests.SafetyPolicyTests   # one class
swift test --filter KeelCoreTests.SafetyPolicyTests/testReadOnlyBlocksWrites   # one test
```

## Fixtures

Golden files live in `Tests/Fixtures/`:

| Folder | Contents | Produced by |
| --- | --- | --- |
| `INFO/` | `INFO` output per server (Redis 5.0.7 to 8.0, Valkey 7.2–9.x, Dragonfly, unrecognized) | Captured from servers |
| `Commands/` | `COMMAND INFO` / `COMMAND DOCS` replies, RESP2 and RESP3 | Captured from Redis 7.2 |
| `Console/` | Raw reply bytes and redis-cli's printed text per case; `VERSION` names the redis-cli | `scripts/capture-console-goldens.py` |
| `Design/tokens.json` | Theme tokens parsed from the [Design](../design/index.md) color tables | `scripts/generate-design-tokens.py` |
| `TLS/` | Private CA, server, client (PEM, PKCS#1, SEC1, encrypted, `.p12`) and self-signed certificates | `TLS/generate.sh` |
| `SSH/` | sshd container (`Dockerfile`, `sshd_config`) and local `serve.sh` | — |
| `Integration/matrix.json` | Container images pinned by digest | Edited by hand |

Fixtures that are parsed from the docs fail the tests when the two drift apart:

- `ThemeTokensTests` compares `KeelTheme` with `Design/tokens.json`. After you change a color table in
  [Design](../design/index.md), run `python3 -I scripts/generate-design-tokens.py`. CI-style check: `--check`.
- `ShortcutBindingsTests` reads the [Default shortcuts](../requirements/functional.md#default-shortcuts) table, so
  the table and `KeelShortcut` can't drift apart. Keep that table's layout (`Action | Default | Notes`).

## Integration matrix

`KeelIntegrationTests` run against containerized Redis 6.0, 6.2, 7.4, 8.x, Valkey 7.2, 8.x, 9.x and Dragonfly 1.x,
plus a Redis 5 container that must be refused with `UNSUPPORTED_SERVER`, three TLS servers (private CA, client
certificate required, self-signed) and an sshd bastion with Redis on its own loopback.

```sh
python3 -I scripts/integration-matrix.py                                   # whole matrix (needs Docker)
python3 -I scripts/integration-matrix.py --servers redis-7.4,valkey-9.x --filter ServerMatrixTests
```

- Every port is published on `127.0.0.1` only. Tests receive ports, never hosts (`KEEL_INTEGRATION_SERVERS`,
  `KEEL_INTEGRATION_REFUSED_PORT`, `KEEL_INTEGRATION_TLS_*`, `KEEL_INTEGRATION_SSH_*`).
- The tests skip without `KEEL_INTEGRATION=1`. The script also sets `KEEL_INTEGRATION_REQUIRED=1`, which turns a
  missing fixture into a failure.
- Per server, `ServerMatrixTests` cover Test Connection and detection, SCAN browsing, each core editor's guarded save,
  the console, bulk delete and a restricted ACL user.
- Evidence goes to `.build/integration/evidence.json`. Containers, keys and temporary folders are removed afterwards,
  also on failure or Ctrl-C.
- A Valkey failure blocks a release exactly like a Redis failure (FR-CN20).

## Benchmarks

`scripts/bench-browser.py` measures the [performance targets](../requirements/non-functional.md#performance) with 1M
and 10M keys.

```sh
python3 scripts/bench-browser.py --redis-server "$(which redis-server)"   # median of 3 runs
python3 scripts/bench-browser.py --quick                                   # single-run smoke check
python3 scripts/bench-browser.py --update-baseline                         # record a new baseline (review it)
```

It runs the `KeelCoreTests` performance tests, `KeelIntegrationTests.BrowserBenchmarkTests` against a throwaway server
it seeds, and launches the app with 200 saved profiles to time the first sidebar render (`KEEL_LAUNCH_METRICS`). The
benchmark tests run only with `KEEL_BENCH=1`. The run fails on a missed NFR target or a regression of more than 20%
against `release/bench-baseline.json`. The baseline is the recording Mac's numbers, so the release workflow runs with
`--no-regression-gate`: on a CI runner regressions are reported in the evidence but only targets and tests fail it.
Evidence goes to `.build/bench/evidence.json`, and the release evidence includes
it.

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request:

| Job | Runner | Steps |
| --- | --- | --- |
| `build-test` | `macos-26` (Xcode 26.0.1) | `swift format lint --strict` (must print nothing), `swift build` (fails on any warning in `Sources/`), `swift test` |
| `integration` | `macos-15-intel` with Colima | `scripts/integration-matrix.py` |

Actions are pinned to commit SHAs. `release.yml` builds, tests, benchmarks and packages tagged releases
([Releasing](releasing.md)).
