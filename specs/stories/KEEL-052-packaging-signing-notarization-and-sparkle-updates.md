# KEEL-052 · Packaging, signing, notarization and Sparkle updates

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 8 pts | S10 | [KEEL-051](KEEL-051-app-icon-asset-catalog.md), [KEEL-048](KEEL-048-integration-test-matrix.md) |

**Specs:** [MAC-08–MAC-11](../07-macos-support.md#distribution-signing-and-updates), [INT-11](../06-integrations.md#updates), [FR-AP07](../03-functional-requirements.md#7-app-basics)

## Story

As a user, I want a signed, notarized Universal DMG that updates itself safely, so that installing and staying current is effortless and trustworthy.

## Scope

- `scripts/package-release.sh`: Universal 2 (`lipo`), hardened runtime, sign app + `keel-askpass` + Sparkle helpers, notarize and staple DMG, `release-evidence.json` (including the latest `.build/bench/evidence.json` from KEEL-047 under `performance`), `SHA256SUMS.txt`
- DMG layout with light icon background; `NSLocalNetworkUsageDescription`
- Sparkle 2 pinned: EdDSA appcast over HTTPS, daily check (toggle), user-confirmed installs, no system profiling
- `.github/workflows/release.yml` pinned to SHAs; unsigned/unnotarized builds only as pre-releases

## Acceptance criteria

- [ ] **AC1.** `spctl --assess` accepts the notarized app on a clean Mac (pending until observed).
- [x] **AC2.** Both architectures present (`lipo -info`), minimum OS 14.0.
- [ ] **AC3.** An update from version N to N+1 installs after confirmation; a tampered update is rejected by the EdDSA check.
- [x] **AC4.** Release evidence lists every check; a failed notarization fails the script.

### Verification record (2026-10-24)

- **AC1 — pending.** Needs a notarized build (no notary profile was configured here) and a clean Mac.
- **AC2 — observed.** `scripts/package-release.sh` (ad-hoc and Developer ID runs): `lipo -info Keel.app/Contents/MacOS/Keel`
  → `x86_64 arm64`; the `architectures` check found both slices in Keel, `keel-askpass` and Sparkle's three binaries,
  and `minimumOS` found `minos 14.0` in both slices of Keel and `keel-askpass`.
- **AC3 — partly observed, pending.** The archive's EdDSA signature (signed with the keychain key) verified against the
  manifest's `SUPublicEDKey`, and a copy with one byte changed was rejected (`updateSignature` passed); the appcast was
  signed and verified (`feedSignature`). An install from N to N+1 through Sparkle needs two signed builds and the feed
  host: **pending**.
- **AC4 — observed.** Every `releaseChecks` entry appears in `release-evidence.json`. A Developer ID run with a notary
  profile that doesn't exist recorded `notarization` and `stapling` as failed and the script exited 1; the ad-hoc run
  exited 0 as a `prerelease`. The rejected-by-Apple path is the same branch (status other than `Accepted`), not observed.
- Also observed: the Developer ID build has the hardened runtime on the app, `keel-askpass` and Sparkle's helpers, no
  entitlements, and launches (`launch` check); the first ad-hoc run showed that ad-hoc + hardened runtime can't load the
  embedded framework, hence the `launch` check and ad-hoc builds without the runtime flag.
- After the review the `performance` check counts only a complete benchmark run (1M and 10M, nothing skipped) of the
  packaged commit on a clean tree; the local evidence (an older, partial run) now records it as skipped.
- **Pending (manual):** DMG Finder layout (runs here used `--no-layout`), install from the DMG on a clean macOS 14 VM
  and the current macOS, Intel hardware, the release workflow on GitHub (needs the secrets), publishing the appcast on
  `bearstouch.com`.

## Unit tests

Test target: `KeelReleaseTests`.

| Test | Verifies |
| --- | --- |
| `ReleaseManifestTests.testManifestHasSparkleFeedAndKey` | Manifest has sparkle feed and key |
| `ReleaseChecklistTests.testEvidenceRequiresAllChecks` | Evidence requires all checks |
| `UpdatePolicyTests.testNoSystemProfiling` | No system profiling |
| `UpdatePolicyTests.testChecksCanBeDisabled` | Checks can be disabled |
| `ReleaseManifestTests.testInfoPlistMatchesManifest` | The committed Info.plist matches the manifest, with the Local Network string |
| `ReleaseChecklistTests.testScriptAgreesWithChecklist` | `release-evidence.py` judges evidence as `ReleaseChecklist` does |
| `ReleaseChecklistTests.testPackageScriptRecordsEveryCheck` | The script records every manifest check |
| `ReleaseChecklistTests.testWorkflowActionsArePinned` | Every workflow action is pinned to a commit SHA |
| `UpdatePolicyTests.testUpdaterOnlyInPackagedBuilds` | No updater without the installed identity, an HTTPS feed and a key |
| `UpdatePolicyTests.testDataRemovalIncludesSparklePreferences` | Remove Keel Data… removes Sparkle's defaults |

## Integration and manual checks

- Manual: install from DMG on a clean macOS 14 VM and on the current macOS; update between two signed test builds.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
