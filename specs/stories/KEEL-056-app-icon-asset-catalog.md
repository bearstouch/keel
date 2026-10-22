# KEEL-056 · App icon asset catalog

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

- [ ] **AC1.** All sizes are generated from one source by the script.
- [ ] **AC2.** ≤ 48 px uses the two-bar form.
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
