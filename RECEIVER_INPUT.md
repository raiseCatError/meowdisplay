# Mac Receiver input

A Mac running the Mac Receiver has an implemented display **and**
control-surface role ([open physical-QA tracker #12](https://github.com/raiseCatError/meowdisplay/issues/12)).
Once the sending Mac allows it, the receiving Mac's local trackpad, mouse
and keyboard are designed to drive that Mac while the video window is in
front, in Mirror or Extend.

**Verification boundary:** Automated input-forwarding tests and builds
pass, but the behavior has **not yet been physically verified using two Macs**.
The steps below describe intended behavior, not a claim that a real two-Mac
session completed. This outstanding QA is separate from the successfully
verified multi-device Mirror/Extend feature (#20).

## Using it

1. Connect as usual. Every session starts **View Only**.
2. Click **Request Control** in the video window's titlebar. In full screen,
   move the pointer to the top of the screen to show the titlebar. The
   sending Mac asks its owner, or allows it straight away if this device is
   set to **Always Allow Requests**.
3. While the titlebar says **Controlling**, the pointer, clicks, scrolling,
   pinch/rotate and keyboard go to the sending Mac.
4. To get this Mac back:
   - **⌃⌥⎋ (Control-Option-Escape)** pauses control. Click the picture to
     resume; that click only resumes and isn't sent.
   - Switching to another app or window (Command-Tab, a click outside the
     window) stops forwarding until the video window is in front again.
   - **Release** in the titlebar gives control back to the sending Mac. A
     new request is needed to control it again.

The sending Mac can revoke control at any time. Its own Allow Input switch,
per-device policy and request prompt all work exactly as for an iPhone or
iPad.

## What is forwarded

| Input | Sent as | Notes |
| --- | --- | --- |
| Pointer movement | `pointer` `move` (absolute, normalized) | Over the picture only, or anywhere during a drag (clamped to the picture's edge). |
| Click, double/triple click | `pointer` `down`/`up`, `clickCount` | Left and right (two-finger click, Control-click via the Control modifier). |
| Drag | `down`, moves, `up` | Released correctly even when the button goes up outside the window. |
| Scroll | `scroll` (video pixels) | Trackpad precise deltas and momentum; wheel lines ≈ 10 pt. Direction follows **this** Mac's natural-scrolling setting. |
| Pinch, rotate | `nativeAppGesture` | Full began/changed/ended lifecycle; cancelled if focus is lost. |
| Keys | `keyboard` `down`/`up` with HID usage | Every key of a full keyboard, F-keys, navigation and keypad. The **sending** Mac's keyboard layout and input method decide the character, as with a keyboard plugged into it. |
| Key repeat | `keyboard` `down` + `repeat: true` | This Mac's own repeat rate. Needs a sender from this branch; an older sender simply doesn't repeat. |
| Shift, Control, Option, Command | `keyboard` `modifierDown`/`modifierUp` | Applied to keys, clicks and scrolls on the sending Mac. |
| Caps Lock | `capsLock` in each key's `modifiers` | Not toggled on the sending Mac. |

**Not forwarded**:
- **Middle and other mouse buttons**: the protocol names left and right only.
- **Fn and Globe-key shortcuts**: macOS turns Fn+arrow into Home/End/Page keys before the app sees it, and those are forwarded.
- **Three- and four-finger swipes, Mission Control, Launchpad and other trackpad system gestures**: macOS keeps these on this Mac, by design.
- **Force Touch pressure**, and **text composed by this Mac's input method**: the sending Mac's own input method composes instead.

## What stays on this Mac

Input is never captured globally. Only events macOS delivers to the video
window while it is in front are looked at (an app-local event monitor scoped
to that window), so:

- System shortcuts macOS handles before any app — **Command-Tab, Command-Option-Escape (Force Quit), Command-Space, Mission Control, screenshots, Control-Command-Q (Lock Screen)** — always act on this Mac.
- **⌃⌥⎋** is reserved for pausing and is never sent.
- While controlling, app shortcuts such as Command-Q, Command-W or Command-, go
  to the **sending** Mac (it's what typing into that window means). Pause
  first (⌃⌥⎋) or switch away to use them on this Mac.
- A modifier still held from before forwarding started (the Command of the
  Command-Tab that brought the window forward) is never sent, so it can't
  turn the next key into a shortcut on the sending Mac.

## Never stuck

The receiver remembers every key, modifier, button and gesture it sent down.
Pausing, focus loss, Release, revocation by the sending Mac and closing the
window all send the matching releases, then `keyboard` `cancel` as a safety
net. A disconnect resets locally: the sending Mac releases everything on
session loss itself (PROTOCOL.md), and a reconnect starts View Only with
nothing held. The sending Mac ignores input the moment its grant ends,
whatever a receiver sends.

## Pointer feel

While controlling, the streamed cursor is drawn at this Mac's pointer
immediately instead of after a network round trip and a video frame. The
sending Mac's reported position takes over 0.25 s after local movement stops,
so the two can't disagree for long (for example when the sending Mac's own
trackpad moves the cursor).

## Code

| Piece | Where |
| --- | --- |
| Rules: geometry, key map, forwarding state machine, cursor echo | `MacReceiver/ReceiverInputForwarding.swift` (AppKit-free, unit tested) |
| AppKit events, window focus, sending, titlebar indicator, hint | `MacReceiver/ReceiverInputController.swift` |
| Video view event overrides | `ReceiverVideoView` in `MacReceiver/MacReceiver.swift` |
| Sender: extra HID usages, key repeat, scroll remainder | `Mac/InputRouting.swift`, `Mac/InputInjector.swift` |

No new wire message exists for any of this. The only addition is the optional
`repeat` field (PROTOCOL.md section 6.1).

## Automated coverage

`MacTests/ReceiverInputForwardingTests.swift` drives the forwarder with
synthetic event sequences:
- **Geometry**: exact fit, letterbox, pillarbox, resize, mixed-resolution full screen, clamped drags.
- **Key map**: a full round trip through the sender's injection table.
- **Pointer**: view only by default; request, decline and requests-disabled; old senders; hover; click, drag and release outside; double and right click; letterbox clicks.
- **Focus and pause**: focus loss mid-drag and mid-pinch; the pause shortcut and click-to-resume; Release.
- **Keyboard**: modifiers and shortcuts; Command held from Command-Tab; key repeat; Caps Lock.
- **Session**: revocation mid-typing; disconnect and reconnect with no stale state.
- **Sender side**: scroll remainder and repeat.
- **Cost**: a measured per-move decision cost.

These prove the receiver's rules and the sender's pure helpers. Nothing here
posts events into the live system. They do not prove how a physical
trackpad or keyboard feels, real latency, or the sending Mac's injected
events in real apps.

## Physical test checklist

Needs two Macs on the same network, paired, both built from this branch:
the sender (for example a MacBook Air) and the receiver (an older MacBook).

1. **View Only.** Connect: the titlebar says View Only; moving, clicking and typing in the window do nothing on the sender.
2. **Request.** Request Control → the sender prompts → Allow: the titlebar says Controlling and the hint names ⌃⌥⎋.
3. **Pointer, Extend.** Drag a window from the sender onto the receiver's extended desktop. With the receiver's trackpad: move, click, double-click a word, right-click (two fingers and Control-click), drag the window by its title bar and drop it with the button released outside the receiver window.
4. **Pointer, Mirror.** Same in Mirror; check the cursor lands exactly under the receiver's pointer at all four corners, windowed and full screen.
5. **Scroll and gestures.** Slow and fast two-finger scrolls (including momentum) in Safari and Finder; the direction matches the receiver's natural-scrolling setting. Pinch-zoom a photo in Preview.
6. **Keyboard.** Type a sentence with Shift; Command-C/Command-V; hold Delete (repeats); arrows, Home/End, F-keys, Escape; Caps Lock. A non-US layout on the sender types its own characters.
7. **Local shortcuts.** While controlling: Command-Tab, Command-Space, Mission Control, Command-Shift-4 and Command-Option-Escape act on the receiver.
8. **Pause and resume.** ⌃⌥⎋ → Paused; typing stays local; click the picture → Controlling again, without a click reaching the sender.
9. **No stuck keys.** Hold Shift (or a mouse button mid-drag), then Command-Tab away, then check on the sender that nothing is held: typing there is lower-case and no drag continues. Repeat with revoking control on the sender, and with unplugging the network mid-drag.
10. **Release and revoke.** Release → View Only, nothing reaches the sender. Request again, then revoke from the sender's device settings: input stops immediately.
11. **Reconnect.** Quit and relaunch the receiver: it starts View Only.
12. **iPhone/iPad unchanged.** With the same sender, an iPhone's Direct Touch, trackpad mode, keyboard, modifiers and scrolling behave as before. Slow two-finger scrolls should be no worse (the sender now carries the scroll remainder instead of rounding each event).
