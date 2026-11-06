# Window mode

Besides **Mirror** (show a Mac display) and **Extend** (add a separate
desktop), a device can choose **Windows** in the app to open **Window view**:
the individual **Mac windows** you pick, arranged side by side on that
device. The in-app label is **Windows**, but on the website and in public
marketing we say **Mac windows** or **Window view** so it cannot be
confused with the Windows operating system (a separate unplanned idea,
[#84](https://github.com/raiseCatError/meowdisplay/issues/84)).
Each receiver makes its own choice; another receiver's mode does not change.

- Every receiver, including iPhone and compact Android phones: up to **9** panes.
- Minimum pane size and the space available decide which arrangements fit.
- One window is the default.

The limit follows the space the app actually has (split screen, a folded
cover screen, Stage Manager), not the device model. When the space shrinks,
extra windows move to **Hidden on this screen** in the window overview; none is
removed, and the arrangement comes back when the space returns.

## Using it

| | iPhone / iPad | Android | Mac Receiver |
| --- | --- | --- | --- |
| Open the window overview | Hold three fingers still on the picture, or Settings → Display → Show Mac Windows… | Hold three fingers still, the rail, or Settings → Display → Choose Windows… | Windows in the title bar, or ⌃⌥W |
| Quick switch | Stage Peek (default): touch and hold the left edge (or right, in Settings), slide to browse, lift (nothing changes), tap a window to show it in the active tile; tap outside to close. Drag inward or tap Expand for a larger browser. The top card, Full Desktop, returns to the whole Mac screen. Settings → Controls → Window Switcher → Rail brings back the window rail (a thin handle at the top by default; Move Rail for another edge) | Same (Settings → Display → Window Switcher) | Overview |
| Switch view | From Window view: Stage Peek's Full Desktop card, or the overview's Mirror/Extend. From the whole screen: answer Yes to "Switch to Window view?" (offered once per launch when the Mac supports it), or open the overview. From Extend, a pick or drop that starts Window view asks first, since the extended display goes away | Same | — |
| Pane/tab options | **Touch and hold a pane's title** (about 0.4 seconds), then **release without dragging** to open its menu: **Fullscreen on This Device / Exit Fullscreen**, Fill Pane / Show Whole Window, Change Window…, Arrange Panes, **Remove from Layout**, and (with control) Close Window on Mac…. A **single tap** selects the pane or switches tabs; it does not open the menu. **Double-tap** a pane's title to enter Fullscreen on This Device, and double-tap it again (it stays visible) to return to the same arrangement; the menu, the fullscreen strip's Exit Fullscreen button and the VoiceOver/TalkBack actions do the same. With one pane, use the rail's **Arrange** action to reveal its title | Hold a pane/tab title for options; a tap selects/switches tabs | Shared pane menu; Arrange shows the pane labels |
| Move a tile | Press and hold its name, then drag: a highlighted area shows where it lands (middle swaps, an edge splits). Release on **Cancel** to leave everything as it was. With more than one pane, moving a whole pane also shows **Remove from Layout** beside Cancel: release there to take the pane off this device's layout (Undo brings it back; the Mac window stays open). Remove is not offered for tabs, for windows or apps dragged in from Stage Peek, or for the last pane | Same | Same, while Arrange is on |
| Tabs in a pane | Drop a window on a pane's labels to add it as a tab; tap a label to switch (only the shown tab streams). Hold a tab's label and drag it: onto another pane's labels to move it there, onto an edge for a new pane, or along its own labels to reorder. Each tab keeps its own rotation, Fit/Fill and zoom. Remove This Tab only takes it out of the pane; the Mac window stays open | Same | — |
| Drag an app in | In Stage Peek, press and hold an app in the carousel or in search results, then drag it onto a pane: one window goes straight in; with several, pick which; with none, you're offered to open it on the Mac (needs control) and its first new window lands there. Nothing opens just because a drag began | Same | — |
| Resize | Arrange Tiles, then drag the grips between tiles | Same | Same |

### Floating windows (iPhone and iPad)

A window can also float over the panes instead of taking a place in the
layout. Floats work over panes and over Full Desktop alike; there is no
separate mode. Nothing about a float changes the Mac: the real window is not
moved, resized or brought forward.

| | iPhone / iPad |
| --- | --- |
| Float a window | In Stage Peek, hold a window's card and choose **Open as Floating Window** (in Mirror it floats over the mirrored desktop straight away; not offered in Extend). A pane's or tab's menu has **Float This Pane** / **Float This Tab**. While dragging a window or a pane title, **draw a circle with it, and a bit more (about a second)** to switch between **Pane** and **Floating** (the chip at the top says which; a ring above your finger fills as you circle, and one haptic marks the switch), or release it on **Float** beside Cancel. Circling on doesn't switch back: pause or move straight first. A shake, a wiggle, a zig-zag, a figure eight or an ordinary drag never switches. The same works with a pointer. Exactly: one and a quarter loops of turning the same way round, for at least one second, on loops 12-240 pt across (radius), with at least 80 % of all the turning one way, no sharp reversal (a step turning more than about 100°) and no 0.4 s without curving; the path is measured in 8 pt steps so touch jitter doesn't count. After a switch it waits until the circling stops (0.4 s) before it can switch again. Settings → Controls → **Default Window Placement** (Pane or Floating) decides where windows you open from Stage Peek go; windows already open stay put |
| Move | Drag the title pill on its top edge, or the short bar under it. While it moves this device draws it under your finger (from a recent still, at its own Fit, zoom and rotation) and the Mac leaves it out, so it's never shown twice or left behind; the live window comes back where you let go. Let go slowly and it stays; let go faster and it glides on and slows down. Touch it while it glides to catch it |
| Tuck it away | Fling it toward the left or right edge, or pull it more than halfway past one, or choose Tuck in its ⋯ menu. A handle stays on that edge: tap it, or pull it inward, to bring the float back where it was. Slide a handle along the edge to move it. Several tucked floats line up; when they don't fit they share one handle with a menu. A fast throw across the middle never tucks. Tucking only hides it here: the Mac window stays open |
| Resize | Drag the curved grip at either lower corner: width and height change freely. The float is a viewport onto the window: its view (Fit with bars where the shapes differ, Fill, your zoom, rotation) scales with it and is never stretched. ⋯ → Size → **Match Window** gives it the window's shape again (no bars). A new float on an iPhone opens at about two-thirds of the width, like picture in picture. With a pointer, the grips show a resize pointer |
| Front and focus | Touch a float to bring it to the front and type into it. Input only reaches the window drawn on top at that point, never a pane a float covers |
| Back into the layout | ⋯ → **Add to Layout**, or circle while dragging its title (it folds into a card under your finger) and drop it on a pane: on a pane's middle it becomes a tab there (it never replaces the window that was there), at an edge it becomes a new pane. Dropped on Cancel or nowhere, it goes back where it was; circling again unfolds it back into the float |
| Fullscreen | Double-tap the title, or ⋯ → **Fullscreen on This Device**. Exiting brings the float back exactly where it was |
| Other options (⋯) | A short native menu, built when it opens (it never changes or jumps while open). Two rows of three at the top act on this device only: **Fullscreen**, **Tuck Left**, **Tuck Right**, then **Fill Viewport** / **Whole Window** (the picture inside the float, cropped or whole; never the Mac window), **Rotate**, **Reset View**. Then Bring to Front (when it isn't), Add to Layout, Size (Small, Medium, Large, Match Window), Change Window…, **Remove from This Device** (the Mac window stays open; Undo brings it back). Everything that changes the real window is in its own **On Your Mac** submenu and needs control: **Show on Mac** (when it's minimized or hidden), **Minimize on Mac** (it stays minimized: the float says so and offers Show on Mac) and **Close Window on Mac…** (asks first). Moving, resizing, tucking, docking or removing a float never minimizes or closes its Mac window |
| Overlapping | A float's outline, title and handles are drawn by this device over the Mac's picture. Where a float is in front, what's behind it (a pane's outline, divider, title, a float's outline, title pill, grips or grabber) steps aside and takes no touches there, so nothing shows through the front float or catches its touches. The resize grips and the bottom grabber show only on the selected float, under the pointer, or while it moves or resizes |
| VoiceOver | Each float is an element with actions: Bring to Front, Move Left/Right/Up/Down, Make Larger/Smaller, Tuck to Left/Right Edge, Add to Layout, Fullscreen on This Device, Remove from This Device. Tucked handles are buttons that bring their float back |

On iPhone (and other compact screens) one float shows at a time; opening or
restoring another tucks the one before. Floats stay where you left them
through rotation, reconnects and saved layouts (a layout saved with floats
opens on older versions of the app with the panes only). A Mac that doesn't
offer floating windows (an older MeowDisplay) keeps them tucked until you
connect to one that does. While a float is tucked, the Mac stops capturing
that window.

**Fullscreen on This Device** temporarily shows only the selected pane on the receiving device; **Exit Fullscreen** restores the previous pane arrangement. This differs from switching to **Mirror** or choosing **Full Desktop** in Stage Peek, which changes the content being viewed.

Removing a tile never closes the Mac window. **Close Window on Mac…** is
separate, asks first, and needs control of the Mac.

Each tile can be rotated on its own (0°, 90°, 180°, 270°). Only the picture
turns; the Mac window doesn't, and clicks, drags, scrolling and Pencil land
where you touch.

## Pointer and keyboard

There is one pointer across all tiles. Moving it over another tile only
highlights that tile; it never changes what you type into. Clicking a tile
makes it the one you type into (its window comes to the front on the Mac) and
that same click goes through. A drag stays in the window it started in, even
if it crosses into another tile.

macOS has one keyboard focus. MeowDisplay sends keys only to the tile you
selected, and only while that window's app really is in front on the Mac. If
something else comes to the front, the tile shows **Typing paused** and
nothing is typed until you tap to resume.

Control still needs the Mac's permission for each session (Request Control). View
Only sessions can arrange tiles and pick windows but send nothing to the Mac.

A press into a tile brings its window to the front first when another window
covers it on the Mac, then lands in it. On Android, hardware keyboards can't
send ⌘ shortcuts (Android keeps the Meta key's combinations for itself): use
the on-screen ⌘ key, or turn on Settings → Input → **Control Key Types ⌘**.

## How it works (sender)

Measured on macOS 27 (integration evidence `W1-sck`): ScreenCaptureKit's
`SCContentFilter(desktopIndependentWindow:)` captures a window's own content
when it is covered, off-screen (including negative coordinates) or belongs to
a hidden app on another Space. Minimized windows and hidden apps deliver no
frames (stills fail with -3811) and resume on the same stream when restored.
A window chosen for a tile while it is minimized (or its app hidden) is
brought back once, without activating its app. A window that was on screen
when its tile first showed it is never brought back by the Mac on its own:
**Minimize on Mac** sticks, and a tucked float shown again doesn't restore
it. **Show on Mac** restores it on request.

So Window mode creates **no virtual display** and never moves, resizes or
re-Spaces a window:

1. one ScreenCaptureKit stream per chosen window, scaled to its tile by the
   window server, at full rate for the active tile and reduced rates for the
   others (30 / 15 / 10 fps as tiles increase; 0 while minimized), at most 16
   window streams on the Mac at once;
2. a GPU compositor (Core Image on Metal) draws the tiles into one canvas the
   size of the receiver's panel, with each tile's fit and rotation;
3. the session's existing encoder sends it as before (H.264 or HEVC).

One encode per receiver keeps hardware encoders and the receivers' decoders
within limits; nine windows never mean nine streams to decode on a phone.
A tiny display stream keeps the Mac's audio and the usual capture lifecycle
(pause, Video Off, recovery).

**Floating panes** are panes drawn over the arrangement instead of in it
(PROTOCOL.md §6.10, `windowFloat`). They use the same capture, compositor
and encode: the compositor draws the tiled panes, then the floats back to
front, and input goes to whatever is drawn on top at that point, so a pane
a float covers can't be clicked or hovered through it. Moving, resizing,
raising or docking a float keeps its window's capture running (no restart,
no sharpness change). A pane almost entirely covered by floats is captured
at 2 fps; a visible float keeps at least 15 fps. A float tucked to the edge
is local: it isn't sent, so its capture stops until it comes back, and so
does its app's sound unless another pane shows that app (Window view plays
the sound of the apps on screen). The Mac
accepts floats only from a receiver that says it can show them; older
receivers, including Android 2.0, see Window view exactly as before.

From **Mirror**, a window opened floating (Stage Peek's **Open as Floating
Window**, a drag in Floating placement, or a tap with Default Window
Placement set to Floating) starts Window view with the mirrored display as
the pane underneath and the window floating over it, without asking, the
same way a window dropped onto the desktop starts Window view beside it.
The Mac's windows are untouched. Floats aren't offered in **Extend**: the
extended desktop is a virtual display that exists only while this device
extends, so leaving Extend removes it and macOS moves the windows on it to
the Mac's other displays, which a float must never cause.

Arranging a float is local too: moving, grabbing, resizing, flinging,
tucking, restoring, docking it, Add to Layout, Bring to Front, fullscreen on
this device, and zooming any pane make it the window you type into, but the
Mac window, its app, Stage Manager and Spaces stay as they are. The window
comes forward on the Mac only when you type into it (with control; the first
key waits for it, briefly) or touch inside it. Keys never go to another
window meanwhile: if the window can't come forward, typing pauses and the
float says so, with **Tap to resume**.

Leaving **Extend** always asks first. Showing a window in a pane from Stage
Peek or the overview, or dropping one onto the desktop, would start Window
view, which removes this device's extended display. So in Extend the device
asks **Switch to Window View?** and explains that the windows on the
extended display move to the Mac's other displays; **Stay in Extend** changes
nothing. The once-per-launch **Switch to Window view?** offer says the same
in Extend. Mirror switches without asking, as before: nothing on the Mac
moves.

Windows are listed by identity and metadata, not by position: MeowDisplay's
own windows, system UI, password prompts, the Stage Manager strip, every
app's menu-bar backdrop and untitled off-screen helpers are left out; titled
windows on other Spaces or minimized are kept. A window id is tied to its
process for the session, so a reused id is a different window and a tile
holding the old one is refused, never pointed at the new one.

## Limits

- **Other macOS accounts.** Each account runs its own MeowDisplay (see
  SAME_MAC_SESSIONS.md). A switched-out account has nothing on screen and
  can't be captured, so windows from two accounts can't be shown at the same
  time. Pairing with one account never gives access to another.
- **Several Macs in one workspace.** The protocol carries the host on every
  tile and each Mac handles only its own; receivers connect to one Mac at a
  time today.
- **Headless Macs.** Window mode needs windows on some display, even a virtual
  one. With no display at all it says so and suggests Extend, which creates
  one.
- **Input over covered windows.** macOS delivers clicks to whatever is on top
  at a point. MeowDisplay raises the target window first and sends nothing if
  something still covers it there. Background-window hover isn't possible
  without moving the Mac pointer, so hover reaches the Mac only over the
  active tile.
- **Zoom.** On iPhone and iPad, tile handles follow the unzoomed picture.
- **Stage Manager.** Windows on the current stage stream live. A window in
  the side strip doesn't: measured on macOS 27.0 (26A428) with a disposable
  window drawing a frame counter, ScreenCaptureKit's per-window stream
  suspends, its screenshot fails (-3811), and neither the legacy
  CGWindowListCreateImage nor SkyLight's private CGSHWCaptureWindowList (with
  or without the `fullSize` option) returns the real window — only the
  tilted thumbnail, or nothing while the strip is hidden. The pane keeps its
  last picture and says why; with control, **Show on Mac** brings that window
  onto the stage, and **Turn Off Stage Manager** switches it off for Window
  mode (back on afterwards). macOS applies Stage Manager only through its own
  control, so that runs two shortcuts the owner makes once with the
  "Set Stage Manager" action (Settings → System → Stage Manager); writing the
  `GloballyEnabled` preference has no visible effect (measured). A window
  that returns to the stage gets a fresh stream within about 2 s.
  Evidence: the integration folder's RESEARCH-2026-10-30-stage-manager-capture-lab.md.

## Turning it off

Mac: Settings → Displays → Windows → **Let devices show individual windows**.
Off, the Mac doesn't offer Window mode and ignores window messages.
