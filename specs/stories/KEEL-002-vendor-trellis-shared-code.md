# KEEL-002 · Vendor Trellis shared code

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E0 Foundation | P0 | 3 pts | S1 | [KEEL-001](KEEL-001-package-scaffold-toolchain-and-ci.md) |

**Specs:** [02 Architecture → Reuse from Trellis](../02-architecture.md#reuse-from-trellis), [INT-07](../06-integrations.md#trellis)

## Story

As a Keel developer, I want Trellis's SSH host library, askpass helper, owner-only storage and shortcut bindings vendored with recorded provenance, so that Keel reuses proven code without any runtime link to Trellis.

## Scope

- `ThirdParty/TrellisShared/` with the files listed in the architecture page, renamed to Keel identifiers (`Keel…` types, `KEEL_` env prefix, Keychain service `Keel SSH Host`)
- `ThirdParty/TrellisShared/PROVENANCE.md`: Trellis commit SHA, file list, every local change
- Vendored tests ported alongside the code

**Out of scope:** reading any Trellis file, setting or Keychain item at run time.

**Note:** the MCP HTTP layer (parser, listener, transport security) and its `KeelMCPTests` were vendored here, then removed on 2026-10-23 with the agent API.

## Acceptance criteria

- [x] **AC1.** The vendored code builds inside Keel's targets and its ported tests pass.
- [x] **AC2.** `PROVENANCE.md` names the Trellis commit and lists each file and each local change.
- [x] **AC3.** A grep of `Sources/` and `ThirdParty/TrellisShared/` finds no `Trellis` Keychain service, `com.bearstouch.trellis` path or `TRELLIS_` variable.
- [ ] **AC4.** Keel and Trellis can run at the same time without sharing state (manual check). **Pending:** not observed yet.

## Unit tests

Test target: `KeelSSHTests`.

| Test | Verifies |
| --- | --- |
| `VendoredIdentifiersTests.testNoTrellisRuntimeIdentifiers` | scans bundled sources/resources for forbidden Trellis identifiers |
| `HostLibraryCodecTests.testLoadsVersion1` | ported codec test still passes under Keel names |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
