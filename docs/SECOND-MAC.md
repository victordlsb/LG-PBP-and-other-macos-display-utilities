# Setting up a second Mac

Task list for a Claude session on a second Mac that shares the same LG UltraFine
40U990A. Read `CLAUDE.md` first: its rules about the monitor apply to every step here.

## The situation

- The first Mac is connected USB-C to USB-C and everything works there.
- The second Mac is a MacBook Pro (M1 Pro) connected to the monitor's **HDMI 1**
  through a **USB-C to HDMI adapter**, so the signal leaves the Mac over USB-C.
- The open question is whether that adapter passes DDC/CI. The M1's built-in HDMI
  port does not, but it is not being used here.
- The owner switches keyboard and mouse between the two Macs, and wants PBP and
  input switching to work from whichever Mac has the keyboard.

## Steps

Work through these in order. Stop and report after any step that fails.

### 1. Check the machine

```sh
uname -m                 # must be arm64
sw_vers -productVersion  # must be 13 or later
xcode-select -p          # must print a path; if not, the owner runs: xcode-select --install
system_profiler SPDisplaysDataType | grep -A6 "LG ULTRAFINE"
```

The last command confirms macOS sees the LG. It sends nothing to the monitor.

### 2. Build

```sh
./build.sh
```

Note whether it reports "signed with developer identity" or "ad-hoc signed".

### 3. Check the inferred state (safe)

```sh
bin/lgpbp state
```

Expected: `Off`, `PBP 50/50` or `PBP 75/25`. If it says the monitor is not
connected, the display's EDID vendor/model is not being recognised through the
adapter; report the vendor and model numbers macOS shows and stop.

### 4. Check whether the adapter passes DDC (ask first)

Ask the owner for permission, then run exactly this, once:

```sh
bin/lgpbp status
```

It is a single read of code `0xD7`, the same read that has been harmless on the
first Mac.

- `PBP (D7) = 1: off` (or 3, 5, 0): the adapter passes DDC. Continue.
- `No valid reply`: wait 3 seconds and try once more. If it fails again, or it
  reports a communication failure, the adapter blocks DDC. Stop here: PBP and
  input control will not work from this Mac with this adapter. Tell the owner the
  options are a USB-C to DisplayPort cable, or controlling the monitor only from
  the first Mac. Steps 6 and 7 still apply; skip step 5.

### 5. Confirm PBP control (ask before each command)

With the owner's yes for each one:

```sh
bin/lgpbp on      # PBP 50/50; this Mac's picture shrinks to half the panel
bin/lgpbp off     # back to full width
```

After each, wait about 6 seconds and check with `bin/lgpbp state`.

### 6. Start the app

```sh
open "LG PBP.app"
```

A split-rectangle icon appears in the menu bar. Launching sends nothing to the
monitor. The owner then:

- chooses **Enable Window Snapping…** and grants Accessibility access;
- optionally ticks **Launch at Login** (move the app to `/Applications` first).

Layouts and widget positions are stored per Mac in
`~/Library/Application Support/LG PBP/`; they are not shared between the two Macs.

### 7. Report

Tell the owner, plainly:

- whether the adapter passes DDC (step 4);
- whether PBP on/off worked from this Mac (step 5);
- which signature the build used, and whether Accessibility was granted;
- which input number this Mac's connection reads as, if the owner approved
  `bin/lgpbp input` (a single read of code `0x60`).

## Input switching

Half done. From the first Mac, switching **to HDMI 1** works. What is missing is the
way back to USB-C, and this Mac is the right place to find it, because the picture
is on this Mac when the command needs to be sent.

`bin/lgpbp input <name>` sends LG's input-switch code (`0xF4` on address `0x50`).
See `CLAUDE.md` for what may and may not be sent on that address.

Only do this after step 4 has shown that the adapter passes DDC, and ask the owner
before each command. Warn them that a successful switch moves the picture to the
first Mac, and that the way back is the monitor's joystick.

Done: with the HDMI 1 Mac alone on screen, `bin/lgpbp input usbc` (value `0xD2`)
moves the picture to the USB-C Mac. `0xD1` does nothing on this monitor. There is
nothing left to test here.

Record the result in the table in `CLAUDE.md`.
