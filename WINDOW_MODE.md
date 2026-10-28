# Window mode

Besides **Mirror** (show a Mac display) and **Extend** (add a separate
desktop), a device can choose **Windows**: Mac windows you pick, shown side by
side on that device. Each device chooses on its own; nothing changes for the
others.

- iPhone and compact Android phones: up to **3** windows.
- iPad, unfolded foldables and large Mac Receiver windows: up to **9**.
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
| Switch view | From Window view: Stage Peek's Full Desktop card, or the overview's Mirror/Extend. From the whole screen: answer Yes to "Switch to Window view?" (offered once per launch when the Mac supports it), or open the overview | Same | — |
| Tile options | Tap a tile's name: Type Here, Change Window…, Rotate, Fill Tile / Show Whole Window, Maximize / Restore Layout, Arrange Tiles, Remove Tile, Close Window on Mac…. With one tile, open the rail and tap Arrange first (the name at the top is the rail) | Same | Same, while Arrange is on |
| Move a tile | Press and hold its name, then drag: a highlighted area shows where it lands (middle swaps, an edge splits) | Same | Same, while Arrange is on |
| Resize | Arrange Tiles, then drag the grips between tiles | Same | Same |

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

Input still needs the Mac's permission for each session (Request Input). View
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
- **Full-screen Spaces and Stage Manager** were not exercised with Stage
  Manager turned on (the test Mac had it off, and MeowDisplay never changes
  that setting).

## Turning it off

Mac: Settings → Displays → Windows → **Let devices show individual windows**.
Off, the Mac doesn't offer Window mode and ignores window messages.
