# KEEL-046 · Privacy and logging guardrails

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 3 pts | S9 | [KEEL-041](KEEL-041-console-view-history-completion-streaming-masking.md) |

**Specs:** [NFR-PV01–NFR-PV04](../04-non-functional-requirements.md#privacy), [FR-AP06, FR-AP10](../03-functional-requirements.md#7-app-basics)

## Story

As a user, I want guarantees that my data never leaves my Mac or lands in logs, so that I can use Keel on sensitive servers.

## Scope

- Logging wrapper: server-derived strings `.private`, release builds log codes and counts only
- Diagnostics export (Help → Export Diagnostics) without hosts, keys, values or secrets
- Static test that forbids `print`/`NSLog` of values in Sources

## Acceptance criteria

- [ ] **AC1.** A full scenario under `log stream --level debug` shows no key names, values or secrets. *Pending: manual log review of a live scenario; the wrapper and source scan are tested (`LoggingPolicyTests`, `SourceScanTests`).*
- [x] **AC2.** Diagnostics contain only versions, counts, server types and error codes. *Observed in `DiagnosticsExportTests` on the generated report; clicking Help → Export Diagnostics in the running app is pending.*
- [ ] **AC3.** No network traffic except configured servers, SSH and the update feed (nettop observation). *Pending: `nettop` observation during the acceptance scenario.*

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `LoggingPolicyTests.testServerStringsArePrivate` | Server strings are private |
| `DiagnosticsExportTests.testContainsNoSensitiveFields` | Contains no sensitive fields |
| `SourceScanTests.testNoRawPrintOfValues` | grep-based test |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
