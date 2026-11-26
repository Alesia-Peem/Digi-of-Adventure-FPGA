# Handoff: continue Stage 3 (Campus Run) from a second Claude account

- To push its branch, the other account's GitHub login must be a collaborator on this repo.
- `docs/superpowers/progress-ledger.md` is a snapshot; it may lag behind the main session.
- Phase 0 is not finished: the Task 6 review fix and Tasks 7-8 are still open.

Paste everything in the box into the other account:

````
You are continuing an FPGA game project. Read all of this before doing anything.

## Setup
git clone https://github.com/Alesia-Peem/Digi-of-Adventure-FPGA.git
cd Digi-of-Adventure-FPGA
git checkout port-new-game
git checkout -b stage3-campus-run
Needs Python 3 (pygame, Pillow, numpy) and Icarus Verilog (iverilog -g2005).
Run `python3 -I fpga/tools/pic_pack.py` once to build fpga/mem/pictures.hex.

## Project
"CPE Escape Room x Obby": a Pygame game about KMUTT Computer Engineering students,
being ported to Verilog for a Digilent Nexys A7-100T (xc7a100tcsg324-1), VGA 640x480,
100 MHz. The Pygame code is the source of truth: do not redesign, simplify or remove
gameplay to make hardware easier. demo_py_old/ is outdated.

## Read first, in this order
1. docs/superpowers/plans/2026-11-26-new-game-port-roadmap.md
2. docs/superpowers/progress-ledger.md   (done work and binding rulings)
3. fpga/docs/audit/stage3_audit.md       (your area, with file:line references)
4. fpga/docs/ARCHITECTURE.md             (existing video and game engine)
5. onlystage_3/                          (the game you are porting)

## Your task: Phase 4 only, Stage 3 "Campus Run"
3 levels from Tiled maps, double jump, animals, a reporter who chases the player,
skills, lifts and a milk-tea block. demo_py/stage3_demo.py is only a wrapper.
The existing fpga/rtl/stage3/ implements an older, different game: rewrite, don't patch.

Order of work:
1. Write a detailed plan in docs/superpowers/plans/ from the audit (work items 2-13).
2. List the audit's open decisions (D1-D6) with your recommendation for each, then
   ask me. Already decided: large pictures stream from QSPI flash, and Stage 3 uses
   Campus Run's own button mapping.
3. fpga/tools/cr_assets.py: tiles, maps, collision grid, sprites, previews, BRAM report.
4. fpga/tools/cr_model.py: fixed-point model of physics, enemies, reporter, skills, flow.
5. fpga/rtl/stage3/cr_core.v: the hardware version.
6. Stop before renderer or top-level integration (see ownership).

## Verification (required)
- Python model vs original onlystage_3/game.py, same inputs every step:
  positions within 1 mm, identical events.
- RTL vs Python model: bit-exact on every step.
- Include boundary cases: jump timing, coyote and buffer windows, collisions,
  time-out, deaths, restart, simultaneous buttons, counter overflow.
- Write the test first, see it fail, then implement.
- Put your test commands in a new fpga/run_tests_s3.sh.

## File ownership (another session is working at the same time)
Yours: new cr_* files in fpga/tools, fpga/rtl/stage3, fpga/tb, plus your plan.
Do NOT edit: fpga/rtl/stage1, stage2, video, top, ui, common, fpga/run_tests.sh,
fpga/tools/pic_pack.py, pic_list.py, ui_compile.py, constraints, vivado.
Campus Run will need a scrolling tile background, a new sprite type and backdrops
in the picture list. Do not make those edits: write the exact interface you need in
fpga/docs/stage3_integration_request.md and tell me.

## Rules
- Synthesizable Verilog-2001, one clock domain, no # delays in RTL.
- Never guess asset names or pin numbers; check the files.
- The board has about 135 BRAM36 and the current design is near full. Report your
  BRAM cost and never assume there is room.
- Vivado is not available here. Never claim synthesis, timing or board results.
- Commit often. Push only your branch stage3-campus-run, and ask me before pushing.
- Models: Haiku for easy tasks, Sonnet for medium, Opus for timing-critical RTL.

## How to talk to me
I'm a first-year Computer Engineering student. After each work item, explain briefly
and simply: what you built, its inputs and outputs, how to run the test, the real
test result, and what is still unfinished. If a test fails or you skipped something,
say so.
````

## Merging back
Merge `stage3-campus-run` into `port-new-game` after Phase 0 is finished, then run
`cd fpga && ./run_tests.sh quick` and `./run_tests_s3.sh`.
