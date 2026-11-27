#!/usr/bin/env bash
# run_tests_s3.sh - Stage 3 (Campus Run) tests. Needs Python 3 with pygame, Pillow, numpy and Icarus Verilog.
#   cd fpga && ./run_tests_s3.sh
set -e
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
mkdir -p sim/build
quiet() { grep -vE "pkg_resources|^pygame |Hello from the pygame"; }

echo "== 1. assets: grid, entities, tiles, sprites, memory files vs onlystage_3"
(cd "$ROOT" && python3 -I fpga/tools/cr_test_assets.py 2>&1) > sim/cr_test_assets.log || { quiet < sim/cr_test_assets.log; exit 1; }
grep -E "^ *tiles|^ *sprite|^ *player|^CR_TEST" sim/cr_test_assets.log

echo "== 2. integer model vs the original game.py, step by step"
(cd "$ROOT" && python3 -I fpga/tools/cr_test_model.py 2>&1) > sim/cr_test_model.log || { quiet < sim/cr_test_model.log; exit 1; }
grep -E "^CR_TEST|random|stage [123]," sim/cr_test_model.log

echo "== 3. scenario files for the RTL (game and model must agree while writing them)"
(cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py gen 2>&1) > sim/cr_gen.log || { quiet < sim/cr_gen.log; exit 1; }
grep "^cr " sim/cr_gen.log
IV="iverilog -g2005 -I rtl/stage3"

echo "== 4. RTL arithmetic unit cr_math.v (multiply, divide, square root) vs Python"
(cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py genmath)
$IV -o sim/build/cr_tb_math.vvp rtl/stage3/cr_math.v tb/cr_tb_math.v
vvp -n sim/build/cr_tb_math.vvp | tee sim/cr_tb_math.log | grep -E "CR_TB_MATH|FAIL"
grep -q "CR_TB_MATH: PASS" sim/cr_tb_math.log

echo "== 5. RTL player + collision (cr_core.v) vs the model, bit exact, every step"
(cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py genphys)
for steps in 1 2; do
  name=phys; [ $steps = 2 ] && name=phys2
  $IV -Pcr_tb_cosim.PHYS=1 -Pcr_tb_cosim.STEPS=$steps -o sim/build/cr_tb_cosim_p$steps.vvp \
    rtl/stage3/cr_math.v rtl/stage3/cr_core.v tb/cr_tb_cosim.v
  vvp -n sim/build/cr_tb_cosim_p$steps.vvp +STIM=sim/cr_${name}_stim.mem +OUT=sim/cr_${name}_rtl.txt | grep CR_TB
  (cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py cmp $name phys)
done
echo "== 6. RTL animals (patrol, follower, walk + water, fly, pop) and contacts vs the model, bit exact"
(cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py genanimals)
$IV -Pcr_tb_cosim.PHYS=2 -o sim/build/cr_tb_cosim_a.vvp rtl/stage3/cr_math.v rtl/stage3/cr_core.v tb/cr_tb_cosim.v
vvp -n sim/build/cr_tb_cosim_a.vvp +STIM=sim/cr_animals_stim.mem +OUT=sim/cr_animals_rtl.txt | grep CR_TB
(cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py cmp animals animals)
echo "== 7. RTL full game (reporter, skills, lifts, tea, doors, flow) vs the model, every scenario of section 3"
$IV -o sim/build/cr_tb_cosim_f.vvp rtl/stage3/cr_math.v rtl/stage3/cr_core.v tb/cr_tb_cosim.v
for s in plan1 plan2 plan3 careless skill interview pit lift timeout restart buttons retreat; do
  vvp -n sim/build/cr_tb_cosim_f.vvp +STIM=sim/cr_${s}_stim.mem +OUT=sim/cr_${s}_rtl.txt > sim/cr_${s}_tb.log
  grep -q "unknown registers: 0 steps" sim/cr_${s}_tb.log || { echo "unknown register values in $s"; exit 1; }
  grep -q "budget ok" sim/cr_${s}_tb.log || { echo "a step of $s is over 400 000 clocks"; exit 1; }
  (cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py cmp $s)
done

echo "== 7b. the same at 2 steps per tick (the board), plus skill pressed on death / refusal / clear ticks"
S2="deathskill skill buttons careless interview restart retreat plan2"
(cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py gen2 $S2)
$IV -Pcr_tb_cosim.STEPS=2 -o sim/build/cr_tb_cosim_f2.vvp rtl/stage3/cr_math.v rtl/stage3/cr_core.v tb/cr_tb_cosim.v
for s in $S2; do
  vvp -n sim/build/cr_tb_cosim_f2.vvp +STIM=sim/cr_${s}2_stim.mem +OUT=sim/cr_${s}2_rtl.txt > sim/cr_${s}2_tb.log
  grep -q "unknown registers: 0 steps" sim/cr_${s}2_tb.log || { echo "unknown register values in ${s}2"; exit 1; }
  grep -q "budget ok" sim/cr_${s}2_tb.log || { echo "a step of ${s}2 is over 400 000 clocks"; exit 1; }
  (cd "$ROOT" && python3 -I fpga/tools/cr_cosim.py cmp ${s}2)
done

echo "== 8. RTL button / command timing at 2 steps per tick"
$IV -o sim/build/cr_tb_ctrl.vvp rtl/stage3/cr_math.v rtl/stage3/cr_core.v tb/cr_tb_ctrl.v
vvp -n sim/build/cr_tb_ctrl.vvp | tee sim/cr_tb_ctrl.log | grep -E "CR_TB_CTRL|FAIL"
grep -q "CR_TB_CTRL: PASS" sim/cr_tb_ctrl.log
echo "CR TESTS: PASS"
