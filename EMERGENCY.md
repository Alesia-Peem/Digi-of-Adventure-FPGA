# TAKEOVER: continue this project (start here)

Written 2026-11-27. Check git and the ledger first; they are newer than this file.

## The two work streams

| Stream | Folder on the Mac | Branch | Owner of |
|---|---|---|---|
| Main (Phase 0, then Stages 1-2, cutscenes) | `~/FPGA-Projects/Digi-of-Adventure-FPGA` | `port-new-game` | everything except Stage 3 |
| Stage 3 Campus Run (second account, **still running**) | `~/Digi-of-Adventure-FPGA` | `stage3-campus-run` | `rtl/stage3`, `cr_*` files |

Never work in the other stream's folder or edit its files.
`HANDOFF.md` is the Stage 3 prompt (already given to the second account; do not send it twice).

## State when this was written

- Phase 0 Tasks 1-7: done and reviewed, on GitHub.
- Task 8 (flash script, README steps, STATUS page): files written but **uncommitted**, not reviewed.
  Files: `fpga/vivado/make_flash.tcl` plus edits in README, nexys_a7.xdc, docs, .gitignore.
- After Task 8: one review of the whole Phase 0 branch.
- Stage 3: second account has tools, model and player physics RTL commits, **not pushed to GitHub**.
- Stage 1 and 2 still follow the old game. No Vivado, timing or board result exists.

## For the person taking over

1. **Same Mac (easiest):** nothing to download. Uncommitted work is there.
2. **Another computer:** you only get what was pushed. Ask the owner to commit and push both
   branches first. You need Git, Python 3 (pygame, Pillow, numpy), Icarus Verilog, Claude Code,
   and GitHub collaborator access to push. After cloning: `python3 -I fpga/tools/pic_pack.py`.
3. Open Claude Code in the main folder and paste the prompt below.

````
You are taking over an FPGA project from another Claude session that has stopped.
Folder: ~/FPGA-Projects/Digi-of-Adventure-FPGA (or my clone), branch port-new-game.

Project: "CPE Escape Room x Obby", a Pygame game being ported to Verilog for a Digilent
Nexys A7-100T. Pygame is the source of truth: demo_py/, onlystage_3/, assets/ (not
demo_py_old/). Never remove or simplify gameplay to make hardware easier.

First find the real state, before changing anything:
1. Read EMERGENCY.md.
2. git log --oneline -15, git status, git diff.
3. Ledger: .superpowers/sdd/2026-11-26-new-game-port-roadmap/progress.md
   (other computer: docs/superpowers/progress-ledger.md). It has the binding rulings.
4. Plan: docs/superpowers/plans/2026-11-26-new-game-port-roadmap.md. Task briefs and
   reports are next to the ledger. Audits: fpga/docs/audit/.
Then tell me the state in a few simple lines.

Next work, in order:
1. Task 8: uncommitted changes may be in the tree. Read them, check them against
   task-8-brief.md and ruling R17, test what can be tested, commit. Do not discard them.
   Then have them reviewed.
2. One review of all of Phase 0 (git diff 732a793..HEAD, code only) and fix real findings,
   including the deferred minors in the ledger that matter.
3. Run cd fpga && ./run_tests.sh (full, not quick; it has not been run since Task 5).
4. Then Phase 1 (shared cards, inventory, handoff). Write its detailed plan first.

Another Claude account is working on Stage 3 in ~/Digi-of-Adventure-FPGA, branch
stage3-campus-run. Do not edit that folder, fpga/rtl/stage3 or cr_* files.

Rules: Verilog-2001, one 100 MHz clock, testbenches in fpga/tb/, test before code, review
every task, record decisions in the ledger, commit often, ask me before pushing.
Expected failures: run_tests sections 4 and 5 only. Vivado is not on the Mac: never claim
synthesis, timing or board results. Models: Haiku easy, Sonnet medium, Opus hard.
I'm a first-year student: explain briefly and simply, with real test results.
````

## Only a person can do these
1. Run Vivado on a Windows/Linux PC (commands in `fpga/README.md`), copy
   `util_baseline.txt` and `timing_baseline.txt` into `fpga/docs/audit/`.
2. Program the board and flash. Title picture = good. Stripes = flash not read
   (often the flash quad mode).
3. Answer the second account's Stage 3 questions.
4. When both streams are done, merge `stage3-campus-run` into `port-new-game`, then wire
   Stage 3 into the renderer and top level (see its `fpga/docs/stage3_integration_request.md`).
