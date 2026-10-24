# 04 Non-functional requirements

Targets are measured on the reference machines (Apple silicon M1 8 GB and an Intel Mac with 16 GB, both on the minimum supported macOS) against a local server, unless stated otherwise. Performance evidence is recorded by `scripts/bench-browser.py`; manual checks that can't be run are recorded as **pending**.

**Benchmark evidence (KEEL-047).** Every run builds optimized (`-c release`), repeats each benchmark (median of 3 by default) and writes `.build/bench/evidence.json`: the machine, the server, each metric with its samples, NFR target, baseline and change, the checks still pending by hand (scroll hitches and main-thread frame time in Instruments, the idle protocol trace, MONITOR at 50,000 lines/s, the Intel machine) and a pass/fail verdict. The run fails when a metric misses its target here, a benchmark test fails, a metric with a target or a baseline is missing from a group the run measured, or a metric is more than 20% slower (or larger) than this architecture's baseline in `release/bench-baseline.json`; changes under 5 ms are timer noise and never count as a regression. The gate is judged on the default median of 3 runs; a single run (`--quick`) is a smoke check and can swing past 20%. `--update-baseline` records a new baseline (groups the run skipped keep their previous values), reviewed like any other change. The release evidence (MAC-10) carries the latest `evidence.json`.

## Performance

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-PF01 | Cold launch to an interactive window in under 1.0 s (Apple silicon) / 2.0 s (Intel) with 200 saved profiles. | Measured from process start to first sidebar render. |
| NFR-PF02 | With 1,000,000 loaded keys, scrolling the flat or tree view holds display frame rate (no dropped frames over 1 s at 60 Hz, ≥ 110 fps on ProMotion) and selecting a row opens its editor header in under 100 ms (local server). | Benchmark with Instruments' Animation Hitches; hitch ratio < 5 ms/s. |
| NFR-PF03 | SCAN ingestion of 1,000,000 keys (COUNT 1,000, local server, auto-page) completes in under 15 s, and the UI stays responsive (main-thread work < 8 ms per frame) throughout. | |
| NFR-PF04 | Building or rebuilding the namespace tree for 1,000,000 keys takes under 2 s off the main actor; expanding any node is under 200 ms. | |
| NFR-PF05 | Local substring filter over 1,000,000 loaded keys returns first results in under 150 ms and completes in under 1 s. | |
| NFR-PF06 | Opening a value: first page visible in under 300 ms for any type on a local server, independent of total value size (hash with 1M fields, list with 10M items, 64 MiB string). | |
| NFR-PF07 | Keel's own overhead on a server is bounded: idle tabs send nothing (TTL countdowns run locally; Info auto-refresh is off by default); type/TTL pipelines are at most 1 per 100 ms per tab. | Idle protocol trace for 60 s shows no commands. |
| NFR-PF08 | Console: a 10,000-element reply renders in under 500 ms; MONITOR at 50,000 lines/s doesn't freeze the UI (output is coalesced and bounded). | |

## Memory and resources

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-RS01 | Key index memory: ≤ 120 bytes per loaded key on average beyond the key bytes themselves (the namespace tree is budgeted separately: it depends on how many folders the keys open); 1,000,000 keys of ~30 bytes use < 200 MB in total for the index and tree, even when every key opens folders of its own. | Instruments Allocations at 1M keys. |
| NFR-RS02 | The configurable loaded-key limit (default 1,000,000, max 10,000,000) is enforced, with a notice; Keel never grows without bound. | |
| NFR-RS03 | Every reply is bounded: maximum single reply 64 MiB (larger replies fail with `LIMIT_EXCEEDED` and the connection is reset); editor pages, console scrollback and MONITOR buffers have fixed limits (FR-ED, FR-CO). | Fuzz test with a fake server sending an oversized bulk string. |
| NFR-RS04 | Idle CPU < 0.5% with 10 connected tabs and no auto-refresh. | |
| NFR-RS05 | Closing a tab releases its connections within 1 s; closing the last tab of a tunnelled profile terminates ssh within 11 s; no ssh process outlives the app (process group cleanup on quit and crash recovery on next launch). | `ps` after quit shows no `ssh -N` children. |

## Reliability and data safety

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-RL01 | Keel never changes server data except through an explicit user action; no background writes. | Code review + protocol trace of browse-only sessions. |
| NFR-RL02 | Multi-step edits are atomic (`MULTI/EXEC`, guarded by `WATCH` where a concurrent change would corrupt the result). A failed step leaves the key unchanged. | Integration tests with a concurrent writer. |
| NFR-RL03 | A lost reply to a write is reported as `OUTCOME_UNKNOWN`, the key is re-read, and the write is never re-sent automatically. | Fault-injection test dropping the connection after send. |
| NFR-RL04 | Persistence: versioned atomic files, last-known-good backup, owner-only permissions, single writer; corrupt or newer files go to recovery and are never overwritten. Interrupting a save leaves a readable file or backup. | Same test pattern as Trellis `WorkspacePersistence` tests. |
| NFR-RL05 | A malformed or hostile server can't crash Keel: the RESP parser rejects invalid lengths, nesting > 128, and non-numeric integers with `PROTOCOL_ERROR` and closes that connection only. | Parser fuzzing (≥ 1M cases) in CI. |
| NFR-RL06 | Crash safety: a crash never loses saved profiles; on next launch Keel reports that connections were closed and doesn't resume bulk jobs. | |

## Security

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-SC01 | Secrets (Redis passwords, key passphrases, SSH passwords) live only in the Keychain (*when unlocked, this device only*), never in files, logs, argv, environment variables, pasteboard or diagnostics. | Grep of the state directory and unified logs after a full scenario finds none. |
| NFR-SC02 | TLS verification is on by default; skipping it is explicit, per profile, and always visible in text. Minimum TLS 1.2. | |
| NFR-SC03 | ssh is run as an executable plus argument array, never through a shell; destinations starting with `-` or containing control characters are rejected; no trust-bypass options are ever added. | |
| NFR-SC04 | The runtime directory for tunnel and askpass sockets is per-user `$TMPDIR`, `0700`, random name; sockets `0600`; symlinked endpoints are rejected; peers must match the user's UID. | |
| NFR-SC05 | Data from Redis (keys, values, INFO, error text) is untrusted: it's never interpreted as markup, URLs aren't auto-opened, JSON is parsed without code execution, and key names with control or bidi characters display escaped (FR-KB10). | |
| NFR-SC07 | Dependencies are pinned (Sparkle by exact version and checksum), and the release workflow pins actions to commit SHAs. | |

## Privacy

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-PV01 | No telemetry, analytics, crash reporting service or remote logging. The only network traffic Keel initiates is to servers the user configured, SSH destinations, and the Sparkle appcast (if enabled). | Little Snitch / `nettop` observation during the acceptance scenario. |
| NFR-PV02 | Values, key names, console input/output, and INFO contents are never logged. `os_log` messages use `privacy: .private` for any server-derived string and contain only codes and counts in release builds. | Log review of a full scenario with `log stream --level debug`. |
| NFR-PV03 | Nothing derived from server data is persisted except what the user explicitly saves (exported files) — no key caches, no value caches, no history (v1). | State-directory review. |
| NFR-PV04 | `CLIENT SETNAME keel` identifies the app to the server by default; the user can turn it off per profile. Keel never sends the user's name, machine name or email. | |

## Accessibility

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-AX01 | Every control has a label, role and state; tables expose rows, columns and headers to VoiceOver; status (connection, read-only, production, TLS not verified, partial load) is text, never color only. | Automated audit (`AccessibilityAuditTests`): every screen is hosted and its accessibility tree walked; no control may lack a name, and each status is found in words. VoiceOver pass over the acceptance scenario (**pending** until run by hand). |
| NFR-AX02 | Full keyboard operation: sidebar, tabs, key list, editors, sheets, palette; visible focus everywhere. See [Keyboard model](#keyboard-model). | `KeyboardNavigationTests`: the Tab order of each screen, arrows in tables, no keyboard trap. Keyboard-only run of the acceptance scenario (**pending** until run by hand). |
| NFR-AX03 | Honors Increase Contrast, Reduce Motion (no animated countdown or sparkline motion), Reduce Transparency, and Dynamic Type equivalents via the data font size setting (9–32 pt). | |
| NFR-AX04 | Contrast ≥ 4.5:1 for text and ≥ 3:1 for badges and the production strip, in light and dark, validated by Trellis's `ThemeContrast` checks. | Automated contrast test over the palette. |

### Keyboard model

- **Tab** moves between the text fields, lists and tables of a screen in reading order and wraps around: in the main
  window the sidebar, the key filter, the key list, then the open editor's filter, table and value. With Full Keyboard
  Access on, buttons, menus and segments join the loop between these stops.
- **↑ / ↓** move the selection in the sidebar, the key list and every editor table (hash fields, list items, set and
  sorted set members, stream entries and an entry's fields); the selected row opens in the viewer. Return opens the
  sidebar's selected connection (⌥Return in a new tab); **⌘I** opens Edit Connection for it.
- Text views that keep Tab — the value viewer (a tab is a character) and the console (Tab completes) — are left with
  **⌃Tab** / **⌃⇧Tab**, as in every Mac text view, so no view traps the focus.
- A focused view always shows it: system controls draw the system focus ring; the sidebar, the editor tables and the
  connection form draw a 2 pt `accent` ring (DS-02); the key list draws the focus ring inside its pane.
- VoiceOver reads editor table rows cell by cell after their column headers ("Field city, Value London, changed"); the
  header labels are marked as headers. Row actions (rename, delete, insert) are also VoiceOver actions on the row.

## Usability

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-UX01 | Every error names what failed and how to recover; server error text is shown verbatim alongside. | Error catalog review. |
| NFR-UX02 | Long operations (scan, bulk delete, large value load) show progress and can be cancelled; nothing blocks the UI with a spinner over the whole window. | |
| NFR-UX03 | Destructive actions are never the default button and are never triggered by Return alone in a typed confirmation. | |
| NFR-UX04 | English UI in v1 with all strings in String Catalogs, ready for localization; numbers, durations, bytes and dates use the user's locale formatters. | |
| NFR-UX05 | Progressive disclosure: a default screen shows at most one primary action, one toolbar row, and no more than two lines of metadata per item; everything else lives behind menus, disclosure rows, hover, or the command palette. | Design review of every screen against the Keel design canvas; any new always-visible control needs a reason recorded in the PR. |

## Quality and maintainability

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| NFR-QA01 | Swift 6 language mode, strict concurrency, warning-free build; `swift format lint --strict` prints nothing. | CI on `macos-26`. |
| NFR-QA02 | XCTest coverage of observable behavior and failure safety per area; RESP codec, URL parser, safety policy and command catalog have exhaustive table tests. | |
| NFR-QA03 | Integration matrix in CI against Redis 6.0, 6.2, 7.4, 8.x, Valkey 7.2, 8.x and 9.x and Dragonfly 1.x containers, including TLS (custom CA, client cert), ACL users with restricted permissions, and an sshd tunnel. | |
| NFR-QA04 | Golden tests for console formatting against redis-cli 7.4 output. | |
| NFR-QA05 | Specs are the contract: behavior changes update these pages in the same change, with new requirement IDs and acceptance checks. | Review checklist. |
