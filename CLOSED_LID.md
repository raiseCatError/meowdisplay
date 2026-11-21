# Stay Awake with Lid Closed

Mac Settings → System → Availability, directly below **Keep Mac Available**.

## What it does

It turns on macOS's global `SleepDisabled` power setting (`pmset -a disablesleep 1`).
With it on, a MacBook keeps running with its lid closed and no external display, so a
receiver can keep using it. It also stops all other sleep, including Apple menu → Sleep.

It is separate from **Keep Mac Available**, which is unchanged. Keep Mac Available holds
an app-owned IOKit assertion (`PreventUserIdleSystemSleep`) that macOS releases when MEOW
exits. That assertion only stops idle sleep. It can't stop lid-close sleep without an
external display. Amphetamine's ordinary assertions can't either. The owner tested this
on an M2 MacBook Air: only `disablesleep 1` kept the Mac awake and usable with the lid
closed. That result comes from one device. It isn't hardware QA of this feature, and
it doesn't cover other models.

## Why it needs care

`SleepDisabled` isn't an assertion:

- It is a single global setting. It has no owner and no reference count, and macOS gives
  no ownership token for it.
- It stays set after MEOW quits, crashes or is force-quit. Whether it survives a restart
  hasn't been verified for this feature. MEOW reads the value at launch either way.
- Only root can write it. Any administrator, Amphetamine's Power Protect helper or
  another tool can change it at any time.

So MEOW can't guarantee ownership. It uses a conservative protocol and states its limits.

## Ownership protocol

| Read value | MEOW record | Shown as | MEOW will… |
|---|---|---|---|
| 0 | none | Off | turn it on when asked |
| 1 | present | On, turned on by MEOW | turn it off when asked |
| 1 | none, or from an earlier boot | On, no current MEOW record (toggle disabled) | never write, unless the person picks **Turn Sleep Back On…** and confirms |
| 0 | present | Off, with "changed outside MEOW, or reset by a restart" | drop the record, never write |
| unreadable | any | Unknown (no switch: Off would be a guess) | never write (fail closed) |

- **Reading.** `/usr/bin/pmset -g` with fixed arguments. It is read-only and needs no
  privileges. macOS has no public API for this value. pmset prints `SleepDisabled` only after
  the value has been stored, so on otherwise normal output (with a "Currently in use:"
  section) a missing line reads as 0, the default. A malformed value or unrecognised output
  counts as unreadable.
- **Turning on.** MEOW reads first. If the value is already 1, MEOW does nothing and claims
  nothing. If it is 0, MEOW writes 1 and reads again. It records ownership
  (`closedLidAvailability.ownership` in its defaults: time, prior value 0 and
  `kern.bootsessionuuid`) only after that read confirms 1. A record from an earlier boot is
  dropped: something else may have set the value since the restart. If the write isn't verified, MEOW records nothing. The setting then
  shows as external, so MEOW never clears it blindly.
- **Turning off.** MEOW acts only when its record exists and a fresh read shows 1. If a
  known sleep utility is running (Amphetamine, KeepingYouAwake, Lungo, Caffeine), MEOW asks
  first, because writing 0 also undoes their use of the shared setting. A running app
  doesn't prove that it controls `SleepDisabled`. Only Power Protect normally does; the
  others hold assertions. After writing 0, MEOW reads again and drops its record only when
  the value is confirmed 0.
- **External changes.** MEOW re-reads at launch, when the Settings row appears, when the app
  becomes active and after wake. It never polls. A change made outside MEOW wins: MEOW drops
  its claim and doesn't fight the change.

- **The person can always undo it.** When sleep is off and MEOW has no current record of
  turning it off, the row says so and offers **Turn Sleep Back On…**. That option explains
  whose setting it may be and needs confirmation, then shows the usual administrator prompt.
- **While a change is pending,** the switch keeps its previous value, so it never shows Off
  while sleep is still disabled.

Known limit: suppose another tool sets 1 again, within the same boot, after something else
had restored 0 while MEOW was in the background without refreshing. Or suppose that tool
sets 1 while MEOW's record is held, and it isn't a running app MEOW recognises. Then MEOW can't tell, and turning the feature off
clears it for both. The confirmation for running utilities narrows this case, but the OS
gives no way to close it fully.

## Privileges

Each change shows the standard macOS administrator prompt. MEOW runs `do shell script` with
`administrator privileges` in a fresh `/usr/bin/osascript` process for each change, off the
main thread. A separate process caches no authorization: an in-process `do shell script`
would skip the password for about five minutes. A separate process also keeps the app
responsive while the prompt is up. The command is a fixed string (`/usr/bin/pmset -a
disablesleep 0|1`), and nothing user-supplied goes into it. No helper is installed. There is
no sudoers entry, no stored credential and no general command runner. Cancelling the prompt
changes nothing.

This needs the non-sandboxed Developer ID build, which is what MEOW ships for macOS.

A signed `SMAppService` launch daemon would remove the password prompt. It would also put a
permanent root process on every Mac that enabled it once, and it needs its own XPC
authentication review. That is a separate security decision, and it isn't part of v1.

## Lifecycle

| Event | Result |
|---|---|
| Quit (menu, ⌘Q, Sparkle update) while MEOW owns it | Alert: **Turn Sleep Back On** (asks for the password) or **Keep Sleep Off**. If restoring fails or is cancelled, a second alert says sleep is still off and gives the command. pmset isn't run on quit unless MEOW holds a record. |
| Ordinary Quit while an administrator change is pending | Quit waits for the prompt to be answered and the write, read-back and ownership recording to finish, then follows the normal quit path above. Repeated Quit requests do not start another operation. |
| Logout, restart, shutdown, or Privacy Shield covering the screen | No prompt: shutdown is never blocked, and nobody could see an alert under the shield. The setting and record stay; the next launch shows the state. |
| Crash or force quit | The setting stays on. The next launch reads 1 plus the record and shows "turned on by MEOW" (same boot), or "no current MEOW record" with **Turn Sleep Back On…** (after a restart). |
| Prompt cancelled or write failed | Nothing changes. A notice explains why. |
| Changed elsewhere | Picked up at the next refresh trigger. MEOW drops its claim. |
| MEOW deleted while on | The setting stays on. Recover with `sudo pmset -a disablesleep 0`. The quit alert tells you this command. |

Force Quit and system termination do not guarantee cancellation of a separate administrator
process. A write may finish after MEOW exits, before it records ownership. The next launch
reads the actual setting and treats an unrecorded change as external; it never guesses that
the operation was cancelled or restores the setting automatically.

## Risks shown to the person

While the feature is on, the Mac doesn't sleep at all. Battery drain, heat, and a closed
MacBook in a bag are the real risks. The row says so once, in plain words, and doesn't
show repeated alerts.

## Future: wake-aware closed-lid access (research, not built)

Goal: let the Mac sleep normally, wake it remotely, keep it awake with the lid closed only
for a live remote session, then restore normal sleep. Open problems:

- **Waking with the lid closed and no display.** Wake on Demand / Bonjour Sleep Proxy and
  Wake-on-LAN (see `REMOTE_WAKE_ON_LAN.md`) can wake the Mac. On the owner's M2, though, a
  lid-closed MacBook falls back to sleep after a short dark wake unless `SleepDisabled` is set.
- **Switching per session.** Turning `SleepDisabled` on and off per session needs root without
  a prompt each time, which means a privileged helper (see Privileges).
- **Restoring safely after a session ends abnormally.** That needs a watchdog in the helper,
  because the app may be gone.
- **Security.** A remotely triggered path to change a root-owned power setting needs its own
  threat model: trusted-device identity, lock-screen state, and replay.
- **Hardware coverage.** Lid-close behaviour differs by model and macOS version. Each needs
  physical QA.
