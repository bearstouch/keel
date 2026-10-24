# KEEL-045 · Accessibility pass

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

- [x] **AC1.** An automated audit finds no unlabeled control in any screen. *(AccessibilityAuditTests.testEveryControlHasLabel hosts every screen — empty and main window in each mode, key list, every editor writable / read-only / partial, all sheets, Info, palette, keyboard settings — and walks its accessibility tree; testAuditCatchesUnlabeledControls proves the audit fails on an unnamed button and text field)*
- [ ] **AC2.** The acceptance scenario completes keyboard-only. *Automated so far:* KeyboardNavigationTests cover the Tab order per screen, ↑/↓ in the sidebar and editor tables, ⌃Tab out of the value viewer and console, and ⌘I → Edit Connection. **Pending:** the full keyboard-only run in the launched app against real servers.
- [ ] **AC3.** VoiceOver pass recorded (pending until performed by hand). **Pending.**

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `AccessibilityAuditTests.testEveryControlHasLabel` | walk view hierarchy per screen |
| `AccessibilityAuditTests.testStatusIsNotColorOnly` | Status is not color only |
| `KeyboardNavigationTests.testTabOrderPerScreen` | Tab order per screen |

## Notes

- Fixed by the audit: keyboard-settings list label, key-list column title and disclosure-triangle labels. New: keyboard
  row navigation and accent focus rings for the editor tables, focus rings for the sidebar, connection form and key
  list, ⌃Tab / ⌃⇧Tab out of text views that keep Tab, ⌘I to edit the sidebar's selection, editor rows spoken with
  their column headers, and "TLS not verified" in the toolbar and on the tab (FR-CN03). The keyboard model is in
  [04 → Keyboard model](../04-non-functional-requirements.md#keyboard-model).
- The audit exempts the parts of AppKit composites (scroll bar arrows, date picker steppers) that AppKit names through
  the whole.
- Follow-ups: "TLS not verified" in Info (FR-CN03 / 02 Architecture); the sidebar's focus shows on the selected row,
  which may be scrolled out of view or inside a collapsed folder; check the connection form's focus ring against the
  design canvas; tab bar and mode switch are reachable only with Full Keyboard Access (⌘1–3 and ⇧⌘[ / ] cover them).

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
