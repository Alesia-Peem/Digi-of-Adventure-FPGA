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
echo "CR TESTS: PASS"
