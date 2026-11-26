# Emergency handoff: if the main account runs out of usage before the work is finished

This is for continuing the **main** work. `HANDOFF.md` is different: it is the Stage 3 side task.

## First, if the new account is on ANOTHER computer

Run these in a terminal (no Claude needed), after checking that no agent is still working:

```bash
cd ~/FPGA-Projects/Digi-of-Adventure-FPGA
cp .superpowers/sdd/2026-11-26-new-game-port-roadmap/progress.md docs/superpowers/progress-ledger.md
git add docs/superpowers/progress-ledger.md EMERGENCY.md
git commit -m "docs: emergency handoff snapshot"
git push origin port-new-game
```

The repo is public. On the same Mac, skip this: the new account can use the folder directly.

## Prompt to paste

````
You are taking over an FPGA project from another Claude session that ran out of usage.

## Where it is
Same Mac: ~/FPGA-Projects/Digi-of-Adventure-FPGA (branch port-new-game). The old session
is stopped, so you may work in this folder.
Other computer: git clone https://github.com/Alesia-Peem/Digi-of-Adventure-FPGA.git,
git checkout port-new-game, then `python3 -I fpga/tools/pic_pack.py`.
Needs Python 3 (pygame, Pillow, numpy) and Icarus Verilog.

## Project
"CPE Escape Room x Obby", a Pygame game being ported to Verilog for a Digilent
Nexys A7-100T. Pygame is the source of truth: demo_py/, onlystage_3/, assets/
(not demo_py_old/). Never remove or simplify gameplay to make hardware easier.

## Find out the real state before doing anything
1. git log --oneline -15, git status  (finished or half-finished work)
2. Ledger: .superpowers/sdd/2026-11-26-new-game-port-roadmap/progress.md
   (other computer: docs/superpowers/progress-ledger.md). Trust it and git over
   anything written here. It holds rulings R1-R17+ and deferred minor findings.
3. Plan: docs/superpowers/plans/2026-11-26-new-game-port-roadmap.md
4. Reports: task-N-report.md next to the ledger. Audits: fpga/docs/audit/.
If there are uncommitted changes, read them and test them. Do not discard them
without asking me.

## State when this was written
- Phase 0 Tasks 1-6: complete and reviewed.
- Task 7 (rooms streamed from flash): test and implementation committed
  (4773d6d, 028f543), final tests were still running, NOT reviewed.
- Task 8 (fpga/vivado/make_flash.tcl for the .mcs, flash programming steps in
  fpga/README.md, memory map, and an honest "Phase 0 status" section in
  fpga/docs/STATUS.md: works+simulated / not done / not verified): not started.
- Then: one whole-branch review of Phase 0.
- Then Phases 1-6 in the roadmap. Each needs its own detailed plan first.
- Stage 3 may be in progress by another session on branch stage3-campus-run
  (see HANDOFF.md). Ask me before touching fpga/rtl/stage3 or cr_* files.

## How to work
- Finish Task 7: run `cd fpga && ./run_tests.sh quick` and the Stage 1/2 frame
  checks, then review the diff 54b526a..HEAD against task-7-brief.md. Then Task 8.
- Expected failures: run_tests sections 4 and 5 (old tests vs new game,
  fixed in Phases 2 and 3). Any other failure is real.
- One implementer at a time. Test first. Review every task. Record decisions in
  the ledger. Commit often.
- Models: Haiku for easy tasks, Sonnet for medium, Opus for hard or
  timing-critical RTL. Use as little as you can while staying correct.
- Verilog-2001, synthesizable, one 100 MHz clock, testbenches in fpga/tb/.
- Ask me before pushing.
- Vivado is not on the Mac. I run it on my Windows/Linux PC. Never claim
  synthesis, timing or board results.

## Talking to me
I'm a first-year Computer Engineering student. Explain briefly and simply, give
real test results, and say clearly what is not finished.
````

## What only a person can do
- Run Vivado: `fpga/vivado/create_project.tcl`, then `fpga/vivado/report_baseline.tcl`
  (commands in `fpga/README.md`). Do this after Task 8.
- Program the board and test it.
