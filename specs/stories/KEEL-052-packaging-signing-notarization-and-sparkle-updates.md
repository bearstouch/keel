# KEEL-052 · Packaging, signing, notarization and Sparkle updates

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 8 pts | S10 | [KEEL-051](KEEL-051-app-icon-asset-catalog.md), [KEEL-048](KEEL-048-integration-test-matrix.md) |

**Specs:** [MAC-08–MAC-11](../07-macos-support.md#distribution-signing-and-updates), [INT-11](../06-integrations.md#updates), [FR-AP07](../03-functional-requirements.md#7-app-basics)

## Story

As a user, I want a signed, notarized Universal DMG that updates itself safely, so that installing and staying current is effortless and trustworthy.

## Scope

- `scripts/package-release.sh`: Universal 2 (`lipo`), hardened runtime, sign app + `keel-askpass` + Sparkle helpers, notarize and staple DMG, `release-evidence.json`, `SHA256SUMS.txt`
- DMG layout with light icon background; `NSLocalNetworkUsageDescription`
- Sparkle 2 pinned: EdDSA appcast over HTTPS, daily check (toggle), user-confirmed installs, no system profiling
- `.github/workflows/release.yml` pinned to SHAs; unsigned/unnotarized builds only as pre-releases

## Acceptance criteria

- [ ] **AC1.** `spctl --assess` accepts the notarized app on a clean Mac (pending until observed).
- [ ] **AC2.** Both architectures present (`lipo -info`), minimum OS 14.0.
- [ ] **AC3.** An update from version N to N+1 installs after confirmation; a tampered update is rejected by the EdDSA check.
- [ ] **AC4.** Release evidence lists every check; a failed notarization fails the script.

## Unit tests

Test target: `KeelReleaseTests`.

| Test | Verifies |
| --- | --- |
| `ReleaseManifestTests.testManifestHasSparkleFeedAndKey` | Manifest has sparkle feed and key |
| `ReleaseChecklistTests.testEvidenceRequiresAllChecks` | Evidence requires all checks |
| `UpdatePolicyTests.testNoSystemProfiling` | No system profiling |
| `UpdatePolicyTests.testChecksCanBeDisabled` | Checks can be disabled |

## Integration and manual checks

- Manual: install from DMG on a clean macOS 14 VM and on the current macOS; update between two signed test builds.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
