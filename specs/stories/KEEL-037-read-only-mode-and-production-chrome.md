# KEEL-037 · Read-only mode and production chrome

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S5 | [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md), [KEEL-026](KEEL-026-windows-connection-tabs-and-modes.md) |

**Specs:** [FR-SF01, FR-SF02, FR-SF07](../03-functional-requirements.md#5-safety), [08 Design → Production strip](../08-design.md#production-strip)

## Story

As an operator, I want production connections to look different and be read-only when I say so, so that I can't change production by accident.

## Scope

- Read-only toggle per profile; turning it off on a Production-labeled profile asks first
- 28 px maroon strip "Production · Read-only" under the tab bar; Window menu "[PROD]"
- "Writing to PRODUCTION" notice the first time per tab on writable production profiles
- Server-enforced read-only shown when the ACL user can't write

## Acceptance criteria

- [ ] **AC1.** The strip appears only for production tabs in the frontmost window, with text, in both themes.
- [ ] **AC2.** Turning read-only off on Production requires confirmation.
- [ ] **AC3.** A protocol trace of every editor action on read-only shows nothing sent.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `ProductionChromeTests.testStripVisibilityFollowsTab` | Strip visibility follows tab |
| `ProductionChromeTests.testDisablingReadOnlyAsks` | Disabling read only asks |
| `ProductionChromeTests.testWindowTitleMarksProd` | Window title marks prod |
| `ProductionChromeTests.testStripContrast` | ≥ 3:1 / text 4.5:1 |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
