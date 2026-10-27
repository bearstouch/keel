# Releasing Keel

Release decisions live in [`manifest.json`](manifest.json) and the app's [`Info.plist`](Info.plist); `KeelReleaseTests`
check both. The rules are [MAC-08 – MAC-11](../docs/macos.md#distribution-signing-and-updates) and
[INT-11](../docs/integrations.md#updates).

| File | What it is |
| --- | --- |
| `manifest.json` | Version, bundle ID, minimum macOS, architectures, bundle artifacts, dependencies, the Sparkle feed and public EdDSA key, and the `releaseChecks` the evidence must hold |
| `Info.plist` | `Keel.app/Contents/Info.plist`; packaging sets both versions from the manifest |
| `dmg/` | The DMG window background (Light icon look) and `make-background.swift`, which renders it |
| `icon/` | App icon assets ([`scripts/generate-app-icon.sh`](../scripts/generate-app-icon.sh)) |
| `bench-baseline.json` | Benchmark baselines ([`scripts/bench-browser.py`](../scripts/bench-browser.py)) |

## Build a release

```sh
scripts/package-release.sh                                       # ad-hoc: a pre-release at best, for local checks
KEEL_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
KEEL_NOTARY_PROFILE=keel-notary \
KEEL_SPARKLE_ACCOUNT=com.bearstouch.keel scripts/package-release.sh
```

Outputs in `dist/`: `Keel.app`, `Keel-<version>.dmg`, `Keel-<version>.zip` (the Sparkle archive), `appcast.xml`,
`SHA256SUMS.txt` and `release-evidence.json`. Each check in the evidence is `passed`, `failed` or `skipped`; any
failure exits 1, and the build is a `release` only when every check passed. Run `scripts/bench-browser.py` first so
the evidence has its `performance` verdict. `--no-layout` skips the Finder pass that positions the DMG icons (needed
where Finder automation isn't allowed).

Ad-hoc builds are signed without the hardened runtime: without a Team ID, library validation can't load the embedded
Sparkle.framework. Only Developer ID builds carry it, and only they are distributed.

## Keys and secrets

- **Sparkle EdDSA key.** The pair was generated once with
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.bearstouch.keel` (after `swift package resolve`); the
  public key is `sparkle.publicEDKey` in the manifest and `SUPublicEDKey` in `Info.plist`. Export the private key with
  `generate_keys --account com.bearstouch.keel -x private.key`, store it as the `SPARKLE_ED_PRIVATE_KEY` repository
  secret, keep an offline backup, then delete the file. Without the private key installed copies can never accept
  another update.
- **Developer ID and notarization** (repository secrets, used by `release.yml`): `MACOS_CERTIFICATE_P12`,
  `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. Locally,
  create the notary profile once with `xcrun notarytool store-credentials keel-notary`.

## Publish

1. Bump `version` in `manifest.json` and both versions in `Info.plist` (plain `X.Y.Z`), add the CHANGELOG section.
2. Push the tag `v<version>`. The workflow tests, benchmarks, packages and creates the GitHub release (a pre-release
   unless the evidence channel is `release`).
3. For a `release`: upload `Keel-<version>.zip` to `https://bearstouch.com/keel/releases/` and then `appcast.xml` to
   `https://bearstouch.com/keel/appcast.xml` (the feed host has no automated deploy yet). Never edit the appcast after
   signing it; re-run `sign_update` instead.

## Test an update locally

Build version N and N+1 with the same key, serve a folder holding N+1's archive and appcast with
`python3 -m http.server` behind an HTTPS proxy (Sparkle refuses plain HTTP), point `SUFeedURL` in N's `Info.plist` at it
and re-sign N. **Check for Updates…** in N offers N+1 and installs it only after you confirm. A changed byte in the
archive must make Sparkle refuse it.
