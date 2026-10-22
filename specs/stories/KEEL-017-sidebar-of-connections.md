# KEEL-017 · Sidebar of connections

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E2 Connection management | P0 | 5 pts | S3 | [KEEL-014](KEEL-014-connection-profiles-and-keychain-secrets.md) |

**Specs:** [FR-CN13](../03-functional-requirements.md#1-connections), [08 Design → Sidebar](../08-design.md#sidebar)

## Story

As a user, I want my connections in folders in a quiet sidebar, so that I can find and open the right server quickly.

## Scope

- Folders (one nesting level), drag-and-drop reorder, rename, collapse state, `+` to add, context menu (connect, edit, duplicate, delete, copy URL)
- One-line rows: label dot, name, link icon when connected, "Failed" when failed; tooltip with host
- Keel icon and wordmark at the bottom left; light red sidebar in light theme
- Double-click / Return connects in a new tab, or focuses the existing tab (⌥ forces a new one)

## Acceptance criteria

- [ ] **AC1.** Moving a profile between folders and collapsing folders survive relaunch.
- [ ] **AC2.** VoiceOver reads name, label and status for each row.
- [ ] **AC3.** Connecting from the sidebar focuses an existing tab for the same profile and db.
- [ ] **AC4.** The sidebar matches the `Sidebar` board in both themes (manual design review).

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `SidebarModelTests.testGroupsAndOrderFromStore` | Groups and order from store |
| `SidebarModelTests.testDragReorderPersists` | Drag reorder persists |
| `SidebarModelTests.testAccessibilityLabelIncludesStatus` | Accessibility label includes status |
| `SidebarModelTests.testOpenFocusesExistingTab` | Open focuses existing tab |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.
