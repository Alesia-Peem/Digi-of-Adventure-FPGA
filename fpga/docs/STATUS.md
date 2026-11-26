# Project status, audit and decisions

Date: 2026-11-20. **What is DONE is listed with how it was verified. Nothing here claims synthesis,
timing or hardware results - Vivado has not been run yet (no Vivado on the development Mac).**

## 1. Scope of this phase

| Part | Status |
|---|---|
| Stage 1 (Final Exam): all gameplay of `stage1_demo.py` | **ported**, simulated, matches Pygame tick by tick |
| FEATURE 1 movement + collision + camera + walk animation | ported (Stage 1 geometry), shared modules `sprite_anim`, `input_hub` |
| FEATURE 2 character forms 1-4 (+ generated art for the secret form) | ported: form register, sprite selection, Stage-1 effects (speed ×1.2, +30 interaction range) |
| FEATURE 3 LFSR, cards (3 rounds), inventory, item effects, hearts | ported, shared modules |
| VGA engine (display list + line buffers), UI VM, fonts, asset ROMs | done, shared by all stages |
| Board top, XDC, Vivado script, on-board demo menu (= demo_hub) | done; stage manager Stage 1 → 2 → 3 |
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

Pygame-side findings (not fixed - outside this phase, please confirm):
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

1. **Vivado run** (synthesis, implementation, timing, bitstream) and the first test on the board.
   Expected first issues: BRAM ≈ 49 of 135 (estimate since the rooms moved to the flash, was ≈ 132; see
   ARCHITECTURE.md §3 memory budget) and the Stage 3 publish /
   physics states contain wide constant multiplies that may need a pipeline register for 100 MHz.
2. If wanted: give `stage3_demo.py` the shared features (hearts, Speed Boost / Freeze, forms, sprite art)
   in Pygame first, then port the change.
