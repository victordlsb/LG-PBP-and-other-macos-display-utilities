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
| `0xF4` = `0xD1` on `0x50`, sent from the HDMI 1 Mac while it **was** on screen (`bin/lgpbp input usbc`) | No visible effect: stayed on HDMI 1 |
| `0xF4` = `0xD2` on `0x50`, sent from the HDMI 1 Mac alone on screen, PBP off | Works: switches to USB-C / Thunderbolt |
| PBP turned on from the Thunderbolt Mac while it was on screen | Thunderbolt Mac on the left, HDMI 1 Mac on the right: the layout the owner wants |
| Read and write `0xD7` over HDMI 1 through a USB-C to HDMI adapter (second Mac) | Works |
| `0xF4` = `0xD0` on `0x50`, sent from the DisplayPort Mac while the USB-C Mac was on screen | Works: switches to DisplayPort. So switching works from the Mac that is **not** on screen |
| Write `0xD7` = 5 / 1 from the Mac that is **not** on screen | Works |

PBP side: the input that is on screen when PBP is switched on goes on the **left**
(the large part in 75/25), whichever Mac sends the command. No DDC command for
swapping the sides is known. `LGMonitor.startPBP` works around it by switching to
the chosen input first (`0xF4` on `0x50`), waiting 4 s, then writing `0xD7`; the app
("Left Side in PBP") and `bin/lgpbp on --left hdmi1|usbc` use it only when PBP is off.
Verified from the HDMI 1 Mac with USB-C as the left side: the picture shows the
USB-C Mac for ~4 s, then PBP comes on with USB-C left and HDMI 1 right.

⌃⌥⌘O toggles between the two Macs: the other one, or this Mac if the other one is what
the app last put full screen (`fullScreenInput`, remembered in memory only, because
the monitor cannot say which input it shows).

Switching to a Mac whose picture is asleep fails: the monitor keeps the link to the
input it is not showing, so that Mac gets no hot-plug and stays dark, and the monitor
falls back after a few seconds (seen with the DisplayPort Mac's lid closed; with
`caffeinate -d` running there it worked). `Sources/Peer.swift` handles it over the
local network, with no monitor access: the sending Mac asks the other app to wake its
picture (`IOPMAssertionDeclareUserActivity`) and waits for "awake" before the switch.
The same link carries "shown <input>" so both apps know the input last put full screen.

"Full Screen" in the app (and ⌃⌥⌘O) reads `0xD7`, writes `0xD7` = 1
if PBP is on, waits 3 s, then sends `0xF4` with the input's value. Not run yet. It
never sends `0xF4` while PBP is on. Which input the Mac is on comes from the EDID
model number (`LGMonitor.ownInput`), not from the monitor.

The EDID model number depends on the input: `0x9EBA` over USB-C, `0x9EB8` over
HDMI 1, `0x9EB9` over DisplayPort. `LGMonitor.models` accepts all three.

The second Mac moved from HDMI 1 to **DisplayPort** on 2026-11-16. The two inputs in
use are listed in `LGInput.inUse` (USB-C and DisplayPort); the menu offers only those.

`bin/lgpbp state` only describes the Mac it runs on: on the Mac that is not on
screen it keeps reporting the last mode, and with a bandwidth-limited link macOS
may pick a half-width mode while PBP is off. The read of `0xD7` is authoritative.
For that reason the app reads `0xD7` each time its menu opens and before a toggle,
and `bin/lgpbp on --left` reads it before deciding to switch inputs. Opening the
menu therefore sends a read to the monitor.

Open questions about input switching:

- The proven `0x90` switch was sent with `m1ddc set input-alt 144`. The project's
  own `bin/lgpbp input hdmi1` builds the same packet but has not been run yet.
- Reading `0x60` from the Mac that is not on screen still answers, and still
  reports that Mac's own input.

Quirks: a "Get VCP" must be written twice before the monitor answers, and for a
few seconds after a mode switch it gives no valid reply (retry once after 3 s).

## Building

`./build.sh` builds `bin/lgpbp` and installs the app as `/Applications/LG PBP.app`,
restarting it if it was running. It leaves no copy in the repo, on purpose: two
copies both get launched and run side by side. It signs with an "Apple
Development" certificate if the keychain has one, otherwise ad hoc. With an ad-hoc
signature the Accessibility permission breaks on every rebuild; the fix is for the
owner to run `tccutil reset Accessibility local.lgpbp.menubar` and grant it again.
Do not run that yourself: it changes privacy settings.

A revoked "Apple Development" certificate still looks valid in the keychain, but
macOS treats an app signed with it as malware and offers to move it to the Bin.
`build.sh` skips revoked identities and refuses to finish if the signature it made
is revoked; the fix is a new certificate from Xcode (Settings → Accounts → Manage
Certificates) and deleting the old one, both done by the owner.

## Git

The repo belongs to the GitHub account `victordlsb`. Commit and push as that
account, with a GitHub noreply author address. Do not commit build products, and
do not commit anything from a machine's personal settings (widget backups, plists).
