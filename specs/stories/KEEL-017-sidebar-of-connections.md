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

- [x] **AC1.** Moving a profile between folders and collapsing folders survive relaunch.
- [ ] **AC2.** VoiceOver reads name, label and status for each row.
- [x] **AC3.** Connecting from the sidebar focuses an existing tab for the same profile and db.
- [ ] **AC4.** The sidebar matches the `Sidebar` board in both themes (manual design review).

**Verification (KEEL-017).** Observed in `SidebarModelTests`, `SidebarModelBehaviorTests` and `SidebarModelReviewTests`
(`KeelUITests`).
- AC1: `testDragReorderPersists` reorders within a folder, moves profiles between folders and onto a heading, reorders
  folders, then opens a fresh `ProfileStore` on the same folder and sees the same groups and order;
  `testGroupsAndOrderFromStore` does the same for a collapsed folder. Foreign text drops and no-op drops write nothing.
- AC2 (**pending** manual VoiceOver pass): every row is one accessibility element labeled "payments-prod, Production,
  connected" (`testAccessibilityLabelIncludesStatus` covers connected, failed, not connected, no label and a renamed
  label), with the host in the hint, button and selected traits, and an "Open in New Tab" action; folder headings read
  "<name> folder" with an expanded / collapsed value. VoiceOver in the running app was not exercised.
- AC3: `testOpenFocusesExistingTab` opens a profile on its database, opens it again and gets the same tab focused;
  ⌥ (newTab) opens another; Return opens the keyboard selection, never one hidden in a collapsed folder.
- AC4 (**pending** manual design review): offscreen renders of `SidebarView` in light and dark were compared with the
  `Sidebar` board (232 wide, 52 px traffic-light band, muted group headings, 32 px rows, `sidebarSelection`, link icon,
  mark and wordmark); the review in the running app with Inter / JetBrains Mono bundled (KEEL-049) is not done.

Known limits: opening from the sidebar adds or focuses a tab in `ConnectionTabs`, an in-memory registry; the actual
connect, the tab bar and `windows.json` arrive with KEEL-020 / KEEL-026, so until then no row shows the link icon or
"Failed" in the app. Search is the ⌘K palette (KEEL-048). Tabs of a profile deleted outside the sidebar (the sheet)
are left to KEEL-026.

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
