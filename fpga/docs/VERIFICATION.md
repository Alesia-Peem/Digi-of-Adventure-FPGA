# Verification

> **Out of date in part:** these results are about the older game (`demo_py_old/`). Since the new game was
> imported, the Stage 1 / 2 co-simulations fail as expected. Current state: `STATUS.md`, "Phase 0 status".

Everything below was run with **Icarus Verilog 13.0** and Python 3.13 (pygame 2.6.1) on 2026-11-20.
Run it all again with `cd fpga && ./run_tests.sh`.

| Level | What | Result |
|---|---|---|
| Simulation | puzzle mathematics (`tools/verify_puzzles.py`) | PASS |
| Simulation | shared modules (`tb/tb_units.v`) | PASS |
| Simulation | Stage 1 RTL vs **original Pygame code**, tick by tick (`tb/tb_s1_cosim.v` + `tools/cosim_s1.py`) | PASS - 3 scenarios, 2 897 ticks, 29 state values per tick, 0 differences |
| Simulation | Stage 1 VGA frames: RTL video pipeline vs Python model of the UI engine (`tb/tb_frame.v` + `tools/frame_check.py`) | PASS - 16 full 640×480 frames, 0 differing pixels (re-run after the Stage 3 renderer changes) |
| Simulation | Stage 2 RTL vs **original Pygame `stage2_demo.py`**, tick by tick (`tb/tb_s2_cosim.v` + `tools/cosim_s2.py`) | PASS - 4 102 ticks, 49 state values per tick, 0 differences |
| Simulation | Stage 2 VGA frames (`tb/tb_frame2.v`) | PASS - 16 frames, 0 differing pixels (after the Stage 3 renderer changes) |
| Simulation | Stage 3 fixed-point model vs **original Pygame `stage3_demo.py`**, same inputs (`tools/cosim_s3.py gen`) | PASS - 8 scenarios, 19 000 ticks, positions within 1.5 mm, same states / hits / skill (one exact finish-line tie, reported - section 7) |
| Simulation | Stage 3 RTL vs model, tick by tick (`tb/tb_s3_cosim.v` + `tools/cosim_s3.py cmp`) | PASS - 8 scenarios, 19 000 ticks, 18 state values + every screen field / condition / renderer phase per tick, 0 differences |
| Simulation | Stage 3 VGA frames (`tb/tb_frame3.v`) | PASS - 12 frames, 0 differing pixels: `careless` (menu, play, reporter, interview, falling, dead) + `cp185` (flyers, plants, logs, flag, win panel) |
| Elaboration | whole design incl. top level (`iverilog -Wall`) | PASS, no warnings except "@* sensitive to all words" (intended) |
| Synthesis / implementation / timing / bitstream | Vivado | **NOT RUN YET** |
| Hardware | Nexys A7 board | **NOT TESTED YET** |

## 1. Puzzle mathematics
Proves: P1 = 6; the K-map table is exactly AB + CD and AB + CD is the only accepted answer (≤ 4
literals); the NAND circuit equals F by truth table; −12 = 11110100; the 5 projector clues have exactly
one solution (C-P-E); door codes 69 and 17865 follow the manual's rules; the manual's own example is right.

## 2. Unit tests (`tb_units.v`)
VGA 800×525 totals, 640×480 active, hsync 96 px / vsync 2 lines active-low · button debounce, tap vs
long press · all 6 card shuffles × 3 slots → 3 different items (no duplicates, none lost), cursor wrap,
career from round 1 · inventory armor cap 3, 2 shards → 1 armor, Slow exactly 600 ticks, restore,
Stage-2 stored mode · hearts: armor absorbs, 3 hits → 0 + one `dead` pulse, set_hearts clamp ·
walk cycle (left leg first, 0.14 s frames, left/right priority, stop) · LFSR = Python formula for 1000 steps.

## 3. Co-simulation with Pygame (the main proof of "same game")
`cosim_s1.py gen` runs the real `demo_py/stage1_demo.py` headless with `dt = 1/60` and a scripted player
(walking routes found by BFS on the demo's own `blocked()`), records the button/switch inputs of every
tick and the Pygame state after every tick. `tb_s1_cosim.v` replays the same inputs on `s1_core.v`.
Both LFSRs start from the same seed, so card shuffles must agree too.

Compared per tick: position (0.1 px), map/close-up, object, page, puzzles answered, puzzles right,
hearts, armor, LFSR value, card round / cursor / face, play/over/clear, lights, door layer, notebook
values A/B/C, facing, walk pose, form, career, shards, boost, help screen, slow, freeze.

Scenarios: **full** (help → cards → all 5 puzzles incl. a wrong passcode → round 2/3 cards → lights,
projector → wrong door code → 69 → 17865 → clear → restart), **death** (wrong codes until 0 hearts,
3 s OUT OF HEARTS, restart), **items** (wrong answers so Hint/Undo/Shard paths are used).

Bugs found and fixed by this method: card shuffle checked the LFSR one cycle too early; a collision
function was not re-evaluated in simulation (argument sensitivity); a testbench race on the tick pulse.

Harness note: the walk-cycle timer of Pygame is run with exact arithmetic in the harness (same logic,
integer ticks). With float `t += 1/60` the switch at an exact multiple of 0.14 s depends on rounding
noise (it flipped between ticks 42·k and 42·k+1); the RTL uses the exact rule `t ≥ 0.14·k`.

## 4. VGA frames
`tb_frame.v` runs the full scenario through `s1_core → ui_composer → line_renderer` and captures complete
640×480 frames at 16 chosen ticks (one per distinct screen). `frame_check.py` renders the same
fields/conditions with `ui_compile.py`'s model and compares every pixel; `sim/frames/cmp_<tick>.png`
shows RTL | model | differences.

Result (2026-11-20): all 16 frames (ticks 2 … 1162: help, cards, map, every close-up page, notebook,
lights off, door) - **0 differing pixels**, no display-list or line-renderer overflow.
The model itself was compared with the Pygame layout by eye (`mem/preview/ui_*.png`), not pixel by pixel.

## 5. Stage 2 co-simulation
`cosim_s2.py gen` drives the real `stage2_demo.py` (with `TEST_MODE = False`, the real game) with a scripted
player that walks along the demo's own `find_path()` and approaches each spot until `find_near()` picks it:
help → round-1 card → Boss walks in (recorded trajectory) → 8 intro lines (skill starts on line 4) → Boss
walks to his desk → hint notes → all 18 parts (zoom on every pickup, round-2 cards at 9 parts) → every
SW15 inventory item → bench → 20 wires with the keyboard editor → SW0/SW1 test input → ask the Boss
(fails: a heart is lost) → the remaining 33 wires → 3 QA tests (round-3 cards after 2) → door → clear.
Compared per tick: position (0.01 px), mode, object, page, parts, found spots, read hints, QA round,
QA inputs, wiring (checksum + count), editor cursor / picker, hearts, armor, all 4 item counts, shards,
boost, slow, LFSR, cards, career, Boss state + position, dialogue (tag, line), skill timer / used, play
time, zoom (on, tick), hint popup, play/over/clear, help, intro, cut-scene, facing, pose, inventory
cursor, notes.

Harness note (exact arithmetic, same logic): dt = 1/60 as a fraction, `speed()` = 312 / 156 exactly,
the wall-slide factor 0.7 as Fraction(7, 10), timers snapped to whole ticks after every update (in
floating point 120 s of play time takes 7201 ticks, 5 s 301), whole-tick walk-cycle timer.
Bugs found by this run and fixed: the card round became active one cycle too late (registered start);
the Boss trajectory index was one tick ahead.

## 6. Frames after the Stage 3 changes
The renderer and composer gained the Stage 3 primitives (type 7: `WATER`, `TERRAIN`, `TEXTIMG`, `HILLS`),
the `S3` composer op, a 6-bit renderer state and the dithered sky, so the Stage 1 and Stage 2 frame checks
were run again. Stage 2: 16 / 16 frames, 0 differing pixels.

Found while re-running: `tb_frame.v` (Stage 1) did not set condition `IS_S1` (254), which the stage
manager sets in the real top level; since the stage-condition wrapping was added during the Stage 2 port
the composer skipped the whole Stage 1 screen program in that testbench. Fixed in the testbench (the
design was not affected); after the fix all 16 Stage 1 frames: 0 differing pixels.

## 7. Stage 3 (graduation obby)
Two reference levels, because the demo is float physics and the FPGA uses integers:

1. `cosim_s3.py gen` runs the **original** `stage3_demo.py` (`Game.step(1/120)`, `do_jump()`, `skill()`,
   the dead timer exactly as `main()` does) and `s3_model.py` (integer model, 1 m = 120·65536 units) with
   the same per-tick inputs. Checked every tick: same state (menu / play / dead / win / lose), same hits,
   same skill use, position difference ≤ 2 cm (worst seen: 1.5 mm).
2. `tb_s3_cosim.v` replays the inputs on `s3_core.v`; `cosim_s3.py cmp` compares 18 state values
   (position, speed, jumps, coyote, state, play time, hits, hit cooldown, skill, interview, message,
   camera, animals alive, reporter, animal position sums) **and** the whole published screen interface
   (128 fields, 256 conditions, camera / water / hills phases) - bit-exact.

Scenarios: `run` (look-ahead planner: gaps, double jumps, deaths), `careless` (runs into animals: reporter,
2nd hit → 5 s interview, falls), `skill` (1st hit, then BTND), `lose` (stands still 120 s), `cp90`, `cp140`,
`cp185`, `cp225` (checkpoints: stone pillars, logs, plants, flyers, finish).

Exact tie (reported, not hidden): in `cp185` the exact position reaches the finish line exactly
(x + w = 249 m); Pygame's float sum is 248.99999999999466, so the demo finishes one 1/120 s step later.
The check stops comparing at that tick and prints the tie. This is float rounding noise, not game logic.

Bugs found by this flow and fixed: Q16 drift (1/120 s is not a binary fraction) moved a collision by one
step → number format changed to 1 m = 120·65536; float timers expire one step later than `t/dt` suggests →
step counts taken from the float behaviour (181, 13, 600, 217, 14 400, 66 frames); the dead timer counts
frames (1.1 s = 66 frames in the demo); a 20-bit product overflow in the cloud scroll; a 14-bit overflow in
the log end-circle test (renderer); condition 0 (constant 1, required by the composer) was not set by
`s3_core` - found by the frame check, the display co-simulation now checks it too.

Visual comparison with the Pygame window (by eye, `s3_side.py`-style side-by-side renders, not pixel
exact because of the 32 px/m scale, 4-bit colour and 1-bit Thai text): menu, play at 15 / 50 / 200 / 245 m,
interview, skill message, dead, win and time-up panels.
