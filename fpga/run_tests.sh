#!/usr/bin/env bash
# run_tests.sh - full regression (Icarus Verilog + Python 3 with pygame, Pillow, numpy).
#   cd fpga && ./run_tests.sh          # everything
#   ./run_tests.sh quick               # skip the (slow) VGA frame capture
set -e
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
mkdir -p sim/build sim/frames
INC="-I rtl/common -I rtl/ui -I rtl/stage2 -I rtl/stage3"
IV="iverilog -g2005 $INC"

echo "== 1. assets + UI program"
python3 -I tools/asset_convert.py > /dev/null
python3 -I tools/stage2_assets.py 2>/dev/null | grep "stage 2"
python3 -I tools/stage3_assets.py 2>/dev/null | grep "stage 3"
python3 -I tools/ui_compile.py

echo "== 2. puzzle mathematics"
python3 -I tools/verify_puzzles.py | tail -1

echo "== 3. unit tests of the shared modules"
$IV -o sim/build/tb_units.vvp rtl/common/*.v rtl/video/vga_timing.v tb/tb_units.v
vvp -n sim/build/tb_units.vvp | grep TB_UNITS

echo "== 4. Stage 1 vs the original Pygame stage1_demo.py (tick by tick)"
(cd "$ROOT" && python3 -I fpga/tools/cosim_s1.py gen > /dev/null 2>&1)
$IV -o sim/build/tb_s1_cosim.vvp rtl/common/*.v rtl/stage1/*.v tb/tb_s1_cosim.v
for s in full death items; do
  vvp -n sim/build/tb_s1_cosim.vvp +STIM=sim/s1_${s}_stim.mem +OUT=sim/s1_${s}_rtl.txt > /dev/null
done
(cd "$ROOT" && python3 -I fpga/tools/cosim_s1.py cmp 2>/dev/null)

echo "== 5. Stage 2 vs the original Pygame stage2_demo.py (tick by tick)"
(cd "$ROOT" && python3 -I fpga/tools/cosim_s2.py gen > /dev/null 2>&1)
$IV -o sim/build/tb_s2_cosim.vvp rtl/common/*.v rtl/video/rom_sync.v rtl/stage2/*.v tb/tb_s2_cosim.v
vvp -n sim/build/tb_s2_cosim.vvp +STIM=sim/s2_full_stim.mem +OUT=sim/s2_full_rtl.txt > /dev/null
(cd "$ROOT" && python3 -I fpga/tools/cosim_s2.py cmp 2>/dev/null)

echo "== 6. Stage 3: fixed-point model vs the original Pygame stage3_demo.py, RTL vs model (tick by tick)"
S3="run careless skill lose cp90 cp140 cp185 cp225"
(cd "$ROOT" && python3 -I fpga/tools/cosim_s3.py gen $S3 2>/dev/null | grep "^s3")
$IV -o sim/build/tb_s3_cosim.vvp rtl/stage3/s3_core.v tb/tb_s3_cosim.v
for s in $S3; do
  vvp -n sim/build/tb_s3_cosim.vvp +STIM=sim/s3_${s}_stim.mem +OUT=sim/s3_${s}_rtl.txt +FOUT=sim/s3_${s}_rtlf.txt > /dev/null
done
(cd "$ROOT" && python3 -I fpga/tools/cosim_s3.py cmp $S3 2>/dev/null)

echo "== 7. full design elaborates (top level)"
$IV -o sim/build/top.vvp rtl/common/*.v rtl/video/*.v rtl/ui/*.v rtl/stage1/*.v rtl/stage2/*.v rtl/stage3/*.v \
  rtl/top/*.v && echo "top: elaborated"

echo "== 8. QSPI picture streamer: pic_stream + qspi_reader vs the S25FL128S model (pixel exact vs previews)"
[ -f mem/pictures.hex ] || python3 -I tools/pic_pack.py
for late in 1 0; do
  $IV -I rtl/video -Ptb_pic_stream.LATE=$late -o sim/build/tb_pic_stream.vvp \
    rtl/video/qspi_reader.v rtl/video/pic_stream.v tb/flash_model.v tb/tb_pic_stream.v
  vvp -n sim/build/tb_pic_stream.vvp | grep -E "TB_PIC_STREAM|FAIL|margin|queued"
  python3 -I tools/pic_check.py TITLE S2_ROOM TITLE_RELOAD=TITLE
  vvp -n sim/build/tb_pic_stream.vvp +ZERO | grep -E "TB_PIC_STREAM|FAIL|missing"
done

if [ "$1" != "quick" ]; then
  echo "== 9. VGA frames: RTL video pipeline vs Python model (pixel exact) - takes a long time"
  python3 -I tools/frame_check.py pick full
  $IV -o sim/build/tb_frame.vvp rtl/common/*.v rtl/stage1/*.v rtl/video/*.v rtl/ui/ui_composer.v tb/tb_frame.v
  vvp -n sim/build/tb_frame.vvp +STIM=sim/s1_full_stim.mem +SNAP=sim/frame_ticks.txt +OUTDIR=sim/frames | grep captured
  python3 -I tools/frame_check.py cmp
  python3 -I tools/frame_check.py pick2
  $IV -o sim/build/tb_frame2.vvp rtl/common/*.v rtl/stage2/*.v rtl/video/*.v rtl/ui/ui_composer.v tb/tb_frame2.v
  vvp -n sim/build/tb_frame2.vvp +STIM=sim/s2_full_stim.mem +SNAP=sim/frame_ticks2.txt +OUTDIR=sim/frames | grep captured
  python3 -I tools/frame_check.py cmp frame_ticks2.txt
  $IV -o sim/build/tb_frame3.vvp rtl/common/*.v rtl/stage3/*.v rtl/video/*.v rtl/ui/ui_composer.v tb/tb_frame3.v
  printf "0\n2\n5A\nDD\n209\n375\n" > sim/frame_ticks3_careless.txt
  vvp -n sim/build/tb_frame3.vvp +STIM=sim/s3_careless_stim.mem +SNAP=sim/frame_ticks3_careless.txt \
    +OUTDIR=sim/frames +PRE=hcareless_ | grep captured
  python3 -I tools/frame_check.py cmp frame_ticks3_careless.txt
  python3 -I tools/frame_check.py pick3 cp185
  vvp -n sim/build/tb_frame3.vvp +STIM=sim/s3_cp185_stim.mem +SNAP=sim/frame_ticks3_cp185.txt \
    +OUTDIR=sim/frames +PRE=hcp185_ | grep captured
  python3 -I tools/frame_check.py cmp frame_ticks3_cp185.txt
fi
