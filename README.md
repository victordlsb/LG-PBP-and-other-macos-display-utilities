# LG PBP and other macOS display utilities

A small macOS menu bar app, called **LG PBP**, that started as a replacement for
LG Switch on an LG UltraFine 40U990A and grew into a general desk-setup helper.
Despite the name, only the Picture-by-Picture control is specific to that monitor.

It does four things:

| Feature | Works with |
|---|---|
| Switch **Picture-by-Picture** on and off from the menu bar or a hotkey | **LG UltraFine 40U990A only** |
| **Snap windows into custom zones** by holding ⌘ while dragging | Any display |
| Connect an **iPad as an extended display** with one click or a hotkey | Any Mac + iPad that support Sidecar |
| **Save and restore desktop widget positions** per screen setup | Any display |

No dependencies, no background polling. Plain Swift and AppKit, built with `swiftc`.

## Requirements

- Apple Silicon Mac, macOS 13 or later (developed on macOS 26)
- Xcode command line tools (`xcode-select --install`)
- For PBP: an LG UltraFine 40U990A connected over Thunderbolt / USB-C

## Build and run

```sh
./build.sh
open "LG PBP.app"
```

`build.sh` produces the menu bar app (`LG PBP.app`) and a command-line tool (`bin/lgpbp`).

If you have an Apple Development certificate in your keychain, the build signs the app
with it. That matters: macOS ties the Accessibility permission to the app's signature,
and an ad-hoc signature changes on every build, which silently invalidates the
permission. If window snapping stops working after a rebuild, run
`tccutil reset Accessibility local.lgpbp.menubar` and grant access again.

## Features

### Picture-by-Picture (LG UltraFine 40U990A)

Menu items for **PBP 50/50**, **PBP 75/25** and **Off**, plus **⌃⌥⌘P** to toggle
between off and the last mode used. Off also exits PIP.

The app only talks to the monitor when you pick an item or press the hotkey. The
state shown in the menu is inferred from the shape of the picture the Mac is sending,
so displaying it sends nothing.

The same commands are available in the terminal:

```sh
bin/lgpbp state        # inferred from the Mac's picture; sends nothing to the monitor
bin/lgpbp status       # asks the monitor; also detects PIP
bin/lgpbp on           # PBP 50/50
bin/lgpbp on 75        # PBP 75/25
bin/lgpbp off
bin/lgpbp input        # which input the monitor is showing
bin/lgpbp input hdmi1  # switch input: usbc, dp, hdmi1, hdmi2 (experimental, see below)
```

Input switching uses the standard input-source code (`0x60`). Reading it works; the
monitor reports its USB-C / Thunderbolt input as 15 (`0x0F`). Switching is not yet
confirmed on this model, and is not in the menu bar app.

### Window layouts (any display)

Hold **⌘** while dragging a window by its title bar. The zones of the active layout
appear on the screen under the pointer; release over a zone to place the window
there. Release ⌘ first to cancel.

- Each screen has its own active layout, chosen from the menu.
- **Edit Layouts…** opens a full-screen editor: drag to draw a zone, drag a zone to
  move it, drag an edge to resize, Delete to remove. Zones snap to a grid that gives
  clean halves, thirds, quarters and fifths; hold ⌥ for free placement.
- Zones are stored as percentages, so a layout fits any screen size.
- A display remembers a separate layout per shape, so the LG switches layout
  automatically between full width, PBP 75/25 and PBP 50/50.

Needs Accessibility access (menu: **Enable Window Snapping…**).
Layouts are saved in `~/Library/Application Support/LG PBP/layouts.json`.

### iPad as a display (Sidecar)

A menu item per iPad in reach, and **⌃⌥⌘I** for the first one. Click to connect
the iPad as an extended display, click again to disconnect.

### Desktop widget positions (any display)

- **Save Widget Positions for This Screen Setup** stores the current arrangement for
  the current combination of screens.
- **Restore Widget Positions** applies it again.
- **Restore Automatically When Screens Change** applies the saved arrangement a few
  seconds after the screen setup changes.

Restoring restarts Notification Center, so widgets disappear for a second or two.
If widgets were added or removed since saving, the app refuses to restore and asks
you to save again.

## How PBP control works

The monitor is controlled over DDC/CI. PBP is VCP code `0xD7`, set with a standard
"Set VCP" packet on the standard host address `0x51`. The monitor does not advertise
this code in its capabilities string; it was found by looking at what LG's own
macOS software sends, and then confirmed one value at a time.

Values of `0xD7` on the 40U990A:

| Value | Effect |
|---|---|
| 0 | Reported while PIP is active. Ignored as a command. |
| 1 | Off (also exits PIP) |
| 2 | Ignored |
| 3 | PBP 75/25 (3840 + 1280 columns) |
| 4 | Ignored |
| 5 | PBP 50/50 (2560 + 2560 columns) |

Two quirks of this monitor on Apple Silicon:

- A "Get VCP" request must be written twice before the monitor answers.
- For a few seconds after switching modes the monitor gives no valid reply.

No command for switching PIP **on**, PIP size or position, or swapping the two
inputs was found.

## Using it with another monitor

Window layouts, the iPad display and widget positions do not depend on the monitor.

PBP control does. The app checks the display's EDID vendor and model and refuses to
send anything to a display that is not the 40U990A, because `0xD7` means something
else on other monitors (in the standard it is "auxiliary power output"). It also
refuses when more than one external display is connected, since it cannot tell
which one is the LG.

Other LG models are reported to use the same code with some of the same values, so
adapting it may be as simple as changing `vendor` and `model` in
`Sources/LGMonitor.swift`. That is untested and at your own risk; read the next
section first.

## Warning: do not scan DDC codes on this monitor

While developing this, a probe that swept "Get VCP" across all 256 codes, first on
the standard address and then on LG's alternate address `0x50`, changed the
monitor's colour and backlight settings. The Picture Mode menu could not undo it;
only a full factory reset (Settings → General → Reset to Initial Settings) did.
The alternate address is an LG service channel and is the likely culprit, though
that was never proven.

This code therefore sends exactly one VCP code on the standard address and nothing
else. If you extend it, add codes one at a time and save a record of the values
before you change anything.

## Caveats

- **Private macOS interfaces.** DDC on Apple Silicon (`IOAVService`), Sidecar
  (`SidecarCore`) and widget positions (Notification Center's preferences) are all
  undocumented. A macOS update can break any of them. The Sidecar code checks that
  each call exists before using it.
- **PIP shows as "Off"** in the menu, because the Mac keeps the full panel in PIP.
  `bin/lgpbp status` detects it.
- **PBP runs at 60 Hz** on this monitor.

## Source layout

| File | Purpose |
|---|---|
| `Sources/LGMonitor.swift` | The only code that talks to the monitor |
| `Sources/Snap.swift` | ⌘-drag detection, zone overlay, window placement |
| `Sources/Layouts.swift` | Layout model and storage |
| `Sources/LayoutEditor.swift` | The layout editor |
| `Sources/Sidecar.swift` | iPad as a display |
| `Sources/WidgetLayouts.swift` | Widget position save and restore |
| `Sources/app/main.swift` | Menu bar app |
| `Sources/cli/main.swift` | Command-line tool |

## References

- [ddcutil wiki: Switching input source on LG monitors](https://github.com/rockowitz/ddcutil/wiki/Switching-input-source-on-LG-monitors)
- [m1ddc](https://github.com/waydabber/m1ddc), for DDC over `IOAVService` on Apple Silicon

## License

MIT. See [LICENSE](LICENSE).

Not affiliated with or endorsed by LG or Apple.
