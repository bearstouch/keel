# KEEL-050 · Accessibility pass

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 5 pts | S9 | [KEEL-042](KEEL-042-server-info-overview.md), [KEEL-041](KEEL-041-console-view-history-completion-streaming-masking.md) |

**Specs:** [NFR-AX01–NFR-AX04](../04-non-functional-requirements.md#accessibility), [DS-04](../08-design.md#principles)

## Story

As a VoiceOver or keyboard-only user, I want every screen fully operable and described, so that Keel is usable without sight or a mouse.

## Scope

- Labels, roles, states on all controls; tables expose rows/columns/headers; focus visible everywhere
- Keyboard-only run of the acceptance scenario; VoiceOver pass

## Acceptance criteria

- [ ] **AC1.** An automated audit finds no unlabeled control in any screen.
- [ ] **AC2.** The acceptance scenario completes keyboard-only.
- [ ] **AC3.** VoiceOver pass recorded (pending until performed by hand).

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `AccessibilityAuditTests.testEveryControlHasLabel` | walk view hierarchy per screen |
| `AccessibilityAuditTests.testStatusIsNotColorOnly` | Status is not color only |
| `KeyboardNavigationTests.testTabOrderPerScreen` | Tab order per screen |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
