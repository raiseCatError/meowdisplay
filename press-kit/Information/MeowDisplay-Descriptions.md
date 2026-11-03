# MeowDisplay — Descriptions and Fact Sheet

Checked 3 November 2026 against the App Store listing, the GitHub v2.0.0 release and meowdisplay.app.

## One sentence
MeowDisplay is a free, open-source app that turns an iPhone or iPad into a display for your Mac, showing the whole desktop, an extended desktop or individual Mac windows you can control by touch.

## About 50 words
MeowDisplay turns an iPhone or iPad into a second screen for a Mac. Mirror the desktop, extend it, or pick individual Mac windows and arrange them side by side. Touch controls, a keyboard with a Text Bar and Stage Peek window switching make it practical on a small screen. It is free and open source.

## About 150 words
MeowDisplay is a free, open-source app that brings your Mac to an iPhone or iPad. Mirror an existing display, extend the desktop onto a new virtual display, or use Window view to show individual Mac windows rather than a shrunken copy of the whole screen. Panes can be arranged in splits and grids of up to nine windows on iPhone and iPad; on a phone, two or three larger panes are usually easiest to read.

Stage Peek lists open windows and running apps so you can switch, search or add a window to a pane. Touch controls include Direct Touch, Natural Touch and Trackpad modes, a control tray with modifier keys and shortcuts, and a keyboard with a Text Bar. Zoom While Typing keeps the line you are editing large.

Devices connect over USB or local Wi-Fi, or remotely over a private network you control, such as Tailscale. Devices are paired, sessions are encrypted, and the Mac decides who may control it.

## Longer overview
MeowDisplay uses a Mac as the sender and an iPhone, iPad, Android device or another Mac as the receiver. Version 2.0 of the Mac app and the iPhone/iPad app is released. Android is in closed testing and does not yet have full parity with the Apple apps.

Display modes. Mirror shows the same display you see on the Mac. Extend adds a separate virtual display that macOS treats like any other monitor. Each connected device can have its own mode, so an iPad can extend while an iPhone shows windows.

Window view. Instead of a whole desktop, a receiver can show the Mac windows you choose, side by side in panes or as tabs. Each pane keeps its own zoom. Full Desktop can also be used as a pane.

Stage Peek. A strip opened from the screen edge shows running apps, open windows and the Mac's displays, with search. From it you can switch a pane to another window, add a window as a new pane, or return to the full desktop.

Input. Receivers send touch, trackpad-style pointer movement, scrolling, keyboard input and shortcuts. The control tray holds modifier keys, Escape, Tab, Return, Undo/Redo, zoom and the keyboard. The Text Bar lets you compose text before sending it, and Zoom While Typing enlarges the line being edited. Control is granted per device and per session on the Mac.

Connections and security. Devices connect over USB (iPhone and iPad) or local Wi-Fi. Remote Access works over a reachable private-network address, such as a Tailscale address, after normal pairing; MeowDisplay does not run a relay or account service. Pairing uses a matching code, sessions use TLS 1.3 and each device's identity is pinned.

MeowDisplay is free, with no subscription, and its source is published under GPL-3.0.

## Key capabilities
1. Mirror, Extend or Window view, chosen per device.
2. Window view panes: splits and grids of up to nine windows on iPhone and iPad.
3. Stage Peek for finding, searching and switching Mac windows.
4. Touch-first control: Direct Touch, Natural Touch and Trackpad, a control tray, keyboard, Text Bar and Zoom While Typing.
5. USB, local Wi-Fi and private-network Remote Access, with pairing, TLS 1.3 and per-session control permission.

## Fact sheet
- Product: MeowDisplay
- Developer: Jai Sukka (raiseCatError), independent developer
- Current version: 2.0.0 for Mac, iPhone and iPad (released 2 November 2026)
- Price: Free, no subscription
- Source: open source, GPL-3.0 — https://github.com/raiseCatError/meowdisplay
- Mac app (sender and receiver): macOS 14 or later
- Separate receiver-only Mac app: macOS 12 or later
- iPhone and iPad: iOS / iPadOS 16.4 or later, App Store — https://apps.apple.com/app/id6817552864
- Android: Android 10 or later, closed testing only
- Connections: USB (iPhone/iPad), local Wi-Fi, Remote Access over a private network such as Tailscale
- Website: https://meowdisplay.app
- Release notes: https://github.com/raiseCatError/meowdisplay/releases/tag/v2.0.0
- Press contact: j@raisecaterror.com
- Public issues and support: https://github.com/raiseCatError/meowdisplay/issues

## Developer background
MeowDisplay is developed independently by Jai Sukka, who publishes as raiseCatError. It began as a fork of OpenDisplay by Philip Poloczek, which provided a working low-level foundation; MeowDisplay has since been rebuilt and extended with its own receiver apps, Window view, Stage Peek, touch controls and Remote Access. The project is free and open source.
