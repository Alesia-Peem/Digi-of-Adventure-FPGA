# SDD ledger — plan: docs/superpowers/plans/2026-11-26-new-game-port-roadmap.md
Spec: master prompt (conversation 2026-11-26) + fpga/docs/audit/*.md. User chose: subagent-driven, defaults D1-D8, execute Phase 0 (Tasks 1-8).

## Pre-flight scan
| Pair / task | Produces → consumes | Finding |
|---|---|---|
| T1 | repo sync | done by controller (0835006); baseline in fpga/docs/audit/baseline_failures.md |
| T3 ↔ T4 | flash format → flash model + pic_stream | plan format differed from implemented pic_pack.py → plan text updated to the implemented format (R1) |
| T4 ↔ T5 | pic_stream ports → line_renderer bg_mode 5 | original x_off/screen-line interface cannot serve S2 zoom → whole-source-row interface (R2) |
| T5 ↔ T7 | line_renderer bg path | both edit line_renderer.v; T7 consumes T5's pic ports; sequential, OK |
| T6 ↔ T7 | cpe_escape_top.v | both edit top; sequential, OK |
| T3 ↔ T7 | pic_list rooms → asset_convert | rooms already in pic_list (R3) |
| T2 | user Vivado run | cannot run on Mac; tcl prepared, result pending user (R4) |
| T3 ↔ T8 | PIC_BASE 0x400000 → write_cfgmem | consistent |
| T7 self | "bg_s2 only if needed" | R5: move both rooms now |

Ruling R1: flash format = pic_pack.py docstring — plan text matched to code — cost if wrong: T4 rework only.
Ruling R2: pic_stream fetches whole source rows by index; renderer indexes x — needed for S2 zoom/S1 camera — cost: none known; 640 B/row fits 31.8 µs line.
Ruling R3: S1/S2 rooms live in pic_list from T3 — T7 only does RTL/asset_convert removal.
Ruling R4: T2 delivers report_baseline.tcl + README; utilisation numbers marked "pending user run".
Ruling R5: both room ROMs move to flash in T7 (−84 RAMB36) — master prompt forbids cutting features; BRAM headroom needed for Campus Run — cost: S2 frames depend on flash too.
Ruling R6: frame-check references regenerate with the new 256-colour palettes; S1/S2 frames must stay 0-diff vs the updated Python frame model.

## Progress
Task 1: complete (commits 732a793..0835006, controller inline, verified: puzzles/units/top PASS)
Task 3: implemented inline by controller (0835006..508d36a) — review pending
Task 3: review 1 — spec ✅, quality changes needed: I1 palette floor (//17) darkens; I2 test cannot detect loader fill/smooth mismatch
Task 3: minor (deferred): round-trip test self-referential (header fields/offsets not asserted vs entries)
Task 3: minor (deferred): docstring "256-byte boundaries so a row fetch never needs more than one READ" misleading (rows are not aligned)
Task 3: minor (deferred): packer reads only assets/, game searches ASSET_DIRS
Task 2: implemented (bba71a1..8f325f2) DONE_WITH_CONCERNS: not executable on Mac; STATUS match "*Complete*" unverified — review dispatched
Task 2: complete (commits bba71a1..8f325f2, review clean; Vivado run pending user)
Task 2: minor (deferred): README should say numbers are synthesis-stage (BRAM may shift after impl, timing indicative)
Task 2: minor (deferred): README could point to synth_1/runme.log for debugging
Task 3: fix round 1/5 (2 addressed pending re-review — I1 palette rounding, I2 loader rebuild test; commits 508d36a..dcb76c2)
Task 3: minor (deferred): CUT12/END1-9 smooth flag not checked through their own loaders; (12,14,20) fill never exercised (all 16:9)
Task 4: dispatched (BASE dcb76c2, opus). Rulings: R-a row-buffer invariant = one-line latency + tag-skip; R-b missing stripe in pic_stream, renderer pattern in T5; R-c line budget 3200 clk assert; R-d pic_load in vblank. XDC QSPI pins from Digilent master (K17,K18,L14,M14 / CSN L13) added commented until T7 wires top.
Task 3: fix round 1/5 re-review: 2 addressed, 0 open (commits 508d36a..dcb76c2)
Task 3: complete (commits 0835006..dcb76c2, review clean after 1 fix round)
Task 3: minor (deferred): duplicate PIL import in test_pic_pack.check_loaders; CUT12/END loaders not cross-checked
Task 4: implemented (dcb76c2..21b965f) DONE; concerns: run_tests aborts at sec 4 (baseline), board SCK timing via STARTUPE2 needs constraints+board test (T7), QE bit/latency, 4-bit dq_oe, pic_map.vh include for Vivado sim
Ruling R7: run_tests.sh must not abort at the known-failing S1/S2 cosim sections (baseline_failures.md) — Task 5 implementer makes sections 4-5 report 'EXPECTED FAIL (Phase 2/3)' and continue; any other failure still exits non-zero — cost if wrong: a real S1/S2 regression would be masked until Phase 2/3 (acceptable: those sections already diverge by design).
Ruling R8 (T5 brief self-conflict): fade is 5 bits fade[4:0], 0..16 (16 = full), per the Interfaces block (Files line said [3:0]) — cost: none.
Ruling R9 (T5): rows/cols outside the picture's w×h show bg_color (the plan's "letterbox colour"); missing-flash pattern = pic_stream rd_rgb stripes passed straight through (R-b) — cost: none.
Task 4: review 1 — spec ✅, quality changes needed: I1 tag reset on pic change untested
Ruling R-c2: max picture width 768 B (1024 B row = ~4190 clk > 3200 budget) — assert in pic_pack; Campus Run backdrops 704 fit — cost: wider art must be split
Task 4: minor (deferred → folded into fix round 1): row_req/pic_load during fetch untested; `take` task style
Task 4: minor (deferred): pic_id/src_row not clamped (caller contract); XDC pins/STARTUPE2 delay/inference unverifiable until Vivado+board (Task 7/8)
Task 4: fix round 1 dispatched (resumed implementer)
Task 4: fix round 1/5 (re-review pending; commits 21b965f..eb281bd)
Task 5: dispatched (BASE eb281bd, opus) with R7/R8/R9
Task 4: fix round 1/5 re-review: all addressed, 0 open (commits 21b965f..eb281bd)
Task 4: complete (commits dcb76c2..eb281bd, review clean after 1 fix round)
Task 4: minor (deferred): TB subset-2 rows 356/357 depend on S2_ROOM h=358 without an assert
Task 5: first implementer lost (session restart attempt), no changes left; re-dispatched fresh (BASE eb281bd, opus), told to commit RED/GREEN increments
Task 5: implemented (eb281bd..0798845) DONE; concerns: SIGKILL fallback for hung s2 gen; pic w/h renderer inputs (T6 drives); fade applies in all bg_modes; row_req only in mode 5; S1/S2 frame tests use old stimulus
Ruling R10: top-level pic_stream integration (pic_stream instance, STARTUPE2, 4 IOBUFs, QSPI ports on cpe_escape_top, XDC lines uncommented, per-picture w/h table from pic_map.vh) moves into Task 6 — its placeholder screens need pictures; Task 7 then only re-points bg_mode 1/2 and removes the room ROMs — cost: Task 6 larger.
Ruling R11: Xilinx primitives live only in a new fpga/rtl/video/qspi_io.v: `ifdef SIMULATION` → plain behavioural wires (sck straight out, dq = oe ? o : i), else STARTUPE2(USRCCLKO=sck, USRCCLKTS=0) + IOBUF per DQ; run_tests.sh/Icarus builds pass -DSIMULATION; create_project.tcl must NOT define it — cost: none.
Task 5: complete (commits eb281bd..0798845, review clean)
Task 5: minor (deferred): orphaned sleep in run_tests with_timeout fallback
Task 5: minor (deferred): bg path now mux + 3 small multipliers in one cycle — check post-P&R slack (Task 8/Vivado); move fade to its own ph stage if short
Ruling R12: missing-flash stripes are faded/letterboxed like any picture (accepted, error-state only) — cost: none.
Ruling R13: bg_mode changes into/out of 5 and pic_load happen together in vblank (Task 6 stage manager enforces it).
Ruling R14: stage sequencing extracted into fpga/rtl/top/stage_mgr.v (unit-testable by tb_stage_mgr) and instantiated by cpe_escape_top; old Stage 3 exits on win + BTNC tap (FA-2) — cost: none.
Task 6: dispatched (BASE 0798845, opus) with R10/R11/R13/R14
Ruling R15 (user request 2026-11-26): all remaining subagents (implementers, reviewers, fix rounds incl. rounds 4-5 escalation) use model=sonnet. Task 6 implementer was already running on opus and is left to finish.
Ruling R16 (user request, supersedes R15): model per task by difficulty —
  haiku  = easy: docs, README, tcl/config, mechanical single-file edits with complete text, tiny re-reviews (<~60 diff lines)
  sonnet = medium: Python tools, testbenches, single-module RTL logic, task reviews of medium diffs, fix rounds 1-3
  opus   = hard: timing-critical RTL (line_renderer, scan-out path), cross-module integration (top, tri-state/primitives), reviews of those, fix rounds 4-5
  Always pass the model explicitly. Cost if wrong: haiku takes more turns on multi-step work -> if an easy task bounces twice, move it up one tier.
Applied: T6 review = opus (top integration, qspi_io primitives); T7 impl+review = opus (renderer bg path, frame-exact); T8 impl = haiku, review = sonnet; fix rounds start one tier at the implementer's tier.
Ruling R17 (user message 2026-11-26): (1) keep flash plan (-84 RAMB36, no quality loss); 4 bpp rooms (-28) stays a documented fallback if Vivado/board shows flash streaming fails. (2) Vivado run is a USER action on their Windows/Linux PC after Task 7+8 (script + .mcs ready); never claim results before it. (3) Task 8 also adds an honest "Phase 0 status" section to fpga/docs/STATUS.md: works+simulated / not done (S1,S2 follow old game; S3 old design; title/cutscenes/endings placeholder pictures) / not verified (synthesis, timing, board).
Task 6: implemented (0798845..1e25d34) DONE; review pending. Full non-quick run not done. STARTUPE2/IOBUF need Vivado+board.
Task 6: review 1 — spec ✅, approved with 1 Important: tap released just before vblank switch can skip next screen (stage_mgr held <= !low8). Fix round 1 dispatched (BASE 84f8b1b), incl. run_tests "&& echo" elaboration minor.
Task 6: minor (deferred): demo cmd / s1,s2 exit pulse arriving while change pending is dropped
Task 6: minor (deferred): tb_stage_mgr GT_PER<<VB_PER unrealistic (addressed partly by new case); xsim sim_1 globs tb_top_pic without SIMULATION
Task 6: fix round 1/5 re-review: 2 addressed, 0 open (17861c1..54b526a)
Task 6: complete (commits 0798845..54b526a, review clean after 1 fix round)
Task 7: dispatched (BASE 54b526a, opus)
Snapshot pushed on user request; Task 7 commits (4773d6d, 028f543) pushed UNREVIEWED.
