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
| Pane/tab options | **Touch and hold a pane's title** (about 0.4 seconds), then **release without dragging** to open its menu: **Fullscreen on This Device / Exit Fullscreen**, Fill Pane / Show Whole Window, Change Window…, Arrange Panes, **Remove from Layout**, and (with control) **Fill Window on Mac**, **Restore Previous Size on Mac** (after a Fill), Minimize on Mac and Close Window on Mac…. A **single tap** selects the pane or switches tabs; it does not open the menu. **Double-tap** a pane's title to enter Fullscreen on This Device, and double-tap it again (it stays visible) to return to the same arrangement; the menu, the fullscreen strip's Exit Fullscreen button and the VoiceOver/TalkBack actions do the same. With one pane, use the rail's **Arrange** action to reveal its title. Beside the Mac's menu bar a pane's titles fold to the shown tab's app icon (and **+N**): **one hold on that icon** opens the menu with the titles shown in full (the titles keep their form until you lift your finger), a **tap** on it shows the titles in full, and a double tap still toggles Fullscreen on This Device | Hold a pane/tab title for options; a tap selects/switches tabs | Shared pane menu; Arrange shows the pane labels |
| Move a tile | Press and hold its name, then drag: a highlighted area shows where it lands (middle swaps, an edge splits). Release on **Cancel** to leave everything as it was. With more than one pane, moving a whole pane also shows **Remove from Layout** beside Cancel: release there to take the pane off this device's layout (Undo brings it back; the Mac window stays open). Remove is not offered for tabs, for windows or apps dragged in from Stage Peek, or for the last pane | Same | Same, while Arrange is on |
| Tabs in a pane | Drop a window on a pane's labels to add it as a tab; tap a label to switch (only the shown tab streams). Hold a tab's label and drag it: onto another pane's labels to move it there, onto an edge for a new pane, or along its own labels to reorder. Each tab keeps its own rotation, Fit/Fill and zoom. Remove This Tab only takes it out of the pane; the Mac window stays open | Same | — |
| Drag an app in | In Stage Peek, press and hold an app in the carousel or in search results, then drag it onto a pane: one window goes straight in; with several, pick which; with none, you're offered to open it on the Mac (needs control) and its first new window lands there. Nothing opens just because a drag began | Same | — |
| Open an app into a tile | In **Choose a window for this tile** (a pane's **Change Window…**) or the overview, search finds the Mac's open windows and, under **Apps to Open**, any app on the Mac that has no window to show (not running, or running without one), each listed once. Tap one and confirm **Open**: the Mac opens exactly that app, without bringing it forward, and its new window goes into that tile (or, from the overview, where a picked window would go); nothing else in the layout changes and no Mac window is moved. Without control, **Request Control and Open** sends the usual control request and the app opens only once the Mac allows it. Several new windows: you pick one. No window within 20 s, a failed launch, no answer within 15 s, control ending before the Mac opened it, or the tile changing meanwhile: it stops, says so, and offers **Try Again** or **Choose a Window**. **Cancel**, or closing the picker, stops waiting; a window that shows later is never placed by itself | — | Same picker; ask for control first |
| Window closed on the Mac | Once the Mac confirms a window is closed (about a second after it closes): a floating window holding it goes away (tucked ones too); a tab goes and its pane shows the next tab; a pane whose only window closed stays where it was, empty, with **Choose Window** and **Remove Pane**. Minimizing, hiding, Stage Manager, Mission Control, other Spaces, a window missing from one listing, or a reconnect never removes anything, and Undo doesn't bring a closed window back. A window that closed while this device was disconnected stays as an unavailable pane | — | — |
| Resize | Arrange Tiles, then drag the grips between tiles | Same | Same |
| App icons | Pane and float titles, Stage Peek and its dock show each app's icon from the Mac; until it arrives, or when the Mac has none, the same neutral tile with the app's initial everywhere. A pane's or float's icon is asked for as soon as the window is shown (not only while browsing) and again after every reconnect; an unanswered ask is repeated a few times (4, 8, 16 s), and the Mac answers an icon asked for again on a new connection, or later on the same one | — | Same for pane titles |

### Floating windows (iPhone and iPad)

A window can also float over the panes instead of taking a place in the
layout. Floats work over panes and over Full Desktop alike; there is no
separate mode. Nothing about a float changes the Mac: the real window is not
moved, resized or brought forward.

| | iPhone / iPad |
| --- | --- |
| Float a window | In Stage Peek, hold a window's card and choose **Open as Floating Window** (in Mirror it floats over the mirrored desktop straight away; not offered in Extend). A pane's or tab's menu has **Float This Pane** / **Float This Tab**. While dragging a window or a pane title, **draw a circle with it, and a bit more (about a second)** to switch between **Pane** and **Floating** (the chip at the top says which; a ring above your finger fills while you're circling, and one haptic marks the switch), or release it on **Float** beside Cancel. Circling on doesn't switch back. To switch again in the same hold, circle the other way round (it switches as soon as that circle is complete), or stop, move on or turn away and circle again; there is no waiting time. An ordinary drag, however it curves (round another window, a long sweep, nudging it into place), a shake, a wiggle, a zig-zag or a figure eight never switches. The same works with a pointer. Exactly (`WorkspaceCircleGesture`): the path is measured in 8 pt chords so touch jitter doesn't count, and the stretch judged is the latest one whose heading turned one and a quarter loops one way round. It switches only when that stretch is a deliberate loop: a least-squares circle through it has a radius of 12-150 pt with the points within 25 % of it (RMS); the points go round that centre the same way (85 % of the turning, at most 10 % of the steps back) and, over 16 pt steps, at least 80 % of the heading's turning is one way round; the path is at most 1.35 times the length of the circle it winds round; it closes (one loop back, where it headed the same way, the finger was within half the radius + 4 pt of where it is); its last loop is round (4πA/L² at least 0.6: a 2:1 ellipse counts, a 4:1 stretched loop doesn't); and it has been circling for at least a second. A step turning more than about 100° or a rest (0.3 s without 8 pt of travel) starts over. The ring shows only while the motion is plausibly a circle, from five eighths of a loop on. After a switch the next circle is built only from what comes after it, and the way round that switched can't switch again until that circling stops: a rest, a sharp turn, turning the other way by 90°, going 1.5 radii + 16 pt from its centre, or three radii of travel without going a quarter of the way round it (the circle it follows may drift while you circle on). Settings → Controls → **Default Window Placement** (Pane or Floating) decides where windows you open from Stage Peek go; windows already open stay put |
| Move | Drag the title pill on its top edge, or the short bar under it. While it moves this device draws it under your finger (from a recent still, at its own Fit, zoom and rotation) and the Mac leaves it out, so it's never shown twice or left behind; the live window comes back where you let go. It follows your finger past any edge or corner (the screen cuts it off there). Let go slowly and it stays; let go faster and it glides on and slows down. Let go partly off screen and it glides back to where its title and ⋯ can be reached, clear of the Dynamic Island, the notch and the Home indicator. Touch it while it glides to catch it |
| Tuck it away | Throw it toward any edge, pull it more than halfway past any edge (in a corner, the edge more of it is past), or choose **Tuck Left** / **Tuck Right** in its ⋯ menu. A throw carries on the way it was going: if that path would take it past an edge it tucks into the first edge it reaches, from the middle or from the far side alike (thrown toward a corner, whichever edge it crosses first). A move that isn't a throw never tucks, however far across the middle it goes, and a throw that falls short glides and stays. While a dragged float hangs more than halfway past an edge, that edge glows where it would tuck, as long as the window. The window itself slides behind the edge and waits there at its own size: a thin strip of it (20 pt, its own rounded inner edge) stays in view, as long as the window (a window 260 pt tall tucked at the left leaves a 260 pt strip), with a quiet grip that brightens under your finger or the pointer. The strip shows the window's last picture (its app icon on a dark card until there is one). Strips on the top and bottom lie along the edge, clear of the corners; all of them stay inside the safe area and clear of the status bar, Dynamic Island and Home indicator bands, so the system's own swipes stay where they were. They give way to the system's edges first, then to the controls (the control tray, the function tray, the ⌘ shortcut column, Stage Peek's handle), sliding along their edge to the nearest free room. Where the controls fill an edge (the control tray along the bottom of a phone in portrait), that edge's strips wait just inside the controls instead, at full length, their windows tucked in under the controls. A throw at an edge the controls fill deeper than that (a keypad over half the screen) glides back instead of vanishing under them, and a float already tucked there waits on the nearest edge with room, at the end next to its own edge, until its edge has room again. A tucked float always has a strip a finger can reach (when nothing of the picture is clear of the system's edges, it sits over the picture), and where a pane divider meets an edge the strip still takes the touch. Several on one edge line up at full length when there's room; on a crowded edge they get shorter evenly (never below 68 pt); only when there isn't room for each do they share one small handle with a menu. Tucking only hides it here: the Mac window stays open, and isn't moved or brought forward |
| Peek and bring it back | Touch a strip and the window peeks out a little more; a pull or a tap carries on from wherever it is, without a jump. Pull it inward and the same window comes out under your finger, point for point, more of it showing as it comes: let go past about 40% of the way (or flick it out) and it carries on out with your finger's speed, straight out of its strip, to where it waited (flush with its edge, at its own size); otherwise it slides back in. Catch it on the way back in to pull again. Tap a strip and the window slides out, straight out of that strip and flush with the edge the strip is on (just inside the controls, or another edge, when that's where it waited; after a rotation, the safe area's edge). Slide a strip along its edge to move it. A touch on a strip while its window is still tucking away or already coming out does nothing (and never reaches the window behind). It's one picture all the way, never a second copy: where the Mac can, it leaves the window out until it has landed, then the live window takes over in place. One haptic on tuck, one on restore; with Reduce Motion they fade instead of sliding |
| Resize | Drag the curved grip at either lower corner: width and height change freely. The float is a viewport onto the window: its view (Fit with bars where the shapes differ, Fill, your zoom, rotation) scales with it and is never stretched. ⋯ → Size → **Match Window** gives it the window's shape again (no bars). A new float on an iPhone opens at about two-thirds of the width, like picture in picture. With a pointer, the grips show a resize pointer |
| Front and focus | Touch a float to bring it to the front and type into it. Input only reaches the window drawn on top at that point, never a pane a float covers |
| Back into the layout | ⋯ → **Add to Layout**, or circle while dragging its title or bar (it folds into a card under your finger; the float itself isn't shown, here or by the Mac, while it's a card) and drop it on a pane, as you'd drop a pane: on a pane's title it becomes a tab, on its middle a tab too (docking never replaces the window that was there), at an edge a new pane (a tab of that pane when there's no room for another). **Remove from This Device** beside Cancel removes the float here only (the Mac window stays open; Undo brings it back). Dropped on Cancel or nowhere, or if the system interrupts the drag (a call, Control Center), it goes back exactly as it was (place, size, view, in front of or behind the same floats); circling again unfolds the card back into the float under your finger (the other way round straight away; the same way round once you've stopped, moved on or turned away) |
| Fullscreen | Double-tap the title, or ⋯ → **Fullscreen on This Device**. Exiting brings the float back exactly where it was |
| Other options (⋯) | A short native menu, built when it opens (it never changes or jumps while open). Two rows of three at the top act on this device only: **Fullscreen**, **Tuck Left**, **Tuck Right**, then **Fill Viewport** / **Whole Window** (the picture inside the float, cropped or whole; never the Mac window), **Rotate**, **Reset View**. Then Bring to Front (when it isn't), Add to Layout, Size (Small, Medium, Large, Match Window), Change Window…, **Remove from This Device** (the Mac window stays open; Undo brings it back). Everything that changes the real window is in its own **On Your Mac** submenu and needs control: **Fill Window on Mac** and **Restore Previous Size on Mac** (as in a pane's menu; the result shows at the top of the float), **Show on Mac** (when it's minimized or hidden), **Minimize on Mac** (it stays minimized: the float says so and offers Show on Mac) and **Close Window on Mac…** (asks first). Moving, resizing, tucking, docking or removing a float never minimizes or closes its Mac window |
| Overlapping | A float's outline, title and handles are drawn by this device over the Mac's picture. Where a float is in front, what's behind it (a pane's outline, divider, title, a float's outline, title pill, grips or grabber) steps aside and takes no touches there, so nothing shows through the front float or catches its touches. The resize grips and the bottom grabber show only on the selected float, under the pointer, or while it moves or resizes |
| VoiceOver | Each float is an element with actions: Bring to Front, Move Left/Right/Up/Down, Make Larger/Smaller, Tuck to Left/Right/Top/Bottom Edge, Add to Layout, Fullscreen on This Device, Remove from This Device; tucking says which edge it went to. Each strip is a button named **Restore** and the window's name, says which edge it's tucked at, and has Restore and Remove from This Device actions; the strips are read together, around the edges from the left (left, top, right, bottom). A shared handle is a button with a menu of its windows |

An iPhone shows several floats at once, overlapping like on an iPad: as many as
the workspace's nine windows allow (one pane and eight floats). Each new one opens
a step up and across from the one before (the first at the bottom centre), never
exactly on top of another. Bringing one to the front or back from its edge never
tucks, resizes or removes the others, and a small screen never does either; the
Mac's own capture limits still apply (a window over them says so). Floats stay where you left them
through rotation, reconnects and saved layouts (a layout saved with floats
opens on older versions of the app with the panes only). A Mac that doesn't
offer floating windows (an older MeowDisplay) keeps them tucked until you
connect to one that does. While a float is tucked, the Mac stops capturing
that window; its strip keeps the window's last picture. A reconnect drops
that picture, so the strip then asks for the window's thumbnail, the way Stage
Peek does (read only), and shows its app icon on a dark card until it comes.

**Fullscreen on This Device** temporarily shows only the selected pane on the receiving device; **Exit Fullscreen** restores the previous pane arrangement. This differs from switching to **Mirror** or choosing **Full Desktop** in Stage Peek, which changes the content being viewed.

Removing a tile never closes the Mac window. **Close Window on Mac…** is
separate, asks first, and needs control of the Mac.

### Fill Window on Mac and Restore Previous Size on Mac

Sometimes the window on the Mac is simply small, and enlarging its picture
here doesn't give the app more room. **Fill Window on Mac** (in a window
pane's menu, with control) resizes the real Mac window to fill the usable
area of the display it is on: below the menu bar, clear of the Dock, and
clear of Stage Manager's strip when its items are showing there. It is not
macOS full screen: no new Space is made. **Restore Previous Size on Mac**
appears after a Fill and puts the window back exactly where it was. These
are different from the pane's own **Fill Pane / Show Whole Window**, which
only changes how this device draws the picture.

Safety rules (PROTOCOL.md 6.10):

- Only these two menu items do it. Moving, resizing, zooming, rotating,
  floating, tucking or fullscreening a pane on the device never touches the
  Mac window, and nothing does it automatically.
- Needs control of the Mac. The Mac checks again right before it acts, and
  does nothing while the Privacy Shield asks for its password or Mission
  Control is open.
- Only the exact window the pane shows: the same window id, app and
  identity the Mac listed, matched to exactly one standard window by
  Accessibility with the same frame and title. Anything less certain is
  refused ("couldn't tell which window"), never guessed.
- It sets that one window's position and size and nothing else: no green
  button, no Window menu, no keyboard shortcut, the app isn't brought
  forward, and full screen is never turned on.
- It reads the result back from both Accessibility and the window server
  before saying it worked. An app that won't go bigger (or smaller) than its
  own limits is reported as resized "as far as the app allows".
- Refused, with the reason shown on the pane: windows that can't be resized,
  full-screen, minimized or hidden windows, windows in Stage Manager's strip,
  windows that closed or reopened, and Macs without Accessibility permission
  for MeowDisplay.
- Restore only applies while the window is still exactly where Fill left it.
  If it was moved or resized on the Mac since, Restore says so and forgets
  the old size; if the display it was on is gone, nothing moves. The old
  sizes are kept in memory only (at most 64), never saved.

Not on Android yet.

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
re-Spaces a window on its own (only **Fill Window on Mac** / **Restore Previous
Size on Mac**, chosen by a person with control, resize one):

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

**Apps to open** in the window picker come from the Mac's app list (`appCatalog`, the same
list as Stage Peek and Launchpad: Spotlight's index of the app folders, kept up to date by the
Mac, so asking for it doesn't enumerate the disk again). The picker asks for it when it opens,
with the revision it holds, so an unchanged list is a one-line `same` answer; the window
listing's refresh every few seconds doesn't ask again (an unanswered ask is repeated a few
times). An app is opened only with control (`appLaunch`, checked when it arrives and again
right before the app opens), by bundle id, without activating it; the receiver waits for a
window of that app that wasn't listed before and puts it in the tile the picker was opened
for, after checking the tile still shows what it showed. Each step is logged on the receiver
as `pickerOpen:` (requested, control requested, launch sent, launch answered, window seen,
several windows, placed, failed, cancelled) and on the Mac as `workspace: appLaunch`.

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
