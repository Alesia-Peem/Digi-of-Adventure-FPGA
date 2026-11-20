# CPE Escape Room × Obby - FPGA port (Nexys A7)

Verilog port of the Pygame game in `../demo_py/`. **Phase 1 = Stage 1 (Final Exam) complete + the three
shared features + the shared video/UI engine.** Stage 2 and 3 are the next phases (see `docs/STATUS.md`).

```
fpga/
  rtl/common/   shared modules: reset_sync tick_gen input_hub button_unit lfsr16 card_deck inventory
                heart_system sprite_anim seven_seg  (+ game_defs.vh)
  rtl/video/    vga_timing line_renderer rom_sync
  rtl/ui/       ui_composer (+ ui_map.vh, generated)
  rtl/stage1/   s1_core (game logic) s1_collision
  rtl/top/      cpe_escape_top (board top) demo_menu
  mem/          ROM contents (.mem) + preview/ PNGs           <- generated, already included
  tools/        asset_convert.py  ui_spec.py ui_screens.py ui_compile.py   (asset + screen compilers)
                cosim_s1.py frame_check.py verify_puzzles.py           (verification)
  tb/           tb_units.v tb_s1_cosim.v tb_frame.v
  constraints/  nexys_a7.xdc (pins from Digilent's master XDC)
  vivado/       create_project.tcl
  docs/         ARCHITECTURE.md  VERIFICATION.md  STATUS.md
  run_tests.sh  full regression
```

## Build the bitstream (Vivado 2020.x or newer, Windows/Linux)

```
cd fpga
vivado -mode batch -source vivado/create_project.tcl -tclargs 100t build
```
or in the GUI: *Tools → Run Tcl Script…* → `fpga/vivado/create_project.tcl`, then *Generate Bitstream*.
The project uses the `.mem` files in `fpga/mem/` (added as *Memory Initialization Files*).
Board: **Nexys A7-100T**. Connect a VGA monitor, program the board, press BTNC to close the help screen.

## Re-generate ROMs after changing art or screens

```
python3 fpga/tools/asset_convert.py     # assets/*.png|jpg -> fpga/mem/*.mem (+ previews)
python3 fpga/tools/ui_compile.py --preview   # ui_screens.py -> ui_prog/str/ptr.mem, ui_map.vh, previews
```
Requires Python 3 with Pillow + numpy (+ pygame for the co-simulation).

## Simulate (Icarus Verilog 12+)

```
cd fpga && ./run_tests.sh          # everything (~5 min incl. VGA frames)
cd fpga && ./run_tests.sh quick    # without the frame capture
```
Single test, e.g. the unit tests:
```
iverilog -g2005 -I rtl/common -I rtl/ui -o sim/build/tb_units.vvp rtl/common/*.v rtl/video/vga_timing.v tb/tb_units.v
vvp -n sim/build/tb_units.vvp
```
Waveforms: add `$dumpfile("x.vcd"); $dumpvars(0, tb_units);` to a testbench and open with GTKWave.

## Controls on the board

BTNU/D/L/R walk · BTNC tap = interact/confirm, hold 0.8 s = back · SW0-7 puzzle inputs · SW14 notebook ·
SW12 demo menu (BTNU/BTND choose, BTNC run: jump to checkpoints, give armor, set hearts/form = SW1..0, …)
