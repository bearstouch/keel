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

- [x] **AC1.** Binary values round-trip byte-exactly through view and edit in Text and Raw.
- [x] **AC2.** Invalid JSON shows line and column and can't be saved from JSON view.
- [ ] **AC3.** Hex view of a 1 MiB value renders without blocking the UI.
- [ ] **AC4.** The viewer matches the `Main` board in both themes.

### Verification notes

- AC1 observed in `ValueViewerTests.testRoundTripBinaryEdit` (all 256 byte values, look-alike `\x41` text, CR/NUL: re-submitting the shown text in Text, Raw and JSON changes nothing; an edit appends exactly) and `ValueViewerModelTests.testTextAndRawEditsBecomeTheDraftByteExactly` (Raw `"v\xff\x00\r"` becomes the draft bytes; Text shows and keeps them). The text view turns off every automatic substitution; typing in the running app is **pending**.
- AC2 observed in `ValueViewerTests.testJSONErrorLocation` ("Line 3, column 1: Expected a string key.") and `ValueViewerModelTests.testInvalidJSONBlocksSaveUntilText` (a blocked save sends no `SET`; after switching to Text it saves as is) and `testSaveRefusedWhileLargeValueIsPrepared`.
- AC3 (not checked): `testHexLayout` shows a 1 MiB value opens in Hex with nothing rendered up front (lines are formatted as the `NSTableView` asks), and `testLargeValuePreparedInBackground` shows values over 64 KiB are prepared off the main actor. Observing a smooth 1 MiB Hex view in the running app is **pending**.
- AC4 (not checked): **pending** design review of the viewer card against `Main` in light and dark, and a VoiceOver pass. No string `EditorBinding` exists until KEEL-029, so the viewer can't yet be opened in the app.
- Review fixes: the text view's coordinator follows a new viewer model for the same key name (database switch); typing during a save is put back to the draft; ⌘S is refused while a large value's view is being prepared.
- Follow-ups: each keystroke decodes (and in JSON view re-validates) the whole text on the main actor — debounce or move off-main for edits near 1 MiB; JSON colors aren't refreshed while typing; unparseable Raw text stays on screen after a revert with no other change; the first edit in JSON view stores the pretty-printed form.

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
