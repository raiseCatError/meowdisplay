# Changelog

## [2.0.0](https://github.com/raiseCatError/meowdisplay/compare/v1.20.0...v2.0.0) (2026-10-31)


### Features

* **receiver:** a Remote Access knock reports how it ended (Tailscale Phase 0) ([d3e61e8](https://github.com/raiseCatError/meowdisplay/commit/d3e61e82b06c1e298c8f241fb20c58c1584e31f6))
* **devices:** a short ID per Mac from its identity key (own HKDF label, not the fingerprint) tells same-named Macs apart: iOS home and Paired Macs, Android home, and This Mac's ID in the Mac's Settings ([d25e4f3](https://github.com/raiseCatError/meowdisplay/commit/d25e4f30a5e3f32cc64ba8187651d58040a58a0a))
* **remote:** a switch for automatic Remote Access in every app ([26ef126](https://github.com/raiseCatError/meowdisplay/commit/26ef126870273302564cb5d003ca5453be4ebc2c))
* **android:** A/V Sync both ways, including picture later than sound ([37f43bd](https://github.com/raiseCatError/meowdisplay/commit/37f43bd68f242d6594835ee3251adeae4b5df5a4))
* **mac:** accept a whole keyboard, key repeat and fine scrolling from receivers ([f514980](https://github.com/raiseCatError/meowdisplay/commit/f514980f440cda9db043608eb068e4d522e48862))
* **android:** accessibility pass — TalkBack labels, roles, states and headings across Home, pairing, Settings, Window-mode panes and menus, Stage Peek, Remote Files and the editors; live status announcements; 48dp targets; the live Mac view is named; text wraps at large font sizes ([45db122](https://github.com/raiseCatError/meowdisplay/commit/45db122c70b0634d3a4acdc1d12f60e2d43041e6))
* **ios:** accessibility pass: Mac screen as a direct-touch element, connection and control announcements, Voice Control names for tray keys and Connect, VoiceOver-adjustable pane divider, no auto-dismiss under VoiceOver, Reduce Motion fades, headings and hidden decorative icons ([990375b](https://github.com/raiseCatError/meowdisplay/commit/990375b7937572295db7eb9c79f5aafe305c8802))
* **mac:** add a per-device Mirror/Extend assignment model ([4e8e4e8](https://github.com/raiseCatError/meowdisplay/commit/4e8e4e88ed23c33afb4ca6d3fc8ad41ff44f6c37))
* **ios:** add a Return key to the touch controls ([af961c5](https://github.com/raiseCatError/meowdisplay/commit/af961c59b6d3a75a59f4a132c0762cedf77d5988))
* **window-mode:** Add to Current Stage for a window in Stage Manager's strip (iPhone, iPad, Android) ([103ed8b](https://github.com/raiseCatError/meowdisplay/commit/103ed8ba1bb0ce696b6fbd8f7e4f813956fa162d))
* **ios:** allow local viewport zoom to 8× and keep rotated pans on screen ([1cc4930](https://github.com/raiseCatError/meowdisplay/commit/1cc4930c64a182fdf36f27deedc81caeceb695f0))
* **ios:** announce the window's size as the Extend panel ([8eadbad](https://github.com/raiseCatError/meowdisplay/commit/8eadbad27b1ca609dd7121168e3fedcd3df3332b))
* **android:** another Mac waits until its invitation is accepted (F2) ([4b15e93](https://github.com/raiseCatError/meowdisplay/commit/4b15e93f0edab191485ab5446d1407c25d6c9a56))
* **receivers:** another Mac waits until its invitation is accepted (F2) ([8838641](https://github.com/raiseCatError/meowdisplay/commit/8838641aad86f7dad1ec5a5e4f784cd8a269314f))
* **stage-peek:** apps bar opens to four rows, then the whole screen; search filters the apps bar on iPhone, iPad and Android; choosing an app in the grown bar closes it ([70d3507](https://github.com/raiseCatError/meowdisplay/commit/70d3507b5db2c272cf8479478badc31ede7f39fe))
* **android:** arbitrate receiver-surface touches like the iOS receiver ([737ff12](https://github.com/raiseCatError/meowdisplay/commit/737ff12fa76d2b8b38e66c9b472c3033154fc557))
* **android:** authenticated media session core ([4086eff](https://github.com/raiseCatError/meowdisplay/commit/4086eff9299f177cf620de45caf93a599e6eedf0))
* **window-mode:** automatic fill (no letterbox in split panes when it hides little), zoom and pan keep the pane's shape, tabbed panes, window drop zones (labels = tab, edges = split, middle = replace); shared vectors schema 2 ([de34388](https://github.com/raiseCatError/meowdisplay/commit/de3438889c77cb52b6d3fbcd9ab4a36fe13cad0d))
* **android-core:** automatic fill, pane-shaped zoom, tabbed panes, window drop zones, 9 panes on phones, layout record schema 2; Dock-style compact Stage Peek, tap/flick entry and natural scrolling (same vectors as Swift) ([25f7e64](https://github.com/raiseCatError/meowdisplay/commit/25f7e648092b9afc7282bbb8d4346ed1ba871e5b))
* **android:** bridge software and hardware typing to the Mac like iOS ([1abd2d4](https://github.com/raiseCatError/meowdisplay/commit/1abd2d43d9de9d3ff6dda2e4626b3dda6f316777))
* **input:** Classic Direct Touch by default; phones start in Trackpad, iPads and tablets in Direct Touch (schema 21, applied once to existing installs) ([e9bbfb0](https://github.com/raiseCatError/meowdisplay/commit/e9bbfb05a13791a8df723fae5c5022f87bf62f53))
* **devices:** Clean Up old entries in the Mac's Known Devices and iOS Paired Macs ([0fc5b2d](https://github.com/raiseCatError/meowdisplay/commit/0fc5b2d210ca9e74d695f169401ce2bc4efec0b6))
* **android:** Clean Up old Mac entries; pins record when they were paired, and no platform guesses among undated pairings ([8cbab2f](https://github.com/raiseCatError/meowdisplay/commit/8cbab2f2dcaaa50a013d86c541879a915136eaf1))
* **android:** Connection Requests per Mac and Automatically Allow, Forget confirmation, Zoom While Typing, Device Name, Mirror-isn't-available notice while extending ([d1fbc73](https://github.com/raiseCatError/meowdisplay/commit/d1fbc734c87701e264b86229dc48b58c6d585018))
* **android:** Control key can type Command on hardware keyboards ([7bd6a45](https://github.com/raiseCatError/meowdisplay/commit/7bd6a452f09dd251fcc847b0c8dda25e4bf407c9))
* **android:** CoreGraphics geometry for the ported receiver controls ([0894cfb](https://github.com/raiseCatError/meowdisplay/commit/0894cfbbf343a82f5dfe5acb645a10e72737d09e))
* **android:** Custom Layout editor, full Function Tray editor, chord palette and gesture command editors; F1–F12 in the shared key list ([35d3022](https://github.com/raiseCatError/meowdisplay/commit/35d302280ad7ed1da0f917b84a3199a2f67fa044))
* **android:** decode H.264 and HEVC to the receiver surface ([3eee1fa](https://github.com/raiseCatError/meowdisplay/commit/3eee1fa3bcf0f9103416359c424e7ce89aeda2c9))
* **remote:** dial reported Tailscale addresses on verified paths ([4914723](https://github.com/raiseCatError/meowdisplay/commit/491472305bfc4151626f0f140ef2e375012aad3d))
* **stage-peek:** Dock-style compact peek, natural scrolling, search and app strip, tap/flick entry, bar in Mirror/Extend ([f02582b](https://github.com/raiseCatError/meowdisplay/commit/f02582b205542f6d00d132a0dea164b7f5157b06))
* **window-mode:** drag an app from Stage Peek onto a pane: one window goes in, several ask which, none offers to open it (control) and places its first new window there ([b5bf4ba](https://github.com/raiseCatError/meowdisplay/commit/b5bf4ba3f27803cb34428dc3f11ccd47ad5728f3))
* **window-mode:** each pane is an accessibility element (its action selects the pane, never a tap through to the Mac); live UI test for the two-finger turn and the Trackpad cursor ([da6b6ed](https://github.com/raiseCatError/meowdisplay/commit/da6b6ed499ae7ec3cd6b1ff146f6cbba6960f556))
* **window-mode:** each tab keeps its own rotation, Fit/Fill and zoom (saved with the layout); drag a tab along its own labels to reorder ([ca189eb](https://github.com/raiseCatError/meowdisplay/commit/ca189eb116c6ae296b6191cc5f5dc279f00831ea))
* **remote:** filter reported Tailscale endpoints in both apps ([2357d42](https://github.com/raiseCatError/meowdisplay/commit/2357d42541a0602f4ab2ae51568d6ead74e32dbe))
* **stage-peek:** floating window switcher for Window mode on iPhone/iPad ([d727146](https://github.com/raiseCatError/meowdisplay/commit/d72714688487d24db0dea6a1914be091eb46bf6a))
* **window-mode:** free-canvas panning in every pane — any edge or corner of the source can be brought to the pane's centre and stays there at 0.7x-8x (empty canvas intended, the source always covers the centre so it can't be lost); same rule on the Mac, iOS and Android (shared vectors); tests for edges, corners, diagonal pan, reverse, reset, rotation, resize and empty-canvas input ([a88a3b5](https://github.com/raiseCatError/meowdisplay/commit/a88a3b567b2a313c285cd4bb5369eb2d7e3bb74e))
* **stage-peek:** Full Desktop card at the top of the stack; full-desktop view offers "Switch to Window view?" (yes/no, once per launch) ([e649f32](https://github.com/raiseCatError/meowdisplay/commit/e649f32d0c5cecf752f5dfcf22c82e2b07803104))
* **window-mode:** Full Desktop is a pane source (Mac captures a whole display into a tile, input lands on that display); drag from the compact peek, a Cancel drop zone, drop a window onto the desktop in Mirror/Extend to start Window mode beside it; empty panes always close up and 2x2/3x3 fill from open windows ([75e5266](https://github.com/raiseCatError/meowdisplay/commit/75e5266308955cd5fd799ab227f5819fbfcd21d9))
* **mac:** give each connected device its own Mirror/Extend mode ([cdb2f2d](https://github.com/raiseCatError/meowdisplay/commit/cdb2f2d4a286058387972cde6718da7babd9d6f8))
* **android:** Help & About, and How to Connect on Home ([3b826f8](https://github.com/raiseCatError/meowdisplay/commit/3b826f873302156c3932f3ba021481512cfce231))
* **android:** home matches the iPhone: centred logo, name and status on top, Settings & Help at the bottom centre ([307dfb1](https://github.com/raiseCatError/meowdisplay/commit/307dfb10b4b8050b88bd700fe184e79a524c826d))
* **android:** inline Request Control wherever an action needs control (Close Window in Stage Peek and the gallery, opening apps, pane Minimize/Close, Remote Finder apps) — the same request as Settings, Awaiting Approval in place, Ask Again; never repeats the action ([e53759f](https://github.com/raiseCatError/meowdisplay/commit/e53759f17b3f6e8bcdf5b662bdba961819ed8d9d))
* **iOS:** inline Request Control wherever an action needs control (Close Window in Stage Peek and the gallery, opening apps, Remote Finder Open on Mac and apps) — the same request as Settings, Awaiting Approval in place, Ask Again after a no; never repeats the action by itself ([68cc73e](https://github.com/raiseCatError/meowdisplay/commit/68cc73ee13619faecb56cc398804e3a56f61bb60))
* **window-mode:** iOS panes — tab labels (shortened, scroll by finger), hold a label to move/merge/split panes, floating label menu (Fullscreen on This Device, Minimize/Close on Mac), drag windows from Stage Peek onto panes, local fullscreen with fading strip, Closed on Mac + Open on Mac; 2x2 and 3x3 on phones (9 panes, minimum size decides) ([4160dc3](https://github.com/raiseCatError/meowdisplay/commit/4160dc3a130c735258b269071825e28ad376d361))
* **stage-peek:** iOS — opens over Mirror/Extend/Window without changing the mode; floating glass search and Dock carousel of every Mac app (Finder first); expanded two-column gallery with displays and real stills; app empty state with Open on Mac; Launchpad with favorites and recents; edge-bar hint and touch haptic ([bdb9146](https://github.com/raiseCatError/meowdisplay/commit/bdb9146308e26682f6003819f42a3eda1308133e))
* **clipboard:** iPhone/iPad Unified Clipboard — Settings ▸ Clipboard (off by default; direction, types, files, size, automatic sending with the iOS paste prompt explained), copies from the Mac written for this device only, Send to Mac with the system Paste button, Mac-copied files saved or shared on request, same-moment copy to choose; Demo shows it off ([377e1ed](https://github.com/raiseCatError/meowdisplay/commit/377e1ed5dd0bf92534276bc2cfb37496fe7f5f39))
* **receiver:** keep recovering over Remote after the quick attempts (F8) ([4fbf85a](https://github.com/raiseCatError/meowdisplay/commit/4fbf85a8067a24641f1808d455ec4c97e03ed032))
* **workspace:** layout engine and tile transform for window workspaces ([254e323](https://github.com/raiseCatError/meowdisplay/commit/254e32333f8d9f759ff31cf1b5aea4b6cfbd5d5b))
* **mac-receiver:** let this Mac's keyboard and trackpad control the sending Mac ([e66337c](https://github.com/raiseCatError/meowdisplay/commit/e66337c11846771e03f13e6bfa7de96784648ec2))
* **window-mode:** Mac browses windows, displays and apps in every display mode; queued, cached stills; full app catalog; launch without activation; minimize on Mac ([e0b4518](https://github.com/raiseCatError/meowdisplay/commit/e0b45182770765235931d9bcb6053102719f63c0))
* **clipboard:** Mac Unified Clipboard — off by default; per-device Ask/Always/Block and direction (by install id) with the owner's prompt; pasteboard watcher that reads only for a ready device, skips private items and never re-sends its own writes; current-host-only writes; relay between devices; verified ranged transfers; Settings ▸ Clipboard and Devices ▸ Clipboard ([6640853](https://github.com/raiseCatError/meowdisplay/commit/6640853358345900a2d822ae834894d0610060a9))
* **android:** MeowDisplay control overlay in Compose ([5197020](https://github.com/raiseCatError/meowdisplay/commit/51970201fe6b9e113e5236e84d710818c4d16c01))
* **android:** MeowDisplay's own icon, logo and blue theme ([9b562b4](https://github.com/raiseCatError/meowdisplay/commit/9b562b4d273ced538caa6eec00ec04afd3e7938a))
* **ios:** minimal home: icon, name and one status line, one Macs card, quiet links, Settings & Help ([42f90cc](https://github.com/raiseCatError/meowdisplay/commit/42f90cce95c9392b29db12ee20b4e66d1bf55323))
* **android:** minimal home: one Macs card, short status, How to Connect and This Device as links ([89030f3](https://github.com/raiseCatError/meowdisplay/commit/89030f3f42f335b2585b0e8e00751ca6901bfe6c))
* **window-mode:** Mission Control pauses panes without restarts; devices say 'Mission Control is open on your Mac. Video is paused.' and one pane offers Exit Mission Control (control only; the Mac re-checks it is open before pressing Escape) ([0941f86](https://github.com/raiseCatError/meowdisplay/commit/0941f86997ef1f301339595bcd829f0a300585ad))
* **touch:** Natural Touch engine style (tap, swipe scroll, press-drag, long-press right click) with Classic unchanged; touchStyle preference, schema 19, shared gesture vectors ([52e522c](https://github.com/raiseCatError/meowdisplay/commit/52e522c4ccf5fbbe5a11471be576acf73cb55b39))
* **android:** Natural Touch style, Touch Style setting and one-time hint; shared gesture vectors ([6f146ca](https://github.com/raiseCatError/meowdisplay/commit/6f146ca7fc011f22570917382f92d9afaf3446ff))
* **privacy-shield:** OLED care — the cover's message and Unlock button move every minute, dim after a minute with no one at the Mac and go dark after five; local input brings them back ([ad9be49](https://github.com/raiseCatError/meowdisplay/commit/ad9be4947395bee0cf53d91fb0cbd9407d474e23))
* **window-mode:** one window per tile, tap a tile to type there, quiet restore of minimized windows, dark letterbox ([22bbb17](https://github.com/raiseCatError/meowdisplay/commit/22bbb17e5367baf0091dad7dba954efc5adf65a6))
* **window-mode:** opt-in Bring Stage Manager Windows Forward (Settings ▸ Controls, off by default) — choosing a window in Stage Manager's side strip also brings it forward on the Mac so it streams live; needs control (the Mac enforces it); iOS and Android ([93300d8](https://github.com/raiseCatError/meowdisplay/commit/93300d847af8b6a2cdd1e23abbacccaba5f585bc))
* **devices:** paired devices show who uses each Mac (its user's full name, from the welcome inside the authenticated session only, never discovery), next to the Mac's name and short ID on iOS home and Paired Macs and Android home; Mac setting Show My Name to Paired Devices (on; off makes devices drop it at their next connection); forgotten Macs lose it ([73580dc](https://github.com/raiseCatError/meowdisplay/commit/73580dce017e1f1f0bde34e7cb042e58758e271b))
* **window-mode:** pane menu bar on Android (same bar, drop-downs, submenus, Show/Hide in the label menu); the demo Mac has menus for its sample apps; the app's own menu is the bold first title (iOS + Android); pane labels keep clear of the demo badge ([a1d8ea9](https://github.com/raiseCatError/meowdisplay/commit/a1d8ea9e82bf81c8aee4123bb5b8eaf9ff2ccebc))
* **window-mode:** pane menu bar — the focused pane's app menus (File, Edit, …) as a bar under its label, read from the Mac through Accessibility one level at a time; tap a title for its drop-down (submenus, shortcuts, check marks); an item is pressed on the Mac only with control, after its window comes forward and only if every title on the way still matches; never the Apple menu; Show/Hide Menu Bar in the label menu; PROTOCOL.md 6.13 (iOS + Mac) ([bed6359](https://github.com/raiseCatError/meowdisplay/commit/bed6359c8bc63decac87feb8dc99ca331654b7bb))
* **window-mode:** pane outlines follow the screen's rounded corners at the outer screen corners only (iOS estimated from the device shape, Android from the window's rounded-corner insets); inner corners stay square ([0e4649c](https://github.com/raiseCatError/meowdisplay/commit/0e4649c0d243018aa9ded1e63c707e5e85e26b2b))
* **mac:** pause and Video Off stop window streams; setting to turn Window mode off ([4006df5](https://github.com/raiseCatError/meowdisplay/commit/4006df5aa8402b541dcaafb7341a60706c276e65))
* **android:** per-Mac Request Input Automatically ([02b1707](https://github.com/raiseCatError/meowdisplay/commit/02b1707cb80b0976366f7e556212d153bb894031))
* **window-mode:** per-tile zoom on iPhone — pinch and pan one tile, captured sharp on the Mac ([fd3a026](https://github.com/raiseCatError/meowdisplay/commit/fd3a026f1a42f6a7bbfdd6a6ff77b0ea7d863347))
* **android:** performance overlay ([a1d7a64](https://github.com/raiseCatError/meowdisplay/commit/a1d7a64550bcb72b0d61d9fd5798ac53b654ea4c))
* **android:** Picture in Picture ([0ae4cd8](https://github.com/raiseCatError/meowdisplay/commit/0ae4cd89779a3dcf981a918fa490ec313c0e9f42))
* **window-mode:** pinch shows at once as a local zoom of the pane (scaled still, clipped to the pane) until the Mac's sharp frame lands; two-finger double-tap resets the pane under the fingers and never right-clicks the Mac (a two-finger tap's right-click waits 0.25 s in Window mode); iOS and Android, shared preview math with tests ([b776c62](https://github.com/raiseCatError/meowdisplay/commit/b776c625cf679e4422de49e29adc3b981061114c))
* **android:** port remote viewport logic from the iOS receiver ([b8397c9](https://github.com/raiseCatError/meowdisplay/commit/b8397c9f5d14d2a9848af5055546fbc9d53741a1))
* **android:** port the pad and custom control layouts from the iOS receiver ([c3bf40c](https://github.com/raiseCatError/meowdisplay/commit/c3bf40ccca163c7fc4ddcce75a8a847a1b3c4061))
* **android:** port the pointer gesture engine, scroll momentum and keyboard edit planner from the iOS receiver ([1d1868a](https://github.com/raiseCatError/meowdisplay/commit/1d1868add287551e02dbb33feea0f6692ad2d30a))
* **android:** port the receiver control model from the iOS receiver ([eb317af](https://github.com/raiseCatError/meowdisplay/commit/eb317aff688d7a375ffe857f25cfc2a201be69ad))
* **android:** port the secure receiver protocol to Kotlin ([4a81053](https://github.com/raiseCatError/meowdisplay/commit/4a81053825c25c74598ecf594c69c1ce7339e198))
* **android:** port tray geometry and the receiver controls tests from the iOS receiver ([4db4b8d](https://github.com/raiseCatError/meowdisplay/commit/4db4b8d9e76fe1b5c86389d13c948fc661c05df2))
* Privacy Shield — while a device is connected the Mac covers its own screens in black (on by default for remote connections, off for local Wi-Fi/peer-to-peer/USB/hotspot; each set in Settings ▸ System and kept); the cover is left out of MeowDisplay's captures so the device's picture and control are unchanged; every physical display, not MeowDisplay's virtual ones; reveal needs a click from the Mac's own input and an administrator's password (macOS asks), and it covers again after 5 min (configurable) without physical input; turning it off asks for confirmation (and the password while covering); each connection shows whether it's on, on the Mac and on iOS/Android (welcome privacyShield) ([d060f8c](https://github.com/raiseCatError/meowdisplay/commit/d060f8cbd45e191186f7bef9eb907246a8b4b784))
* **android:** receiver app with Keystore identity and secure pairing ([7dc5116](https://github.com/raiseCatError/meowdisplay/commit/7dc5116a2720f1288155848028d322165a7f5ce7))
* **android:** receiver input view, keyboard, control store and overlay contract ([009def1](https://github.com/raiseCatError/meowdisplay/commit/009def192ac749c8b046b39625605de9c9e84104))
* **window-mode:** receiver model for browsing in every mode — app catalog, displays, prioritized stills with backoff, fuzzy search (shared vectors); browsing gated like the picture on the Mac ([976393b](https://github.com/raiseCatError/meowdisplay/commit/976393b74aa99864fe301ec1debfddb2632129f2))
* **window-mode:** redo, saved layouts per Mac (windows matched again by app when applied), press-and-hold a divider to resize outside Arrange; Layouts menu with arrangements in the Arrange bar (iOS + Android); fix the macOS 12 receiver build (ViewThatFits/scrollDisabled guarded) ([4970d4d](https://github.com/raiseCatError/meowdisplay/commit/4970d4d9e087b3fd150a16b8532415df24983f43))
* **android:** Remote Access core - endpoint parsing, pinned-TLS knock, saved addresses, status, recovery, route labels, Pair over Remote runner ([60bb1e4](https://github.com/raiseCatError/meowdisplay/commit/60bb1e47bba258add061e6195ca6ea225374be20))
* **android:** Remote Access in the app - Add Remote Mac, knock on Connect, status rows, Pair over Remote, route label ([015141b](https://github.com/raiseCatError/meowdisplay/commit/015141b8585b7aeecfd4d5256ab7f7e1bb5b2b90))
* **files:** Remote Finder on Android — the same Finder-like browser (asks the Mac first; locations, breadcrumbs, back button and system Back, list and icon views with stills, search across folders, Quick Look for images and text with pinch zoom, Open on Mac or in a pane's app with control, Show in Folder, Finder Windows, the Mac's apps) and Stage Peek search; the demo Mac answers with a small made-up folder tree; the demo badge no longer covers Stage Peek's search or the Finder header; Applications falls back to the running apps on both platforms ([bd1e684](https://github.com/raiseCatError/meowdisplay/commit/bd1e6841290f809440ae9feac861d19ac0c79c0f))
* **files:** Remote Finder on iPhone — Finder in the Stage Peek carousel opens a Finder-like browser of the Mac's approved folders (asks the Mac first; locations, breadcrumbs, back, list and icon views with Quick Look stills, search across folders, Quick Look for images and text, Open on Mac or in a pane's app with control, Show in Folder, the Mac's apps); Stage Peek search offers the same file search; shared receiver model with tests ([11379d3](https://github.com/raiseCatError/meowdisplay/commit/11379d32fb1ff710bf0bd700fae4868a284913e7))
* **files:** Remote Finder on the Mac — read-only browsing of owner-approved folders (off by default, chosen in Settings, home folder or external drives only, never ~/Library or hidden files, symlinks can't leave the folder); the owner allows each session from a non-activating prompt; list, search, previews, grid thumbnails, open on the Mac (needs control, never activates, optionally in a tile's app); PROTOCOL.md 6.12 ([792d436](https://github.com/raiseCatError/meowdisplay/commit/792d436d4715392e01d6bf38f3f9a9425966e5d2))
* **files:** Remote Finder permissions per device and two-way transfers on the Mac — Ask/Always/Block with approved-folders or all-accessible scope and separate browse, download, upload, modify and delete capabilities (keyed by the authenticated device id, never widened while a device controls the Mac, removed on Forget, re-checked on every request, Revoke ends transfers); the prompt offers This Session, Always Approved Folders and All Files (confirmed); range downloads in parts with digests that fail if the file changes; uploads into a hidden temp file finished atomically with conflict handling and space checks; new folder, rename, copy, move, duplicate, Trash with Put Back, zip/unzip (bsdtar), info, Open With; Settings ▸ Devices ▸ Files ([5d21f7a](https://github.com/raiseCatError/meowdisplay/commit/5d21f7afffdbd7b905607539d55cee88e65019fc))
* **remote:** remoteEndpoints wire format and a store for reported addresses ([66ca0cb](https://github.com/raiseCatError/meowdisplay/commit/66ca0cb4e3a9172d603699a12b8a8e4cbd0be989))
* **privacy-shield:** removed with this Mac's login password (macOS asks; was administrator) after a click from the Mac's own mouse or trackpad; while macOS asks, all remote input is dropped so the password can only come from the Mac's own keyboard, and the prompt is left out of what devices see; devices never see the cover: its windows and the Mac-side notice are made and left out of every capture before they appear (the cover waits for the captures; covers anyway after 3 s and logs it) ([9965776](https://github.com/raiseCatError/meowdisplay/commit/996577612745e48cdc1d8c4ac196aa8c97c79f6e))
* Request Control in place on Stage Manager strip and closed-window tiles (then Show on Mac / Open on Mac), and in Remote Finder's header while browsing without control — iOS and Android ([ccddbdf](https://github.com/raiseCatError/meowdisplay/commit/ccddbdf98f808199b8fd2f3b476e87248bdd6d05))
* **android:** run the secure media listener in the receiver app ([a64868d](https://github.com/raiseCatError/meowdisplay/commit/a64868d1b30732dc7bb774dcaeed923f92ac8665))
* **android:** schedule Mac audio like the iOS receiver ([e4f574d](https://github.com/raiseCatError/meowdisplay/commit/e4f574d120c75b12526efe64cf8271acd450e63b))
* **stage-peek:** scroll the expanded gallery over its cards, Close Window by swipe or X with the Mac's result, Compact Dock band, adaptive gallery columns ([6bf7966](https://github.com/raiseCatError/meowdisplay/commit/6bf7966cb488bb74c0e0ea56183c453a8f9f9e88))
* **remote:** send and keep remoteEndpoints in every app ([4e3aedf](https://github.com/raiseCatError/meowdisplay/commit/4e3aedfdc430e05dccee319b1f7e047f893ea407))
* **mac:** send Android receivers to their own update link ([a04c229](https://github.com/raiseCatError/meowdisplay/commit/a04c22937d96a43de6ac76efb429a3aeda4c69bb))
* **android:** send remote input only under the Mac's grant, never stuck ([60a6a88](https://github.com/raiseCatError/meowdisplay/commit/60a6a88a0d79cb20f0717b2704fcacd6da9b8b12))
* **android:** Session settings show status and an Auto-Reconnect switch ([ae5530b](https://github.com/raiseCatError/meowdisplay/commit/ae5530ba945873f2c143060b135f7d3967419f8c))
* **stage-manager:** Set Up Automatically in Settings > System > Stage Manager ([673445b](https://github.com/raiseCatError/meowdisplay/commit/673445b5490b8284d8ae79b469f1192fadc17bdf))
* **mac:** settings for "Use This Mac as a Display" and safer role switching ([334880f](https://github.com/raiseCatError/meowdisplay/commit/334880fdf98fbcd16fa0b4810de993016701a836))
* **android:** Settings from the home screen, connected or not ([d867376](https://github.com/raiseCatError/meowdisplay/commit/d8673762c7c7dc882724e5fc14c7c17b056ee819))
* **mac:** show and change each device's display mode in its settings ([b48fc01](https://github.com/raiseCatError/meowdisplay/commit/b48fc0198c34c8c8522e4da089368f42a307a5c2))
* **android:** show the MeowDisplay control overlay on the live screen ([a57cf87](https://github.com/raiseCatError/meowdisplay/commit/a57cf87f68b9a0ab708f19cd5b0202e34f5a5ce9))
* **window-mode:** sound follows the panes — the receiver hears only the apps whose windows its panes show (per app: ScreenCaptureKit can't split one app's windows), nothing when no pane shows a window, everything when a pane shows a whole desktop; if macOS can't narrow it, normal sound rather than silence ([a414bdf](https://github.com/raiseCatError/meowdisplay/commit/a414bdf297a7747788c17d1e412683bf17785a5d))
* **stage-peek:** Spatial Overview packing (shared rule) — windows keep their shape, bigger Mac windows look bigger within a clamp, rows without overlap in a stable order, every window at least 72 pt (more pages when needed, one size on every page); Swift + Kotlin + fixtures/stage-peek/spatial.json; tests for 1–50 windows on phone/landscape/tablet/small screens and extreme shapes ([5f8bf47](https://github.com/raiseCatError/meowdisplay/commit/5f8bf47d07f8da3eb45cebda29e7c1c04fed6a3a))
* **stage-peek:** Spatial Overview — Settings ▸ Controls ▸ Expanded Layout: Gallery (default) or Spatial Overview; the expanded peek then shows windows at their shapes and relative sizes (shared packing), with pages when they can't all be comfortably tappable; same tap, hold-to-drag into a pane, menu and close as the gallery's cards; search results stay a grid; iOS and Android ([d379a5a](https://github.com/raiseCatError/meowdisplay/commit/d379a5a62efc4ac6cb77d0ce10ffd85909845425))
* **window-mode:** Stage Manager on the Mac in Settings — the Mac always reports on/off; Turn Off (confirmed, restored when Window mode ends) and Turn On from the device, control only (iOS + Android) ([03f1a38](https://github.com/raiseCatError/meowdisplay/commit/03f1a38bfc9a8472f8f66f68877fcb348e4f085a))
* **window-mode:** Stage Manager — owner-confirmed Turn Off Stage Manager from a strip pane (control only, turned back on when Window mode ends or at next launch), optional Turn Off During Window Mode in Mac Settings ▸ System (off by default, confirmed), the Mac's Stage Manager state sent to receivers; no capture is started for a window in the strip (it could spoil later captures, SCStreamError -3811/-3812) — it starts once the window is on the stage ([54db3e4](https://github.com/raiseCatError/meowdisplay/commit/54db3e49e32d793305910fa7d1e13fb43e24bb66))
* **android:** Stage Peek core port with shared vectors; Window Switcher preference (schema 20) ([051bf68](https://github.com/raiseCatError/meowdisplay/commit/051bf68803b66b841b6a46b04e8675fce5721597))
* **android:** Stage Peek gallery scrolls over its cards, Close Window by swipe or X with the Mac's result, Compact Dock band, adaptive gallery columns ([8aacf06](https://github.com/raiseCatError/meowdisplay/commit/8aacf068c05f311416bf1e6147ece6bb4ac31792))
* **android-core:** Stage Peek search, still planner, app catalog, displays and launch on the wire (same vectors as Swift) ([633eca3](https://github.com/raiseCatError/meowdisplay/commit/633eca3e88f3ba6bd1d4c43bda002780d87854d0))
* **android:** Stage Peek window switcher in Window mode, Switch to Window view prompt, Window Switcher settings ([682c93f](https://github.com/raiseCatError/meowdisplay/commit/682c93fbf1432658fd418477aadfe084cf4d2441))
* **ios:** start iPad on the radial bottom-right Custom layout ([4e476d3](https://github.com/raiseCatError/meowdisplay/commit/4e476d322c45a389dd341b621fa21de8034f1f05))
* **android:** Streaming Profile, Priority, Maximum FPS, Mirror Display, Extend Shape, Video, Resync, Switched Out, Update Required ([6764ef6](https://github.com/raiseCatError/meowdisplay/commit/6764ef6d9a83d347ac8e273214f91950f1101cc4))
* **remote:** Tailscale discovery on the Mac (status --json on request: own name, peer suggestions) and connection guidance on Android and iOS ([1f3a98a](https://github.com/raiseCatError/meowdisplay/commit/1f3a98ae4891efdfd57d111bc529580073629fa0))
* tell several people's sessions on one Mac apart ([ce026d5](https://github.com/raiseCatError/meowdisplay/commit/ce026d55c9db4012db22a40960932b9ade3459c3))
* **ios-peek:** the grown apps bar shows each app's name under its icon, as in Launchpad ([63c3c46](https://github.com/raiseCatError/meowdisplay/commit/63c3c46feccd55e4b4841149185530adc4365518))
* **android:** the live receiver screen with input, viewport and Settings ([b57aa81](https://github.com/raiseCatError/meowdisplay/commit/b57aa8131df46abf88f99277576a4f6fb5ad2700))
* **receiver:** the Remote recovery schedule, ported from Android (F8, step 1) ([e6d2d7e](https://github.com/raiseCatError/meowdisplay/commit/e6d2d7e327aa9227502f79e638ebf21600d849de))
* **ios:** the roomy control layout follows the window, not the device ([ab850e3](https://github.com/raiseCatError/meowdisplay/commit/ab850e39790fc41204c3a50762666cb662879398))
* **ios:** the screen stays awake only while a Mac's picture is watched (30 s grace for reconnects); Auto-Lock as usual on Home, in Settings, in the background and after a failed connection; Keep Screen Awake While Streaming in Settings ▸ General ([185fa54](https://github.com/raiseCatError/meowdisplay/commit/185fa5420a62eba27b6173773396db9bcfa4fdcc))
* **shield:** Touch ID (or the login password on the same sheet) removes the Privacy Shield when the Mac has it; setting Remove With Touch ID; the Touch ID sheet is kept off devices like the password dialog ([009582f](https://github.com/raiseCatError/meowdisplay/commit/009582fbeba7adf7ae12efca936795fabc477637))
* **ios:** Touch Style setting (Natural Touch / Classic), Smart Touch under Classic only, live switch without reconnect, one-time Natural Touch hint ([0077b4c](https://github.com/raiseCatError/meowdisplay/commit/0077b4c329af5d29a352789e50f0ac2a7a8133a8))
* **window-mode:** Trackpad cursor per pane — always shown in the focused pane, kept on its picture, starts in the middle and comes back where it was per pane and tab ([d846d63](https://github.com/raiseCatError/meowdisplay/commit/d846d6320f2c35086e70e63b944b98978eefd1f4))
* **android:** Try the Demo, a sample Mac on the device with the real controls ([213a0a5](https://github.com/raiseCatError/meowdisplay/commit/213a0a5a6cb89cb8cb8aaebbf8ea70a00411bd15))
* **window-mode:** turn panes freely with two fingers — any whole-degree angle, the window point under the fingers stays put, magnet at right angles with Snap Rotation, instant turned preview; menu Rotate steps to the next right angle (Mac + iOS) ([c8923d1](https://github.com/raiseCatError/meowdisplay/commit/c8923d1dcff8b2848e99302cec5a76ed79fec04f))
* **android:** turn panes freely with two fingers — any whole-degree angle, window point under the fingers stays put, magnet at right angles with Snap Rotation, turned instant preview (parity with iOS) ([b8b84fd](https://github.com/raiseCatError/meowdisplay/commit/b8b84fdb623f7e8c93a5faa21a47e9525e75a4a6))
* **files:** two-way Remote Finder on iPhone and iPad — Save to Device and Share (files and whole folders, through the system picker and share sheet, copies removed afterwards), uploads of files and folders with Keep Both / Replace / Skip (for all) and folder Merge, a transfers list with progress, speed, cancel and retry (downloads resume), new folder, rename, duplicate, copy/move and paste, compress/expand, Move to Trash with Undo, Get Info, Open With the Mac's apps, favorites, session-only recents, sort/filter/hidden files, select mode with batch actions, and the grant shown under the title with Ask the Mac for more; movies and audio stream with seeking, PDFs show their pages, images come at full size and other documents open in Quick Look (only with download); no endless spinners (timeouts with Try Again); upload parts stay under the 32 KB control limit; workspace events reach the main actor in order; end-to-end tests against the Mac's browser ([f843036](https://github.com/raiseCatError/meowdisplay/commit/f843036326174f395beee3381e35f94b1d9025c0))
* **android:** two-way Remote Finder — Save to Device through the system picker (a file, or several and whole folders into a chosen folder), Share through the share sheet with read-only content URIs from the app's own FileProvider, uploads of picked documents and folder trees with Keep Both / Replace / Skip (for the rest) and folder Merge, a transfers list with progress, speed, cancel and retry (downloads resume after the last verified range), new folder, rename, duplicate, copy/move and paste, compress/expand, Move to Trash with Undo, Get Info, Open With the Mac's apps, favorites, session-only recents, sort/filter/hidden files, Select with batch actions and the grant under the title with Ask the Mac; movies and audio stream with seeking (MediaDataSource with read-ahead), PDFs show their pages (PdfRenderer), images come at full size; timeouts with Try Again; the demo Mac is view-only; core tests against a fake Mac ([262fc12](https://github.com/raiseCatError/meowdisplay/commit/262fc12007550c527e2cfdf191b59fa659814ada))
* typing strip on the iOS keyboard and Mac text-caret follow for Zoom While Typing ([d3a7469](https://github.com/raiseCatError/meowdisplay/commit/d3a74697c28fb10b3166fbdee5a79b82d5f6cf4d))
* **android:** typing strip on the keyboard and caret-following Zoom While Typing ([187681a](https://github.com/raiseCatError/meowdisplay/commit/187681a7af85e4132762149de508a3d0ba1b7b1e))
* **android:** Unified Clipboard on Android — ClipboardModel (twin of the iOS client), system clipboard adapter (focus-only reads, sensitive copies skipped, Mac copies marked remote and ours), Settings ▸ Clipboard, prompts over the picture, Save/Share of the Mac's copied files ([395cce8](https://github.com/raiseCatError/meowdisplay/commit/395cce8f58ffb54318340677c299aa0bd6591e80))
* **clipboard:** Unified Clipboard sync engine — events by origin and sequence with causal context, Lamport tie-break, echo/duplicate/older rules, verified ranged blob reads; Swift + Kotlin with shared vectors ([0e3c324](https://github.com/raiseCatError/meowdisplay/commit/0e3c324357d2e814070c4ec5249855cc88f63218))
* **mac:** use this Mac as a display from MeowDisplay itself ([c9e8248](https://github.com/raiseCatError/meowdisplay/commit/c9e8248f96bb3cef2c33784a4c4ff951edbe38fb))
* **connect:** when a dial to a device stalls, the Mac checks whether macOS Local Network privacy blocks it, says so with the fix, and advertises it (lnd) so iPhone, iPad and Android explain why Connect can't finish ([dc36bd2](https://github.com/raiseCatError/meowdisplay/commit/dc36bd230b77e472f008db2583ac57c57dc545d5))
* **android:** Window mode catches up with iOS — Stage Peek in every mode (Dock-style column, search pill, app carousel, two-column gallery, Displays, Launchpad), hold a card to drag it onto a pane or the desktop with a Cancel zone, tab labels with hold-to-drag and a floating pane menu (Fullscreen on This Device, Minimize/Close on Mac, View Full Screen for desktop panes), local fullscreen strip, per-pane pinch zoom, empty panes close up, desktop panes on the wire; no-display fallback drop on both platforms ([53673de](https://github.com/raiseCatError/meowdisplay/commit/53673dea2c20e98e179a9e828804ba00b9bfd6b0))
* **ios, mac-receiver:** Window mode on iPhone, iPad and Mac Receiver; iOS hardware input ([f6b9904](https://github.com/raiseCatError/meowdisplay/commit/f6b9904a381c0bfbb54f98ddb767c414f61817a3))
* **android:** Window mode UI, Home while connected, hardware mouse and keys ([77eb322](https://github.com/raiseCatError/meowdisplay/commit/77eb322ddc68819f3a2215dfcbd6af82f8d7ff66))
* **mac:** Window mode — native per-window capture composited per receiver ([686a652](https://github.com/raiseCatError/meowdisplay/commit/686a652bd83e049a9edd93bfd5e1276783450737))
* **android:** workspace engine port, window protocol client, receiver Connect ([314a38b](https://github.com/raiseCatError/meowdisplay/commit/314a38bfde2144eb0a39fabac789fec8426903eb))

### Bug Fixes

* **clipboard:** a blob range accepts no more than its read asked for, so a peer can't push a whole declared blob into memory (security review) ([e6553ca](https://github.com/raiseCatError/meowdisplay/commit/e6553ca4796607387b63071788fb794a71bb1859))
* **clipboard:** a device sends copies only in its own name and its claims about others are clamped to what the Mac saw; declared sizes capped at parse; files received onto the Mac are quarantined (security review) ([415c7ae](https://github.com/raiseCatError/meowdisplay/commit/415c7ae5f77219e923d124590451d9bda7584c58))
* **files:** a download retried after a damaged range resumes after the last range that matched its digest, not after the bytes received (which kept the damaged part) ([7df5f68](https://github.com/raiseCatError/meowdisplay/commit/7df5f68ecde5c90c86288ddc9b4d3697c1a661e4))
* **capture:** a fresh content request goes out beside one that started before the display existed (at most two out) instead of queuing behind it in replayd; callers reacting to the same change within 50 ms share one request ([ed34d39](https://github.com/raiseCatError/meowdisplay/commit/ed34d39fe01fb180a76bb8ad1feba09081fb5312))
* **remote:** a hostname's last label is never all digits, so 999.1.1.1 or 1.2.3 is rejected as a mistyped address on Mac, iPhone and Android; shared vectors ([cf20d5b](https://github.com/raiseCatError/meowdisplay/commit/cf20d5b4a1a29dda1a196b0f901e5e93077448ba))
* **android:** a local Wi-Fi session that drops falls back to Remote when the Mac has a saved address ([8890ead](https://github.com/raiseCatError/meowdisplay/commit/8890ead7c97c0bd4b43810458ad920dc77cfc071))
* **devices:** a Mac's user name drops bidi overrides, format characters, separators and private-use characters on Android as on Apple platforms, so it can't disguise itself as another Mac's ID (security review) ([ec6c4f7](https://github.com/raiseCatError/meowdisplay/commit/ec6c4f7530d6529ddcf09ea541cb1b4097e9bfe2))
* **touch:** a Natural hold on the Mac display's left edge parks the pointer there (Stage Manager can appear) instead of right-clicking; Window Switcher UI test ([dde8a7b](https://github.com/raiseCatError/meowdisplay/commit/dde8a7ba5873f14db4eb702b2b3b38a01d31be23))
* **extend:** a new display is found in the first answer from any request started after it was created, even when macOS's reconfiguration notices invalidate answers meanwhile (with AltTab flooding replayd, that answer came after 5 s; the replacement took 20 s) ([0ea6ebf](https://github.com/raiseCatError/meowdisplay/commit/0ea6ebf61697abbe76bf9f61ac0fcac6e591485a))
* **android:** a non-P-256 key at a saved address is a different Mac ([b42c492](https://github.com/raiseCatError/meowdisplay/commit/b42c492cb9e9ca689bf968e7e8c74934f8e65f6f))
* **receiver:** a replaced connection's late error or EOF never drops the new session ([32e0bce](https://github.com/raiseCatError/meowdisplay/commit/32e0bce358c9c10afdea9ff385ca02dbe9a8fc8b))
* **pairing:** a silent peer frees the responder at the reveal deadline ([c0f7eb1](https://github.com/raiseCatError/meowdisplay/commit/c0f7eb13443851c91457793cd28696d31e1124be))
* **stage-peek:** a tap fills the tile being switched (active, only, else first waiting) and never adds a tile; Switch to Window view prompt leaves by itself after 8 s ([3c54b53](https://github.com/raiseCatError/meowdisplay/commit/3c54b5361a655f96f4b67d3279b94bc6830a9357))
* **window-mode:** a tile refused as a duplicate window becomes an empty pane, labelled Empty ([96b5e92](https://github.com/raiseCatError/meowdisplay/commit/96b5e9288d177e8b337e74a23681bc62593c4924))
* **window-mode:** a tile the Mac refused asks for a window instead of staying blank ([8893d9d](https://github.com/raiseCatError/meowdisplay/commit/8893d9d6c62e5da6bc52f96c8c7ed0f8118b986f))
* **receivers:** a waiting Mac's approval holds only for its own connection ([8b8998a](https://github.com/raiseCatError/meowdisplay/commit/8b8998a219591c83e97323292c24333a8c6d2e4a))
* **window-mode:** a window macOS keeps paused though listed on the stage gets one fresh stream per change in the window, then stays honestly Paused (no restart loop; a single frame no longer resets the restart count); resumes on new frames or when the window moves, activates or leaves the strip ([40222cd](https://github.com/raiseCatError/meowdisplay/commit/40222cdfb2995784fa4b52ea89d937180479e57a))
* **window-mode:** a window's sheets ("Save changes?", alert and Open/Save panels) show in its pane and take presses there — macOS draws a sheet as its own window, so the pane captured the window without it and refused a tap on Don't Save as covered; sheets are matched by order, app and position, never listed on their own, captured beside their window and drawn through the same zoom and rotation ([6255cd8](https://github.com/raiseCatError/meowdisplay/commit/6255cd8d7c844bf8167c77257abdf3d965603e56))
* **mac:** a Window-mode tile stopped while starting never leaves its capture running ([f4fb256](https://github.com/raiseCatError/meowdisplay/commit/f4fb256c830bcf2591b297f49b0adf6a271cfbda))
* **receiver:** adopt an idle-time newcomer only after its pinned handshake ([c1ebf6e](https://github.com/raiseCatError/meowdisplay/commit/c1ebf6e46fb9a445ef312554727a7c545f677119))
* **android:** an imported layout can't borrow a built-in action's identity ([0839cc0](https://github.com/raiseCatError/meowdisplay/commit/0839cc0cfb5df4953fc938c58de8947a9aba133a))
* **pairing:** an unconfirmed pairing prompt never disrupts sessions; declined codes cool down ([dad5b23](https://github.com/raiseCatError/meowdisplay/commit/dad5b23b3ddb782532c3b214fa863d27d9ddd041))
* **android:** announce the display, not the window, and only when it changes ([6b35573](https://github.com/raiseCatError/meowdisplay/commit/6b35573a9101e39e2e62a74550ebf5ed8e9467c9))
* **mac:** answer a Remote Access knock that arrives over Tailscale/VPN at its source first, so a stale Bonjour entry can't shadow the working route; found with the Moto on cellular ([36a92fb](https://github.com/raiseCatError/meowdisplay/commit/36a92fb1561ffb1c4cf9dc7153af60869e528f3b))
* **android:** Back backgrounds a live session instead of ending it ([51536b1](https://github.com/raiseCatError/meowdisplay/commit/51536b1947db7d88d52a56f00f0c2e0c5b287ced))
* **mac:** back off when the Remote knock listener can't start ([0f685c9](https://github.com/raiseCatError/meowdisplay/commit/0f685c9bdceb6fbfd9406c1d2c1b8cb05c682ff6))
* **ios:** beside the pane menu bar, tabs shrink to the shown tab's icon and "+N" ([9a98a4b](https://github.com/raiseCatError/meowdisplay/commit/9a98a4b22afae7fd4461b10198c59108ad4bb208))
* **android:** blocked Macs never preempt, unadmitted Macs drive no UI ([db9f4c9](https://github.com/raiseCatError/meowdisplay/commit/db9f4c92f96f15bb2b7246283bc4314dc40fac78))
* **network:** bound unauthenticated pairing and knock connections ([733a8fa](https://github.com/raiseCatError/meowdisplay/commit/733a8fae8024d600acfdf770586fce854e7c1488))
* **android:** bound unauthenticated pairing connections ([314a100](https://github.com/raiseCatError/meowdisplay/commit/314a1005617363582cb2bb487ca0ef08d67b8a76))
* **android:** bound window thumbnails and app icons before decoding ([38f5ecd](https://github.com/raiseCatError/meowdisplay/commit/38f5ecd31e748eabf5c0a5737c1e464f9eac79fb))
* **ios:** build the edge-layout touch region from typed pieces ([18bc616](https://github.com/raiseCatError/meowdisplay/commit/18bc616166ba3ea87781dce0873efac3cc12d2af))
* **ios:** build the edge-layout touch region from typed pieces ([9512ef2](https://github.com/raiseCatError/meowdisplay/commit/9512ef291e9b96e303d257b3648a0f825b338dd6))
* **mac:** capture-service waits are bounded; own-window lookups share the broker ([aee630c](https://github.com/raiseCatError/meowdisplay/commit/aee630c0fc9deee2e5b0fb0e71a0776e1ebff2c7))
* **stage-manager:** cards for windows in Stage Manager's strip never show the strip's tilted thumbnail; they keep the last real picture (dimmed) or the app icon and say In Strip ([01cfd63](https://github.com/raiseCatError/meowdisplay/commit/01cfd63f60a22139bde95eaa2b53553b931b2809))
* **receivers:** choosing a window for a closed tile shows it ([03c90bc](https://github.com/raiseCatError/meowdisplay/commit/03c90bc3f8ec2f44148e7f01b06c53802f4f5b0f))
* **wire:** control messages over 32 KB travel in ordered parts (PROTOCOL.md 6.14) — receivers dropped every longer one, so Remote Finder previews loaded forever, many Stage Peek window stills never came and a pane's whole-source still for live zoom was lost; receivers advertise hello.chunks and reassemble in order, bounded (4 MiB, 4 in flight, 15 s) and digest-checked; shared vectors ([2879526](https://github.com/raiseCatError/meowdisplay/commit/287952615aff2e66edcc0099e56b25008a8a86f7))
* **receiver:** control shows as allowed only when the Mac allowed it ([bda4b1c](https://github.com/raiseCatError/meowdisplay/commit/bda4b1ceee287bec511fa2e0ba120330fae605f7))
* **privacy-shield:** crash showing the cover — SwiftUI no longer sizes any shield window; the notice panel's self-sizing looped (height 33/34 pt) until AppKit threw; covers are plain AppKit with a placed message; fixed-size Unlock and notice panels ([a97e13b](https://github.com/raiseCatError/meowdisplay/commit/a97e13be5f6bbcd2985570b459801142c4aca822))
* **mac:** Debug builds get their own main-executable UUID (no debug-dylib stub) so macOS Local Network privacy can match the grant; startup step timings in the log; device test that connects the iPhone to the paired Mac ([ebb37cf](https://github.com/raiseCatError/meowdisplay/commit/ebb37cf01192632ac52c96c94fe70e670b456ef3))
* **ios:** declare 3B52.1 for the metadata of files picked for upload ([0d526d2](https://github.com/raiseCatError/meowdisplay/commit/0d526d25d1cb126cbbcd6c2f64e41e5a64c11a7f))
* **workspace:** divider drags follow the finger and undo as one step; tile chrome stays clear of controls ([28a1ed4](https://github.com/raiseCatError/meowdisplay/commit/28a1ed4f140014489b428cef0fd71007922846d2))
* **mac:** don't advertise this Mac as a sender while it's a display ([02c605a](https://github.com/raiseCatError/meowdisplay/commit/02c605a454fb3fb6397e8bb21596e941ec1dfdfd))
* **remote-finder:** drop Mac file names that could leave their folder and keep every saved copy inside the export folder ([4b3114a](https://github.com/raiseCatError/meowdisplay/commit/4b3114a9a70de7dd1389254166b4c602fd1cb472))
* **receiver:** drop the Remote Access port field that changed nothing ([2343688](https://github.com/raiseCatError/meowdisplay/commit/2343688d99fabbcd76bffabe777fb021e3312893))
* end control, not just input, when a login session is switched out ([0f4dff9](https://github.com/raiseCatError/meowdisplay/commit/0f4dff9318fcf19d0dd694311d31293ce2844413))
* **release:** enforce manual iOS release and keep Android review on testing tracks ([d176b27](https://github.com/raiseCatError/meowdisplay/commit/d176b27443cc47237dd5368f1b5835988fd864e3))
* **stage-peek:** every new opening starts unfiltered — all windows, no app selected, no search — on iOS and Android; dismissal clears the temporary filters, preferences kept ([1d10689](https://github.com/raiseCatError/meowdisplay/commit/1d10689562179dd9a5116efd4c4f3e7b47c9931a))
* **stage-peek:** expanded gallery lightly blurs the Mac picture behind it (cards stay sharp); Reduce Transparency dims instead ([27c0bba](https://github.com/raiseCatError/meowdisplay/commit/27c0bbaa61d3bc61f0e3fddcf2e3af3075994d01))
* **mac:** explain a standalone receiver opened while this Mac is a display ([6197267](https://github.com/raiseCatError/meowdisplay/commit/61972679d85fa50e695ba14f8133ce0b5e3d9003))
* **ios:** expose tray controls as buttons to VoiceOver, Voice Control and Switch Control ([8b11d1e](https://github.com/raiseCatError/meowdisplay/commit/8b11d1ea7741054a1edb825a56b81c4accf3c123))
* **android:** first session gets the Request Input prompt and View Only UI ([da9a446](https://github.com/raiseCatError/meowdisplay/commit/da9a44632c1d44391378bdc914c429b34982f39e))
* **ios:** fit the iPhone Main Tray to the screen ([994a2d3](https://github.com/raiseCatError/meowdisplay/commit/994a2d326de86ba3fa0129debdee514e81589792))
* **consent:** grant prompts never take focus, have no Return default and answer only the person at the Mac ([1c66a99](https://github.com/raiseCatError/meowdisplay/commit/1c66a99cb38b5dc612178064bb4639419b05abce))
* **android:** hardware video decoding on decoders without low-latency mode ([381adce](https://github.com/raiseCatError/meowdisplay/commit/381adce24a674a72fb05482273e874cec8c556c2))
* **window-mode:** hide Add to Current Stage until it works; Show on Mac is back next to Turn Off Stage Manager ([41a3cbe](https://github.com/raiseCatError/meowdisplay/commit/41a3cbe2b93e146ec85544845926746195d65d33))
* **ios:** home Connect/Wake & Connect label never truncates; footer links on one row as plain tinted text; Touch Style UI test skips on a device set to Trackpad ([36d8c1b](https://github.com/raiseCatError/meowdisplay/commit/36d8c1b67bf91168d404de59c0239c36a1be7a3a))
* **ios:** home row buttons keep their natural width (no overflow), ••• is a plain icon; checked on iPhone ([baf0f73](https://github.com/raiseCatError/meowdisplay/commit/baf0f73874ca006453ebcbc21b4fb2fcf631f1e9))
* **controls:** imported layouts can't impersonate built-in actions (F3) ([c347704](https://github.com/raiseCatError/meowdisplay/commit/c347704e578a18c4a9275105f4cc1f6722b88b7c))
* **window-mode:** in View Only a touch meant for the Mac never leaves the device and shows Request Control inside the selected pane (selecting a pane, pan and zoom stay local; Macs reporting control state must have granted it; older Macs unchanged); existing request flow, no replay ([058bbe4](https://github.com/raiseCatError/meowdisplay/commit/058bbe4b1f143766209d0ba0e0d2f5202c08da35))
* **stage-manager:** in View Only, Stage Manager on/off asks for control in place (Settings and the pane's Turn Off) instead of sending an action the Mac drops; iOS canControlMac now follows the Mac's confirmed control, not just a live session; Android Settings gets the same inline Request Control ([c39f839](https://github.com/raiseCatError/meowdisplay/commit/c39f8393a52ee29a6fb035e0a7802c1870c2bea4))
* **android:** in View Only, tapping another pane selects it instead of asking for control ([045072c](https://github.com/raiseCatError/meowdisplay/commit/045072c91eb4e9102199d96bc8c1c5c1e291591e))
* **android-window-mode:** inline Request Control in a paused pane sits on a chip, readable over the paused picture ([752f3c3](https://github.com/raiseCatError/meowdisplay/commit/752f3c3329d11879936680a18320c27c6e51268c))
* iOS code measures time with CACurrentMediaTime (no undeclared required-reason API, so the privacy manifest test passes); Android clears its sent clipboard copies at start ([4bdf11b](https://github.com/raiseCatError/meowdisplay/commit/4bdf11b00fa3b6ffa1ccaca7ad3564a6c2f4de57))
* **window-mode:** iPhone instant zoom shows the pane's whole-source still where the moved picture doesn't reach and hands over when the Mac's frame with the final view is out (bounded); the final zoom is sent as the fingers lift; window stills and Remote Finder previews stay under the 1 MiB control-message limit ([d6935a0](https://github.com/raiseCatError/meowdisplay/commit/d6935a0690f843b28d1a855a290549e855a3595a))
* **security:** keep each role's approval policy and peer data separate ([532380f](https://github.com/raiseCatError/meowdisplay/commit/532380f1a435d9a2d6698bf04063a147b6dd0bd4))
* **ios:** keep the Demo Mode banner usable at large text sizes ([2aae709](https://github.com/raiseCatError/meowdisplay/commit/2aae7090c6e15702b4542b82e3e765e960677b68))
* **mac:** keep the display awake while a device watches — a sleeping display stopped every capture (panes retried until they gave up) once the 60 s stabilization hold ran out on an idle or shielded Mac ([c9af421](https://github.com/raiseCatError/meowdisplay/commit/c9af4211e5ad8202bac1d466de3bbeb32ac9972e))
* **receiver:** keep the pending-connection deadline buildable on macOS 12 ([ed940b1](https://github.com/raiseCatError/meowdisplay/commit/ed940b11e0f79310694c7f2116ed43dee9bf5264))
* **security:** keep the receiver lock in the user's own folder and fail closed ([a0bd044](https://github.com/raiseCatError/meowdisplay/commit/a0bd044ea8f84aa528f3a87662d273c97ad4e200))
* **mac:** keep the refused-Mirror notice true for a device already mirroring ([4f4fbb9](https://github.com/raiseCatError/meowdisplay/commit/4f4fbb976514fcd40dd37a6503eb011e09c951cc))
* **ios:** keep the shortcut palette with the tray when Avoid Notch moves it ([ca9eea1](https://github.com/raiseCatError/meowdisplay/commit/ca9eea16cea0a805065923c20475954c38a1c3b3))
* **android:** keep the video surface alive and bound cursor sprites ([9ef17b2](https://github.com/raiseCatError/meowdisplay/commit/9ef17b2da4f4814b6cfd31d97d787dcbd5f13267))
* **touch,android:** left-edge Natural hold parks the pointer instead of right-clicking; shared fixture case ([01b0897](https://github.com/raiseCatError/meowdisplay/commit/01b0897605e5515a142556056503fe5bbc48f0be))
* **android:** live picture is immersive; tile pills stay clear of the cutout ([6310f82](https://github.com/raiseCatError/meowdisplay/commit/6310f825dab7f1f3193ac30d96daa029880125e6))
* **copy:** local network permission prompts say Wi-Fi, and the Mac's names every kind of receiver it connects to ([68e4f00](https://github.com/raiseCatError/meowdisplay/commit/68e4f00a9a03443f7c9786e0059433d3b4520e3d))
* **mac:** lock the sender state its async paths write off the queue (C8) ([f49b628](https://github.com/raiseCatError/meowdisplay/commit/f49b628d7b3a837fb102a5a8e4d743a82aad1cf5))
* **window-mode:** log window actions the Mac ignores because the session has no control ([6f7e313](https://github.com/raiseCatError/meowdisplay/commit/6f7e313a9fc44a85a2521d7c15b0db56df0e2892))
* **remote:** Mac-initiated Remote dials reach the media port; Forget clears a receiver's hints ([756a787](https://github.com/raiseCatError/meowdisplay/commit/756a78753dd8ecd2f2aef44278382ae63089c54b))
* **logs:** mask addresses, Tailscale names and device IDs in app logs ([0706714](https://github.com/raiseCatError/meowdisplay/commit/07067142f06d797449c720fb4e4cb01144f09207))
* **mac:** match a link-local gateway that carries the kernel's embedded scope ([46347d0](https://github.com/raiseCatError/meowdisplay/commit/46347d04c3736181ff0f1656882a4e1518d85d74))
* **android:** match the iPhone fixes from physical QA ([d71b49f](https://github.com/raiseCatError/meowdisplay/commit/d71b49fc9ca231a417c870536c92b55f436c25df))
* **touch:** Natural Touch hint never passes taps to the Mac (Android), and its timer runs only while it can be seen ([239982e](https://github.com/raiseCatError/meowdisplay/commit/239982e469573fc454b6668e631a79f3b0ae3291))
* never let an advertisement rename or join another Mac's group ([ae6729c](https://github.com/raiseCatError/meowdisplay/commit/ae6729c2bcca47ef7b37d8402dae9b08de20d0eb))
* **ci:** never trust recorded release state as evidence for publication ([e894dd5](https://github.com/raiseCatError/meowdisplay/commit/e894dd58eba9a9565145fac2cc3f4cb3ac34a6a2))
* **android:** never write to the media socket on the caller's thread ([b2c5119](https://github.com/raiseCatError/meowdisplay/commit/b2c51193f34ccfedf59c947857dfacb567c106c8))
* **mac:** no crash when a press lands outside the target window ([3bc5c28](https://github.com/raiseCatError/meowdisplay/commit/3bc5c287cb53fdff693246ed66692d975a4753c0))
* **rulesets:** no GitHub Actions bypass actor; validate every file before applying ([df792e6](https://github.com/raiseCatError/meowdisplay/commit/df792e65612f80786bcae90a73ce0f9ec74ae9ac))
* **window-mode:** no stale 'Choose a window' over a live pane; Waiting and Reconnecting show a live spinner ([3a5b3c7](https://github.com/raiseCatError/meowdisplay/commit/3a5b3c7f9b48019f89497dfb1b33fb512f14872d))
* **window-mode:** no whole-picture zoom in Window mode ([fad0329](https://github.com/raiseCatError/meowdisplay/commit/fad032964d9ac39c0fec1de1da6e67f8aba5260f))
* **privacy-shield:** nothing a device sends changes the Mac while it asks for the password; the cover can't be removed behind the owner's back ([6fc9321](https://github.com/raiseCatError/meowdisplay/commit/6fc932131ce9c59e98e4090ac0806991d4288a24))
* **android:** one address can't hold every media handshake slot ([b389dba](https://github.com/raiseCatError/meowdisplay/commit/b389dba09d5fec353665d666250d7383987f23f6))
* **mac:** one display-awake assertion counted across viewers; released with the last viewer, on sender stop, when Screen Recording is revoked and while switched out ([3c15edd](https://github.com/raiseCatError/meowdisplay/commit/3c15edd6eb6ce9a17e98c68ecd08a151d2d4e302))
* **receiver:** one Mac receiver owns the ports, in either launch order ([d91ccdd](https://github.com/raiseCatError/meowdisplay/commit/d91ccdd9a3326820bea4f290377172fa1803db98))
* **capture:** one shared, cached request for ScreenCaptureKit content (one in flight app-wide, answers reused until displays or shield windows change, bounded and cancellable waits); Extend lists its display and the shield windows from one answer instead of two; start traces with a per-session id from admission to first encoded frame ([e268f46](https://github.com/raiseCatError/meowdisplay/commit/e268f4634e23112071c478bd3aa40308d2a989b3))
* **receiver:** only an admitted session's chunked messages are assembled ([1abf65b](https://github.com/raiseCatError/meowdisplay/commit/1abf65bf6e3fa7c9e5ee3e58d050f60d59c609e5))
* **pairing:** only canonical P-256 identities, one peer per key (F1) ([7c5567b](https://github.com/raiseCatError/meowdisplay/commit/7c5567be7178760f1208f9e6f32a9830650ce43e))
* **android:** Pair over Remote hint names the Mac's real path (Settings, Devices, Open Pair over Remote) ([3802515](https://github.com/raiseCatError/meowdisplay/commit/38025153b61da04cdcb07974e80883ce25b9b015))
* **window-mode:** pane menu takes its natural height; the menu bar never shows the previous tab's app; live Rotate test ([a6d4523](https://github.com/raiseCatError/meowdisplay/commit/a6d4523627135ae59dd790e747e8200b5540fdbe))
* **window-mode:** panes capture their whole source and zoom when composing; Fit by default with 0.7x-8x zoom per pane; Stage Manager windows use their real frame and report paused instead of waiting forever; stalled captures restart with backoff, then fail with Retry ([6cc69d1](https://github.com/raiseCatError/meowdisplay/commit/6cc69d1c741e3ba1c1b22ffffefff1eb7c0d5d7e))
* **android:** panes Fit by default with 0.7x-8x zoom per pane centred on the fingers; instant zoom over the pane's whole-source still, handed over when the Mac's frame with the view is out; paused (Stage Manager strip), reconnecting and failed panes say so with Show on Mac and Retry; the demo Mac draws zoom and answers the new messages ([4366924](https://github.com/raiseCatError/meowdisplay/commit/43669248e41cf4e2852792f894b78ecc69402b27))
* **mac:** Personal Hotspot — QUIC that dies right after hello falls back to secure TCP ([4729b7c](https://github.com/raiseCatError/meowdisplay/commit/4729b7cb8f964f2f693622532ae30090ec70fbda))
* **stage-peek:** phones show two windows per row in the expanded gallery whatever the text size (one only below 254 pt), up to four in landscape; shared rule and vectors for iOS and Android; UI test measures the rendered columns ([5a5c562](https://github.com/raiseCatError/meowdisplay/commit/5a5c56268a3bbe4b646507a43a0c9661ba109280))
* **android:** pin only handshake-presentable keys, one peer per key ([29512b7](https://github.com/raiseCatError/meowdisplay/commit/29512b7780b6a9216a08cab06dc8c2d8b40a9c95))
* **files:** protected folders are matched case-insensitively ("library" is ~/Library on a case-insensitive volume); Files requests from several devices wait in line, each in a fresh panel whose Allow button wakes after 0.8 s, so a click can't answer a swapped-in question ([fdcb45a](https://github.com/raiseCatError/meowdisplay/commit/fdcb45ad41577ba4c85ab4607dd26cc33c28bb93))
* **video:** receivers recover from a lost picture with one keyframe request, not none or a storm ([f808d0f](https://github.com/raiseCatError/meowdisplay/commit/f808d0f11c4bff2d5800582971f4645e4c37cbac))
* **window-mode:** reconnects — the menu bar asks again after a reconnect even for the same pane and app; Remote Finder's Allow for This Session lasts for the device's session (a hotspot TCP or cable swap doesn't ask again), and flipping the Files switch makes every device ask again ([ff8660f](https://github.com/raiseCatError/meowdisplay/commit/ff8660fa4cba332e43fb3594416b3fadce51b64e))
* **android-pins:** refuse Mac ids that use the pairing-date key prefix ([28405df](https://github.com/raiseCatError/meowdisplay/commit/28405dfaffc2b77b4415896da1bdac4110593588))
* **rulesets:** release-state fails closed; installer reports partial state ([3001885](https://github.com/raiseCatError/meowdisplay/commit/30018855412568aff277b4c45c4d34376f80b956))
* **files:** Remote Finder writes never touch hidden items and reads follow no symlink swaps ([1bd2370](https://github.com/raiseCatError/meowdisplay/commit/1bd2370e06e70a4451851aced89493f69e28252a))
* **mac:** requests in flight after a Files revoke hear revoked, not asking ([f2418db](https://github.com/raiseCatError/meowdisplay/commit/f2418db68e1e0d872e23d467b59029e7614a5a3a))
* reset native gesture bookkeeping when an input grant ends ([a29c1f5](https://github.com/raiseCatError/meowdisplay/commit/a29c1f5079f9abd7c59a9e4398f7a3d738620189))
* **release:** resumed publication needs the final approval and live re-verification ([1f36e0d](https://github.com/raiseCatError/meowdisplay/commit/1f36e0da217ce0bc71b63ca7b7cbc31914ae2929))
* **mac:** run the Tailscale CLI only when Tailscale signed it (B7) ([05f119c](https://github.com/raiseCatError/meowdisplay/commit/05f119c0f52f8e67da6975536e43ca87ce40787b))
* **remote-finder, iOS:** Save and Share present the system picker and share sheet from the top view controller (inside a SwiftUI sheet they showed nothing and the copies were deleted early), shared copies kept a minute; a progress bar with Cancel while copies are prepared and Saved/Shared feedback; cleaner preview actions (Save, Share, Folder; one Open on Mac button, hold to choose the app) ([60dd727](https://github.com/raiseCatError/meowdisplay/commit/60dd72752a879766681236a050ef789593200925))
* **qa:** Save to Device no longer crashes, Save/Share copies reach the device, peek controls stay put; apps bar grows Launchpad-style ([b94abf6](https://github.com/raiseCatError/meowdisplay/commit/b94abf6f3dbc4046b9feb07b6357ef4396342023))
* **ios:** screen size, panel scale and frame rate come from the app's own scene, not UIScreen.main (foldables, external displays, Stage Manager) ([ee6f5c2](https://github.com/raiseCatError/meowdisplay/commit/ee6f5c2dc0af1b07d7c1efe6145091259f601826))
* **ios:** screen-awake timing uses CACurrentMediaTime (systemUptime is an undeclared required-reason API); tests follow the schema-21 defaults (Classic, phones in Trackpad) ([a8d12da](https://github.com/raiseCatError/meowdisplay/commit/a8d12da08ca1fa7acac027b3632cbbb00d7bce84))
* **ipad-qa:** scrolling, peek drags and Save/Share from the owner's iPad QA (2026-10-31) ([cdeda71](https://github.com/raiseCatError/meowdisplay/commit/cdeda71923d1a6fa59dcb25e112d89b1c808343d))
* **receiver:** settings from a newer build survive running an older one ([669cbdb](https://github.com/raiseCatError/meowdisplay/commit/669cbdb6f67480a44e2411d07fab0b5071323e81))
* **ios:** Settings is a stack in narrow regular-width windows ([d7b3f26](https://github.com/raiseCatError/meowdisplay/commit/d7b3f26361137c375466693a335a7222999951de))
* **ios:** Settings keeps a way back to its list in narrow regular-width windows ([b48f420](https://github.com/raiseCatError/meowdisplay/commit/b48f420f3462516c4943c5cc3a3a5a14b1e6a95b))
* **ios:** Show on Mac for minimized tiles, landscape tray clear of the notch, Request Control hints ([dfd8207](https://github.com/raiseCatError/meowdisplay/commit/dfd82078402dc43980f58c741a0a4ca28a39c8d3))
* **ios:** show Return to upgraders whose Function Tray is untouched ([f81898b](https://github.com/raiseCatError/meowdisplay/commit/f81898ba6dd55271ba09dad67432ca944d6db283))
* **ios:** show the keyboard bar in Demo Mode ([45432b3](https://github.com/raiseCatError/meowdisplay/commit/45432b3b417ec61f1de413251a79ce2a18aed408))
* **stage-peek:** sideways swipes at finger speed flick instead of scrubbing; the expanded gallery stays between the controls; Android peek clears the Control Tray and keeps its own dialogs open ([31d110b](https://github.com/raiseCatError/meowdisplay/commit/31d110bd8dc69064afdf6a1053767bbf76aaee03))
* **menus:** stale-reply check is nonisolated so the Mac tests compile ([32d71a1](https://github.com/raiseCatError/meowdisplay/commit/32d71a190696b655a8f727e8ef9ccca05340e8d2))
* **mac:** start the arrangement restore window on the first tick ([4737a50](https://github.com/raiseCatError/meowdisplay/commit/4737a50b67bdd7a11cbe0cfff2c789f96ded897c))
* **window-mode:** startup follows the session through the hotspot TCP hot swap, so Window mode starts and the picker lists windows ([f4a6f91](https://github.com/raiseCatError/meowdisplay/commit/f4a6f917afa55b74860001ceab2b89f8eccdc214))
* **rulesets:** state the pull-request settings GitHub keeps on the live rulesets ([ed5e741](https://github.com/raiseCatError/meowdisplay/commit/ed5e741255fa56490e32477f0e426039df002705))
* **android:** stopping the media listener lets the goodbye reach the Mac ([987d653](https://github.com/raiseCatError/meowdisplay/commit/987d653a2ac39367d4ec761a2db2f89e9cd6f401))
* **input:** tap-then-drag presses where the finger came down ([12eef6e](https://github.com/raiseCatError/meowdisplay/commit/12eef6effe2c69388903d14d8990897cda5e53ab))
* **consent:** the clipboard prompt follows the same rules as the other grant prompts ([30ece43](https://github.com/raiseCatError/meowdisplay/commit/30ece4344fcb99bb596aaef6a6191cad1f425806))
* **privacy-shield:** the cover never drops during reconnects or mode switches; Lock Mac from iPhone, iPad and Android; Full Desktop defaults to Mirror ([ff74ca5](https://github.com/raiseCatError/meowdisplay/commit/ff74ca53991358079b03b785f4c7e98c59369db2))
* **privacy-shield:** the cover stays above every app window while macOS asks for the administrator password (it dropped to normal level, showing the screen before authentication) and returns to the top after 60 s; a device connecting after a local reveal brings the cover back, so the 'on' it is told is true (security review) ([3324ad5](https://github.com/raiseCatError/meowdisplay/commit/3324ad53500a2e7458f257bcb6c7ec120ea7c6c0))
* **release:** the dry run never uses secrets after a failed environment check ([774858d](https://github.com/raiseCatError/meowdisplay/commit/774858dfcbcb7373168a62ba0696d73b458257eb))
* **remote:** the filter's rejection reason is an Error (Swift.Result needs one) ([e7cccf5](https://github.com/raiseCatError/meowdisplay/commit/e7cccf56af6b1715dcc71d832908b0fbd52aca1f))
* **stage-peek:** the grown apps bar stops above Expand and Close so they stay usable; Compact shrinks the bar first; tapping All Apps' bottom handle closes it ([9b8ba92](https://github.com/raiseCatError/meowdisplay/commit/9b8ba9267d0c872a8520bf66277991cf951df2b7))
* **window-mode:** the instant preview moves only the window's own outline, so a turned pane's empty box corners no longer smear dark shapes over the picture while turning or panning (iOS + Android) ([86092d3](https://github.com/raiseCatError/meowdisplay/commit/86092d35f4e64f670a96e4b5afef07bb746426d3))
* **window-mode:** the Mac cursor keeps its shape in panes — it was sized against the Mac display's shape on a phone-shaped canvas and stretched; Window-mode cursor messages carry the pane's scale and rotation, cursorImg its size in points, and iPhone and Android draw it from those (bounded 16–44 pt, turned with the pane; Android draws it in Window mode unless a mouse pointer hovers); live panes fetch their whole-source still before the first pinch; zoom and still timings logged ([b569346](https://github.com/raiseCatError/meowdisplay/commit/b569346e48cc562641e44b6f1139c5b73248b4de))
* **android-menus:** the menu bar never shows the previous tab's app; asks again up to three times ([5116572](https://github.com/raiseCatError/meowdisplay/commit/51165723f8d42c75fd5dcc99dafdaaf8d399043f))
* **window-mode:** the pane menu always fits on screen; inline Request Control in it ([b604745](https://github.com/raiseCatError/meowdisplay/commit/b6047458c6181623387a22d8db939f8755cce6ff))
* **android:** the screen stays on only while the picture is watched ([adbaeae](https://github.com/raiseCatError/meowdisplay/commit/adbaeae76687b27f436e97fdcff23736a9f815af))
* **android:** the View Only pill follows Window mode and pane selection ([3eaf714](https://github.com/raiseCatError/meowdisplay/commit/3eaf7144c1ca19bf63bef7da626e9a83fd9e8c4c))
* **stage-peek,ios:** toolbar lifts above the controls under it (collided with the settings button on iPhone); Full Desktop subtitle unclipped; on-device UI test against a live Mac ([c2c10a6](https://github.com/raiseCatError/meowdisplay/commit/c2c10a6fa873b8b86fa21d4988705d4d1f8bd691))
* **window-mode:** Turn Off Stage Manager runs the owner's two Shortcuts (macOS's own Set Stage Manager action) instead of writing the preference, which macOS didn't apply in the lab (unchanged 3 s later, 27.0); it waits for the change and reports 'failed' when macOS didn't apply it; devices offer the button only when the Mac says ready and otherwise explain where to set it up (workspaceState stageManagerControl); Mac Settings ▸ System ▸ Stage Manager has the setup steps; a window back from the strip gets a fresh stream after 2 s instead of 6 ([8902a1b](https://github.com/raiseCatError/meowdisplay/commit/8902a1bfcbf10fff284097b0c42058423f588723))
* **ios:** typing strip sits on its own material bar so the echo never blends into the Mac picture; UI test for the strip echo, checked on iPhone ([45da72f](https://github.com/raiseCatError/meowdisplay/commit/45da72f07bb2a9f74357c3d50e8e22d2deffc53a))
* **ios:** Undo/Redo stays a column in the landscape corner; the pane menu bar shares the label row ([1574838](https://github.com/raiseCatError/meowdisplay/commit/1574838a6c361ac0071a142143e4d22cb05706d8))
* **android:** update button opens our own Play listing; unauthenticated Switched Out claims can't hide a paired Mac ([34197e4](https://github.com/raiseCatError/meowdisplay/commit/34197e49b6894e01fc0812f045f0ac8b66395850))
* **release:** verify the Android upload signature without -strict, and build the first Play bundle locally ([d3cb067](https://github.com/raiseCatError/meowdisplay/commit/d3cb06729ab438816ee07d990ef912ee8d27ccea))
* **android-window-mode:** View Only Request Control pill shows inside the selected pane (same request flow and states), not at the screen bottom ([2747368](https://github.com/raiseCatError/meowdisplay/commit/274736857f92041295e1e0e5a432fa97493a1221))
* **security:** wake targets follow the authenticated Mac; spoofed discovery can't raise a trust failure ([51c8968](https://github.com/raiseCatError/meowdisplay/commit/51c8968056bdcd8bc82ea6f6b80f452bae10bc01))
* **mac:** Window mode hardening from the independent security review ([6b13ad7](https://github.com/raiseCatError/meowdisplay/commit/6b13ad795794ba29e11734e58a3eee63d7a92130))
* **mac:** Window mode input found on the phone: covered windows, Smart Touch, twin frames ([373ff6e](https://github.com/raiseCatError/meowdisplay/commit/373ff6ebca69e24663b84d8f71ad4fc082f09f3c))
* **mac:** window streams stay stopped while the display is paused ([b520942](https://github.com/raiseCatError/meowdisplay/commit/b52094264b152b42269fb4703b8c1ac8517cb688))
* **a11y:** with VoiceOver or TalkBack on, the Mac picture takes no touches until Direct Touch is turned on from its actions; activating it never clicks the Mac ([7f8a0f1](https://github.com/raiseCatError/meowdisplay/commit/7f8a0f1f7754807a624e1ef02e366093e2ada049))

### Performance Improvements

* **mac:** a session that never connected backs off its redials ([37b38d8](https://github.com/raiseCatError/meowdisplay/commit/37b38d88445e6ecaa523d8a96be6e9426592cbcb))
* **android:** entering or leaving picture-in-picture keeps the video surface ([4117517](https://github.com/raiseCatError/meowdisplay/commit/4117517355950025c7fe287287745a63dbccf216))
* **mac:** Mirror display lists share the capture service request ([9025f65](https://github.com/raiseCatError/meowdisplay/commit/9025f658c2c0f4052281701a43f4fbc449ac8f51))
* **mac:** the Mirror display list never reuses an answer from before the change ([fbde652](https://github.com/raiseCatError/meowdisplay/commit/fbde652d52abedd5e9c936c7098ae9e39714ef96))
* **android:** video frames and audio packets no longer go to the main thread ([7b89229](https://github.com/raiseCatError/meowdisplay/commit/7b89229856985887d1f3162015219e91cc466ee0))
* **window-mode:** warm the video encoder at launch (first start waited ~3 s for it); a Full Desktop pane is no longer restarted as stalled before its stream starts ([fd0212d](https://github.com/raiseCatError/meowdisplay/commit/fd0212dc4145d316f8298cc5478b5a79dd8292cf))

## [1.20.0](https://github.com/raiseCatError/meowdisplay/releases/tag/v1.20.0) (2026-10-25)

The first MeowDisplay release, built from OpenDisplay 1.19.0. Release notes: the
[v1.20.0 GitHub Release](https://github.com/raiseCatError/meowdisplay/releases/tag/v1.20.0).
Entries below this one are upstream OpenDisplay's.

## [1.19.0](https://github.com/peetzweg/opendisplay/compare/v1.18.0...v1.19.0) (2026-09-01)


### Features

* **mac:** full-pixel mirror capture and a receiver decode ceiling ([#258](https://github.com/peetzweg/opendisplay/issues/258)) ([f1f3ec5](https://github.com/peetzweg/opendisplay/commit/f1f3ec57540cb42325fc57d0f79b6a8d740744a5))

## [1.18.0](https://github.com/peetzweg/opendisplay/compare/v1.17.0...v1.18.0) (2026-09-01)


### Features

* **mac:** standalone OpenDisplay Receiver app, a spare Mac as a display ([#145](https://github.com/peetzweg/opendisplay/issues/145)) ([23b62b3](https://github.com/peetzweg/opendisplay/commit/23b62b3da59fbb3ce2836a29aec34c7f7bf71a1d))
* **web:** add coverage showcase ([#239](https://github.com/peetzweg/opendisplay/issues/239)) ([89d9902](https://github.com/peetzweg/opendisplay/commit/89d9902857e23c67c77b7e845ddbd7b8e99d4aea))

## [1.17.0](https://github.com/peetzweg/opendisplay/compare/v1.16.1...v1.17.0) (2026-08-20)


### Features

* **ios:** share the phone's connection log from Settings & Help ([#227](https://github.com/peetzweg/opendisplay/issues/227)) ([ba2ddb2](https://github.com/peetzweg/opendisplay/commit/ba2ddb2ceae30577a1d872f12425aa18a1cd3bde))


### Bug Fixes

* Honor the system capture stop and survive poisoned display identities ([#231](https://github.com/peetzweg/opendisplay/issues/231)) ([87b000b](https://github.com/peetzweg/opendisplay/commit/87b000b9906587d793c642e0dcd1b1032069f2e8))

## [1.16.1](https://github.com/peetzweg/opendisplay/compare/v1.16.0...v1.16.1) (2026-08-10)


### Bug Fixes

* Prevent Mac & iOS device displays from diverging due to dropped frames ([#207](https://github.com/peetzweg/opendisplay/issues/207)) ([c8b2417](https://github.com/peetzweg/opendisplay/commit/c8b24177cbab6df58bfc727873261c53a412cb89))

## [1.16.0](https://github.com/peetzweg/opendisplay/compare/v1.15.0...v1.16.0) (2026-08-08)


### Features

* **web:** add compatible apps section to the landing page ([#200](https://github.com/peetzweg/opendisplay/issues/200)) ([3d68908](https://github.com/peetzweg/opendisplay/commit/3d68908808d9b8bfe97a0bad3e1ce0e7e61f43df))


### Bug Fixes

* **mac:** fall back to a nil encoderSpecification when creation fails ([#197](https://github.com/peetzweg/opendisplay/issues/197)) ([#202](https://github.com/peetzweg/opendisplay/issues/202)) ([d9eb302](https://github.com/peetzweg/opendisplay/commit/d9eb302d4d25e2c72847420d5e462ff035520e49))
* **mac:** log rejected encodes instead of dropping them silently ([#118](https://github.com/peetzweg/opendisplay/issues/118)) ([215100d](https://github.com/peetzweg/opendisplay/commit/215100d09477712f75cfd6684a13cc6a68d0edc8))
* **mac:** preserve virtual displays across rotation ([#210](https://github.com/peetzweg/opendisplay/issues/210)) ([2a4abf7](https://github.com/peetzweg/opendisplay/commit/2a4abf7408866dec05e8461cf7086e8059cda877)), closes [#203](https://github.com/peetzweg/opendisplay/issues/203)
* **mac:** re-attach capture on stream death instead of full display rebuild ([#29](https://github.com/peetzweg/opendisplay/issues/29)) ([#157](https://github.com/peetzweg/opendisplay/issues/157)) ([ceebb2d](https://github.com/peetzweg/opendisplay/commit/ceebb2d46130c8aac912439279d7b1f71c851e31))

## [1.15.0](https://github.com/peetzweg/opendisplay/compare/v1.14.0...v1.15.0) (2026-08-02)


### Features

* **ios:** Apple Pencil input with pressure, tilt and proximity ([#163](https://github.com/peetzweg/opendisplay/issues/163)) ([1c857a4](https://github.com/peetzweg/opendisplay/commit/1c857a4ebd26080aedeba3086b7bee02a0a5a6c1))


### Bug Fixes

* **input:** stop two-finger scroll from firing a click ([#188](https://github.com/peetzweg/opendisplay/issues/188)) ([04590ed](https://github.com/peetzweg/opendisplay/commit/04590ed1871f533108d8a81f498df188c69f249c))
* **mac:** bound the log, throttle hot log paths, make it easy to send ([#180](https://github.com/peetzweg/opendisplay/issues/180)) ([19481a6](https://github.com/peetzweg/opendisplay/commit/19481a66aa7015eaf3830737bfb3cf43f105250d))

## [1.14.0](https://github.com/peetzweg/opendisplay/compare/v1.13.0...v1.14.0) (2026-07-30)


### Features

* **ios:** lower deployment target to iOS 16 ([#178](https://github.com/peetzweg/opendisplay/issues/178)) ([518b62d](https://github.com/peetzweg/opendisplay/commit/518b62d656a154f128f3e8bc677a9ad39004b7e5))

## [1.13.0](https://github.com/peetzweg/opendisplay/compare/v1.12.1...v1.13.0) (2026-07-21)


### Features

* end the session when the receiver sleeps, reconnect on wake ([#166](https://github.com/peetzweg/opendisplay/issues/166)) ([e7eb0e5](https://github.com/peetzweg/opendisplay/commit/e7eb0e57ede6bab10a31968dc66428cc266f9f9e))

## [1.12.1](https://github.com/peetzweg/opendisplay/compare/v1.12.0...v1.12.1) (2026-07-21)


### Performance Improvements

* reduce lag spikes when scrolling or drawing fast ([#162](https://github.com/peetzweg/opendisplay/issues/162)) ([0490441](https://github.com/peetzweg/opendisplay/commit/0490441cf147fe8c5f7d13e2f17333aae7544047))

## [1.12.0](https://github.com/peetzweg/opendisplay/compare/v0.11.0...v1.12.0) (2026-07-12)


### Features

* **ios:** add remote-config force-update gate ([#135](https://github.com/peetzweg/opendisplay/issues/135)) ([b4133f2](https://github.com/peetzweg/opendisplay/commit/b4133f25e27c6f8937b4cbf4b3985b82265068f7))
* **mac:** seamless transport switching between USB and WiFi ([8fecc3c](https://github.com/peetzweg/opendisplay/commit/8fecc3c4147da4778ce0111c55eb1aecd6bde22a))
* **protocol:** add version handshake on the wire ([#132](https://github.com/peetzweg/opendisplay/issues/132)) ([d506e6c](https://github.com/peetzweg/opendisplay/commit/d506e6cfc9c8ac43b5e56093ea5665df9426d86b))
* **web:** add four community posts to demo showcase ([3f13f9c](https://github.com/peetzweg/opendisplay/commit/3f13f9c0ef71fe666fadd46b48fe14887cba42c1))
* **web:** add Ko-fi support nudge banner under downloads ([10bfcdc](https://github.com/peetzweg/opendisplay/commit/10bfcdcceda08d6a948f14fed7e070cee717aba0))
* **web:** center hero Ko-fi nudge, move second to end of demo section ([d2256d4](https://github.com/peetzweg/opendisplay/commit/d2256d43e48292a4d4dd5297a8ece1b035430fdf))
* **web:** drop side borders on mobile Ko-fi nudge, keep top/bottom band ([2dd6b26](https://github.com/peetzweg/opendisplay/commit/2dd6b267514333394ffb4c8d54b0aa79ed17bc61))
* **web:** extract Ko-fi nudge into repeatable borderless SupportNudge section ([b12e00b](https://github.com/peetzweg/opendisplay/commit/b12e00b6202a5ec13995b5d9c278ce3f8db029e8))
* **web:** move Ko-fi nudge above downloads, drop hero support hint ([ca37938](https://github.com/peetzweg/opendisplay/commit/ca37938dc05767ffafd388dd223dab8a17ddd855))
* **web:** place sticky Ko-fi bar between hero and downloads section ([7c0f1e7](https://github.com/peetzweg/opendisplay/commit/7c0f1e776a41ef938a422e7c962dc9e5ee6a685a))
* **web:** revert Ko-fi nudge to centered bordered pill (drop full-width bar) ([a3e2b1d](https://github.com/peetzweg/opendisplay/commit/a3e2b1d1a12a9de5db57ea21485bf70341e6f111))
* **web:** show Ko-fi nudge both above (left) and below (centered) downloads ([66c1923](https://github.com/peetzweg/opendisplay/commit/66c192395f83e4c887fbbdc9d3870b5bd9a0ec91))
* **web:** single full-width sticky Ko-fi bar above downloads; unsticks at support; pointer cursor on support button ([2523672](https://github.com/peetzweg/opendisplay/commit/25236724858b49eac37b066571258f9fc449b6d2))
* **web:** sticky Ko-fi support nudge between hero and downloads ([15a18e7](https://github.com/peetzweg/opendisplay/commit/15a18e771303648563e968b2778895ac361fdc03))


### Bug Fixes

* **mac:** cancel virtual display retry on disconnect ([a131076](https://github.com/peetzweg/opendisplay/commit/a131076892780d0a9dcdc12aa9047d1240598999))
* **mac:** generation-guard the reconnect dial ([79452c7](https://github.com/peetzweg/opendisplay/commit/79452c7bef3e9b356d5e72b7401a8d4d9025cad2))
* **mac:** latest arrangement wins across orientation flips ([ad7800d](https://github.com/peetzweg/opendisplay/commit/ad7800dcb12a4557bd07a8481f7913da3b762fdd))
* **mac:** remember virtual display arrangement across reconnects ([72d4578](https://github.com/peetzweg/opendisplay/commit/72d45781c05ce9cf43e38476460e3b32977e17b6)), closes [#116](https://github.com/peetzweg/opendisplay/issues/116)
* **mac:** retry virtual display creation while a stale serial lingers ([8acc36c](https://github.com/peetzweg/opendisplay/commit/8acc36c3690351cd74541e0cf583c80c578435ef))


### Miscellaneous Chores

* release 1.12.0 ([5dc7b31](https://github.com/peetzweg/opendisplay/commit/5dc7b31ed6b3d6c19a4bebabe7e8ffa1981eafc4))

## [0.11.0](https://github.com/peetzweg/opendisplay/compare/v0.10.1...v0.11.0) (2026-07-07)


### Features

* **web:** full-bleed showcase strip with ad-blocker-proof tweet fallbacks ([26879c2](https://github.com/peetzweg/opendisplay/commit/26879c28f7c2912e8fc86b7c24ea3de7c58ac3d1))
* **web:** replace live X embeds with self-hosted static post cards ([9415b37](https://github.com/peetzweg/opendisplay/commit/9415b37ba2639ced50707b52efae921f5b2d84d2))
* **web:** showcase community tweets alongside the demo video ([9d95a94](https://github.com/peetzweg/opendisplay/commit/9d95a94cb56dcb4b99b630204610576cc4e8ec47))
* **web:** showcase community tweets alongside the demo video ([b32a4d1](https://github.com/peetzweg/opendisplay/commit/b32a4d1f2327e7d06166f4892acd6d70a70137dd))


### Bug Fixes

* **mac:** force extend-mode virtual display out of system mirror sets ([84f7dee](https://github.com/peetzweg/opendisplay/commit/84f7dee8e22f80c7b7a5d1e3bc23cb933fa56817))
* **mac:** force extend-mode virtual display out of system mirror sets ([#100](https://github.com/peetzweg/opendisplay/issues/100)) ([e3fca0e](https://github.com/peetzweg/opendisplay/commit/e3fca0e0869faafe9af9e3bd617ed9e8c936b64a))

## [0.10.1](https://github.com/peetzweg/opendisplay/compare/v0.10.0...v0.10.1) (2026-07-03)


### Bug Fixes

* **ci:** appcast never publishes on first release (untracked file) ([090144c](https://github.com/peetzweg/opendisplay/commit/090144cd195acf2397d804ddf5e5538ed7ece1ac))
* **ci:** publish appcast on first release (detect untracked file) ([db16008](https://github.com/peetzweg/opendisplay/commit/db16008ef3c9176b33ba3b8c319cc843547155c1))

## [0.10.0](https://github.com/peetzweg/opendisplay/compare/v0.9.0...v0.10.0) (2026-07-03)


### Features

* **mac:** scaffold Sparkle auto-update with Pages-hosted appcast ([42415f8](https://github.com/peetzweg/opendisplay/commit/42415f802485136b7bf4261705aae47863430787))
* **mac:** Sparkle auto-update with Pages-hosted appcast (rebase of [#70](https://github.com/peetzweg/opendisplay/issues/70)) ([1d52c29](https://github.com/peetzweg/opendisplay/commit/1d52c298cb3ed125e340fd6d9f115521a2404370))
* **web:** activate App Store download link for iOS receiver ([9ae421e](https://github.com/peetzweg/opendisplay/commit/9ae421ee079b558bb1ad095dab35a007eabb1b5b))
* **web:** add demo video section ([6a5a358](https://github.com/peetzweg/opendisplay/commit/6a5a358730e7844f528dcb9fcabf2b14a36c6e01))
* **web:** add hero app-icon logo with animated navbar handoff ([c4b2997](https://github.com/peetzweg/opendisplay/commit/c4b29971778905c1e29606a7d51f63c3d281f3e7))
* **web:** add multi-screen feature, tweak Ko-fi iPad wording ([279a39d](https://github.com/peetzweg/opendisplay/commit/279a39dd12dc58b6dbff9f78c9c8ac234fd40e37))
* **web:** add Plausible analytics and iOS Smart App Banner ([5504d91](https://github.com/peetzweg/opendisplay/commit/5504d91d46fbd6f4d41e964df5733eea9855eab5))
* **web:** add social share image and FAQPage structured data ([3fe0915](https://github.com/peetzweg/opendisplay/commit/3fe0915d25381a3f3276d61d88e4df5e463dc97c))
* **web:** align download secondary links, add older-version link, iPadOS, mobile step order ([1d59277](https://github.com/peetzweg/opendisplay/commit/1d59277bc1402f609a47d5fa184c93ee5351f34c))
* **web:** refine feature copy and reorder the grid ([a4e0799](https://github.com/peetzweg/opendisplay/commit/a4e0799a4ce6e2bb3ddd896e8113e1136f6df03f))
* **web:** reorder sections, Ko-fi branding, cost transparency, scroll-spy ([36105d3](https://github.com/peetzweg/opendisplay/commit/36105d3b1624f869ba7ce2fea29227281ceb7468))
* **web:** serve site from opendisplay.app custom domain ([712918f](https://github.com/peetzweg/opendisplay/commit/712918f21ca03c9a457a75766165896b2f7c99a2))


### Bug Fixes

* **ci:** guard Sparkle appcast step via env, not secrets context ([acd23b5](https://github.com/peetzweg/opendisplay/commit/acd23b5ca0fb087908494ada816cb3cb16ecf197))
* **ci:** release workflow fails at startup (secrets in if:) ([ff2e82f](https://github.com/peetzweg/opendisplay/commit/ff2e82f31f96973aee70674f648d56b4c47c2788))

## [0.9.0](https://github.com/peetzweg/opendisplay/compare/v0.8.0...v0.9.0) (2026-06-30)


### Features

* rename app to OpenDisplay ([07d9962](https://github.com/peetzweg/opendisplay/commit/07d9962ef83ffab8628a263f978e98d5f1cd1d94))

## [0.8.0](https://github.com/peetzweg/opensidecar/compare/v0.7.2...v0.8.0) (2026-06-29)


### Features

* **site:** improve landing-page SEO (robots, sitemap, meta) ([757983c](https://github.com/peetzweg/opensidecar/commit/757983c33d2d310dd9b32749b3cf8827d8b99eeb))
* **site:** improve landing-page SEO (robots, sitemap, meta) ([d1e63c9](https://github.com/peetzweg/opensidecar/commit/d1e63c902fcdbf462b49e1eef441087b459cab05)), closes [#59](https://github.com/peetzweg/opensidecar/issues/59)


### Bug Fixes

* **mac:** guard liveness monitors against double-start ([#75](https://github.com/peetzweg/opensidecar/issues/75) hardening) ([0c96e65](https://github.com/peetzweg/opensidecar/commit/0c96e65f75d6de1de980dc9b80fc7a57728e5da0))
* **mac:** stop CPU leak that creeps up across sleep/wake ([#75](https://github.com/peetzweg/opensidecar/issues/75)) ([c365668](https://github.com/peetzweg/opensidecar/commit/c365668e1a45e9dfbde44b1256ea9b4982270638))
* **mac:** stop cursor-image poll leak across sleep/wake ([#75](https://github.com/peetzweg/opensidecar/issues/75)) ([0e8a959](https://github.com/peetzweg/opensidecar/commit/0e8a9591cc6e2d73507c355ce84178344b0fcfae))

## [0.7.2](https://github.com/peetzweg/opensidecar/compare/v0.7.1...v0.7.2) (2026-06-23)


### Bug Fixes

* cd the DMG shell block to the repo root instead of expanding paths ([557bbf9](https://github.com/peetzweg/opensidecar/commit/557bbf9f5d7f9d75cd32b763a3c1347a843d6fa5))

## [0.7.1](https://github.com/peetzweg/opensidecar/compare/v0.7.0...v0.7.1) (2026-06-23)


### Bug Fixes

* use absolute paths when packaging the macOS DMG ([04860c7](https://github.com/peetzweg/opensidecar/commit/04860c7cf3549cbfb5b2e881cd017a3493df8c6e))

## [0.7.0](https://github.com/peetzweg/opensidecar/compare/v0.6.16...v0.7.0) (2026-06-23)


### Features

* **iOS:** first-run onboarding hint that the Mac app is required ([3d012f3](https://github.com/peetzweg/opensidecar/commit/3d012f30024f946b04064716f143bdf60762820a)), closes [#49](https://github.com/peetzweg/opensidecar/issues/49)
* new app icon + branding (laptop + display, happy-Mac faces) ([65dabce](https://github.com/peetzweg/opensidecar/commit/65dabce97541a0c470f5eadd3942e09eae664190))
* ship notarized .dmg + wire TestFlight link ([#48](https://github.com/peetzweg/opensidecar/issues/48)) ([1c10ce9](https://github.com/peetzweg/opensidecar/commit/1c10ce964a62180a4aea427ecf8965ab706b9045))
* ship notarized .dmg, wire TestFlight link ([#48](https://github.com/peetzweg/opensidecar/issues/48)) ([e902f14](https://github.com/peetzweg/opensidecar/commit/e902f14f30404f0b84600bb307591c7c6491af70))


### Bug Fixes

* **docs:** restore horizontal padding on mobile for hero and table ([7b10044](https://github.com/peetzweg/opensidecar/commit/7b100441433b94680972fd8e2473e66ddb36240e))

## [0.6.16](https://github.com/peetzweg/opensidecar/compare/v0.6.15...v0.6.16) (2026-06-15)


### Bug Fixes

* inject release version and unique build number into app builds ([924b464](https://github.com/peetzweg/opensidecar/commit/924b464f43d1170808b77e48448b6e2ecdd61ab4))

## [0.6.15](https://github.com/peetzweg/opensidecar/compare/v0.6.14...v0.6.15) (2026-06-15)


### Bug Fixes

* use full explicit iOS app icon set for TestFlight validation ([42569e3](https://github.com/peetzweg/opensidecar/commit/42569e381538eceaf8c8c070332b4939788d0338))

## [0.6.14](https://github.com/peetzweg/opensidecar/compare/v0.6.13...v0.6.14) (2026-06-15)


### Bug Fixes

* add CFBundleIcons with both IconName and IconFiles to resolve 90022/90023 ([271bd7a](https://github.com/peetzweg/opensidecar/commit/271bd7a5edf4277730dc3da4cc7f73c3f9398848))
* move legacy icons to iOS/ root, drop CFBundleIcons ([10e5b51](https://github.com/peetzweg/opensidecar/commit/10e5b51a1d313f8b43ff49efe4ed5f7e5f42ef3a))

## [0.6.13](https://github.com/peetzweg/opensidecar/compare/v0.6.12...v0.6.13) (2026-06-15)


### Bug Fixes

* add standalone legacy icon PNGs to fix altool 90022/90023/90713 ([783ecdd](https://github.com/peetzweg/opensidecar/commit/783ecddc5c214e8b385399159b935262af0fbb6f))

## [0.6.12](https://github.com/peetzweg/opensidecar/compare/v0.6.11...v0.6.12) (2026-06-15)


### Bug Fixes

* try universal/ios without size or rendering-intent ([d3fa276](https://github.com/peetzweg/opensidecar/commit/d3fa2769ee607b3c6803810aa549c769803b5778))

## [0.6.11](https://github.com/peetzweg/opensidecar/compare/v0.6.10...v0.6.11) (2026-06-15)


### Bug Fixes

* combined icon format with rendering-intent + CFBundleIconName ([9b606c1](https://github.com/peetzweg/opensidecar/commit/9b606c1646626cac1d48bd6b73344281cbb7e63f))

## [0.6.10](https://github.com/peetzweg/opensidecar/compare/v0.6.9...v0.6.10) (2026-06-15)


### Bug Fixes

* use Xcode 26 icon format with rendering-intent template ([1169c57](https://github.com/peetzweg/opensidecar/commit/1169c57c4ec1b84bae0ae73ea6bae96f00cb6358))

## [0.6.9](https://github.com/peetzweg/opensidecar/compare/v0.6.8...v0.6.9) (2026-06-15)


### Bug Fixes

* add universal ios-marketing icon alongside per-size entries ([0075d95](https://github.com/peetzweg/opensidecar/commit/0075d95ba31c8286106e106a0591fc48ecbc6dd8))

## [0.6.8](https://github.com/peetzweg/opensidecar/compare/v0.6.7...v0.6.8) (2026-06-15)


### Bug Fixes

* use Xcode 16+ universal app icon format for iOS ([fdcf118](https://github.com/peetzweg/opensidecar/commit/fdcf11894f4962d288fd54e1a6b3c16c8a551e5a))

## [0.6.7](https://github.com/peetzweg/opensidecar/compare/v0.6.6...v0.6.7) (2026-06-15)


### Bug Fixes

* add iPad icon sizes and switch CI to macos-26 for iOS 26 SDK ([2e0ad58](https://github.com/peetzweg/opensidecar/commit/2e0ad589ee80c039fb6fed7c18b286d67336e599))

## [0.6.6](https://github.com/peetzweg/opensidecar/compare/v0.6.5...v0.6.6) (2026-06-15)


### Bug Fixes

* pass explicit app_identifier to upload_to_testflight ([8bd61c4](https://github.com/peetzweg/opensidecar/commit/8bd61c4dad87333a8db276e48672f51db4d0bf64))

## [0.6.5](https://github.com/peetzweg/opensidecar/compare/v0.6.4...v0.6.5) (2026-06-15)


### Bug Fixes

* add setup_ci for keychain and correct Mac profile name ([c29944c](https://github.com/peetzweg/opensidecar/commit/c29944c3073967418801eb63c1656d441922612c))

## [0.6.4](https://github.com/peetzweg/opensidecar/compare/v0.6.3...v0.6.4) (2026-06-14)


### Bug Fixes

* wire match profiles to xcodebuild via update_code_signing_settings ([ea0fcdd](https://github.com/peetzweg/opensidecar/commit/ea0fcddad566170d892391287dc1c83d349d5b71))

## [0.6.3](https://github.com/peetzweg/opensidecar/compare/v0.6.2...v0.6.3) (2026-06-14)


### Bug Fixes

* use manual code signing for iOS Release to work with match ([200f665](https://github.com/peetzweg/opensidecar/commit/200f66571f159aff875543cbf87db3f5ffbc0752))

## [0.6.2](https://github.com/peetzweg/opensidecar/compare/v0.6.1...v0.6.2) (2026-06-14)


### Bug Fixes

* add explicit schemes to project.yml and restore SSH deploy key workflow ([9262883](https://github.com/peetzweg/opensidecar/commit/9262883fb656062054887479fa9fee7496dec1cd))

## [0.6.1](https://github.com/peetzweg/opensidecar/compare/v0.6.0...v0.6.1) (2026-06-14)


### Bug Fixes

* trigger release build with split CI jobs ([99100a6](https://github.com/peetzweg/opensidecar/commit/99100a6087d41db461bf45b674f84f60a94ddb81))

## [0.6.0](https://github.com/peetzweg/opensidecar/compare/v0.5.0...v0.6.0) (2026-06-14)


### Features

* fastlane release pipeline for iOS TestFlight and notarized Mac builds ([d940685](https://github.com/peetzweg/opensidecar/commit/d940685d9a515a0f11fe248c1f85e95e67a8d39d))

## [0.5.0](https://github.com/peetzweg/opensidecar/compare/v0.4.0...v0.5.0) (2026-06-11)


### Features

* auto-connect the -host/-port manual endpoint alongside devices ([e3dfc0f](https://github.com/peetzweg/opensidecar/commit/e3dfc0f7db6de8a1aaa39c4afedd6d2db4df9830))
* dedupe USB/WiFi sessions to the same physical device ([3228256](https://github.com/peetzweg/opensidecar/commit/3228256139ab80e658c7f0d019b30f91346ee854))
* multi-device sessions — one virtual display per connected device ([272a794](https://github.com/peetzweg/opensidecar/commit/272a794d20946dd8133cdb673104c589ed87c81b))
* multiple devices as simultaneous extended displays ([bc6b869](https://github.com/peetzweg/opensidecar/commit/bc6b869a321a964656d9c30c249c558c1afe8d99))
* one row per physical device, no automatic transport handover ([1cf5745](https://github.com/peetzweg/opensidecar/commit/1cf57450a09c632388fbb4f833f701e8aed89c54))
* per-display test patterns + multi-device docs and test tool ([d04a4ce](https://github.com/peetzweg/opensidecar/commit/d04a4cec233a061d1b6ef0d9fb12b27094b35cc5))
* relicense from MIT to GPL-3.0 ([22607a7](https://github.com/peetzweg/opensidecar/commit/22607a760afe0589f1f2485743b0a972b5f71804))


### Bug Fixes

* enforce HiDPI mode continuously, orientation-specific display serials ([300330e](https://github.com/peetzweg/opensidecar/commit/300330ea05d8ab0b99d9a3822bf745b33a2d28a7))
* real event source + clickState on injected clicks ([ede0ce4](https://github.com/peetzweg/opensidecar/commit/ede0ce4c11a0da2385109222338398216676d248))
* size the cursor sprite against the live display mode ([b494081](https://github.com/peetzweg/opensidecar/commit/b49408116d320655e2a13d0dbec5b45d220fb64a))
* user clicks take over dying sessions; recover vanished [@2x](https://github.com/2x) modes ([0b74810](https://github.com/peetzweg/opensidecar/commit/0b74810acf013116e8343bcebea422da661f262d))

## [0.4.0](https://github.com/peetzweg/opensidecar/compare/v0.3.0...v0.4.0) (2026-06-11)


### Features

* built-in USB connectivity (drop the iproxy requirement) ([3ab674a](https://github.com/peetzweg/opensidecar/commit/3ab674acc15f271dd36d3001abee927aff762c41))
* built-in USB connectivity over usbmuxd, drop the iproxy requirement ([79e07a5](https://github.com/peetzweg/opensidecar/commit/79e07a5bf011ad341a45c3f0de4fb7eac3002463))
* editable device name for the WiFi connection picker ([eb6f036](https://github.com/peetzweg/opensidecar/commit/eb6f036f062954cdd43f0159763e50431a692de1))
* editable device name for the WiFi picker ([a470abc](https://github.com/peetzweg/opensidecar/commit/a470abc74a18b84194507669b645423f76c5b6f9))


### Bug Fixes

* cursor disappears after a reconnect ([288e3b1](https://github.com/peetzweg/opensidecar/commit/288e3b10b1e0538034e39715f99a869036d6b51e))
* device-name field needed two taps to edit ([0855813](https://github.com/peetzweg/opensidecar/commit/0855813fafb457f04cec8710617c0de9ef24dc91))
* re-send the cursor sprite to a reconnecting receiver ([2c13082](https://github.com/peetzweg/opensidecar/commit/2c130820deb94cebadada633a08c934e16d5c7db))
* wrap the performance overlay so it fits in portrait ([809368c](https://github.com/peetzweg/opensidecar/commit/809368cc8bdff47e6c59a732aac8df59f9431ba5))

## [0.3.0](https://github.com/peetzweg/opensidecar/compare/v0.2.0...v0.3.0) (2026-06-10)


### Features

* app presentation modes and menu bar panel sizing fix ([cc7caa5](https://github.com/peetzweg/opensidecar/commit/cc7caa593b99c1f2cecc2eb5e5fa55ecc6fd6fbe))
* end session when the device disconnects, rename Phone target to iOS ([5b99719](https://github.com/peetzweg/opensidecar/commit/5b99719cb5a630b3bfc103aca5844d4e82513456))
* experimental Metal renderer with true glass-time latency metric ([e9b784c](https://github.com/peetzweg/opensidecar/commit/e9b784c6b444c86b6527889827db0cd111d9e7f4))
* local cursor echo — pointer rendered on-device off the video path ([f043be5](https://github.com/peetzweg/opensidecar/commit/f043be5da9263fa3e5e86ca4f8d9b3759eee8f6e))
* menu bar app, true latency telemetry, quality presets, low-latency encoder ([d826668](https://github.com/peetzweg/opensidecar/commit/d826668f189078287682148744eeb341a50e32c0))
* transport badge and expanded debug overlay, Release deployment ([547355d](https://github.com/peetzweg/opensidecar/commit/547355d51f55c7eeaa07ffce4a7e336e6159617f))


### Bug Fixes

* Metal renderer A/B verdict — system layer wins, Metal stays opt-in ([49b4b8d](https://github.com/peetzweg/opensidecar/commit/49b4b8d83d59d780fb5059575dd8c13ab7afd041))
* rebuild the capture pipeline when the stream dies ([bc0f9d8](https://github.com/peetzweg/opensidecar/commit/bc0f9d8416d1fa301ed5e6859978738af64f06bb))


### Performance Improvements

* sustain true 60fps capture and cut input latency ([964d567](https://github.com/peetzweg/opensidecar/commit/964d5678e891055ea126b2ffa10fba97ade6a283))

## [0.2.0](https://github.com/peetzweg/opensidecar/compare/v0.1.0...v0.2.0) (2026-06-10)


### Features

* Arrange Displays shortcut in the Mac app ([c64bdec](https://github.com/peetzweg/opensidecar/commit/c64bdec442499408811ff64badaaae5954e129d5))
* opt-in performance overlay on the iPhone ([770b5d1](https://github.com/peetzweg/opensidecar/commit/770b5d1609aeda27e082e01cf7c5ee1dcf0df82f))
* permission status UI, iOS settings screen, system light/dark mode ([f5a4131](https://github.com/peetzweg/opensidecar/commit/f5a41311ed8bc2cd749f6168b37d8ed5339ff7f9))
* rebrand to a neutral Apple white-and-blue palette ([d2543a0](https://github.com/peetzweg/opensidecar/commit/d2543a067afd3ae286b451b95672200d5e47b3ef))


### Bug Fixes

* automatic recovery from stale and half-open connections ([8b49ccb](https://github.com/peetzweg/opensidecar/commit/8b49ccb540ee4e335d486472d470857dd8324808))

## 0.1.0 (2026-06-10)


### Features

* automated releases with downloadable macOS and iOS builds ([377b5d3](https://github.com/peetzweg/opensidecar/commit/377b5d3621b8cf826cc7f74ff3fdc23607577d08))
