# Multiple devices: per-device Mirror/Extend

Each connected iPhone, iPad, Android device or receiving Mac can have
its own Mirror/Extend selection ([completed issue #20](https://github.com/raiseCatError/meowdisplay/issues/20)).
One device can mirror the Mac's built-in display while other receivers
extend it as separate desktops, and changing one device doesn't reset
another receiver's mode.

**Verification update (2026-10-31):** The maintainer confirms working
multi-device behavior was physically verified; issue #20 is closed. The
scenario checklist below remains a useful reproducible regression checklist,
not a record proving that every individual edge case was exercised.
Mac-to-Mac *input forwarding* is a separate, still physically unverified
feature ([#12](https://github.com/raiseCatError/meowdisplay/issues/12)).

## How it works

Every connected device already had its own `MacSender` pipeline: its own
virtual display (Extend), ScreenCaptureKit stream, encoder and connection.
What made devices share a mode was the Mac-wide `mode` and
`mirrorDisplayUUID` settings that every pipeline was built from, plus
`restartAll()`, which rebuilt every device whenever either changed.

| Piece | Where | Role |
| --- | --- | --- |
| Per-device choice | `DeviceDisplayModeStore` | Mode and Mirror source per receiver install id (`displayMode.<id>` in the Mac's defaults). Unset fields follow the Mac default. |
| Mac defaults | `SenderController.mode`, `.mirrorDisplayUUID` | The pre-#20 global settings, same storage, now the default for devices without their own choice. |
| Authority | `DisplayModeCoordinator` | Resolves each live session's assignment and names exactly the sessions a change must rebuild. |
| Live assignment | `DeviceSession.displayAssignment` | What that session's pipeline was actually built with. |
| Rebuild | `SenderController.rebuild(_:)` | `restartAll()` for one session: same teardown, same carried invitation. |
| Mirror source | `MirrorSourceResolver` | Automatic, capture recovery and wake recovery skip MeowDisplay virtual displays. |
| Live virtual displays | `VirtualDisplayRegistry` | Every MeowDisplay virtual display alive in this process and its owning session; `VirtualDisplay` registers for its own lifetime. |
| Display identity | `VirtualDisplayIdentityPlanner` | An Extend display skips a serial/product identity another live session holds. |

All of these except the controller and views are Foundation/CoreGraphics
only and run in the hostless `OpenSidecarMacTests` bundle.

### What changes what

| Event | Effect |
| --- | --- |
| Displays → Default Display Mode / Default Mirror Display | Rebuilds only devices that follow the default and now capture differently. |
| Device settings → Display Mode / Mirror Display | That device only; remembered for it. **Mac Default** returns it to following the default. |
| The receiver's own Mirror/Extend or Mirror display control | That device only; remembered for it. |
| Connect with Mirror / Connect with Extend | That device only; remembered for it. |
| Session approval (Allow & Mirror / Allow & Extend) | That device only. |
| Video Off (Mac-wide) | With a physical display: every Extend device moves to Mirror in place (no reconnect), the default becomes Mirror, and a device whose own choice was Extend now remembers Mirror. Video On never restores Extend. Headless: nothing changes mode. |
| Streaming profile, priority, codec, quality | Still Mac-wide `restartAll()`; each device keeps its own mode across it. |
| Forget | Removes the device's display mode with its other per-device state. |

A rejected request (Mirror without a usable physical display, Extend while
video is off) leaves that device as it was, tells only that receiver, and
shows the reason in the device's settings.

### Mirror source and lost displays

- **Automatic** is the first capturable display that is not a MeowDisplay
  virtual display. Before #20 it was simply the first display, which with an
  Extend device connected could be that device's desktop. With no
  MeowDisplay displays present, behavior is unchanged.
- An explicit pick of another device's extended desktop is honored, so a
  phone can deliberately mirror an iPad's Extend desktop.
- If the chosen display is missing at start, the device mirrors Automatic and
  keeps its choice; the picker says so. If the mirrored display disappears
  mid-session, capture recovery moves to Automatic under the same exclusion.
  If only MeowDisplay displays remain, Mirror fails with the existing
  "No display available to mirror" error instead of mirroring another device.

### No protocol change

`displayModeRequest`, `displayModeState`, `mirrorDisplayRequest` and
`mirrorDisplayState` were already per connection. Existing iPhone, iPad and
Mac receivers work unchanged. Their mode control now affects only themselves.

### Limits

- macOS decides how many virtual displays and simultaneous captures the Mac
  can sustain. MeowDisplay sets no limit of its own and has not measured one.
- A device without a known install id when it connects (a USB device whose
  install id isn't resolved yet) starts with the Mac default. Its own choice
  is applied by rebuilding that session once its hello authenticates.
- Changing a device's mode restarts that device's stream (a short reconnect)
  and, like any new connection, its input grant: it must request control
  again. Other devices are not touched.

## Automated coverage

`MacTests/DisplayModeAssignmentTests.swift` drives the real coordinator and
registry with synthetic receivers:

- Mirror + Extend, Extend + Extend, Mirror + Mirror (different sources)
- three receivers (the issue's table) and five in every mix
- changing one device while others are active; default changes reaching only
  followers
- interleaved connects and disconnects with no leaked entries or displays;
  a receiver crash mid-switch; route changes; sender restart from the store
- a USB session identified late; staged one-off choices
- rejections (no physical display, Video Off, ended session)
- Video Off and Video On semantics
- Automatic exclusion, explicit pick of a MeowDisplay display, a lost
  selected display, recovery after the mirrored display is unplugged
- identity collisions and registry ownership, including a late release of an
  old display
- input from three receivers landing in three different display rectangles

These prove the decision logic. They do not prove WindowServer,
ScreenCaptureKit or multi-device hardware behavior.

## Physical test checklist

Needs one Mac with a built-in display (plus an external display for the
Mirror-source rows), an iPhone and two iPads (or an iPad and a receiving Mac),
all paired. Run on a build from this branch.

1. **Single device, unchanged.** One iPhone: switch Mirror ⇄ Extend from the
   Displays page and from the iPhone. Both work as in 1.20.0.
2. **Mirror + Extend.** iPad A Extend, then iPhone → Mirror from the iPhone.
   iPad A keeps its desktop and windows, no reconnect. iPhone shows the
   built-in display, not iPad A's desktop.
3. **Extend + Extend.** iPad A and iPad B in Extend: System Settings →
   Displays shows two separate MeowDisplay displays; arrange them apart; drag
   a window onto each.
4. **The issue's table.** iPad A Extend · iPhone Mirror · iPad B Extend at
   once. Touch on each device lands on its own screen.
5. **Switch one while others stream.** Change iPad B to Mirror from its device
   settings: only iPad B reconnects; iPad A's display, window placement and
   input grant survive.
6. **Mirror + Mirror.** With an external display: iPhone mirrors built-in,
   iPad mirrors the external display (each from its device settings).
7. **Lost display.** While a device mirrors the external display, unplug it:
   that device moves to the built-in display (not an iPad's desktop); the
   others are unaffected. Plug it back and reselect.
8. **Defaults.** Set Default Display Mode to Mirror: only devices on
   **Mac Default** switch.
9. **Reconnect and restart.** Disconnect and reconnect each device, then quit
   and relaunch the Mac app: every device returns in its own mode, and
   System Settings → Displays shows no leftover MeowDisplay displays after
   all devices disconnect.
10. **Video Off.** With two Extend devices, turn Video Off: both move to
    Mirror without reconnecting. Turn it back on: both stay in Mirror.
11. **Headless.** On a Mac with no active physical display (for example a
    Mac mini with its monitor unplugged) and one device extending: a Mirror
    request from that device is refused with a message on that device only.
12. **Forget.** Forget a device with its own mode, pair again: it follows the
    Mac default.
