# KEEL-028 · Value viewers: Text, JSON, Hex, Raw

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 5 pts | S5 | [KEEL-027](KEEL-027-editor-shell-save-bar-and-conflicts.md) |

**Specs:** [03 → Value editors common rules](../03-functional-requirements.md#3-value-editors), [08 Design → Editor](../08-design.md#editor)

## Story

As a user, I want to view any value as text, formatted JSON, hex or raw, so that I can read binary and structured data confidently.

## Scope

- Viewer panel with Text / JSON / Hex / Raw switch; JSON auto-selected when the value parses, "✓ Valid JSON" or the parse error line/column
- Hex: offset, hex, ASCII columns; Raw: redis-cli escaping; Text: UTF-8 with invalid bytes escaped
- Selected element of collections opens in the viewer; viewer choice remembered per key pattern for the session

## Acceptance criteria

- [ ] **AC1.** Binary values round-trip byte-exactly through view and edit in Text and Raw.
- [ ] **AC2.** Invalid JSON shows line and column and can't be saved from JSON view.
- [ ] **AC3.** Hex view of a 1 MiB value renders without blocking the UI.
- [ ] **AC4.** The viewer matches the `Main` board in both themes.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `ValueViewerTests.testJSONAutoDetection` | Jsonauto detection |
| `ValueViewerTests.testJSONErrorLocation` | Jsonerror location |
| `ValueViewerTests.testHexLayout` | offset/hex/ascii |
| `ValueViewerTests.testRawEscapingMatchesRedisCli` | Raw escaping matches redis cli |
| `ValueViewerTests.testTextEscapesInvalidUTF8` | Text escapes invalid UTF-8 |
| `ValueViewerTests.testRoundTripBinaryEdit` | Round trip binary edit |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
