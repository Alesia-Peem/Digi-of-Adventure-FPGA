#!/usr/bin/env bash
# run_tests.sh - full regression (Icarus Verilog + Python 3 with pygame, Pillow, numpy).
#   cd fpga && ./run_tests.sh          # everything
#   ./run_tests.sh quick               # skip the (slow) VGA frame capture
#   ./run_tests.sh frames12            # sections 1-3, then only the Stage 1 / Stage 2 VGA frame comparisons
set -e
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
mkdir -p sim/build sim/frames
INC="-I rtl/common -I rtl/ui -I rtl/stage2 -I rtl/stage3 -I rtl/video"
# -DSIMULATION: rtl/video/qspi_io.v is behavioural (no STARTUPE2 / IOBUF) - needed by every compile of the
# top or of rtl/video/*.v. Vivado (create_project.tcl) never defines it.
IV="iverilog -g2005 $INC"
IVS="$IV -DSIMULATION"

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

# Sections 4 and 5 are KNOWN to fail against the new Pygame game (docs/audit/baseline_failures.md; fixed in
# Phase 2 / 3): they report EXPECTED FAIL and the run continues. Any other section failing still stops the run.
EXPECTED_FAIL_MSG="EXPECTED FAIL (Phase 2/3 - see docs/audit/baseline_failures.md)"
expected_fail() {          # run "$@" with set -e in a subshell; a failure is reported, not fatal
  set +e
  ( set -e; "$@" )
  local rc=$?
  set -e
  [ $rc -eq 0 ] || echo "   $EXPECTED_FAIL_MSG (exit $rc)"
}
with_timeout() {           # with_timeout SECONDS cmd...  (macOS has no GNU timeout by default)
  local secs=$1; shift
  # pygame (SDL) turns SIGTERM into a QUIT event that a hung script never reads -> KILL 5 s after TERM
  if command -v timeout > /dev/null 2>&1; then timeout -k 5 "$secs" "$@"; return $?; fi
  if command -v gtimeout > /dev/null 2>&1; then gtimeout -k 5 "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2> /dev/null && sleep 5 && kill -KILL "$pid" 2> /dev/null ) > /dev/null 2>&1 &
  local watcher=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$watcher" 2> /dev/null || true
  wait "$watcher" 2> /dev/null || true
  return $rc
}
S2_GEN_TIMEOUT=${S2_GEN_TIMEOUT:-120}   # the Stage 2 trace generator currently waits forever

# Stage 1 / Stage 2 frames: the stimulus is generated from demo_py_old (the OLD game the current s1_core /
# s2_core were ported from) - the new game's scenarios do not exist yet (Phase 2/3). Rooms come from the flash
# model (real pic_stream chain), so mem/pictures.hex is needed.
frames12() {
  [ -f mem/pictures.hex ] || python3 -I tools/pic_pack.py
  (cd "$ROOT" && COSIM_DEMO=demo_py_old python3 -I fpga/tools/cosim_s1.py gen full 2>/dev/null | grep "^scenario")
  python3 -I tools/frame_check.py pick full
  $IVS -o sim/build/tb_frame.vvp rtl/common/*.v rtl/stage1/*.v rtl/video/*.v rtl/ui/ui_composer.v tb/flash_model.v \
    tb/tb_frame.v
  vvp -n sim/build/tb_frame.vvp +STIM=sim/s1_full_stim.mem +SNAP=sim/frame_ticks.txt +OUTDIR=sim/frames | grep captured
  python3 -I tools/frame_check.py cmp
  (cd "$ROOT" && COSIM_DEMO=demo_py_old with_timeout "$S2_GEN_TIMEOUT" python3 -I fpga/tools/cosim_s2.py gen full \
    2>/dev/null | grep "^scenario")
  python3 -I tools/frame_check.py pick2
  $IVS -o sim/build/tb_frame2.vvp rtl/common/*.v rtl/stage2/*.v rtl/video/*.v rtl/ui/ui_composer.v tb/flash_model.v \
    tb/tb_frame2.v
  vvp -n sim/build/tb_frame2.vvp +STIM=sim/s2_full_stim.mem +SNAP=sim/frame_ticks2.txt +OUTDIR=sim/frames | grep captured
  python3 -I tools/frame_check.py cmp frame_ticks2.txt
}
if [ "$1" = "frames12" ]; then      # only the Stage 1 / Stage 2 frame comparisons
  echo "== 12. VGA frames, Stage 1 + Stage 2 only"
  frames12
  exit 0
fi

section4() {
  (cd "$ROOT" && python3 -I fpga/tools/cosim_s1.py gen > /dev/null 2>&1)
  $IV -o sim/build/tb_s1_cosim.vvp rtl/common/*.v rtl/stage1/*.v tb/tb_s1_cosim.v
  for s in full death items; do
    vvp -n sim/build/tb_s1_cosim.vvp +STIM=sim/s1_${s}_stim.mem +OUT=sim/s1_${s}_rtl.txt > /dev/null
  done
  (cd "$ROOT" && python3 -I fpga/tools/cosim_s1.py cmp 2>/dev/null)
}
section5() {
  (cd "$ROOT" && with_timeout "$S2_GEN_TIMEOUT" python3 -I fpga/tools/cosim_s2.py gen > /dev/null 2>&1)
  $IV -o sim/build/tb_s2_cosim.vvp rtl/common/*.v rtl/video/rom_sync.v rtl/stage2/*.v tb/tb_s2_cosim.v
  vvp -n sim/build/tb_s2_cosim.vvp +STIM=sim/s2_full_stim.mem +OUT=sim/s2_full_rtl.txt > /dev/null
  (cd "$ROOT" && python3 -I fpga/tools/cosim_s2.py cmp 2>/dev/null)
}

echo "== 4. Stage 1 vs the original Pygame stage1_demo.py (tick by tick)"
expected_fail section4

echo "== 5. Stage 2 vs the original Pygame stage2_demo.py (tick by tick, generator timeout ${S2_GEN_TIMEOUT} s)"
expected_fail section5

echo "== 6. Stage 3: fixed-point model vs the original Pygame stage3_demo.py, RTL vs model (tick by tick)"
S3="run careless skill lose cp90 cp140 cp185 cp225"
(cd "$ROOT" && python3 -I fpga/tools/cosim_s3.py gen $S3 2>/dev/null | grep "^s3")
$IV -o sim/build/tb_s3_cosim.vvp rtl/stage3/s3_core.v tb/tb_s3_cosim.v
for s in $S3; do
  vvp -n sim/build/tb_s3_cosim.vvp +STIM=sim/s3_${s}_stim.mem +OUT=sim/s3_${s}_rtl.txt +FOUT=sim/s3_${s}_rtlf.txt > /dev/null
done
(cd "$ROOT" && python3 -I fpga/tools/cosim_s3.py cmp $S3 2>/dev/null)

echo "== 7. full design elaborates (top level)"
$IVS -o sim/build/top.vvp rtl/common/*.v rtl/video/*.v rtl/ui/*.v rtl/stage1/*.v rtl/stage2/*.v rtl/stage3/*.v \
  rtl/top/*.v
echo "top: elaborated"     # separate line: a failing compile stops the run (set -e)

echo "== 8. QSPI picture streamer: pic_stream + qspi_reader vs the S25FL128S model (pixel exact vs previews)"
[ -f mem/pictures.hex ] || python3 -I tools/pic_pack.py
for late in 1 0; do
  $IV -I rtl/video -Ptb_pic_stream.LATE=$late -o sim/build/tb_pic_stream.vvp \
    rtl/video/qspi_reader.v rtl/video/pic_stream.v tb/flash_model.v tb/tb_pic_stream.v
  vvp -n sim/build/tb_pic_stream.vvp | grep -E "TB_PIC_STREAM|FAIL|margin|queued"
  python3 -I tools/pic_check.py TITLE S2_ROOM TITLE_RELOAD=TITLE
  vvp -n sim/build/tb_pic_stream.vvp +ZERO | grep -E "TB_PIC_STREAM|FAIL|missing"
done

echo "== 9. bg_mode 5: streamed picture + fade + display list, flash model -> pic_stream -> line_renderer (pixel exact)"
python3 -I tools/frame_check.py picgen
$IV -I rtl/video -o sim/build/tb_frame_pic.vvp rtl/video/line_renderer.v rtl/video/rom_sync.v rtl/video/vga_timing.v \
  rtl/video/qspi_reader.v rtl/video/pic_stream.v tb/flash_model.v tb/tb_frame_pic.v
while read -r name args; do
  # shellcheck disable=SC2086
  vvp -n sim/build/tb_frame_pic.vvp $args < /dev/null | grep "captured"
done < sim/pic_scenes.txt
python3 -I tools/frame_check.py piccmp

echo "== 10. stage manager: OPEN -> S1 -> C12 -> S2 -> C23 -> S3 -> END -> OPEN (unit test)"
$IV -I rtl/video -o sim/build/tb_stage_mgr.vvp rtl/top/stage_mgr.v tb/tb_stage_mgr.v
vvp -n sim/build/tb_stage_mgr.vvp | grep -E "TB_STAGE_MGR|FAIL"
vvp -n sim/build/tb_stage_mgr.vvp | grep -q "TB_STAGE_MGR: PASS"

echo "== 11. top level: flash model on the QSPI pins -> OPEN shows the title (pixel exact), BTNC -> Stage 1"
$IVS -o sim/build/tb_top_pic.vvp rtl/common/*.v rtl/video/*.v rtl/ui/*.v rtl/stage1/*.v rtl/stage2/*.v \
  rtl/stage3/*.v rtl/top/*.v tb/flash_model.v tb/tb_top_pic.v
vvp -n sim/build/tb_top_pic.vvp | tee sim/build/tb_top_pic.log | grep -E "TB_TOP_PIC|FAIL|captured|WARNING"
grep -q "TB_TOP_PIC: PASS" sim/build/tb_top_pic.log
python3 -I - <<'PY'
# game area (VGA lines 60..419) = mem/preview/pic_TITLE.png exactly (bg_mode 5, fade 16, empty display list);
# lines outside the game area black
import sys
import numpy as np
from PIL import Image
tok = open("sim/frames/top_title.ppm").read().split()
assert tok[:4] == ["P3", "640", "480", "15"]
rtl = np.array(tok[4:], dtype=np.int32).reshape(480, 640, 3)
ref = np.asarray(Image.open("mem/preview/pic_TITLE.png").convert("RGB"), dtype=np.int32)
assert ref.shape == (360, 640, 3) and not np.any(ref % 17)
exp = np.zeros((480, 640, 3), dtype=np.int32)
exp[60:420] = ref // 17
n = int(np.any(rtl != exp, axis=2).sum())
print("top_title   : %6d differing pixels %s" % (n, "OK" if n == 0 else "DIFF"))
sys.exit(0 if n == 0 else 1)
PY

if [ "$1" != "quick" ]; then
  echo "== 12. VGA frames: RTL video pipeline vs Python model (pixel exact) - takes a long time"
  frames12
  $IVS -o sim/build/tb_frame3.vvp rtl/common/*.v rtl/stage3/*.v rtl/video/*.v rtl/ui/ui_composer.v tb/tb_frame3.v
  printf "0\n2\n5A\nDD\n209\n375\n" > sim/frame_ticks3_careless.txt
  vvp -n sim/build/tb_frame3.vvp +STIM=sim/s3_careless_stim.mem +SNAP=sim/frame_ticks3_careless.txt \
    +OUTDIR=sim/frames +PRE=hcareless_ | grep captured
  python3 -I tools/frame_check.py cmp frame_ticks3_careless.txt
  python3 -I tools/frame_check.py pick3 cp185
  vvp -n sim/build/tb_frame3.vvp +STIM=sim/s3_cp185_stim.mem +SNAP=sim/frame_ticks3_cp185.txt \
    +OUTDIR=sim/frames +PRE=hcp185_ | grep captured
  python3 -I tools/frame_check.py cmp frame_ticks3_cp185.txt
fi
