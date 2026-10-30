<!-- Sanitized copy of the integration folder's STORE-ACCESSIBILITY-2026-10-30.md (2026-10-31). Local paths and personal names removed; the integration folder holds the original and evidence. -->

# Store accessibility: what to declare for MeowDisplay 2.0 (2026-10-30)

Branch feature/v2-hotspot-parity, commits 45db122 (Android) and 990375b (iOS). Nothing here is
submitted. Everything below was checked in code and builds only. **Nobody has used it with
VoiceOver, Voice Control or TalkBack on a device yet**, so the first step is the owner's device check.

## What the accessibility passes added

**iOS and iPadOS (990375b, 15 files):**
- The Mac picture is one element called "Mac screen". **Changed later the same night (7f8a0f1):**
  while VoiceOver runs, the picture takes no touches at all until the user picks **Turn On Direct
  Touch** from its actions (VoiceOver rotor ▸ Actions). Activating the picture (double tap) never
  clicks the Mac. Before this, VoiceOver's own gestures could reach the Mac: exploring by touch
  over a direct-interaction element, or the double-tap fallback that taps the element's centre.
  Direct Touch ends when VoiceOver stops. Android does the same for TalkBack (double tap and long
  press are answered by the view; injected touches are ignored until Direct Touch).
- VoiceOver announces: Connected to <Mac>; Reconnecting, Connection Lost and Mac Disconnected;
  Request Control granted or refused; Remote Files notices; pairing errors.
- Voice Control: spoken names for the tray keys (Cmd, Alt, Ctrl, Esc, Dock, Gear) and for
  Connect, Wake & Connect, Try Again, Pair and More. Connect's long-press Mirror and Extend choices
  are VoiceOver actions.
- Window mode: panes are buttons with a Focus action. The pane divider is adjustable (swipe up or
  down to resize in 5% steps). The card Add button is an action, and the app menus expose
  checkmarks and submenus.
- The "Switch to Window view?" prompt and the Natural Touch note stay on screen while VoiceOver
  runs, instead of disappearing after 8 or 12 seconds.
- Reduce Motion: banners and sheets fade instead of sliding. The marquee, drag overlays and Stage
  Peek were already covered.
- The pairing sheet scrolls at large text sizes, and the code is read digit by digit. Headings are
  added, decorative icons are hidden, and the A/V Sync and Control Size sliders have names and values.

**Android (45db122, 17 files):**
- TalkBack labels, roles, states and headings across Home, pairing, Settings, Window-mode panes and
  menus, Stage Peek, Remote Files and the editors.
- Live status announcements and a named live Mac view.
- Touch targets of 48 dp where the layout allows. Text wraps at large font sizes.

## App Store Connect: Accessibility Nutrition Labels

App Store Connect asks, for each device (iPhone, iPad), whether the app supports each feature.
Apple's rule is that a feature is declared only when people can complete the app's **common
tasks** with it. For MeowDisplay those tasks are: pair, connect, request control, use the tray,
change settings, use a Window-mode pane and Remote Files.

| Feature | iPhone | iPad | Recommendation |
|---|---|---|---|
| VoiceOver | After device check | After device check | Declare only once the checklist below passes. The Mac's own picture is video, so VoiceOver can't read what's on the Mac. Everything around it is labelled. |
| Voice Control | After device check | After device check | Same checklist, by voice ("Tap Connect", "Tap Cmd"). Custom icon-only shortcuts are named by their titles. |
| Larger Text | Don't declare yet | Don't declare yet | Home, Settings, sheets and Files scale. The in-session tray chips, the 10 pt control hints and the Stage Peek chips are fixed sizes. |
| Dark Interface | Declare | Declare | System colours throughout; the session screen is dark by design. Glance at Home in Dark mode first. |
| Differentiate Without Color Alone | Declare | Declare | Status and On/Off/Selected states are in text or traits, not colour only. |
| Sufficient Contrast | Don't declare yet | Don't declare yet | Not measured. Risks: white text on translucent overlays over a bright Mac picture, and system blue text (about 4:1 on white). |
| Reduced Motion | Declare | Declare | Decorative motion fades or stops. The live video and the finger-driven pan, zoom and rotate follow the user's own hands, so they are not decorative. |
| Captions | No (not applicable) | No (not applicable) | No spoken media of its own; audio is the Mac's system sound. |
| Audio Descriptions | No (not applicable) | No (not applicable) | No video content of its own. |

Labels can be changed later. Declaring fewer features now and adding more after testing is safer
than declaring one that fails review or a user.

### Automated audit on the iPhone (2026-10-30, XCUITest `performAccessibilityAudit`, iOS 27.0.1)

- Home screen: 6 issues. "Dynamic Type font sizes are partially unsupported" on How to Connect,
  the Mac's name, Nearby, This Device and Try the Demo; the Mac's name is clipped.
- Live Window-mode session: 1 issue. The Stage Manager notice ("Google Chrome is in Stage
  Manager's side strip…") is clipped.
- These confirm **Larger Text stays undeclared**. Sufficient Contrast had no audit findings on
  these screens, but the audit doesn't judge text over the live Mac picture, so it also stays
  undeclared until measured. iPad not audited yet (it was locked).
- Evidence: `evidence/live-stabilization-2026-10-30/audit-iphone*.log` and `.xcresult`.

### Owner's device check (about 15 minutes per device)

Turn on VoiceOver (Settings ▸ Accessibility ▸ VoiceOver, or triple-click the side button if set up).
1. Home: swipe through. Each Mac should read its name and status. Double-tap Connect.
2. Hear "Connected to <Mac>". Swipe to the Mac screen; it reads "Mac screen". Double-tap it:
   you hear how to turn on Direct Touch, and **nothing happens on the Mac**. Touch around the
   picture: nothing happens on the Mac. Then Actions ▸ Turn On Direct Touch: touches now reach
   the Mac. Find Mac screen again and Turn Off Direct Touch.
3. Tray: swipe through the keys (Command, Option, Control, Escape, Keyboard and so on). Double-tap
   Command and hear "On".
4. Request Control (on a session without control): double-tap, then approve on the Mac. You should
   hear the result.
5. Window mode: swipe to a pane ("<title> pane, button"), double-tap to focus it, then find "Resize
   tiles" and swipe up or down.
6. Settings ▸ Input ▸ Stage Manager: turn it off and on.
7. Remote Files: open a folder and hear the notices.
8. Turn VoiceOver off. With Voice Control on, say "Tap Connect", "Tap Cmd", "Tap Esc" and "Show names".
9. Larger Text: set the largest size (Accessibility ▸ Display & Text Size ▸ Larger Text), then check
   Home, pairing and Settings. Expect the in-session tray not to grow.

If steps 1–7 work on both devices, declare VoiceOver. If step 8 works, declare Voice Control.

## Google Play

Play has no per-feature accessibility declaration like Apple's. Accessibility shows in the listing
text and in Play's pre-launch report (an automated scan that runs on closed-test uploads).

Suggested listing sentence, once the TalkBack check passes:
> Works with TalkBack and Voice Access: controls, settings and pairing are labelled, status changes
> are announced, and text scales with your font size. The Mac's screen itself is a live picture.

TalkBack check: steps 1–7 above, with TalkBack gestures. **The Moto has no TalkBack** (LineageOS
without Google services), so this needs TalkBack installed on it (owner's call) or another
Android phone.

Known Android gaps (from the pass):
- Tray chips are 40 dp. Their size comes from the shared core layout geometry, so changing them
  changes the layout on every device.
- Pane title labels are 26–30 dp tall, below 48 dp.
- The brand blue #007AFF on white is about 4.0:1, under the 4.5:1 that small text needs. The
  pre-launch report may flag it.
- Dragging a window onto a pane has no non-touch equivalent.

## App Review notes (paste-ready, optional)

> MeowDisplay shows a live picture of the user's Mac. Around that picture, everything is accessible:
> pairing, connecting, the control tray, Settings, Window-mode panes and Remote Files support
> VoiceOver and Voice Control. The Mac picture itself is one "Mac screen" element with direct
> interaction, so VoiceOver users can touch it to control the Mac. The Mac's own contents can't be
> read by VoiceOver on the phone; VoiceOver on the Mac covers that.

## Not covered

- The Mac app (sender) had no accessibility pass in this round.
- The Performance overlay is a diagnostics view and is not accessible.
- New iOS strings are not yet in Localizable.xcstrings. The app is English-only today, so nothing
  changes for users; add them before adding a language.
- iPad Strip and Custom layouts were reviewed in code only.
