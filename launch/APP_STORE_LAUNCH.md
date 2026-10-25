# MeowDisplay is now on the App Store

*October 25, 2026*

**Your Mac. Another screen. Anywhere.**

MeowDisplay for iPhone and iPad is now available, free, on the App Store:
<https://apps.apple.com/us/app/meowdisplay/id6817552864>

MeowDisplay turns your iPhone or iPad into a mirrored or extended display for
your Mac, and lets you control the Mac from it: Direct Touch, a trackpad-style
pointer, Mac gestures, a keyboard, control trays and shortcuts, Apple Pencil on
supported iPads, and Mac system audio on the receiver.

Connect over USB or Wi-Fi, pair your devices once by confirming a matching
code, and make a little more room for your Mac.

Free and open source. No MeowDisplay account required.

## What you need

| | |
|---|---|
| **iPhone or iPad** | iOS or iPadOS 16.4 or later. [MeowDisplay on the App Store](https://apps.apple.com/us/app/meowdisplay/id6817552864), free |
| **Mac** | macOS 14 or later, running the MeowDisplay Mac app |

**The Mac app is not on the App Store and has no signed download yet.** For now
you build it from source with Xcode (a free Apple account is enough to sign
it). The [`release/app-store-rc`](https://github.com/raiseCatError/meowdisplay/tree/release/app-store-rc)
branch matches App Store version 1.20.0. Setup:
<https://meowdisplay.app/docs#status>. A signed, notarized Mac download will
follow through the project's release workflow; this note will be updated when
it exists.

## Good to know

- Mac-to-iPhone is the primary tested setup. iPad and the standalone Mac
  Receiver work but need broader hardware validation.
- Remote Access works over a private network you set up yourself, such as
  Tailscale. MeowDisplay runs no relay or server of its own.
- Controlling the Mac needs Accessibility permission, **Allow Input** turned on,
  and a control request from the device each session. Connecting alone never
  grants control.
- The app is in English for now.

## Thank you, OpenDisplay

MeowDisplay started as a fork of [OpenDisplay](https://github.com/peetzweg/opendisplay)
by Philip Poloczek, which provided the working foundation: Mac screen capture,
virtual displays, video encoding and the original receiver. MeowDisplay remains
open source under GPL-3.0.

## Links

- App Store: <https://apps.apple.com/us/app/meowdisplay/id6817552864>
- Website: <https://meowdisplay.app/>
- Setup: <https://meowdisplay.app/docs>
- Features: <https://meowdisplay.app/features>
- Support: <https://meowdisplay.app/support>
- Source: <https://github.com/raiseCatError/meowdisplay>
