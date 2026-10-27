# Releasing

Keel ships as a Universal 2, Developer ID-signed and notarized DMG, with automatic updates through Sparkle 2. The
rules are [MAC-08 – MAC-11](../macos.md#distribution-signing-and-updates) and [INT-11](../integrations.md#updates).
The step-by-step operator guide, including key handling, is [`release/README.md`](https://github.com/bearstouch/keel/blob/master/release/README.md)
in the repository.

## Release inputs

| File | What it is | Checked by |
| --- | --- | --- |
| `release/manifest.json` | Version, bundle ID, minimum macOS, architectures, bundled artifacts, dependencies, Sparkle feed and public EdDSA key, and the `releaseChecks` the evidence must hold | `KeelReleaseTests` |
| `release/Info.plist` | `Keel.app/Contents/Info.plist`; packaging sets both versions from the manifest | `UpdatePolicyTests` |
| `release/icon/` | App icon assets generated from `keel-icon.svg` | `AppIconAssetsTests` |
| `release/dmg/` | DMG window background | — |
| `release/bench-baseline.json` | Benchmark baselines | `scripts/bench-browser.py` |

## Building

```sh
scripts/package-release.sh                                       # ad-hoc signed: local checks only
KEEL_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
KEEL_NOTARY_PROFILE=keel-notary \
KEEL_SPARKLE_ACCOUNT=com.bearstouch.keel scripts/package-release.sh
```

Outputs go to `dist/`: `Keel.app`, `Keel-<version>.dmg`, `Keel-<version>.zip` (the Sparkle archive), `appcast.xml`,
`SHA256SUMS.txt` and `release-evidence.json`. Each check in the evidence is `passed`, `failed` or `skipped`. Any
failure exits 1, and the build counts as a `release` only when every check passed. Run `scripts/bench-browser.py`
first so the evidence has its performance verdict. The EdDSA key comes from `KEEL_SPARKLE_KEY_FILE` or
`KEEL_SPARKLE_ACCOUNT`.

Ad-hoc builds are signed without the hardened runtime, because library validation can't load the embedded
Sparkle.framework without a Team ID. Only Developer ID builds carry the hardened runtime, and only they are
distributed.

## Bundled helpers

`package-release.sh` copies and signs `keel-askpass` (into `Contents/Helpers`) and Sparkle's helpers. A new helper
also needs an entry in `release/manifest.json` and in the data-removal plan (`KeelRelease`).

## Publishing

1. Bump `version` in `manifest.json` and both versions in `Info.plist` (plain `X.Y.Z`), and add the CHANGELOG section.
2. Push the tag `v<version>`. `release.yml` tests, benchmarks and packages the build, then creates the GitHub release
   (a pre-release unless the evidence channel is `release`).
3. For a `release`, upload the archive and then `appcast.xml` to the Bearstouch release host. Never edit the appcast
   after signing it; re-run `sign_update` instead.

Before a release, complete the [release verification matrix](../macos.md#release-verification-matrix) and record any
check that couldn't be run as pending.
