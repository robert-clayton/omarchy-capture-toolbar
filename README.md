# Omarchy capture toolbar

A Snipping Tool style capture toolbar for [Omarchy](https://omarchy.org). Press Print and the focused monitor freezes and dims, with a small toolbar at the top. Drag a region, click a window, or click empty space to capture the whole monitor.

It is an Omarchy shell plugin (id `ziru.capture`). Saving, copying, the editor and screen recording all go through Omarchy's own capture commands, so captures behave the same as Omarchy's built-in screenshot and recording.

## What it does

- Screenshot or Record mode (keys `1` and `2`).
- Region, Window or Screen target (`R`, `W`, `F`). Region mode also accepts a click on a window, or on empty space for the whole monitor.
- A delay of 0, 3, 5 or 10 seconds (`D`). For screenshots the timer runs first and the toolbar comes back with a fresh freeze. For recordings the countdown runs after you select.
- Desktop audio, microphone and webcam toggles in Record mode (`A`, `M`, `C`).
- Copy text from the screen, read a QR code, or pick a color (`T`, `Q`, `P`).
- A Stop recording button while a recording runs (`S`).
- `Enter` captures what is highlighted. `Esc` closes the toolbar.
- It remembers your last choices in `~/.local/state/ziru-capture-toolbar.json`.

Screenshots are cropped from the frozen frame, saved to your screenshot folder (`OMARCHY_SCREENSHOT_DIR`, or your Pictures folder), copied to the clipboard, and announced with a notification that opens the editor (`OMARCHY_SCREENSHOT_EDITOR`, default `tensaku-edit`). Recordings run `omarchy-capture-screenrecording` on the area you chose.

## Install

```bash
omarchy plugin add https://github.com/robert-clayton/omarchy-capture-toolbar.git --enable
```

Then bind Print to it in `~/.config/hypr/bindings.lua`. This keeps Print as the stop key while a recording runs, and moves Omarchy's instant screenshot to Shift+Print:

```lua
hl.unbind("PRINT")
o.bind("PRINT", "Capture toolbar", "omarchy-capture-screenrecording --stop-recording || omarchy-shell shell toggle ziru.capture '{}'")
o.bind("SHIFT + PRINT", "Instant screenshot", "omarchy-capture-screenshot")
```

You can also open it from a script with `omarchy-shell shell toggle ziru.capture '{}'`. The payload accepts `"mode": "screenshot"` or `"mode": "record"`.

## How it works

| File | Job |
|---|---|
| `Toolbar.qml` | The overlay, the picker and the toolbar |
| `bin/grab` | Freezes the focused monitor with `grim` and prints the monitor and its windows from `hyprctl` as JSON |
| `bin/shot` | Crops the frozen frame with ImageMagick, then saves, copies and notifies like `omarchy-capture-screenshot` |
| `bin/shim/omarchy-capture-region` | Goes first on `PATH` when a recording starts, so Omarchy's recorder gets the toolbar's selection instead of opening its own picker |

It needs `grim`, `jq`, `magick` (ImageMagick) and `wl-copy`, which a standard Omarchy install includes.

## Status

This is a personal plugin, tested on Omarchy 4.0.6 with Hyprland, an NVIDIA GPU and two monitors at scale 1. Fractional scaling and rotated monitors are untested.
