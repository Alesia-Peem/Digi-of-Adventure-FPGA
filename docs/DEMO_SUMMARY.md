# CPE Escape Room × Obby: FPGA port status (27 November 2026)

## In one paragraph

We are porting our Pygame game to Verilog for the Digilent Nexys A7-100T with VGA output. The game
was updated during the project, and **the FPGA version has not caught up**. The FPGA design plays the
**earlier version** of Stages 1, 2 and 3, joined by single still pictures. Everything below was tested
in **simulation only** (Icarus Verilog). It has not yet been synthesised in Vivado or run on the board.

## What works (in simulation)

| Part | Detail |
|---|---|
| Screen order | Title → Stage 1 → picture → Stage 2 → picture → Stage 3 → ending picture → Title |
| Stage 1, Final Exam (earlier version) | Movement, collision, camera, puzzles, cards, inventory, item effects, hearts, door password |
| Stage 2, Internship (earlier version) | Its puzzles and circuit wiring, using the board's buttons and switches instead of a mouse |
| Stage 3, Graduation obby (earlier version) | Obstacle course with its physics and screens |
| Shared features | 4 character forms, random cards, hearts, demo menu (SW12) |
| VGA graphics | 640×480 output; the screen frames we test match our Python model pixel for pixel |
| Large pictures | Read from the board's flash chip, because they do not fit in the FPGA's block memory |
| Missing flash data | Shows stripes and a red LED instead of a picture |

Stage 1 and Stage 2 game logic was compared with the earlier Pygame version tick by tick on
20 November. That comparison has not been repeated since the later changes. Stage 3 logic matches our
fixed-point Python model bit for bit, and the model stays within 2 mm of the earlier Pygame version.

## What is not done

| Part | Status |
|---|---|
| Stage 1 and 2 changes from the latest game | Not started. Our tests against the latest game fail, as expected |
| New Stage 3, "Campus Run" | Game logic and graphics data are on a separate branch (`stage3-campus-run`). It is **not drawn on screen and not connected** to the board design |
| Title, cutscenes, ending | One still picture each: no animation, no other slides, no fades |

## What is not verified

- No Vivado synthesis, timing result or bitstream.
- No test on the real board: VGA output, buttons, flash programming and flash reading are untested.
- Block memory use is estimated at about 49 of 135 blocks. This is not a measured figure.

## Controls on the board

| Control | Action |
|---|---|
| BTNC | Next picture; in a stage, interact or confirm (hold 0.8 s to go back) |
| BTNU, BTND, BTNL, BTNR | Move |
| SW0–SW7 | Puzzle inputs |
| SW12 | Demo menu (jump to checkpoints, set hearts or character form) |
| SW14 | Notebook |

## Why it is not finished

- The game changed while the port was in progress.
- Two room pictures alone needed more block memory than the chip could spare, so picture loading had to
  be redesigned to use the flash chip.
- Vivado does not run on the Mac we developed on, so work could only be checked in simulation.

## Next steps

1. Build in Vivado and test on the board.
2. Update Stage 1 and 2 to the latest game.
3. Connect Campus Run to the screen and controls.
4. Add the animated title, cutscenes and endings.

## Board test results (fill in after testing, delete anything not tried)

| Check | Result |
|---|---|
| Vivado builds a bitstream | |
| Timing met | |
| Block memory used | |
| Title picture appears from flash | |
| Stage 1 playable | |
| Stage 2 playable | |
| Stage 3 playable | |
