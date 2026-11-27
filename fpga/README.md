# CPE Escape Room × Obby - FPGA port (Nexys A7)

Verilog port of the Pygame game in `../demo_py/`. **The port is not finished**: Stage 1 and 2 still follow
the older game in `../demo_py_old/`, Stage 3 is an older design, and title / cutscenes / ending are single
placeholder pictures. Read `docs/STATUS.md` ("Phase 0 status") first. Nothing has been run in Vivado or on
the board yet.

```
fpga/
  rtl/common/   shared modules: reset_sync tick_gen input_hub button_unit lfsr16 card_deck inventory
                heart_system sprite_anim seven_seg  (+ game_defs.vh)
  rtl/video/    vga_timing line_renderer rom_sync pic_stream qspi_reader qspi_io (+ pic_map.vh, generated)
  rtl/ui/       ui_composer (+ ui_map.vh, generated)
  rtl/stage1/   s1_core (game logic) s1_collision
  rtl/stage2/   s2_core (+ s2_walk, s2_circuit)
  rtl/stage3/   s3_core
  rtl/top/      cpe_escape_top (board top) stage_mgr demo_menu
  mem/          ROM contents (.mem), pictures.bin (goes into the flash) + preview/ PNGs  <- generated, included
  tools/        asset_convert.py  ui_spec.py ui_screens.py ui_compile.py   (asset + screen compilers)
                cosim_s1.py frame_check.py verify_puzzles.py           (verification)
  tb/           testbenches + flash_model.v (simulated QSPI flash)
  constraints/  nexys_a7.xdc (pins from Digilent's master XDC)
  vivado/       create_project.tcl report_baseline.tcl make_flash.tcl
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
Board: **Nexys A7-100T**. The big pictures are **not** inside the bitstream: they must be written into the
board's flash chip once (next section).

## Put the game on the board (bitstream + pictures in the QSPI flash)

These steps have **not been tried yet** (no Vivado on the development Mac, no board test). If a menu name
differs in your Vivado version, or a step fails, write down the exact message.

The board has a 16 MiB flash chip that keeps its contents without power. We put two things in it: the
bitstream at address `0x000000` (the FPGA loads it at power-up) and `mem/pictures.bin` at `0x400000` (the
game reads pictures from there while it runs).

1. **Build the bitstream** (above). It ends up in
   `vivado/cpe_escape/cpe_escape.runs/impl_1/cpe_escape_top.bit`. Check that the file exists and that Vivado reported
   no errors.
2. **Make the flash image** (run from `fpga/`):
   ```
   vivado -mode batch -source vivado/make_flash.tcl
   ```
   This writes `vivado/flash/cpe_escape.mcs` (bitstream + pictures in one file).
3. **Check which flash chip your board has.** Digilent's Nexys A7 reference manual says Spansion
   **S25FL128S**, but boards can differ between revisions: read the marking on the chip (or the manual for
   your revision) before choosing the memory part in step 5.
4. Connect the board's USB programming port (labelled PROG) to the PC, connect a VGA monitor, power on.
5. In Vivado: *Open Hardware Manager* -> *Open target* -> *Auto Connect*. Right-click the `xc7a100t` device ->
   *Add Configuration Memory Device*, search for `s25fl128s` and pick the part that matches your chip (the
   project plan expects `s25fl128sxxxxxx0-spi-x1_x2_x4`).
6. When asked to program it (or right-click the memory device -> *Program Configuration Memory Device*):
   choose `vivado/flash/cpe_escape.mcs`, keep *Erase*, *Program* and *Verify* ticked, OK. It can take a few
   minutes, mostly erasing.
7. **Boot from flash:** switch off, set the programming-mode jumper **JP1** to the SPI-flash (Quad-SPI)
   position - see Figure 2.1 "Configuration Options" in the Nexys A7 reference manual for which pins - then
   switch on (or press the PROG button). Booting takes a few seconds (estimate); the DONE LED lights when the
   FPGA is configured.
8. **What you should see:** the game's **title picture** (640x360, black bars above and below). Press BTNC to
   go to Stage 1
   (BTNC again closes its help screen).

After that you can try a new Verilog build quickly over JTAG (*Program Device* with the `.bit`): the
pictures stay in the flash. Redo steps 1, 2, 5 and 6 when `pictures.bin` changes, because picture offsets and sizes are compiled into the bitstream through `pic_map.vh`, so the bitstream must be rebuilt. A design loaded only over JTAG is lost at power-off; to keep a Verilog change after power-off, redo steps 1, 2, 5 and 6.

### If something is wrong

| What you see | What it means | What to check |
|---|---|---|
| **Diagonal magenta/black stripes** where a picture should be (title, or behind the characters in Stage 1/2), **RGB LED LD16 red** | The FPGA runs, but it did not read the marker `CPEP` + the expected picture count at flash `0x400000` (`missing` in `pic_stream.v`) | Was the `.mcs` (not only the `.bit`) programmed, with Verify passing? Was the `.mcs` made from the same build (picture count)? Is the flash's QUAD bit set (below)? Otherwise it may be read timing (`docs/STATUS.md`, not verified). The check is repeated on every picture change (next screen) and on CPU RESET |
| DONE LED stays off after power-on | The FPGA did not configure from flash | JP1 position, memory part chosen, programming/verify messages, QUAD bit |
| Monitor says "no signal" although the DONE LED is on | Not a flash problem | VGA cable, monitor input |
| A picture appears but with wrong pixels | The flash is read, but unreliably | Read timing; report it |

**QUAD bit.** The game and the boot both use "Quad Output Read" (command `0x6B`), which only works when the
non-volatile QUAD bit in the flash chip is 1. Vivado is expected to set it when it programs an x4 image, but
we have **not verified** that. If you see the symptoms above although programming verified, read the flash's
configuration register (CR1, bit 1) with a flash tool or ask for help.
A lit DONE LED after booting from flash is **not** taken as proof that the QUAD bit is set: that would need
the FPGA's x4 boot to read with the same command (`0x6B`) and to fail, rather than fall back, when the bit is
0, and we could not confirm either from the Xilinx configuration guide (UG470) here. The game's own check
is LD16 red / the stripes above.

## Baseline run for the porting team

Synthesis-only utilisation and timing baseline (needs the project from `create_project.tcl`; run from `fpga/`):

```
cd fpga
vivado -mode batch -source vivado/create_project.tcl -tclargs 100t
vivado -mode batch -source vivado/report_baseline.tcl
```
The numbers are **synthesis-stage** only: BRAM use can still change after implementation, and the timing is
only an indication (not the final result). The first command re-creates the project (`-force`), which removes
any bitstream you built before, so build again afterwards. If synthesis fails, read the log in the synth_1
run directory: `vivado/cpe_escape/cpe_escape.runs/synth_1/runme.log`.
The script fails loudly if `synth_1` does not complete. It writes `fpga/docs/audit/util_baseline.txt`
(hierarchical, per-instance RAMB36/RAMB18) and `fpga/docs/audit/timing_baseline.txt`. If you ran it on another
machine, copy those two files into `fpga/docs/audit/` and replace the memory-budget estimates with the real numbers.

## Re-generate ROMs after changing art or screens

```
python3 fpga/tools/asset_convert.py     # assets/*.png|jpg -> fpga/mem/*.mem (+ previews)
python3 fpga/tools/ui_compile.py --preview   # ui_screens.py -> ui_prog/str/ptr.mem, ui_map.vh, previews
python3 fpga/tools/pic_pack.py     # pictures (list: tools/pic_list.py) -> mem/pictures.bin/.hex, pic_map.vh
```
After `pic_pack.py`, rebuild the bitstream and the flash image (the picture offsets and sizes are in both).
Requires Python 3 with Pillow + numpy (+ pygame for the co-simulation).

## Simulate (Icarus Verilog 12+)

```
cd fpga && ./run_tests.sh          # everything, incl. the slow VGA frame captures
cd fpga && ./run_tests.sh quick    # without the frame capture
cd fpga && ./run_tests.sh frames12 # sections 1-3 + Stage 1/2 VGA frames
```
Sections 4 and 5 report `EXPECTED FAIL` for now (see `docs/audit/baseline_failures.md`).
Single test, e.g. the unit tests:
```
iverilog -g2005 -I rtl/common -I rtl/ui -o sim/build/tb_units.vvp rtl/common/*.v rtl/video/vga_timing.v tb/tb_units.v
vvp -n sim/build/tb_units.vvp
```
Waveforms: add `$dumpfile("x.vcd"); $dumpvars(0, tb_units);` to a testbench and open with GTKWave.

## Controls on the board

Title / cutscene / ending pictures: BTNC tap = next. In the stages: BTNU/D/L/R walk · BTNC tap = interact/confirm, hold 0.8 s = back · SW0-7 puzzle inputs · SW14 notebook ·
SW12 demo menu (BTNU/BTND choose, BTNC run: jump to checkpoints, give armor, set hearts/form = SW1..0, …)
