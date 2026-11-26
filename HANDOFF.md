# Handoff: continue Stage 3 (Campus Run) from a second Claude account

## Before starting
- `git clone https://github.com/Alesia-Peem/Digi-of-Adventure-FPGA.git`, then `git checkout port-new-game`.
- The progress ledger is committed as a snapshot: `docs/superpowers/progress-ledger.md`.
- Install Python 3 (pygame, Pillow, numpy) and Icarus Verilog, then run
  `python3 -I fpga/tools/pic_pack.py` to rebuild the git-ignored `fpga/mem/pictures.hex`.
- Phase 0 Task 6 is committed but **not yet reviewed**; Tasks 7-8 are not started.

## Limits
- There is no detailed Phase 4 plan yet; the roadmap only details Phase 0.
- Campus Run needs renderer changes (`fpga/rtl/video/line_renderer.v`: scrolling tile background,
  new sprite type). Those wait until Phase 0 is merged.
- Stage 3 has open decisions D1-D6 in `fpga/docs/audit/stage3_audit.md`.
- Vivado is not installed on the Mac. Nothing is verified by synthesis, timing or on the board.

## Prompt to paste into the other account

```
Clone https://github.com/Alesia-Peem/Digi-of-Adventure-FPGA.git and check out branch port-new-game.
I'm continuing an FPGA port of a Pygame game (KMUTT CPE Escape Room x Obby) to a
Digilent Nexys A7-100T in Verilog.

Read in this order:
1. docs/superpowers/plans/2026-11-26-new-game-port-roadmap.md
2. docs/superpowers/progress-ledger.md (what is done, rulings)
3. fpga/docs/audit/stage3_audit.md (your area)

Your task: Stage 3 "Campus Run" only. onlystage_3/ is the source of truth, not
demo_py_old/. Create branch stage3-campus-run. First write a detailed plan for
Phase 4 from the audit, and ask me about its open decisions (D1-D6). Then start
with the Python tools: cr_assets.py, then cr_model.py (physics), each tested
against the original game.py.

Another session owns rtl/stage1, rtl/stage2, rtl/video and rtl/top. Do not edit
them. If you need a renderer change, stop and tell me.

Rules: Verilog-2001, testbenches in fpga/tb/, test before code, commit often.
Pygame is the source of truth for gameplay. Vivado is not available on this Mac,
so never claim synthesis, timing or board results. Use Haiku for easy tasks,
Sonnet for medium, Opus for hard timing-critical RTL.
```

## Merging back
Merge `stage3-campus-run` into `port-new-game` after Phase 0 is finished, then run
`cd fpga && ./run_tests.sh quick`.
