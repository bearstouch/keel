# Contributing to Keel

Thanks for your interest in Keel. This guide covers how to get set up, how changes are made, and what a pull request
needs before it can be merged.

## Ground rules

- Be respectful and constructive in issues, reviews and discussions.
- **The docs are the behavior contract.** [`docs/`](docs/index.md) defines how Keel behaves. If your change alters
  behavior, update the relevant page in the same pull request; a new behavior gets a new requirement ID with an
  acceptance check. Requirement IDs (`FR-`, `NFR-`, `INT-`, `MAC-`, `DS-`) are stable: never renumber or reuse them. If a
  page is ambiguous, resolve the ambiguity there instead of inventing behavior in code.
- **Be honest about verification.** Report what you actually ran and observed. Mark checks you could not perform, such
  as VoiceOver, notarization on a clean Mac, Intel Macs or managed cloud Redis, as *pending* in
  [status](docs/project/status.md). Never mark them as passed.
- **Never test against servers you don't own.** Use the in-memory fake servers and the pinned containers.

## Getting set up

Follow [Development setup](README.md#development-setup) in the README. You need macOS 14 or later and Xcode 26 (Swift
6.2); CI builds with Xcode 26.0.1.

While developing, run the app with a separate state folder so you don't touch the profiles you use day to day:

```sh
swift run Keel --state-directory "$PWD/.build/dev-state"
```

Use `--fixture` when you also want passwords kept in memory instead of the Keychain.

## Finding something to work on

- Look for issues labelled `good first issue` or `help wanted`.
- For anything larger than a small fix, open an issue first and describe the problem and your proposed approach.
  Agreeing on direction early saves rework.
- Pending checks and known gaps are listed in [status](docs/project/status.md); P1 and P2 features are in the
  [product overview](docs/overview.md#scope). Cluster and KeyDB support need requirements in `docs/` before any code.

## Making a change

1. Fork the repository and create a topic branch from `develop`, for example `fix/zset-score-paging`.
2. Find the requirements the change touches in `docs/` and update them first or alongside the code.
3. Make the change, with tests (see [Tests](#tests)).
4. Run the full local gate. It must be clean, with no warnings and no lint output:

   ```sh
   swift format -i -r Sources Tests ThirdParty
   swift format lint --strict -r Sources Tests ThirdParty
   swift build
   swift test
   ```

5. If you touched server compatibility (commands, capability probes, RESP handling), also run the container matrix,
   which needs Docker or Colima:

   ```sh
   python3 -I scripts/integration-matrix.py
   ```

   If you touched the key browser or key index, run `python3 scripts/bench-browser.py --quick`. If you touched
   packaging, bundled helpers or resources, run `scripts/package-release.sh`.
6. Update the docs: `README.md` and `CHANGELOG.md` for user-visible changes, the relevant page under `docs/` for
   behavior changes, [`docs/api/`](docs/api/index.md) when a public API changes, [`docs/design/`](docs/design/index.md)
   when the design changes, and [status](docs/project/status.md) when a check is closed or still pending.
7. Open a pull request against `develop` (see [Pull requests](#pull-requests)).

The full definition of done is in [Change workflow](docs/development/workflow.md).

## Architecture rules and code style

The rules enforced in review are in [Development rules](docs/development/rules.md). In short:

- **One data path.** Every command goes through `DataCommandService` and `SafetyPolicy` before anything is written to
  the socket. No view or console talks to a `RedisConnection` directly, and a blocked command sends nothing.
- Read-only fails closed: it blocks every write, script that may write, admin and unknown command.
- SCAN only, never `KEYS`, in the browser; values load in bounded pages, and every buffer that grows with server data is
  bounded.
- Keys and values are byte strings end to end; display escaping never changes the bytes sent to the server.
- A lost reply to a write is `OUTCOME_UNKNOWN`: re-read, never re-send.
- Never implement SSH. Build `/usr/bin/ssh` argument arrays without a shell, add no trust-bypass options, and never
  signal a reused PID.
- Persistence is versioned, atomic and owner-only. Never persist or log values, key names, console text, passwords or
  tokens; secrets live only in the Keychain.
- Keel is independent of Trellis at run time. Code vendored from Trellis lives in `ThirdParty/TrellisShared`, uses Keel
  names, and every local change is recorded in its `PROVENANCE.md`.
- Never depend on a Redis-only command without a capability probe: Valkey is first-class and release-blocking.
- Match the surrounding dense Swift style, use only the [design](docs/design/index.md) tokens, and keep every view
  accessible (labels, roles, visible focus, text never color-only).

The [architecture docs](docs/architecture.md) explain how the pieces fit together.

## Tests

- Tests use XCTest, with one test class per area, in the test target that matches the module.
- Assert observable behavior and failure safety. For example, test that the previous state is retained when an
  operation fails, and that a blocked command sends nothing.
- Use descriptive test names and keep existing names stable. Extra tests that come out of review go in
  `*ReviewTests.swift`. See [Testing](docs/development/testing.md).
- Test protocol code against the in-memory fake servers first. `KeelIntegrationTests` run pinned containers (Redis,
  Valkey, Dragonfly, TLS and ACL fixtures, sshd) and never the user's servers, Keychain or state.
- Inject time, the filesystem, the Keychain, processes and transports so tests are deterministic.
- Useful filters:

  ```sh
  swift test --filter KeelCoreTests
  swift test --filter KeelCoreTests.SafetyPolicyTests
  ```

## Commits

- Write focused commits with imperative subjects in the [Conventional Commits](https://www.conventionalcommits.org/)
  style, with a module or area as the scope:
  - `feat(browser): show TTL badges in the flat view`
  - `fix(ssh): keep the tunnel when a tab joins a cancelled start`
  - `docs(readme): add an app screenshot`
- Don't commit build output (`.build/`, `dist/`), personal Xcode state, or anything from your real Application Support
  directory.

## Pull requests

A good pull request:

- explains **what** changed and **why**, links the issue and names the requirement IDs it touches;
- lists **how you verified** it: the commands you ran, the test counts, and any manual checks, with unperformed checks
  marked *pending*;
- includes screenshots or a short recording for UI changes, in both light and dark appearance;
- keeps to one concern. Refactors that aren't needed for the change belong in their own PR.

Maintainers review for correctness, acceptance gaps, regressions, data-loss risk, races and leaks, security,
accessibility and test gaps. Expect questions, and expect follow-up commits to be requested.

## Reporting bugs

Open an issue that includes:

- the Keel version or commit, macOS version, and CPU (Apple silicon or Intel);
- the server type and version (Redis, Valkey or Dragonfly) and how you connect (TCP, TLS, SSH tunnel);
- steps to reproduce, what you expected, and what happened;
- if useful, a diagnostics report from **Help → Export Diagnostics…**. It never contains hosts, key names, values or
  secrets, but review it before attaching.

Don't paste key names, values, console output, passwords or private hostnames from your servers.

## Reporting security issues

**Don't open a public issue for security vulnerabilities.** Report them privately through GitHub's
[private vulnerability reporting](https://github.com/bearstouch/keel/security/advisories/new) for this repository.
Include the affected version, the impact, and minimal reproduction steps. We will acknowledge your report and
coordinate a fix and disclosure with you.

Areas that are especially security-sensitive include the safety policy and the data path (read-only bypasses,
unconfirmed destructive commands), the RESP parser and its reply bounds, TLS verification, SSH invocation and the
askpass helper, Keychain handling, persistence permissions, and update verification.

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
