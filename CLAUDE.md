# Instructions for Claude

This repo is a macOS menu bar app ("LG PBP") plus a CLI (`bin/lgpbp`). Read
`README.md` for what it does. This file is what you need to know before touching
anything, and `docs/SECOND-MAC.md` is the task list for setting it up on a second Mac.

## Hard rules for the monitor

The monitor is an LG UltraFine 40U990A, controlled over DDC/CI. A careless probe
during development changed its colour and backlight settings and the owner had to
factory-reset it. So:

1. **Never sweep or scan DDC codes.** No loops over VCP codes, no "dump everything".
2. **LG's alternate address `0x50` is a service channel and the likely cause of
   the damage.** Exactly one thing may be sent there: the input-switch code `0xF4`
   with one of the values `0x90`, `0x91`, `0xD0`, `0xD1`, `0xD2`. The owner accepted
   that risk for this command only. No other code, no reads, no scans, ever.
3. **Everything else stays on the standard address `0x51`**, and only two codes
   are in scope there: `0xD7` (PBP) and `0x60` (read the current input). All monitor
   access lives in `Sources/LGMonitor.swift`; keep it that way.
4. **Ask the owner before sending the monitor anything**, read or write. Say
   exactly which command you will run and wait for a yes. One approval covers one
   command, not the next one.
5. If anything on screen changes unexpectedly, stop and tell the owner. The
   recovery is the joystick menu: Settings → General → Reset to Initial Settings.

`bin/lgpbp state` is always safe: it infers the PBP state from the Mac's picture
and sends nothing to the monitor.

## What has been verified on this monitor

| Command | Result |
|---|---|
| Read `0xD7` | Works. 1 = off, 3 = PBP 75/25, 5 = PBP 50/50, 0 = PIP active |
| Write `0xD7` = 1, 3, 5 | Works |
| Write `0xD7` = 0, 2, 4 | Ignored |
| Read `0x60` | Works. The USB-C / Thunderbolt input reads as 15 (`0x0F`) |
| Write `0x60` = `0x11` (HDMI 1) | Ignored: the input stayed on USB-C |
| `0xF4` = `0x90` on `0x50`, sent from the active input | Works: switches to HDMI 1 |
| `0xF4` = `0xD1` on `0x50`, sent from the Mac that was **not** on screen | No effect |

Open questions about input switching:

- Whether `0xD1` or `0xD2` is the value for USB-C. `0xD1` did nothing, but it was
  sent from the Mac that was not being shown, so the monitor may simply ignore
  switch commands from an inactive input.
- The proven `0x90` switch was sent with `m1ddc set input-alt 144`. The project's
  own `bin/lgpbp input hdmi1` builds the same packet but has not been run yet.
- Reading `0x60` from the Mac that is not on screen still answers, and still
  reports that Mac's own input.

Quirks: a "Get VCP" must be written twice before the monitor answers, and for a
few seconds after a mode switch it gives no valid reply (retry once after 3 s).

## Building

`./build.sh` builds `bin/lgpbp` and `LG PBP.app`. It signs with an "Apple
Development" certificate if the keychain has one, otherwise ad hoc. With an ad-hoc
signature the Accessibility permission breaks on every rebuild; the fix is for the
owner to run `tccutil reset Accessibility local.lgpbp.menubar` and grant it again.
Do not run that yourself: it changes privacy settings.

## Git

The repo belongs to the GitHub account `victordlsb`. Commit and push as that
account, with a GitHub noreply author address. Do not commit build products, and
do not commit anything from a machine's personal settings (widget backups, plists).
