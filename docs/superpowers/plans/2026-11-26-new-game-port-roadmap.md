# New-Game FPGA Port — Roadmap & Phase 0/1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the existing Nexys A7 Verilog port (built from the OLD Pygame) to exact parity with the NEW authoritative game (user's Drive zip): Stage 1–3, title, cutscenes, ending — and make it fit the FPGA.

**Architecture:** Keep the proven engine (display-list line renderer, UI VM, tick-by-tick cosim against Pygame). Add one shared **QSPI-flash picture streamer** so every large bitmap (S1/S2 rooms, cutscene/ending/title pictures, Campus Run backdrops) leaves BRAM. Stage 3 is rewritten as `cr_core.v` (Campus Run) with a tile-map background mode. Each stage keeps the 3-level verification chain: Pygame → (Python fixed-point model where needed) → RTL bit-exact per tick → VGA frame pixel-exact.

**Tech Stack:** Verilog-2001 (Vivado-synthesizable), Icarus Verilog 13 for simulation, Python 3 + Pillow/numpy/pygame for asset tools and cosim, Vivado 2020+ on the user's Windows/Linux PC (no Vivado on the Mac), target `xc7a100tcsg324-1`.

**Spec:** the master prompt (conversation, 2026-11-26) + audit reports, which carry the file:line detail every task below cites:
- `fpga/docs/audit/stage1_audit.md` (S1-#n = its §5 item n)
- `fpga/docs/audit/stage2_audit.md` (S2-#n)
- `fpga/docs/audit/stage3_audit.md` (S3-#n)
- `fpga/docs/audit/flow_assets_audit.md` (FA-#n)

## Global Constraints

- Source of truth = `~/FPGA-Projects/drive_assets/Digi-of-Adventure-main/` (NEW). Old `demo_py/` is kept only as `demo_py_old/` for diffing.
- Stage 3 = `onlystage_3/` "Campus Run" (`demo_py/stage3_demo.py` is a wrapper).
- RTL: Verilog `.v`, synthesizable, no `#` delays, no SV-only constructs; testbenches only in `fpga/tb/`.
- Single 100 MHz clock domain (pixel clock via enable, as today). No DDR2/MIG.
- BRAM budget: ≤ 135 RAMB36 equivalents on xc7a100t, target ≤ 120 to leave timing/placement margin.
- Puzzle answers are unchanged and must stay: P1 A=6, P2/3 B=7, P4 C=5, projector password `CPE`, door L1 = 69, door L2 = 17865 (`tools/verify_puzzles.py` must PASS after every task).
- Never claim synthesis/timing/board results without a real Vivado/board run; mark them "pending user run".
- Every deviation from Pygame is recorded in `fpga/docs/STATUS.md` §4 with its reason.
- Commits on branch `port-new-game`, message trailer per session attribution.

## Review Focus

1. **Flash not programmed / wrong offset** — the board booted with only the bitstream must show a clear "PICTURES MISSING" pattern, not garbage or a hang. Test in Task 4 (magic-word check).
2. **Stage restart after game over (hearts = 0)** must restore the *stage-entry* handoff (career, backs, form, armor) — not defaults and not the dying state. Test in Phase 2/3 cosim `death` scenarios.
3. **Button held across a screen change** (e.g. BTNC held from cutscene into Stage 2) must not fire a second action — one-shot pulses re-armed only after release. Test in Task 6 stage-manager TB.
4. **Timer widths** — Freeze 600 frames, zoom 132 ticks, Campus Run time-out 14 400 steps all overflow current counters; every widened counter gets a boundary test at max and max+1.
5. **Switches already up at stage entry** (SW0–7 puzzle inputs, SW14 notebook, SW15 help) must not count as an edge/answer. Test in Phase 2 cosim `gates`.

---

## Roadmap (phases)

| Phase | Content | Audit items | Gate to next phase |
|---|---|---|---|
| **0** | Repo sync, Vivado baseline, memory architecture (flash streamer), stage manager skeleton | FA-1, FA-5, FA-6, FA-7, FA-14 | streamer frame-exact in sim; user's Vivado run reports real BRAM; title picture shows on board |
| **1** | Shared features to new rules: card table per stage, inventory (Freeze 600 f, Heart Loss, Undo P4), career/back/pick handoff, ending resolver | S1-#6/#7, S2-#6/#7/#12, FA-3 | unit TBs pass; handoff TB = NEW `get_handoff()` |
| **2** | Stage 1 parity (user's stage) | S1-#1…#10 | cosim `full/death/items2/gates/wrong` PASS vs NEW `stage1_demo.py` |
| **3** | Stage 2 parity | S2-#1…#15 | cosim `full/bench/...` PASS vs NEW `stage2_demo.py` |
| **4** | Stage 3 Campus Run rewrite | S3-#2…#13 | model vs `game.py` ≤ 1 mm, RTL = model bit-exact, frames pixel-exact |
| **5** | Title, cutscenes, ending, demo menu parity, item-face ROM | FA-2, FA-4, FA-8…#13 | cosim of every input path vs Pygame screens |
| **6** | Vivado closure + board bring-up | S3-#15, FA-14 | ≤ 135 BRAM, timing met @100 MHz, full playthrough on the board |

Phases 2, 3 and 4 are independent once Phase 1 lands and can run in parallel (separate files: `rtl/stage1`, `rtl/stage2`, `rtl/stage3`). **Each of Phases 1–6 gets its own detailed plan file** (`docs/superpowers/plans/2026-11-xx-phaseN-*.md`) written from its audit section right before execution; this file details Phase 0 only.

### Memory budget (estimates, to be replaced by Task 2's Vivado numbers)

| Item | RAMB36 now | After Phase 0 |
|---|---|---|
| Current design total (FA §5) | ≈137 | — |
| `bg_s1` room → flash | −42 | ≈95 |
| `bg_s2` room → flash (if Task 7 confirms it is a full bitmap) | − (measure) | ≤ 95 |
| old Stage 3 ROMs removed (Phase 4) | − (measure) | |
| + Campus Run tiles/maps/sprites (S3 §3) | +24…40 | |
| + item-face ROM 16×32×32×8 b (FA-8) | +4 | |
| + S2 UNDO history 200×270 b (S2-#9) | +2 | |
| + sprite ROM growth (Boss, TA, 15 faces → item ROM) | +2…14 | |
| **Projected** | | **≈ 125–135 → must also move `bg_s2`; target ≤ 120** |

---

## Phase 0 — detailed tasks

### Task 1: Sync the new game into the repo

**Files:**
- Move: `demo_py/` → `demo_py_old/` (git mv, kept for diffs)
- Create: `demo_py/` ← NEW `demo_py/*.py` (13 files), `onlystage_3/` ← NEW `onlystage_3/` (minus `__pycache__`), `assets/` ← NEW `assets/` (add the 47 new files; keep identical ones)
- Modify: `.gitignore` (ignore `*:Zone.Identifier`, `*~RF*.TMP`, `* - Copy.png`, `__pycache__/`)
- Modify: `fpga/tools/cosim_s1.py`, `cosim_s2.py`, `cosim_s3.py`, `s3_model.py`, `stage2_assets.py` — the import path constant that points at `demo_py` for the OLD reference becomes `demo_py_old` **only for cosim_s3/s3_model** (old Stage 3 RTL stays testable until Phase 4 deletes it); S1/S2 cosims point at NEW `demo_py`.

**Interfaces:** Produces: NEW Pygame importable at `demo_py/` and `onlystage_3/` from repo root.

- [ ] **Step 1:** `git checkout -b port-new-game`; copy with `ditto` (not `unzip`: Thai filename `stage2_สำรอง.py`).
- [ ] **Step 2:** Verify imports headless: `cd demo_py && SDL_VIDEODRIVER=dummy python3 -c "import stage1_demo, stage2_demo, card_assets, open, cutscene_1_2, cutscene_2_3, cutscene_ending"` → no exception. (`stage3_demo` needs Tkinter; check `python3 -c "import sys; sys.path[:0]=['onlystage_3']; import game, level, render"`.)
- [ ] **Step 3:** `python3 -I fpga/tools/verify_puzzles.py | tail -1` → PASS.
- [ ] **Step 4:** Run `fpga/run_tests.sh quick`. **Expected:** sections 1–3 PASS; sections 4–5 (S1/S2 cosim) **FAIL** at the first divergent tick (now comparing against NEW code). Record the first failing tick per scenario in `fpga/docs/audit/baseline_failures.md` — this is the Phase 2/3 starting point.
- [ ] **Step 5:** Commit `chore: import new authoritative game (Drive zip) as reference`.

### Task 2: Vivado baseline (user runs it)

**Files:**
- Create: `fpga/vivado/report_baseline.tcl` — opens the project made by `create_project.tcl`, runs `synth_design`, writes `report_utilization -hierarchical -file fpga/docs/audit/util_baseline.txt` and `report_timing_summary -file fpga/docs/audit/timing_baseline.txt`.
- Modify: `fpga/README.md` — one section "Baseline run for the porting team" with the exact command.

- [ ] **Step 1:** Write the tcl; dry-check syntax on the Mac is impossible — keep it to the documented commands only (`open_project`, `reset_run synth_1`, `launch_runs synth_1 -jobs 4`, `wait_on_run synth_1`, `open_run synth_1`, the two reports).
- [ ] **Step 2:** **User action:** on the Vivado PC: `cd fpga && vivado -mode batch -source vivado/create_project.tcl -tclargs 100t && vivado -mode batch -source vivado/report_baseline.tcl`; copy the two `.txt` files back into `fpga/docs/audit/`.
- [ ] **Step 3:** Replace the "Memory budget" estimates above with the real RAMB36/RAMB18 per instance. If total ≤ 120 *without* moving `bg_s2`, Task 7 stays optional.
- [ ] **Step 4:** Commit `docs: real Vivado BRAM/timing baseline`.

(Phase 0 continues with Tasks 3–5 in parallel while waiting for the user's run.)

### Task 3: Picture packer `fpga/tools/pic_pack.py`

**Files:**
- Create: `fpga/tools/pic_pack.py`, `fpga/tools/pic_list.py` (the ordered list of pictures: id, source file, target rect, resample mode)
- Create (generated): `fpga/mem/pictures.bin`, `fpga/mem/preview/pic_XX.png`, `fpga/rtl/video/pic_map.vh` (`localparam PIC_TITLE = 0, …` and byte offsets)
- Test: `fpga/tools/test_pic_pack.py`

**Interfaces:**
- Produces the flash image format documented in the `pic_pack.py` docstring (little-endian, offsets relative to `PIC_BASE = 0x400000`): `"CPEP"`, `u16 count`, `u16 version=1`; then 8 B per picture `{u32 off, u16 w, u16 h}`; at `off`: 256 × `u16` 0x0RGB palette, then `h` rows × `w` bytes of index (row y at `off + 512 + y*w`); pictures 256-byte aligned. `pic_map.vh` gives `PIC_BASE`, `PIC_COUNT`, `PIC_<NAME>` ids.
- `pic_list.py` (22 pictures, id order = list order): S1_ROOM, S2_ROOM (640×358, same resize as the old `convert_bg`), TITLE, OPEN1-6, CUT12, CUT23_1-3, END1-9 (640×360, built with the game's own Pygame loaders at 960×540, then LANCZOS to 640×360).
- **Status: DONE by the controller (commits 0835006..508d36a): PIC_PACK PASS, 5.08 MB.**

- [ ] **Step 1: failing test** `test_roundtrip`: pack → unpack every picture → `max |orig_quantised − decoded| == 0`, header count == `len(pic_list.PICS)`, total size < `16 MiB − PIC_BASE`.
- [ ] **Step 2:** `test_psnr`: decoded vs original RGB PSNR ≥ 30 dB for photos, ≥ 36 dB for flat art (FA §5.1 values).
- [ ] **Step 3:** implement (median-cut 256 colours per picture via Pillow `quantize(256, method=MEDIANCUT, dither=NONE)`, then 4:4:4 palette).
- [ ] **Step 4:** `python3 -I fpga/tools/test_pic_pack.py` → PASS; eyeball previews.
- [ ] **Step 5:** Commit.

### Task 4: QSPI flash streamer `pic_stream.v` (+ sim flash model)

**Files:**
- Create: `fpga/rtl/video/qspi_reader.v`, `fpga/rtl/video/pic_stream.v`
- Create: `fpga/tb/flash_model.v` (behavioural S25FL128S subset: `0x6B` Quad Output Fast Read, 8 dummy clocks, `$readmemh` of `pictures.bin` converted by the packer to `pictures.hex`)
- Create: `fpga/tb/tb_pic_stream.v`
- Modify: `fpga/constraints/nexys_a7.xdc` — add `QSPI_CSN` and `QSPI_DQ[3:0]` **copied verbatim from Digilent's Nexys-A7-100T-Master.xdc** (do not type from memory; the clock goes through `STARTUPE2.USRCCLKO`, no pin).

**Interfaces:**
- `qspi_reader(clk, rst, start, addr[23:0], len[15:0], busy, data[7:0], data_valid, qspi_csn, qspi_sck, qspi_dq_i[3:0], qspi_dq_o[3:0], qspi_dq_oe)` — SCK = clk/2 (50 MHz), one `0x6B` command per burst.
- `pic_stream(clk, rst, pic_id[4:0], pic_load, row_req, src_row[9:0], rd_x[9:0], rd_rgb[11:0], busy, missing, + qspi pins)`:
  - `pic_load` pulse (in vblank): read the header entry of `pic_id` (off, w, h) and its 256-entry palette into a 256×12 palette RAM. Also checks the magic once after reset; `missing=1` when it is not `"CPEP"` (flash not programmed or quad mode not enabled).
  - `row_req` pulse with `src_row`: fetch row `src_row` of the current picture (all `w` bytes, `w ≤ 1024`) into the *back* half of a ping-pong 2×1024×8 row buffer; the halves swap on the next `row_req`. If `src_row` equals the row already in the front half, no fetch (Stage 1 shows each source row on 2 screen lines).
  - `rd_x` → `rd_rgb` = palette[front_row[rd_x]], 2-cycle latency like the existing `rom_sync` + palette path in `line_renderer.v:600-603`.
  - Why whole rows: Stage 2 zooms (`bg_mode 2`, source x = `zoom_ox + screen_x * zoom_inv`), Stage 1 scrolls with a camera; both need random x within one source row, never more than one row per screen line.
- Top-level instantiates `STARTUPE2` (`USRCCLKO = qspi_sck`, `USRCCLKTS = 0`) inside `cpe_escape_top.v` only — never in the TB (TB connects `qspi_sck` directly to the model).

- [ ] **Step 1: failing TB** `tb_pic_stream`: with `fpga/mem/pictures.hex` in the flash model, for `PIC_TITLE` and `PIC_S2_ROOM`: `pic_load`, then for each row 0..h-1 issue `row_req` at the real VGA line period (800 × 4 clocks = 3200 cycles of 100 MHz), wait for the swap, read `rd_x` 0..w-1 and write RGB to `sim/frames/pic_<NAME>.ppm`; a small Python check (`fpga/tools/pic_check.py`) compares each .ppm to `fpga/mem/preview/pic_<NAME>.png` → expect FAIL (module absent).
- [ ] **Step 2:** TB `test_missing`: flash model loaded with zeros → `missing == 1` within 1 ms, renderer shows the "PICTURES MISSING" stripe pattern (Review Focus 1).
- [ ] **Step 3:** implement `qspi_reader` then `pic_stream`.
- [ ] **Step 4:** Line budget check in TB: worst-case fetch (seek + 640 B) finishes in < 1 VGA line (32 µs): assert `busy` low before the next `line_req`. 640 B at 25 MB/s ≈ 25.6 µs + ~0.4 µs command — record the measured margin.
- [ ] **Step 5:** PASS both; commit.

### Task 5: Renderer `bg_mode` for streamed pictures

**Files:**
- Modify: `fpga/rtl/video/line_renderer.v` (add `BG_PIC` mode: background pixel = `pic_stream.rd_rgb`, letterbox colour outside the picture rect, fade factor `fade[3:0]` multiplies RGB for fade-from-black)
- Modify: `fpga/tools/frame_check.py` (frame model learns `BG_PIC` + fade)
- Test: extend `fpga/tb/tb_frame.v` with scene `pic_title` and `pic_fade8`.

**Interfaces:** Consumes Task 4 `pic_stream`. New `bg_mode 5` = full-screen picture 1:1 (src_row = game row, rd_x = game x), with `fade[4:0]` (0..16, 16 = full) scaling the background colour for fade-from-black. Task 7 re-points `bg_mode 1/2` at the same stream. New top-level inputs to `line_renderer`: `pic_rgb[11:0]` and outputs `pic_row_req`, `pic_src_row[9:0]`, `pic_rd_x[9:0]`.

- [ ] Steps: failing frame test → implement → frame-exact PASS → commit.

### Task 6: Stage manager skeleton (screen sequence)

**Files:**
- Modify: `fpga/rtl/top/cpe_escape_top.v` — 3-bit `screen` register: `OPEN → S1 → C12 → S2 → C23 → S3 → END → OPEN`; each stage/screen exposes `exit_req`; placeholder screens OPEN/C12/C23/END show their first picture via `BG_PIC` and exit on BTNC (real behaviour comes in Phase 5).
- Create: `fpga/tb/tb_stage_mgr.v`

- [ ] **Step 1: failing TB:** drive each `exit_req` and assert the sequence above; assert form ≥ 1 after C12 and ≥ 2 after C23 (FA-2); assert BTNC held across a transition fires once (Review Focus 3).
- [ ] **Step 2:** implement; **Step 3:** PASS + `run_tests.sh quick` still at the Task 1 baseline (no new failures); commit.

### Task 7: Move room backgrounds to flash

**Files:**
- Modify: `fpga/tools/asset_convert.py` (stop emitting `bg_s1*.mem` and `bg_s2*.mem`; both rooms are already in `pic_list`), `fpga/rtl/video/line_renderer.v` (remove `u_bg1`, `u_bg2`, `u_p1`, `u_p2`; `bg_mode 1/2` compute `sy` as today and request that source row from the stream, read `sx` via `pic_rd_x`), `fpga/rtl/top/cpe_escape_top.v` (`pic_load` of `PIC_S1_ROOM` / `PIC_S2_ROOM` on stage entry). Ruling R5: both rooms move now (−84 RAMB36), not only bg_s1.
- Test: existing `tb_frame.v` Stage 1 scenes.

- [ ] **Step 1:** Re-baseline: frame-check S1 scenes must be **pixel-identical** to before except the palette change (256-colour vs 64-colour) — first regenerate the reference frames with the new palette in `frame_check.py`, then compare.
- [ ] **Step 2:** implement; **Step 3:** PASS; BRAM delta in `fpga/docs/STATUS.md` memory table; commit.

### Task 8: Flash programming flow + docs

**Files:**
- Create: `fpga/vivado/make_flash.tcl` — `write_cfgmem -format mcs -size 16 -interface SPIx4 -loadbit "up 0x0 cpe_escape.bit" -loaddata "up 0x400000 ../mem/pictures.bin" -file cpe_escape.mcs`
- Modify: `fpga/README.md` (program flash: Hardware Manager → Add Configuration Memory Device `s25fl128sxxxxxx0-spi-x1_x2_x4` → program `.mcs`), `fpga/docs/ARCHITECTURE.md` (memory map), `fpga/docs/STATUS.md` (deviation: crossfades → fade from black).

- [ ] **Step 1:** write both; **Step 2:** **User action:** program the board, power-cycle → title picture appears; record result honestly in STATUS.md; **Step 3:** commit.

---

## Decisions needed from the user (defaults used if no answer)

| # | Question (source) | Default the plan uses |
|---|---|---|
| D1 | Move large pictures to QSPI flash (fade-from-black instead of crossfade; cutscene 1-2 zoom optional) — FA §6 | **Yes, flash streamer** (only option that fits without lowering resolution) |
| D2 | Round 1 yellow card: new code = second P3 hint, STATUS.md said Speed Boost — S1 §6 | **Follow new code (hint)** |
| D3 | Timers decrement twice per tick while walking in Stage 1 (so "10 s" ≈ 5 s) — bug or intended? | **Port as-is** (Pygame is truth), note in STATUS.md |
| D4 | Stage 2 Hard hint crashes Pygame before bench power-on — S2 §6 Q1 | **Treat as "no hint available" toast**, document as the one intentional fix |
| D5 | Board buttons on title/cutscenes/ending: skip / back — FA §9 | BTNC = next, BTNL = back, hold BTNC 0.8 s = skip |
| D6 | SW15 help toggle (physical switch can't be pushed back) | help opens on SW15 rising edge, closes on falling edge or BTNC |
| D7 | Campus Run controls conflict (BTNC = skill, BTND = start/pause) | Use Campus Run's own mapping inside Stage 3 |
| D8 | Ending shows form 2 for a form-3 player (Python) vs generated gold form | **Follow Python** |
