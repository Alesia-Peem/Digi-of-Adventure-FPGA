# Project status, audit and decisions

**What is DONE is listed with how it was verified. Nothing here claims synthesis, timing or hardware
results - Vivado has not been run yet (no Vivado on the development Mac).**

## Phase 0 status (2026-11-27)

Phase 0 = import the new game, move the big pictures to the QSPI flash, add the screen sequence. Sections 1-4
below were written on 2026-11-20 about the **older** game (now `demo_py_old/`); where they differ, this
section is right.

### Works and tested in simulation (Icarus Verilog only)

* Puzzle maths (`tools/verify_puzzles.py`).
* Shared modules (`tb/tb_units.v`).
* Flash streamer `qspi_reader` + `pic_stream` against a behavioural flash model, including the "flash not
  programmed" case (`tb/tb_pic_stream.v`).
* Full-screen pictures from the flash (`bg_mode 5`, fade, display list on top), pixel exact
  (`tb/tb_frame_pic.v`); the title picture through the whole top level (`tb/tb_top_pic.v`).
* Screen sequence OPEN -> S1 -> C12 -> S2 -> C23 -> S3 -> END -> OPEN (`tb/tb_stage_mgr.v`).
* Stage 1 / Stage 2 rooms read from the flash: whole VGA frames pixel exact (`./run_tests.sh frames12`, run
  during Task 7; the test inputs come from `demo_py_old/`).
* Stage 3 (old design): RTL bit-exact with the fixed-point model, model within 2 mm of `demo_py_old`.

`./run_tests.sh quick` passed on 2026-11-27 (sections 4 and 5 reported the expected failures).

### Not done

* Stage 1 and Stage 2 still follow the **old** game. Their co-simulations against the new game
  (`run_tests.sh` sections 4 and 5) are expected failures (`audit/baseline_failures.md`).
* Stage 3 is the old design; **Campus Run is not ported**.
* Title, cutscenes and ending are **single placeholder pictures** (no animation, no other slides).

### Not verified

* No synthesis, no implementation, no timing result, no bitstream.
* No board result: flash programming, booting from flash, the `STARTUPE2` / `IOBUF` flash pins and the read
  timing are untested. `make_flash.tcl` has only been run with a stand-in for `write_cfgmem` under `tclsh`.
* **Open board risk - flash QUAD bit:** the `0x6B` read needs the flash's non-volatile QUAD bit. Vivado is
  expected to set it when programming an x4 image (Trenz Electronic wiki; a web search summary also mentions a
  bug about it in Vivado 2014.1/2014.2, AMD answer 61067, page not read), but this is not confirmed for our tool version or board. Symptom if the game
  cannot read the flash: **diagonal magenta/black stripes** (`missing`). Since the x4 boot uses quad reads
  too, a missing QUAD bit may instead show as "DONE LED stays off" (our inference).
* **Open board risk - read timing:** `pic_stream` samples with `LATE_SAMPLE = 1` and 8 dummy clocks (flash
  default latency code assumed). The XDC has no timing constraints for these pins.
* BRAM about 49 of 135 RAMB36 is an **estimate**.
* The full (non-quick) `./run_tests.sh` has not been run since Task 5. In particular the Stage 3 VGA frame
  comparison has not been repeated after the later renderer changes.

### Planned deviation from Pygame

* **Crossfades become fades from black**: the streamer shows one picture at a time, so two pictures cannot be
  blended. Not implemented yet: the renderer has a `fade` input, the top level holds it at full brightness
  until Phase 5.

## 1. Scope of the 2026-11-20 port (older game)

| Part | Status |
|---|---|
| Stage 1 (Final Exam): all gameplay of `stage1_demo.py` | **ported**, simulated, matches Pygame tick by tick |
| FEATURE 1 movement + collision + camera + walk animation | ported (Stage 1 geometry), shared modules `sprite_anim`, `input_hub` |
| FEATURE 2 character forms 1-4 (+ generated art for the secret form) | ported: form register, sprite selection, Stage-1 effects (speed ×1.2, +30 interaction range) |
| FEATURE 3 LFSR, cards (3 rounds), inventory, item effects, hearts | ported, shared modules |
| VGA engine (display list + line buffers), UI VM, fonts, asset ROMs | done, shared by all stages |
| Board top, XDC, Vivado script, on-board demo menu (= demo_hub) | done; stage manager (now OPEN → S1 → C12 → S2 → C23 → S3 → END, `stage_mgr.v`) |
| Stage 2 (Internship): all gameplay of `stage2_demo.py` | **ported**, simulated, matches Pygame tick by tick |
| Stage 3 (Graduation obby): all gameplay and screens of `stage3_demo.py` | **ported**, simulated: model = Pygame (≤ 2 mm, same events), RTL = model bit-exact (state + every screen field) |

## 2. Decisions taken with you (2026-11-20)

1. Round 1 yellow card = **Speed Boost** (stage1_demo had `HINT_HARD` twice; stage2_demo already had
   `BOOST`). Fixed in `demo_py/stage1_demo.py` too.
2. Projector clue 2 "Facebook, Canva, X" → Correct Pos **0** (was 1, which made E-C-P the only
   solution instead of C-P-E). Fixed in `demo_py/stage1_demo.py` too; uniqueness proven by
   `tools/verify_puzzles.py`.

## 3. Audit of the existing files (`rtl/`, `tb/`, `tools/`, `assets/*.mem`)

| File | Finding | Action |
|---|---|---|
| `rtl/stage1/stage1_controller.v`, `vga_renderer.v` | empty (0 bytes) | replaced by `fpga/rtl/stage1/s1_core.v`, `fpga/rtl/video/*` |
| `rtl/common/button_unit.sv`, `reset_sync.sv`, `tick_gen.sv`, `lfsr16.sv` | correct, synthesizable | converted to Verilog-2001 (logic kept); lfsr gets a `load` for testing |
| `input_hub.sv` | correct, but SV-only hierarchical reference `g_btn[4].tap_i`; events not tied to game ticks | rewritten: ports instead of hierarchy, per-tick event latching |
| `card_deck.sv` | shuffle/selection logic correct; it sampled the LFSR by itself, so card order could never match Pygame | rewritten: the stage shuffles exactly like `card_start()` (step until `lfsr & 7 < 6`) |
| `card_trigger.sv` | correct policy | merged into the Stage-1 sequencer (Pygame order) |
| `door_lock.sv` | codes 69 / 17865 correct | merged into `s1_core` (door is a close-up there) |
| `heart_system.sv` | correct | converted; `set_hearts` added for the demo menu |
| `hint_selector.sv` | picked a **random** unsolved puzzle; Pygame `smart_hint()` uses fixed order P3→P2→P1→P4 on the *right/wrong* state | replaced (in `s1_core`) |
| `inventory.sv` + `item_effect.sv` | items stored and used manually = **Stage 2** rules; Stage 1 applies them when the card turns; timers ran on 1 Hz (10 s → 9..10 s) | new `inventory.v` with `store_mode` (Stage 1 / Stage 2) and exact frame timers |
| `game_pkg.sv` | answers correct | constants moved into the modules / `game_defs.vh` |
| `tb/*.sv` | **ran them under Icarus 13: all PASS** (they test the old model) | superseded by `fpga/tb/*` |
| `tools/img_to_mem.py` | sprites squeezed to 24×48 (the art is 32×32), room 250×140 raw | superseded by `fpga/tools/asset_convert.py` |
| `assets/finalexam.mem` | output of the old script, unused | left untouched |
| Old files | **not deleted or modified**; the new project is the `fpga/` folder | |

Pygame-side findings of 2026-11-20 (about the older demos, now `demo_py_old/`):
* `stage2_demo.py` declares `CHECKPOINTS`/`ACTIONS` but has no `start`, `get_handoff`, `jump_to`,
  `do_action`, `get_progress`; `demo_hub.py` will crash when switching to Stage 2.
* `stage3_demo.py` is not a hub stage (creates its own window at import, no `Game.start/poll/draw`) and
  does not use hearts, items (Speed Boost / Freeze), forms or the sprite art. The FPGA ports it **as it
  is** (Pygame is the source of truth): the handed-over armor / boost are not used in Stage 3 and the
  final form is not unlocked there, because the demo has no such rule yet. Adding them = a Pygame change
  first, then the same change in `s3_model.py` / `s3_core.v`.
* Handoff: `get_handoff()` exists but no stage reads `handoff`; every stage restarts at 3 hearts.
  The FPGA carries armor / shards / boost between stages (inventory `load_*` ports), hearts reset to 3.

## 4. Where the FPGA version differs from Pygame (and why)

| Difference | Reason |
|---|---|
| Fonts are 8×16 / 6×12 / 16×32 bitmaps (Menlo) instead of the Pygame default font | hardware text; sizes chosen to match f_m / f_s / f_l at 2/3 scale |
| Cards drawn 3× = 96 px (Pygame smooth-scales to 113 px); cursor frame / name strip follow the art | crisp integer scaling of 32×32 pixel art |
| Player drawn 2× = 64 px (Pygame 61 px) | same reason |
| Room pictures use a 256-colour palette, 4 bits per colour channel (streamed from the QSPI flash) | the Nexys A7 VGA DAC is 4:4:4 |
| Coffee stain is a circle (Pygame: ellipse) | circle primitive; it still hides the answer |
| Toast box fixed width | box sized for the longest message |
| Texts that named keyboard keys now name the board controls ("hold BTNC 0.8 s") | the board has no keyboard |
| Debug keys F1-F6 / hub menu → SW12 demo menu | same functions (`jump_to`, actions, hearts, form, debug view, F5) |
| Walk-frame boundaries use exact time (t ≥ 0.14·k) | Pygame sums float `dt`; at exact multiples the result depends on rounding noise |
| Stage 2 wires are drawn as right-angle routes (Pygame: bezier curves) | no frame buffer fits in BRAM; the renderer draws each wire per scan line |
| Stage 2 source picker: the wire being edited turns yellow (Pygame also rings every source point) | keeps the display list small |
| Stage 2 mouse wiring / AUTO-WIRE button / F7-F9 | keyboard path of the demo is used; auto-wire, all parts, skill ready are in the SW12 demo menu |
| Stage 2 player's 'hints seen' list remembers the last 16 hints for de-duplication (Pygame: all) | the notebook only shows the last 2 |
| Stage 2 skill button text says "SW13" instead of "[E]", dialogue hints say BTNC / hold BTNC | board controls |
| Stage 3 runs on exact integers (1 m = 120·65536); Pygame on floats | positions agree within 2 mm; at an exact tie (position exactly on a boundary) Pygame's answer depends on float rounding noise - seen once: the finish line crossed 1 physics step (8 ms) earlier (cp185 scenario, reported by the check) |
| Stage 3 Thai text = 1-bit bitmaps of the demo's font (no anti-aliasing); key names → BTNL/BTNR/BTNU/BTNC/BTND | no text shaping engine in hardware; board controls |
| Stage 3 drawing at 32 px/m (demo: 64 px/m on 1280×720), polygons (hills, water) evaluated per pixel instead of per 16-px segment | half resolution game area; exact sine per pixel is cheaper than polygon fill |
| Stage 3 colours 4 bit per channel; the sky gradient is dithered (2×2) | Nexys A7 VGA DAC is 4:4:4; without dither the gradient shows bands |
| Stage 3 HUD time shows whole steps (`int(rem)`), at the exact second the float demo may show the previous second for one frame | display only |
| Stage 3 at most 6 animals, 2 falling animals and 3 plants are drawn at once (the level never has more on screen) | fixed number of display slots |

## 5. Next phases

1. **Vivado run** (synthesis, implementation, timing, bitstream, flash image) and the first test on the board
   (steps: `../README.md`).
   Expected first issues: BRAM ≈ 49 of 135 (estimate since the rooms moved to the flash, was ≈ 132; see
   ARCHITECTURE.md §3 memory budget) and the Stage 3 publish /
   physics states contain wide constant multiplies that may need a pipeline register for 100 MHz.
2. Phases 1-6 of `docs/superpowers/plans/2026-11-26-new-game-port-roadmap.md` (new Stage 1 / 2 behaviour,
   Campus Run, real title / cutscenes / endings).
