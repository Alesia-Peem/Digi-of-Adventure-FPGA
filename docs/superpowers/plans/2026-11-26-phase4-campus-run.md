# Phase 4: Stage 3 "Campus Run" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the game logic and assets of `onlystage_3/` to hardware (`cr_core.v`), verified step by step against the original, and write down the renderer/top interface the integration needs.

**Architecture:** Three layers: `onlystage_3/game.py` (float, truth) → `cr_model.py` (integers) → `cr_core.v` (bit-exact with the model). Collision is a lookup in a 250×11 grid plus three special boxes (puzzle, two lifts). One sequencer runs one 1/120 s step in the order of `Game.step()`.

**Tech Stack:** Verilog-2001, Icarus Verilog 13 (`-g2005`), Python 3 with pygame, Pillow, numpy.

**Spec:** `fpga/docs/audit/stage3_audit.md` (S3-#n = item n of its §6); behaviour = `onlystage_3/*.py`. Where they disagree, the Python wins.

## Decisions (user accepted the recommendations, 2026-11-26)

| # | Decision |
|---|---|
| D1 | Full 32×32 tiles, 4 bpp with 15 colours per tile; backdrops stream from QSPI flash at 704×352 |
| D2 | Per-tile palettes, hard edges on tiles, bitmap fonts; cloak stays translucent; keep all effects, ask before dropping any |
| D3 | Campus Run's own button mapping |
| D4 | No hearts or items in Stage 3; Stage 2's handoff passes through unchanged |
| D5 | No HOW TO PLAY screen (as the demo hub), so no `READY` mode |
| D6 | Cutscenes stay in Phase 5 |

**Accepted ties (user, 2026-11-27, option A).** `onlystage_3/` is not changed. Where a value lands exactly on a
boundary that depends on the player's float history, the game and the model may differ by one step: (1) an animal
waking (`camera + 20 >= trigger`; it then stays 1.7 cm out), (2) `progress` on a whole percent (and the 92 %
message), (3) the end of the tea growth (sprite size). Only these three; `cr_cosim.Run` names and counts them.
The hardware uses exact integer comparisons.

Execution: native (this session), one fresh review of the whole branch at the end.

## Global Constraints

- Source of truth is `onlystage_3/` on this branch. No gameplay is removed or simplified. The audit's `NEW/...` paths mean `onlystage_3/...`.
- Synthesizable Verilog-2001, one clock domain (100 MHz), no `#` delays in RTL.
- Create only: `fpga/tools/cr_*`, `fpga/rtl/stage3/cr_*`, `fpga/tb/cr_*`, `fpga/mem/cr_*` and `fpga/mem/preview/cr_*` (generated), `fpga/run_tests_s3.sh`, `fpga/docs/stage3_integration_request.md`, this plan.
- Do not edit: `fpga/rtl/{stage1,stage2,video,top,ui,common}`, `fpga/run_tests.sh`, `fpga/tools/{pic_pack,pic_list,ui_compile}.py`, `fpga/constraints`, `fpga/vivado`. Do not delete `s3_core.v` / `s3_consts.vh` (the top still uses them).
- `run_tests.sh` compiles `rtl/stage3/*.v`, so `cr_core.v` must compile cleanly there from the day it is added.
- Model vs original: same inputs every step, positions within 1 mm, identical events. RTL vs model: bit-exact every step.
- Test first, see it fail, then implement. Every comparison reports differences; a float tie is listed by name, never silently accepted.
- BRAM figures are estimates. Never claim synthesis, timing or board results.
- Commit often. Push only `stage3-campus-run`, and only after the user says yes.
- Subagent models, if used: Haiku easy, Sonnet medium, Opus timing-critical RTL.
- After each task, report in simple words: what was built, inputs/outputs, test command, real result, what is unfinished.

## Fixed-point format (all tasks)

| Quantity | Rule |
|---|---|
| Length | 1 m = `Q = 600*4096 = 2457600` units, signed 32 bit |
| Player state (`x`, `vx`, `y`, `vy`, gravity) | extra `VF = 8` fraction bits (signed 40 bit). Without them: 2.1 mm gravity drift, and a wall reached one step late after a double jump |
| Tie tolerance | vertical 128 units (52 um), horizontal 1 unit, instead of the game's EPS: exact landings are designed ties |
| Per-step speeds (units) | run 102400, enemy 40960, tea 53248, retreat 61440, lift 16384, sink 12288, water sink 57344 (all exact) |
| Normal gravity | `G*Q/14400 = 6965.986` units/step², stored with VF bits |
| Player jump integration | `y += v - g/2; v -= g` (`game.py:312-314`) |
| `fall_item` (tea, walkers) and retreat fall | `v -= g; y += v` (`game.py:395-397`, `505-506`) — a different rule |
| Timers | whole steps, obtained from `timer_steps()` (Task 3) |
| Reporter score | `5*|dx| + 8*|dy| + 10*Q if near` (5 × the Python score, exact) |

Float countdowns measured on 2026-11-26 (steps until the game's condition flips):

| Timer | Condition in `game.py` | Steps |
|---|---|---|
| coyote 0.15, buffer 0.15 | `> 0` | 19 |
| notice 2.0 | `> 0` | 241 |
| protection 0.65 | `> 0` | 78 |
| protection after interview 1.0 | `> 0` | 121 |
| flash 0.45 | `> 0` | 54 |
| skill 5, interview 5 | `< EPS` | 600 |
| cloak follow 0.6 | `< EPS` | 72 |
| retreat 2.0, level clear 2.0 | `< EPS` | 240 |
| time limit 120 | `<= 0` | 14400 |

Double jump is allowed while `elapsed_steps <= 134`.

## Review Focus

1. **Both BTNL and BTNR held, or jump and skill on the same tick** — axis is 0; both actions happen in `step()` order (test in Task 6).
2. **BTND pressed during CLEAR, WIN or an interview** — pause toggles only from play/pause; an interview can be paused (Task 5).
3. **A button already held when the stage is entered** — no jump, skill or pause until it is released and pressed again (Task 9).
4. **Restart in the middle of a chase, interview, tea flight or lift ride** — nothing from the old attempt survives (Task 5, repeated bit-exact in Task 9).
5. **A short BTNC press between two 60 Hz ticks** — the skill must not be lost; the core takes a latched pulse, which `input_hub` does not provide yet (Task 9 TB, Task 10 request).

## File Structure

| File | Responsibility |
|---|---|
| `fpga/tools/cr_assets.py` | levels → grid, entity tables, tiles, maps, sprites, previews, BRAM report |
| `fpga/tools/cr_model.py` | integer model of `game.py` (no file or pygame code) |
| `fpga/tools/cr_cosim.py` | scenarios; original vs model; stimulus/expected files; RTL vs model |
| `fpga/tools/cr_test_assets.py`, `cr_test_model.py` | plain `assert` test scripts, like `test_pic_pack.py` |
| `fpga/rtl/stage3/cr_core.v`, `cr_consts.vh` (generated) | hardware game logic |
| `fpga/rtl/stage3/cr_math.v` | shared sequential divider and square root |
| `fpga/tb/cr_tb_cosim.v`, `cr_tb_ctrl.v` | step-trace replay; button/entry cases |
| `fpga/run_tests_s3.sh` | all Stage 3 tests; exits non-zero on any failure |

---

### Task 1: Collision grid and entity tables (S3-#2, part 1)

**Files:** Create `fpga/tools/cr_assets.py`, `fpga/tools/cr_test_assets.py`.

**Interfaces — Produces:**
- `load_maps() -> dict[int, Level]` (imports `onlystage_3.level.Level` from the repo root, so path fallbacks match the game)
- `grid(level) -> tuple[list[int], list[int]]`: `(solid, water)`, 250 column words; bit `r` = cell with `y == r`
- `surfaces_mask(solid_col: int) -> int` = `solid_col & ~(solid_col >> 1)`
- `entities(stage) -> list[dict]` with keys `species, motion, x, y, base_y, lo, hi, trigger, leader, active` after the spawn snap of `Game.restart`, in construction order; `leader` is an index or -1; skins excluded (they are random)

- [ ] **Step 1: failing tests**

```python
def test_grid_matches_level():
    for s, L in A.load_maps().items():
        solid, water = A.grid(L)
        cells = lambda g: {(x, y) for x in range(250) for y in range(11) if g[x] >> y & 1}
        assert cells(solid) == {(int(b.x), int(b.y)) for b in L.solids}
        assert cells(water) == {(int(b.x), int(b.y)) for b in L.water}

def test_surfaces_match_level():
    for s, L in A.load_maps().items():
        solid, _ = A.grid(L)
        for x in range(250):
            m = A.surfaces_mask(solid[x])
            assert sorted(y + 1 for y in range(11) if m >> y & 1) == sorted(L.surfaces(x + .5))

def test_entity_counts():
    assert [len(A.entities(s)) for s in (1, 2, 3)] == [36, 23, 44]
    assert [sum(e["leader"] >= 0 for e in A.entities(s)) for s in (1, 2, 3)] == [2, 0, 5]
```

- [ ] **Step 2:** `python3 -I fpga/tools/cr_test_assets.py` → FAIL (`No module named 'cr_assets'`).
- [ ] **Step 3:** implement the four functions.
- [ ] **Step 4:** same command → PASS.
- [ ] **Step 5:** commit `feat(cr): collision grid and entity tables from the Tiled maps`.

### Task 2: Tiles, maps, sprites, previews, BRAM report (S3-#2, part 2)

Needs decisions D1 and D2.

**Files:** Modify the two files of Task 1. Create (generated, committed) `fpga/mem/cr_{solid,water,ent,tiles,tpal,map,spr,spal}.mem`, `fpga/mem/preview/cr_*.png`, `fpga/rtl/stage3/cr_consts.vh`.

**Interfaces — Produces:**
- map word, 9 bit: `{hflip, tile_id[7:0]}`, tile 0 = empty; address `level*4096 + row*256 + col`, row 0 = top
- tile: 32×32 × 4 bpp; index 0 = transparent (alpha < 128); 15 × 12-bit colours per tile
- `bram_report() -> list[tuple[str, int, int]]` = (item, bits, BRAM36)
- backdrops: `preview/cr_bg{1,2,3}.png`, 704×352, for the picture list (requested in Task 10, not added here)

- [ ] **Step 1: failing tests** `test_level_image_exact` (compositing unquantised deduped tiles through the maps equals compositing `level.cells`, for all three levels), `test_quantised_psnr` (mean per-tile PSNR over opaque pixels ≥ 28 dB; print the worst tile), `test_tile_count` (≤ 255 unique after H-flip dedupe).
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** implement; `python3 -I fpga/tools/cr_assets.py` writes the files and prints the report. Sprites are stored at drawn size (sizes from `render.py:183-199`).
- [ ] **Step 4:** run → PASS; the user looks at the previews.
- [ ] **Step 5:** commit.

### Task 3: Model — timers, player physics, grid collision (S3-#3)

**Files:** Create `fpga/tools/cr_model.py`, `fpga/tools/cr_cosim.py`, `fpga/tools/cr_test_model.py`.

**Interfaces — Consumes:** `grid`, `entities`. **Produces:**
- `timer_steps(seconds: float, limit: float) -> int`: how many `t -= 1/120` it takes until `t <= limit` (**the user writes this one: `TODO(human)`**)
- `Model(maps_tables, seed)`: `new_game()`, `restart(msg_id)`, `step(axis: int, jump: bool, skill: bool)`, `snapshot() -> tuple`, `HEADER: tuple[str, ...]`
- `cr_cosim.original(stage) -> game.Game` and `cr_cosim.compare(script) -> Report(worst_mm, first_diff, ties)`; `script` is a list of `(axis, jump, skill)` per step

- [ ] **Step 1: failing tests**

```python
def test_timer_steps():
    assert M.timer_steps(.15, 0) == 19 and M.timer_steps(5, 1e-7) == 600
    assert M.timer_steps(120, 0) == 14400 and M.timer_steps(2.0, 1e-7) == 240
```

plus sweeps, each asserting `worst_mm <= 1` and no `first_diff` in `(grounded, jumps, buffer>0, grace>0)`: `sweep_double_jump` (second press at every step 1..140), `sweep_coyote` (press 0..22 steps after leaving a ledge), `sweep_buffer` (press 0..22 steps before landing), `wall_push`, `head_bump`, `fast_fall_stack`, `late_double_jump_over_pit` (the ~175 m/s case).
- [ ] **Step 2:** `python3 -I fpga/tools/cr_test_model.py` → FAIL.
- [ ] **Step 3:** implement `move()` / `try_jump()`. Order that the grid code must keep: X pass visits rows high→low, columns left→right, then puzzle, then lifts; Y pass ends on the highest top when falling and the lowest bottom when rising. Double jump: `s = isqrt(rise<<16) + isqrt(H<<16)`, `g = ((2*s*s) << VF >> 16) // n**2`, `n = 144 - elapsed_steps`, `vy = isqrt(2*g*(rise << VF))`.
- [ ] **Step 4:** run → PASS; record the worst mm per sweep.
- [ ] **Step 5:** commit.

### Task 4: Model — animals and contacts (S3-#4)

**Files:** Modify `cr_model.py`, `cr_cosim.py`, `cr_test_model.py`.

**Interfaces — Produces:** `Lfsr16(seed)` with the recurrence of `fpga/rtl/common/lfsr16.v`; `choice(n) = (state*n) >> 16`. The harness replaces `game.random` with an object whose `choice` / `sample` draw from the same generator in the same call order. `sample` of 2 from 15: `i = choice(15); j = choice(14); j += j >= i`.

- [ ] **Step 1: failing tests** for each level, 14 000 steps with the camera moved along the level: same `active`, `alive`, `contacts` sets every step; positions ≤ 1 mm; follower delay = 60 steps; ant cycle 240/120/240/120 steps; a walker that enters water dies on the same step.
- [ ] **Step 2:** FAIL. **Step 3:** implement `update_enemy` and the contact test (`game.py:338-391`, `598-617`). **Step 4:** PASS. **Step 5:** commit.

### Task 5: Model — reporter, skills, lifts, tea, flow (S3-#5)

**Files:** Same three.

**Interfaces — Produces:** modes `PLAY=0, PAUSE=1, CLEAR=2, WIN=3` (plus `READY=4` only if D5 says so); `pause_toggle()`; `confirm()` (WIN → `exit_req`); message ids 0 none, 1 new game, 2 time up, 3 splash, 4 fell, 5 stage 2 title, 6 stage 3 title, 7 need a reporter for Cloak, 8 pick up tea, 9 tea awakening, 10 reporter coming, 11-13 near finish L1-L3, 14 need tea. The harness maps message text to id.

- [ ] **Step 1: failing tests**, one per behaviour: `chase_then_interview`, `cloak_refused_without_chase`, `cloak_follow_retreat`, `phase_ignores_hits_600_steps`, `lift_ride_both_kinds`, `tea_gold_growth`, `door_l2_needs_tea`, `clear_to_next_level`, `win_l3`, `timeout_at_14400`, `restart_mid_everything` (Review Focus 4), `pause_in_each_mode` (Review Focus 2). Each asserts identical event sequence and ≤ 1 mm.
- [ ] **Step 2:** FAIL. **Step 3:** implement `game.py:412-526` and `528-630`. The trail is a 512-entry ring; the retreat height uses floor division.
- [ ] **Step 4:** PASS. **Step 5:** commit.

### Task 6: Scenarios that clear every level (S3-#6)

**Files:** Modify `cr_cosim.py`; create `fpga/run_tests_s3.sh`.

**Interfaces — Produces:** `SCEN: dict[str, callable]`; `gen(name)` writes `sim/cr_<name>_stim.mem` (one word per step: `[0]` left `[1]` right `[2]` jump `[3]` skill `[4]` menu `[8]` command, `[15:12]` command op, `[31:16]` argument) and `sim/cr_<name>_expect.txt`. Scenarios: `plan1/2/3` (reach the door), `careless`, `skill`, `interview`, `pit`, `lift`, `timeout`, `restart`, `buttons` (Review Focus 1).

- [ ] **Step 1: failing test** `plan<n>` ends in CLEAR or WIN in both original and model.
- [ ] **Step 2:** FAIL. **Step 3:** bot = beam search over axis and press timing on copies of the model; the found inputs are saved to `fpga/tools/cr_routes.json` so tests do not search again.
- [ ] **Step 4:** `cd fpga && ./run_tests_s3.sh` → all Python sections PASS. **Step 5:** commit.

### Task 7: `cr_core.v` — player and collision (S3-#9)

**Files:** Create `fpga/rtl/stage3/cr_core.v`, `cr_math.v`, `fpga/tb/cr_tb_cosim.v`.

**Interfaces — Produces:**

```verilog
module cr_core #(parameter MEM_DIR = "mem/", parameter STEPS_PER_TICK = 2) (
    input  wire clk, rst, gtick,
    input  wire btn_left, btn_right,          // levels
    input  wire ev_jump, ev_skill, ev_menu,   // one pulse per press, valid with gtick
    input  wire enter,                        // stage entry
    input  wire demo_cmd, input wire [3:0] demo_op, input wire [15:0] demo_arg,
    output wire exit_req, step_done, busy,
    output wire [2:0] mode, output wire [1:0] level, output wire [12:0] cam_px,
    input  wire [5:0] q_idx, output wire [31:0] q_data   // entity read port for the publisher
);
module cr_math (input wire clk, rst, start, op_sqrt, input wire [63:0] a, b,
                output reg busy, done, output reg [63:0] result);   // floor quotient or floor sqrt
```

`ev_jump`/`ev_skill` apply to the first step of a tick only. The testbench sets `STEPS_PER_TICK = 1` so every step has its own input, and one extra run uses 2.

- [ ] **Step 1: failing TB** replays `cr_<name>_stim.mem`, prints `HEADER` columns at each `step_done`; `cr_cosim.py cmp` reports the first differing step. Unit cases for `cr_math`: `isqrt(0)`, `isqrt(2**63)`, negative-dividend floor division.
- [ ] **Step 2:** FAIL. **Step 3:** implement (timing-critical: Opus). **Step 4:** physics sweeps from Task 3 bit-exact; assert worst step < 400 000 clocks. **Step 5:** commit.

### Task 8: `cr_core.v` — animals (S3-#10)

- [ ] **Step 1:** extend `HEADER` with per-step entity checksums (x, y, active, alive, exposure) → FAIL.
- [ ] **Step 2:** entity ROM + state RAM, 5 follower delay rings of 64, one entity at a time.
- [ ] **Step 3:** Task 4 scenarios bit-exact, all three levels. **Step 4:** commit.

### Task 9: `cr_core.v` — reporter, skills, lifts, tea, flow (S3-#11)

**Files:** Modify `cr_core.v`; create `fpga/tb/cr_tb_ctrl.v`.

- [ ] **Step 1: failing tests:** all Task 6 scenarios bit-exact; `cr_tb_ctrl`: `enter` with skill/jump/menu already pulsing in the same cycle does nothing (Review Focus 3); a skill pulse delivered with one `gtick` is applied exactly once (Review Focus 5); `demo_cmd` while `busy` is not lost; restart finishes before the next `gtick`.
- [ ] **Step 2:** implement (`place_reporter` = one pass over solid cells within ±10 columns keeping the minimum `(score, x, y)` free spot).
- [ ] **Step 3:** `./run_tests_s3.sh` PASS and `cd fpga && ./run_tests.sh quick` shows no new failure. **Step 4:** commit.

### Task 10: Integration request (S3-#7, #8, #12, #13 — specified, not implemented)

**Files:** Create `fpga/docs/stage3_integration_request.md`.

It must state, with exact widths, formats and a test criterion for each:
1. Scrolling tile background mode (map/tile/palette formats of Task 2, camera, 352→360 row map from `render.py:200`, water bob lines).
2. Sprite primitive: any size, flip, four-side clip, alpha.
3. Three backdrops for `pic_list.py` (704×352) and how the parallax offset reaches `pic_rd_x`.
4. HUD / modal screens and the fields the publisher needs from `q_data` and the scalar outputs.
5. Top: instance, `BTNC` press pulse from `input_hub`, buttons per Campus Run, exit on WIN, 7-seg, LEDs, level select.
6. `cr_consts.vh` in `create_project.tcl`; remove old Stage 3.
7. BRAM report from Task 2 and its dependency on Phase 0 Task 7 (rooms leaving BRAM).

- [ ] Write it, check every number against `cr_assets.py` output, commit, tell the user.
