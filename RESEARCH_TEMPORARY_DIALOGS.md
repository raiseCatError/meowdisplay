# Research: dialogs from a captured app in Window view

**Status:** Research only. Nothing here is implemented beyond what already shipped (sheets drawn in their pane).
**Reviewed:** 2026-11-07, macOS 27.0 (26A428), MeowDisplay `dev` + the stabilization branches.
**Related:** issue #139 (a broader receiver-local floating pane idea; floating panes have since shipped). This note doesn't widen that issue.

## The problem

In Window view a pane shows one Mac window, captured on its own. When that app opens Open, Save, Upload,
Attach, Choose Folder or an alert, the person must be able to see and use it from the device. If the
dialog isn't drawn in the pane, the app looks frozen: it waits for an answer nobody can see.

## What ships today

- `WindowSheetMatcher` (Mac/WindowCatalog.swift) treats an **untitled, normal-layer window of the same
  process**, ordered directly above one of that process's windows, horizontally centred on it and
  starting inside it, as that window's sheet.
- `WindowWorkspaceEngine` captures the front-most such sheet of each tiled window beside the window and
  draws it over the pane at its true place (same transform as the window: zoom, fit, rotation).
  Presses landing on it go to the Mac at the sheet's real position (`sheetCovers`), so pointer, keyboard
  and scrolling work through the normal, authorized input path.
- Sheets are never listed on their own. Everything else that is a normal-layer, titled or on-screen
  window of a shared app is listed in Stage Peek like any window.
- Since `feature/window-close-cleanup`: when a window held in a pane, tab or float closes on the Mac, it
  leaves the layout automatically (`watch` / `gone`, PROTOCOL.md 6.10).

## Demonstrated (probe, 2026-11-07)

A small AppKit probe (an AppKit test app, not part of the repository) opened each dialog for
about two seconds over a 900×672 window and listed the window server's windows. The Mac's screen was
off during the run, so every window reported `onscreen=0`; layers, owners, titles and frames are still
the window server's own.

| Dialog | Windows the window server has | Layer | Title | Caught by `WindowSheetMatcher`? |
| --- | --- | --- | --- | --- |
| App-modal `NSAlert.runModal()` | one window owned by the app | 0 | empty | Yes when its window is centred on screen (the alert is centred on screen); otherwise it is listed as an untitled window and not drawn in the pane |
| Sheet `NSAlert.beginSheetModal` | one window owned by the app, centred inside its window | 0 | none | Yes |
| App-modal `NSOpenPanel.runModal()` | a window owned by the app **and** a window of the same size and place owned by `com.apple.appkit.xpc.openAndSavePanelService` (another process) | 0 / 0 | "Open" / "Open" | No (titled). Listed as an "Open" window of the app |
| Sheet `NSSavePanel.beginSheetModal` | a window owned by the app, centred inside its window, **and** the service's window at the same frame | 0 / 0 | "Save" / "Save" | No (titled). Listed as a "Save" window of the app |
| TextEdit at launch (earlier probe) | TextEdit's own "Open" window, the service's "Open" window, a TextEdit "Save Panel Accessory View" (off screen) | 0 | "Open" | No. Listed; the app-opening flow can place it in a pane |

What this shows:

1. Dialogs are not at the modal-panel level on this macOS: alerts and panels are ordinary layer-0
   windows. Window level can't tell a dialog from a document window.
2. Open and Save panels are **titled** and hosted partly in a separate system process. The app owns a
   window with the panel's title and frame; the file browser itself is a remote view served by
   `openAndSavePanelService`, which also has its own window at the same place. The catalog already
   leaves the service's windows out (`com.apple.appkit.xpc.` prefix).
3. So today a Save sheet or an Open panel is not drawn in its pane. It is in Stage Peek as a
   separate "Save"/"Open" window of the same app, which the person can choose or float by hand.

## Not demonstrated (needs a Mac with its screen on and the device)

- Whether ScreenCaptureKit's capture of the **app-owned** Open/Save window includes the remote file
  browser, or only an empty frame. If it is empty, the service's window would have to be captured too,
  and associating it by "same frame, same title, system process" is exactly the weak evidence this
  feature must not rely on.
- What Accessibility reports for each: whether the parent window's `AXSheets` holds the titled Save
  panel, the app-modal panel's `AXModal` and subrole, and whether this is stable across apps (AppKit,
  Catalyst, Electron, Chrome's own file chooser, Safari's upload sheet).
- Input into the remote file browser (typing a name, scrolling the file list, choosing a file) through
  presses posted at the panel's screen position.

## Safe subset (proposed, not built)

Only with evidence from the app's own process and Accessibility, never from timing, closeness or a
system process alone:

1. **Titled sheets drawn in their pane.** A same-process window that sits on a tiled window like a
   sheet, and that the parent window's Accessibility element lists in `AXSheets`, is treated exactly
   like today's untitled sheets (drawn over the pane, presses routed to it). Without Accessibility
   trust, or if the attribute doesn't confirm it, nothing changes. Requires confirming the capture
   shows the file browser (above).
2. **App-modal dialogs as a temporary float, on request.** When the app shown in a pane has a
   front-most same-process window that Accessibility reports as modal (`AXModal`) and it isn't drawn in
   the pane, the pane says so ("TextEdit is showing “Open” on the Mac") with **Show Here**, which floats
   that listed window. It is already listed to this device, so nothing new is exposed. The float is
   marked temporary: never saved, never undoable, removed when the window closes (`gone`), on
   disconnect, on revocation and on lock.
3. **Never automatic for another process.** Dialogs hosted only by a system process, unrelated apps'
   windows, notifications, password and permission prompts stay out, as today.

View Only stays view only throughout: no input reaches a dialog without the session's control grant.

## Limits today

- A Save or Open sheet, or an app-modal alert that isn't over its window, isn't drawn in the pane. Open
  Stage Peek: it is listed as a window of the same app ("Save", "Open", or untitled) and can be shown in
  a pane or floated, then answered there.
- A sheet on a sheet: only the front-most is drawn.

## Test plan once built

Browser upload chooser (Safari, Chrome), AppKit Open/Save as panel and as sheet, TextEdit at launch,
an alert over a Save panel, two apps opening dialogs at the same time, two captured apps each with a
dialog, a system dialog that must stay out, View Only and with control, Cancel/close/reopen, capture
suspension, rotation, reconnect, lock, and press/typing coordinates in the dialog.
