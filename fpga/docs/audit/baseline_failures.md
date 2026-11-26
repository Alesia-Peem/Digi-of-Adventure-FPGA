# Baseline after importing the NEW game (Phase 0, Task 1) - 2026-11-26

Old Verilog + old test scenarios, run against the NEW authoritative Pygame (`demo_py/`, `onlystage_3/`).

| Check | Result | Why (expected) | Fixed in |
|---|---|---|---|
| `verify_puzzles.py` | PASS | answers unchanged (A=6, B=7, C=5, CPE, 69, 17865) | - |
| `tb_units` (shared modules) | PASS | not tied to Pygame | - |
| full top elaborates | PASS | | - |
| `cosim_s1.py gen` (scenario `full`) | FAIL before tick 1 of the compare: `AssertionError: no card round open` at `cosim_s1.py:157` | NEW Stage 1 shows a 3-line TA intro before round 1; the old script presses for a card that is not there yet | Phase 2 (S1-#2 rewrite scenarios) |
| `cosim_s2.py gen` | HANGS (killed after > 5 min) | NEW Stage 2 has no round-1 card round (career now comes from Stage 1); the old script waits for it forever | Phase 3 (S2-#14) |
| Stage 3 cosim / frames | not re-run: still compared against `demo_py_old` (old Stage 3 is replaced by Campus Run in Phase 4) | | Phase 4 |

The old full regression (before the import) passed completely, including every VGA frame (0 differing pixels).
