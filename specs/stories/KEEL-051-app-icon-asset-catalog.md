# KEEL-051 · App icon asset catalog

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 2 pts | S9 | [KEEL-001](KEEL-001-package-scaffold-toolchain-and-ci.md) |

**Specs:** [08 Design → App icon (DS-07–DS-10)](../08-design.md#app-icon), [design/icon](../design/icon/)

## Story

As a user, I want the Layered keel icon crisp at every size and appearance, so that Keel is recognisable in the Dock and Finder.

## Scope

- Export concept A from `design/icon/Icon.dc.html` geometry to SVG/PNG at 16–1024 px (@1x/@2x), small form ≤ 48 px
- Default, dark and tinted appearances in the asset catalog / `.icns`; light variant for DMG and website
- `scripts/generate-app-icon.sh` reproducible from the SVG source

## Acceptance criteria

- [x] **AC1.** All sizes are generated from one source by the script.
- [x] **AC2.** ≤ 48 px uses the two-bar form.
- [ ] **AC3.** The built app shows the icon in Dock, Finder and Cmd-Tab; dark/tinted appearances switch with the system setting.

## Unit tests

Test target: `KeelReleaseTests`.

| Test | Verifies |
| --- | --- |
| `AppIconAssetsTests.testAllSizesPresent` | All sizes present |
| `AppIconAssetsTests.testSmallSizesUseSimpleForm` | pixel sample |
| `ReleaseManifestTests.testIconInBundle` | Icon in bundle |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

## Verification (2026-10-24)

- **AC1:** observed. `scripts/generate-app-icon.sh` renders `release/icon/AppIcon.iconset`, `AppIcon.icns`, the Icon
  Composer bundle `AppIcon.icon` and every export from `release/icon/keel-icon.svg` alone (palettes and forms are blocks
  it rewrites); `--check` re-renders and reports no difference, so the output is reproducible.
  `AppIconAssetsTests.testAllSizesPresent` checks the iconset sizes, the `.icns` holding 16–1024 px, the Dark / Tinted /
  Light PNGs at the DS-10 sizes, the eight flattened SVGs and the `.icon` layer with Dark and Tinted fills.
- **AC2:** observed. `AppIconAssetsTests.testSmallSizesUseSimpleForm` samples (512, 408) on the 1024 grid in every PNG
  (inside the full form's second bar, in the small form's gap): 16 and 32 px are the small form, 64 px and up the full
  form, in all four looks; it fails when a full-form 16 px image is put in its place. Also checked by eye on the renders.
  AC2 covers the `.icns` and the exports; see the known limitation below for macOS 26's `Assets.car` rendering.
- **AC3:** partly observed. `ReleaseManifestTests.testIconInBundle` runs `--compile`: `actool` builds `Assets.car` with
  `NSAppearanceNameAqua`, `NSAppearanceNameDarkAqua` and `ISAppearanceTintable` icon renditions beside the committed
  `.icns`, and the manifest lists both and `iconName` `AppIcon`. A hand-assembled `Keel.app` (debug binary, ad-hoc
  signed, `CFBundleIconName`/`CFBundleIconFile` = `AppIcon`) showed the Keel icon through `NSWorkspace.icon(forFile:)`,
  the Finder's icon source, on macOS 26.
- **Pending:** the icon in the Dock, Finder and Cmd-Tab from the packaged app, and Dark / Tinted switching with System
  Settings → Appearance → Icon & widget style (no screen capture here, and the system setting wasn't changed); the
  icon on macOS 14–15; the bundle Info.plist keys arrive with `package-release.sh` (KEEL-052).
- **Known limitation:** Icon Composer bundles have no per-size layers, so where macOS 26 draws the icon from
  `Assets.car` it scales the full mark down to 16–32 px; the small form is in the `.icns`, the exports and the
  sidebar (documented in 08 Design → App icon).
