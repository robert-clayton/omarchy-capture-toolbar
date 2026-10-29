#!/bin/bash
# Self-check for the bin/ helpers. Stubs clipboard and notifications, so it is
# safe to run on a live desktop. The grab checks need a running Hyprland.
set -u
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ziru-capture-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub"
printf '#!/bin/sh\nexit 0\n' >"$tmp/stub/omarchy-notification-send"
printf '#!/bin/sh\ncat >/dev/null\n' >"$tmp/stub/wl-copy"
chmod +x "$tmp/stub/"*
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# shot crops in physical pixels and deletes its frame
magick -size 400x300 xc:red -fill blue -draw 'rectangle 100,50 199,149' "$tmp/frame.png"
out=$(OMARCHY_SCREENSHOT_DIR="$tmp" PATH="$tmp/stub:$PATH" bin/shot "$tmp/frame.png" 100 50 100 100)
check "shot writes the cropped size" '[[ $(magick identify -format %wx%h "$out") == 100x100 ]]'
check "shot crops the right pixels" '[[ $(magick "$out" -format "%[pixel:p{50,50}]" info:) == "srgb(0,0,255)" ]]'
check "shot deletes its frame" '[[ ! -e $tmp/frame.png ]]'

# the shim hands the toolbar's selection to Omarchy's recorder unchanged
check "shim echoes a region" '[[ $(ZIRU_CAPTURE_SELECTION="10,20 300x200" bin/shim/omarchy-capture-region smart --match-monitor) == "10,20 300x200" ]]'
check "shim echoes a monitor" '[[ $(ZIRU_CAPTURE_SELECTION="monitor:DP-4" bin/shim/omarchy-capture-region) == "monitor:DP-4" ]]'
check "shim fails without a selection" '! ZIRU_CAPTURE_SELECTION= bin/shim/omarchy-capture-region'

if hyprctl version &>/dev/null; then
  before=$(hyprctl getoption cursor:no_hardware_cursors -j | jq .int)
  check "grab writes a frame and JSON" 'bin/grab "$tmp/ziru-capture-frame-1.png" | jq -e .monitor.name >/dev/null && [[ -s $tmp/ziru-capture-frame-1.png ]]'
  printf '#!/bin/sh\nexit 1\n' >"$tmp/stub/grim"; chmod +x "$tmp/stub/grim"
  check "grab fails when grim fails" '! PATH="$tmp/stub:$PATH" bin/grab "$tmp/ziru-capture-frame-2.png" >/dev/null && [[ ! -e $tmp/ziru-capture-frame-2.png ]]'
  check "grab restores the cursor setting" '[[ $(hyprctl getoption cursor:no_hardware_cursors -j | jq .int) == "$before" ]]'
else
  echo "skip grab checks (no Hyprland)"
fi

((fails == 0)) && echo "all checks passed" || { echo "$fails failed"; exit 1; }
