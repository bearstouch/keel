# KEEL-003 · Owner-only versioned persistence

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E0 Foundation | P0 | 5 pts | S1 | [KEEL-002](KEEL-002-vendor-trellis-shared-code.md) |

**Specs:** [02 Architecture → Persistence](../02-architecture.md#persistence), [NFR-RL04](../04-non-functional-requirements.md#reliability-and-data-safety), [MAC-12](../07-macos-support.md#files-credentials-and-permissions)

## Story

As a user, I want Keel's settings and profiles saved safely, so that a crash or a bad file never loses or corrupts my data.

## Scope

- `Persistence` actor: atomic owner-only writes (temp `O_EXCL|O_NOFOLLOW` 0600, fsync, rename, fsync dir), dirs 0700, single writer, sequence-gated, 300 ms debounce, immediate flush on quit
- Versioned Codable envelopes for `connections.json`, `hosts.json`, `windows.json`, `settings.json`, `known-ca.json`; last-known-good backups
- Load results `.missing` / `.loaded` / `.recovery(reason, backup?)`; corrupt files preserved as `*.corrupt.<UUID>.json`; newer versions open read-only
- Reads capped at 4 MiB and 128 nesting levels

## Acceptance criteria

- [x] **AC1.** Every saved file is mode 0600 inside a 0700 directory; symlinked targets are refused. *(Observed: `testWritesOwnerOnlyAtomically`, `testRefusesSymlinkedTarget` — file, backup and folder.)*
- [x] **AC2.** Killing the process at any point of a save leaves either the new file or the previous file/backup readable. *(Observed by fault injection between fsync and rename of both the backup and the current file, `testInterruptedSaveLeavesReadableState`; no real SIGKILL run.)*
- [x] **AC3.** An older debounced save never overwrites a newer one. *(Observed: `testSequenceGateDropsStaleSave`.)*
- [x] **AC4.** A corrupt file triggers recovery with **Recover backup** / **Start empty** and the original is preserved before anything is written. *(Observed at the domain level — `RecoveryChoice` — in `testCorruptFileIsPreservedBeforeRecovery` and `PersistenceReviewTests`, including files over 4 MiB. **Pending:** the on-screen prompt arrives with the first store that loads a file, KEEL-014.)*
- [x] **AC5.** A file with a newer `version` is never overwritten during the session. *(Observed: `testNewerVersionOpensReadOnly`, at load and mid-session. The envelope key is `schemaVersion`.)*

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `PersistenceTests.testWritesOwnerOnlyAtomically` | permissions, temp file cleanup, rename semantics |
| `PersistenceTests.testRefusesSymlinkedTarget` | O_NOFOLLOW behavior |
| `PersistenceTests.testSequenceGateDropsStaleSave` | older save loses to newer |
| `PersistenceTests.testCorruptFileIsPreservedBeforeRecovery` | `.corrupt.<UUID>` copy exists |
| `PersistenceTests.testNewerVersionOpensReadOnly` | no write after loading v99 |
| `PersistenceTests.testInterruptedSaveLeavesReadableState` | injected failure between fsync and rename |
| `PersistenceTests.testRejectsOversizedAndDeepJSON` | 4 MiB / 128 levels caps |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
