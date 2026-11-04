#!/usr/bin/env bash
# the cartridge image is rom/demo.hex (4096 bytes, one hex byte per line); replace it to run another cartridge.
# yosys (slang) -> nextpnr-himbaechel -> gowin_pack. usage: TOOLS=/path/oss-cad-suite ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
TOOLS=${TOOLS:?set TOOLS to the oss-cad-suite directory}
export PATH="$TOOLS/bin:$TOOLS/lib:$PATH"
TOP=atari_top; OUT=build/$TOP; mkdir -p "$OUT"
SRCS="rtl/board/gowin_prims.v rtl/board/pll_hdmi.v rtl/cpu6502c.sv rtl/tia.sv rtl/atari_sys.sv rtl/atari_video.sv rtl/top/uart_tx.sv rtl/top/atari_top.sv rtl/hdmi/*.sv"
SL="--compat vcs --allow-use-before-declare --relax-enum-conversions --allow-merging-ansi-ports --allow-dup-initial-drivers --ignore-assertions"
yosys -q -l "$OUT/yosys.log" -m slang -p "read_slang $SL --top $TOP -D SYNTHESIS ${DEFS:-} $SRCS; hierarchy -top $TOP; synth_gowin -top $TOP -family gw2a -json $OUT/synth.json; tee -o $OUT/stat.txt stat"
rm -f "$OUT/pnr.json"
for SEED in ${SEEDS:-1 42 7 21 3 5 9 11}; do
  if nextpnr-himbaechel -q -l "$OUT/nextpnr.log" --json "$OUT/synth.json" --write "$OUT/pnr.json" --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst=rtl/board/tangnano20k.cst --pre-pack rtl/board/place.py --sdc rtl/board/clocks.sdc --vopt ioreg_in_iob --timing-allow-fail --seed $SEED; then
    echo "placed with seed $SEED"
    if grep -q "clk_p.*PASS" "$OUT/nextpnr.log"; then break; fi
    echo "seed $SEED: pixel clock timing not met, trying the next seed"
  else echo "seed $SEED failed"; fi
done
[ -f "$OUT/pnr.json" ] || { echo "placement failed"; exit 1; }
gowin_pack -d GW2A-18C --mspi_as_gpio -o "$OUT/$TOP.fs" "$OUT/pnr.json"
ls -la "$OUT/$TOP.fs"; grep -E "Max frequency|LUT4|DFF|BSRAM" "$OUT/nextpnr.log" | tail -8
