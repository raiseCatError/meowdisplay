# MeowDisplay 2.0 — Reviewer's Guide

MeowDisplay is free. You do not need a review code, licence key or account.

## What it does
- Shows your Mac on an iPhone or iPad: mirrored, as an extended display, or as individual windows (Window view).
- Lets you control the Mac from the device by touch, pointer, keyboard and shortcuts, once the Mac allows it.
- Connects over USB, local Wi-Fi, or Remote Access over a private network you already run, such as Tailscale.

## What it does not do
- It does not run a cloud relay, account system or remote-access service. Remote Access needs a route you provide.
- It is not a fleet-management or enterprise remote-support product.
- Android is in closed testing and does not have every feature of the Apple apps.
- It does not replace Apple Sidecar or Universal Control and does not use them.

## What to install
1. On the Mac: MeowDisplay 2.0 from https://meowdisplay.app/downloads or the GitHub release (macOS 14 or later). Homebrew users can install the `meowdisplay` cask from the `raiseCatError/homebrew-tap` tap.
2. On the iPhone or iPad: MeowDisplay from the App Store (iOS / iPadOS 16.4 or later).

## Connect
1. Open MeowDisplay on the Mac and grant Screen Recording. Grant Accessibility if you want to control the Mac from the device.
2. Open the app on the iPhone or iPad on the same Wi-Fi network, or connect it by USB.
3. Choose the Mac, confirm the matching pairing code on both devices, and approve with Touch ID or your password on the Mac.
4. If a device was paired before and will not reconnect, Forget it on both sides and pair again.

## A five-minute demonstration
1. Mirror (1 min): connect an iPad and rotate it to landscape. The Mac desktop appears.
2. Extend (1 min): in the iPad's Settings › Display, choose Show Mac Windows… › Extend. Drag a window onto the new display on the Mac.
3. Window view (1 min): on the iPhone, choose Show Mac Windows… and pick a window. Open Stage Peek from the left edge, expand it, touch and hold another window and choose Add as New Pane.
4. Stage Peek (1 min): open Stage Peek again, search for an app, and switch the selected pane to Full Desktop or another window.
5. Typing (1 min): select a pane with a text document, open the keyboard from the control tray, type into the Text Bar and press Done. Zoom While Typing keeps the line large.

## Connection types
- USB (iPhone and iPad): wired, lowest setup effort, no network needed.
- Local Wi-Fi: devices on the same network discover each other.
- Remote Access: connects to an already paired Mac through a reachable private-network address such as a Tailscale address or MagicDNS name. The address only routes the connection; it never grants trust, and pairing is still required.

## Security and permission
- Pairing requires a matching code on both devices and approval on the Mac.
- Sessions are encrypted with TLS 1.3, and each device's identity is pinned after pairing.
- Input is a separate permission: the Mac's Input settings decide whether each device must ask, is always allowed, or is view-only. A device can request control during a session.

## Known issues in 2.0.0 (open, not yet fixed)
- iPad with the Custom control layout: after rotating between portrait and landscape, Window view panes can stay sized for the previous orientation until MeowDisplay is relaunched. Strip and Overlay layouts are the workaround. Tracked in https://github.com/raiseCatError/meowdisplay/issues/129.
- iPhone in landscape: Stage Peek's default Compact Dock has room for about one window card at a time. Settings › Controls › Window Switcher › Dock › Normal shows more cards. Tracked in https://github.com/raiseCatError/meowdisplay/issues/130.

## Other behaviour observed during capture (3 November 2026)
- A window already shown on one device is not offered in another device's Stage Peek.
- Moving a window that sits on another device's extended display into a pane can take 10–15 seconds to appear.
- Keyboard input goes to the Mac's key window; select the pane you want before typing.

## Links
- Release notes: https://github.com/raiseCatError/meowdisplay/releases/tag/v2.0.0
- Setup: https://meowdisplay.app/docs
- Features: https://meowdisplay.app/features
- Support and troubleshooting: https://meowdisplay.app/support
- Issues: https://github.com/raiseCatError/meowdisplay/issues
- Press contact: j@raisecaterror.com

## Story angles
- A free way to use an iPhone or iPad you already own as a display for your Mac.
- Individual Mac windows on a phone, arranged side by side instead of a shrunken desktop.
- Touch-first control of a Mac: tray, Text Bar, Zoom While Typing and three touch modes.
- An independently developed, open-source project with no hosted relay: remote use runs over your own private network.
