# Stage 1 audit: new Pygame vs Verilog port

Date: 2026-11-26. This audit only reads files. The only file written is this report.

Abbreviations used for citations:

* **O:** `Digi-of-Adventure-FPGA/demo_py/stage1_demo.py`, the OLD Pygame that the port was co-simulated against (1172 lines)
* **N:** `drive_assets/Digi-of-Adventure-main/demo_py/stage1_demo.py`, the NEW Pygame and the source of truth (1501 lines)
* **T:** `drive_assets/Digi-of-Adventure-main/demo_py/stage1_test.py`
* **core:** `fpga/rtl/stage1/s1_core.v`, **col:** `fpga/rtl/stage1/s1_collision.v`, **deck:** `fpga/rtl/common/card_deck.v`, **inv:** `fpga/rtl/common/inventory.v`
* **scr:** `fpga/tools/ui_screens.py`, **spec:** `fpga/tools/ui_spec.py`, **cos:** `fpga/tools/cosim_s1.py`, **tbc:** `fpga/tb/tb_s1_cosim.v`

Which file is the real Stage 1: `demo_hub.py` REGISTRY loads `("Stage 1", "stage1_demo", "Game")` (new demo_hub.py:26). `open.py` only sets a flag `go_stage1` (open.py:131,164) and imports no stage. Nothing imports `stage1_test.py` (grep over the whole new tree). **`stage1_demo.py` is the authoritative file.** `stage1_test.py` is an earlier snapshot that sits between OLD and NEW:

* It already has: answer validation with CORRECT/INCORRECT feedback, "Laptop 1/2" names, BTNR confirm on the paper, and round 1 = HINT_HARD twice (T:78).
* It does not yet have: the TA intro, the notebook guide, `card_backs` / career in the handoff, the P4-only Undo, the frozen-player Freeze, Slow x0.1, the second timer decrement, or the new geometry. In T, Freeze is still 5 s and laptop3 r = 190 (T:584,597; diff output).

Ignore T.

---

## 1) Summary

* **Puzzles now give feedback (largest change).** In OLD, every confirm was recorded, right or wrong, and `right[]` held a hidden truth (O:491-496). In NEW, `commit()` accepts only correct answers (N:580-616).
  * A wrong answer changes nothing except a red "INCORRECT! ..." message and a toast.
  * The notebook can now only hold correct values: A=6, B=7, C=5.
  * The RTL still records wrong answers (core:293-301, 463-535). It is **WRONG** for all 5 puzzles.
* **New gameplay gates that block `update()`:**
  * A 3-line TA intro dialogue at every full stage start. The card round does not open until it is finished (N:652-661).
  * A one-time "ANSWER SAVED TO NOTEBOOK - flip SW14" overlay. It appears after the first correct P1, P3 or P4 and freezes the game until SW14 is on (N:610-611, 662-668).
  * The RTL has neither (**MISSING**).
* **Controls changed:**
  * P2 paper: BTNU/BTND pick the slot, BTNR confirms. Clear-on-BTND is gone (N:777-820).
  * P5 PC login: BTNL/BTNR pick the box, BTNU = letter-1, BTND = letter+1 (N:879-891).
  * The RTL uses the OLD mapping (core:471-489, 516-535). **WRONG.**
* **Card and item rules changed:**
  * Round 1 yellow = HINT_HARD (was BOOST; N:89).
  * FREEZE = the player is frozen for 10 s (was 5 s, no effect; N:100, 563, 692-693).
  * SLOW = x0.1 speed (was x0.5; N:695).
  * UNDO now always undoes **Puzzle 4** (N:537-544).
  * Slow and Freeze timers are decremented **twice per tick in map mode** (N:677-678 and 685-686), so 10 s lasts 5 s while walking.
  * RTL status: card_deck, inventory and the s1_core undo are **WRONG**. Round 1 cannot simply be edited in `card_deck.v`, because `s2_core` shares it.
* **Geometry:**
  * Low-cabinet blocker width 200 → 160 (N:69).
  * Laptop 1 radius 190 → 160 (N:126).
  * Teacher PC anchor y 620 → 650 (N:129).
  * The RTL has the old numbers (col:42, core:82, core:85, scr:46,51). **WRONG.**
* **Puzzle answers and door codes are unchanged and re-verified:** A=6, B=7, C=5, password CPE (unique solution of the 5 projector clues), lock 1 = 69, lock 2 = 17865 (section 3). The RTL constants (core:62-69) are **OK**.
* **New screens and assets:**
  * TA NPC drawn in the room at (1210,395) with depth sorting (N:944-952, 1043-1057).
  * Intro dialogue box with portrait (N:954-982).
  * "[SEARCH : NAME]" label above the player near any object. This needs `find_near()` every tick (N:984-1023).
  * Projector clues drawn as app-logo images (N:1212-1257).
  * Revealed round 2/3 cards show item art `<career>_<item>.png` (new card_assets.py `get_image`).
  * The sprite ROM has 1 free slot of 64 (asset_convert.py:15-21) and BRAM is estimated at about 132 of 135 (ARCHITECTURE.md:54-66). **This needs a decision.**
* **Handoff and demo hooks:**
  * `get_handoff()` now also returns `career` and `card_backs` (the slot positions picked in rounds 2 and 3), padded with LFSR picks (N:327-342). Stage 2 reads them (new stage2_demo.py:640-642). The RTL has no such ports (core:862-865). **MISSING.**
  * `jump_to` keeps the career and defaults it to EARTH (1) instead of AIR (0) (N:384-391). **WRONG.**
  * `door_wrong` now types 99999 at the door instead of poisoning the notebook (N:420-422). **WRONG.**
* **SW15 = Help toggle.** Help is open at power-on, SW15 shows/hides it, and tap/back closes it (N:265-266, 435-436, 454-456, 647-651). **MISSING** in the RTL. A physical switch cannot be "set back to 0" by the game (open question 3).
* **Verification is out of date.**
  * `cosim_s1.py` imports `demo_py/` from the FPGA repo, which holds the OLD file (cos:23). The new file must be copied in before any cosim.
  * All 3 scenarios will diverge: help, then the intro taps, the P2/P5 key changes, and the `items` scenario relies on wrong answers being recorded (cos:315-318).
  * The trace does not capture the new state: intro, notebook guide, feedback/cmsg, card_backs, near object (cos:93-105, tbc:72-76).

---

## 2) Change table

Status: OK = RTL already matches NEW · WRONG = RTL implements the OLD behaviour · MISSING = no RTL at all. Effort: S < half a day, M = 1-2 days, L > 2 days (port plus cosim).

### 2.1 Gameplay flow / state machine

| # | Change | Old | New | RTL file:line affected | Status | Effort |
|---|---|---|---|---|---|---|
| F1 | Intro dialogue (TA, 3 lines: "Hey! Our Final Exam in Room CPE1119 is starting right now." / "To pass the exam, you must solve all 5 puzzles around the classroom to uncover the password for the exit door." / "Good luck!") | none | `intro_idx = 0` on `reset_stage(True)`, `None` on a death restart (N:282). In `update()` after help: sprite stop; back = skip all; tap = next / close; `return` (N:652-661). Round 1 cards only open after it. | core:370-386 (Q_TOP), core:302-323 (reset_stage), core:353-354 (enter) | MISSING | M |
| F2 | Notebook guide gate | none | After the first correct commit of P1, P3 or P4 (i in 0,2,3), `notebook_guide_pending=1` (N:610-611). `update()` returns (timers and cards frozen) until `sw[14]` is 1, then sets `seen=1` and continues in the same tick (N:662-668). `seen` is reset by every `reset_stage` (N:285-286). | core:370-386, core:293-301 | MISSING | S |
| F3 | Order of `update()` | lfsr x7, flash, help, clear, over, timers, cards, sw14, map/closeup (O:524-547) | lfsr x7, flash, help (also sets sw15=0), **intro**, **nb-guide**, clear, over, timers, cards, sw14, map (**timers again**) / closeup (N:644-689) | core:357-415 | WRONG | M (with F1, F2, I6) |
| F4 | Help open/close via SW15 | help at start; H key toggles (O:368) | `sw[15]=True` and help shown at init (N:265-266,271). Toggling SW15 sets `show_help = sw[15]` (N:435-436, 454-456). tap/back closes and sets `sw[15]=False` (N:647-651). Hub `start()` sets both False (N:322-325). | core:144, 351, 354, 374-375; top cpe_escape_top.v:68-81 | MISSING (reopen) | S + decision (Q3) |
| F5 | Standalone replay after clear | `reset_stage(True)`, no intro existed | the same call now replays the intro (`intro_idx=0`) (N:669-672, 282) | tbc:17-19 re-enter; core:353-354 | MISSING (via F1) | S |
| F6 | Feedback reset on SW0-7 change | none | In the whiteboard/paper/laptop-2 close-ups, any switch change clears `cmsg` and `feedback` (N:437-438 mouse = any SW; N:451-452 keys = SW0-7) | core (no switch-edge detector) | MISSING | S |
| F7 | Entering a close-up resets feedback | n/a | `self.feedback = None` (N:726) | core:451 | MISSING (with P0) | S |

### 2.2 Map / collision / objects

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| G1 | Low cabinet blocker | `Rect(100,880,200,125)` (O:58) | `Rect(100,880,160,125)` (N:69) | col:42; scr:46 (debug view) | WRONG | S |
| G2 | Laptop 1 (`laptop3`) interaction radius | r=190, name "Laptop" (O:115) | r=160, name "Laptop 1" (N:126) | core:85 (`obj_r` 190); spec:82 (OBJ "LAPTOP") | WRONG | S |
| G3 | Laptop 2 (`laptop4`) name | "Laptop" | "Laptop 2" (N:127) | spec:82 | WRONG | S |
| G4 | Teacher PC anchor | (1540,620) (O:118) | (1540,650) (N:129) | core:82 (`obj_ay` 620); scr:51 (debug anchors) | WRONG | S |
| G5 | Floor trapezoid, other blockers, SPAWN, other objects, `find_near` (+30 px for form≥1) | — | unchanged (N:61-75, 123-132, 704-711) | col:15-46, core:76-87, 264-267 | OK | — |
| G6 | TA NPC in the world | none | Drawn every map frame at GUIDE_POS (1210,395), feet at y+4, height SPR_H·ZOOM. Behind the player if 395 ≤ py, else in front (N:944-952, 1043-1057). No collision, not interactive (BLOCKERS unchanged, not in OBJS). | scr:34-41 draw_world; spr.mem slot | MISSING | M (asset) |
| G7 | "[SEARCH : NAME]" prompt | none | In map mode when `find_near()` is not None and the intro is off. f_tiny on a black box at alpha 155, centred above the sprite (`player_y - img_h - 8`), drawn after the dark overlay. Names: WHITEBOARD, PAPER, LAPTOP 1, LAPTOP 2, PROJECTOR SCREEN, TEACHER COMPUTER, LIGHT SWITCH, EXIT DOOR (N:984-1023, 1062). | core:431 (find_near only on tap); spec:41 has an unused `NEAR_OBJ` cond | MISSING | M |

### 2.3 Puzzles / close-ups

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| P0 | `commit()` semantics | Always `done=1`, `right=correct`, stores the value, note "Px answer entered", toast "Notebook updated!" (O:491-496, 616, 641, 657, 666, 689) | **wrong**: `right` stays as is, `feedback=False`, `cmsg="INCORRECT! "+wrong_msg`, toast "Incorrect - try again"; done, value and notes untouched. **correct**: stores the value, `done=right=1`, appends the note if it is new, `cmsg="CORRECT! "+msg`, toast "Puzzle %d correct - saved to Notebook" (N:580-616) | core:293-301 commit; 466-468, 485-486, 500-502, 508-510, 530-534 | WRONG | M |
| P1 | Whiteboard (base conversion) | ROOM 402, value recorded even if wrong | Title "ROOM CPE1119 - FINAL EXAM" (N:1115). Value accepted only if = 6. Messages: "The base-conversion answer is correct. Puzzle 1 is complete." / "The base-conversion answer is incorrect. Check your calculation and try again.". Note "P1 correct answer: A = %d" (N:755-768). | core:463-470; scr:100; spec:63-68,85 | WRONG | S |
| P2 | Paper (K-map), controls | L/R slot, tap store "Stored in T%d.", D clear "T%d cleared.", U confirm (O:620-642) | U/D slot (wrap 3), tap store "Stored in Term%d. Continue setting the other terms, then press BTNR to check." (neutral colour), **R confirm**, no clear, L does nothing. Empty: "INCORRECT! No terms have been stored yet. Please create your K-map expression first." (feedback=False, **no toast**). Accept: `p2_table==0xF888` and ≤4 literals. `p2_eq` is rewritten **before** commit, even when wrong (N:807). Messages: "Your K-map expression is correct. You can use this to solve the next puzzle." / "Your K-map expression is not correct. Check your variables and terms, then try again.". Note "P2 correct answer: F = "+eq (N:771-820). | core:471-489; scr:163 ("T%d:"), 306 footer; spec:63-68 (CMSG STORED/CLEARED/NOTERM) | WRONG | M |
| P2b | Paper texts | "rows: A B      columns: C D", "T%d:" | "rows: A B    columns: C D    Do it in terms of SOP" (N:1151), "Term%d:  " (N:1163), footer "BTNU/BTND slot \| BTNC store \| BTNR confirm answer" (N:1169) | scr:153, 163, 306 | WRONG | S |
| P3 | Laptop 1 (NAND) | value B = popcount of any circuit | B stored only when the truth table = 0xF888 (so always 7). Messages: "The NAND circuit produces the correct truth table. Puzzle 3 is complete." / "The NAND circuit output does not match the required truth table. Check the connections and try again.". Note "P3 correct circuit: NAND-only output matches the K-map." (N:838-848). Page-0 text "Task: Build F from puzzle on cabinet as a", "Constraint: 74HC00 quad NAND gates only. G(n) = Gate(n)" (N:1177-1179). Footer "BTNL/BTNR field \| BTNU/BTND source \| BTNC save circuit" (N:1192). Editor keys unchanged. | core:490-504; scr:180-181, 308 | WRONG | S |
| P4 | Laptop 2 (two's complement) | any value recorded | Accept only 0b11110100. Messages: "The two's-complement value is correct. Puzzle 4 is complete." / "The binary value is incorrect. Check the two's-complement conversion and try again.". Note "P4 correct answer: 11110100 (unsigned 244 / signed -12)." (N:851-864). Footer "ANSWER: set SW7-SW0, then BTNC" (N:1210). | core:505-512; scr:309 (footer already OK) | WRONG | S |
| P5 | Teacher PC login, controls and text | U/D box, L/R letter (R=+1), wrong → "Incorrect passcode. Attempt logged." plus a note per attempt (O:677-694) | L/R box, **U = letter-1, D = letter+1** (N:879-891). Wrong → "INCORRECT! ACCESS DENIED. The passcode is incorrect. Check the letters and try again.", no note. Right → "CORRECT! ACCESS GRANTED. The login passcode is correct. Puzzle 5 is complete.", note "P5 correct login passcode: CPE", page=0 (N:892-902). Each L/R/U/D clears feedback. Footers: login "BTNU/BTND letter (A-Z) \| BTNL/BTNR box \| BTNC enter"; page 0 "BTNU/BTND or BTNC: open file"; pages 1-2 "BTNU/BTND: page" (N:1290-1307). | core:516-535, 640-642 (l26); scr:313-314; spec:66 | WRONG | S |
| P5b | Door manual page 2 | "B = report code from cabinet + laptop 1", "C = receipt code from laptop 2" (O:981) | "... laptop 1 (Number of bit 1)", "... laptop 2 (Number of bit 1)" (N:1302) | scr:287-288 | WRONG | S |
| P6 | Projector | names as text, header "Correct Pos", footer when dark "Turn off room lights to view clearly" (O:922-939) | Same 5 clue rows, but drawn as 22×22 logo images `app_logo_*.png` (text fallback only if the file is missing). Header "Correct Positions". Dark-mode footer "Use the 3-app code " (N:1212-1260). | scr:219-240, 310 | WRONG (text) / MISSING (logos) | S text, M-L logos |
| P7 | Door (2 locks) | — | Logic unchanged (N:630-642, 904-911). Footer "BTNU/BTND digit \| BTNL/BTNR box \| BTNC confirm" (N:1277). Door messages stay gold (feedback is None on entry). | core:536-553 OK; scr:312 footer | OK logic / WRONG footer | S |
| P8 | Close-up chrome | "Back: hold Space (BTNC) or press Esc" (O:796), cmsg always gold | "Back: hold BTNC for 0.8 s" (N:1097). cmsg colour: green (110,255,145) if correct, red (255,105,105) if incorrect, gold otherwise (N:1091-1094), max 2 wrapped lines | scr:83-93 (single colour CMSG, U(440) one line + suffix) | WRONG | M (colour + 2-line wrap) |
| P9 | Close-up titles | "LAPTOP" ×2 | "LAPTOP 1", "LAPTOP 2" (from Obj names N:126-127) | spec:82 | WRONG | S |

### 2.4 Hearts / door / items / cards / timers

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| H1 | Hearts / armor / door damage, OUT OF HEARTS 3 s and restart | — | unchanged (N:618-628, 674-676) | core:197-201, 378-381, 628-633; heart_system.v | OK | — |
| C1 | Card round 1 items | green HINT_HARD, yellow **BOOST**, red ARMOR (O:78; the FPGA team's decision STATUS.md §2.1) | green HINT_HARD, yellow **HINT_HARD**, red ARMOR (N:87-91) | deck:8, 51 (`item_of` round 1). `card_deck` is also used by `s2_core` (s2_core.v:106), so this needs a per-instance item table | WRONG | S-M |
| C2 | Card rounds 2/3 items, triggers (≥3 done, ==5 done), shuffle, cursor | — | unchanged (N:89-91, 483-503) | core:388-403; deck | OK | — |
| C3 | Card pick records slot | none | rounds 2/3: `card_backs.append(cursor)` (N:513); cleared by `reset_stage` | core (no register) | MISSING | S |
| C4 | Revealed round 2/3 card art | card back + item-name strip (O:1018-1022) | `get_image` tries `<career>_<item>.png`, then `<item>.png`, then the card back (new card_assets.py `get_image`). The name strip is gone; the name only shows when there is no art at all (N:1327-1338) | core:679-681, 735-737 (cimg); scr:371-374 (strip) | WRONG / MISSING art | M + BRAM (Q4) |
| C5 | "Obtained" box | box (60,300,520,110), title f_m y308, desc wrap 490 at y340 (O:1027-1031) | box (80,300,480,110), title **f_l** y306, desc wrap 440 at y350 (N:1343-1348). Hint "BTNL/BTNR choose   BTNC pick" (N:1350) | scr:376-381 | WRONG | S |
| I1 | FREEZE | `freeze_t=5.0`, only a HUD timer (O:478, 89) | `freeze_t=10.0`; `speed()` returns 0 while active (N:563, 692-693). Text "You are frozen in place for 10 seconds." (N:100) | inv:75 (300 frames), inv:36 width `[8:0]` (max 511 < 600); core:222-224 (speed ignores freeze); spec:79 | WRONG | S |
| I2 | SLOW | x0.5 (O:551) | x0.1 (N:695): 0.6 px/tick for form 0, **0.72** px/tick for form≥1. 0.72 does not fit the int+tenths position format | core:12-13, 222-224, 229-239 (tenths) | WRONG | S (form 0) / M (hundredths for form≥1) |
| I3 | UNDO | restores the last commit record, any puzzle (O:449-458) | If `done[3]`: `ans C=None`, `done[3]=right[3]=0`, removes notes starting "P4 ", text "Puzzle 4 was undone. Solve it again!". Else "Nothing to undo right now." (N:537-544). Round 3 only opens at 5/5 done, so in normal play it **always** undoes P4. | core:610-619; spec:74-76 (U1..U5) | WRONG | S |
| I4 | HINT_SMART | P5 first, then first not-right of P3,P2,P1,P4 | Same code (N:525-531). Since `right` now only becomes 1 on a correct answer, `right == done` in practice | core:241-243 | OK | — |
| I5 | SHARD / ARMOR / forge | — | unchanged (N:558-572) | inv:68-74 | OK | — |
| I6 | Timer decrement | once per tick in play (O:538-539) | once per tick in play (N:677-678) **plus once more** when the map branch runs (no deck, SW14 off, map mode) (N:684-687). `speed()` sees both decrements. Checked: a float `10.0 - k·dt` reaches 0 after exactly 600 single or 300 double ticks, so frame counters stay exact. | core:383 (inv_tick once), 405-415; inv:57-60 | WRONG | S-M (see work item 6) |
| I7 | BOOST | reachable via round 1 yellow | no longer reachable in Stage 1. `inv["boost"]` stays False (ITEM_TEXT BOOST is unused) | core:621; deck | follows C1 | — |

### 2.5 UI texts / screens

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| U1 | HOW TO PLAY rows | keyboard wording (O:1057-1068) | Move "BTNU / BTND / BTNL / BTNR"; Interact / confirm "BTNC (tap)"; Back "BTNC (hold for 0.8 s)"; Puzzle inputs "SW0-SW7"; Notebook "SW14 (toggle)"; Help "SW15 (toggle)". Sentence "Approach an object and press BTNC. If nothing happens, it is scenery." at y=330. Prompt "BTNC: start" (N:1379-1393) | scr:407-421 (own wording, plus a "Demo tools SW12" row) | WRONG | S |
| U2 | Notebook | title "(SW14 / key N to close)" | "NOTEBOOK  (SW14 to close)" (N:1358). New note texts (P1-P5 above). Notes are deduplicated and each is wrapped with `blit_wrap` at 480 px (N:1363) | scr:327-357 (title already OK; one fixed 13-px line per note); spec:85-86 | WRONG (notes) | M |
| U3 | Notebook guide overlay | none | dark alpha 205. Box (48,165,544,190): "ANSWER SAVED TO NOTEBOOK" (f_l, green), "Your correct answer has been recorded.", "Flip SW14 to open the Notebook and view it." (gold), "Gameplay will continue after you open it." (N:1369-1377). Drawn when pending and SW14 is off, after cards and intro (N:1461-1462) | scr:424-442 | MISSING | S |
| U4 | Intro talk box | none | Box (40,392,880,128) fill (14,18,28,α232), gold 2-px border. Portrait box 100×100 at (56,406). "TA" f_m gold at (174,404). Line wrapped at 726 px, lh 24. "n / 3" at the bottom left. "BTNC: next >>" (blue) or "BTNC: start exam >>" (green, last line) at the bottom right (N:954-982) | scr | MISSING | M |
| U5 | Toasts | "Notebook updated!" | "Puzzle %d correct - saved to Notebook", "Incorrect - try again" (N:592, 615). The rest unchanged | spec:57-61 | WRONG | S |
| U6 | Draw order | world, hud, notebook, cards, flash, over, clear, toast, help | ..., cards, **intro**, **nb-guide**, flash, ... (N:1451-1479) | scr:424-435 | WRONG | S |
| U7 | HUD, 7-seg, LEDs, clear and over screens | — | unchanged (N:1395-1449, 1465-1475) | core:810-859; scr:59-74, 384-397 | OK | — |

### 2.6 Handoff / demo hooks

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| D1 | `get_handoff()` | hearts, form, armor, boost, shards (O:262-264) | + `career`, + `card_backs` (2 slot indices). If fewer than 2 were picked (e.g. the door is opened without rounds 2/3, which is possible because the door codes are constants), the list is padded with `lfsr_step(); v = lfsr & 7; if v < 3` (N:327-342). This **advances the LFSR** | core:26-33, 862-865; top cpe_escape_top.v:102-120 | MISSING | M (needs an s2_core input too) |
| D2 | `jump_to` career | `career = 0` after the auto-answers (O:316); start/clear leave career None | `career = current or 1` and kept for **every** key, including start and clear (N:383-393) | core:561-573 (`dk_setcv <= 0`, only for r2/r3/door) | WRONG | S |
| D3 | `jump_to` card_backs | n/a | r3 keeps `prev[:1]`, door and clear keep `prev[:2]`, start and r2 use `[]` (N:398-414) | core:558-597 | MISSING | S |
| D4 | `jump_to` intro | n/a | "start" leaves the intro on. Every other key sets `intro_idx=None` (N:395-397) | core:561-573 | MISSING | S |
| D5 | `do_action("door_wrong")` | jump to door, `ans A = 7`, `right[0]=0` (O:328-331) | jump to door, `door_digits = [9,9,9,9,9]` (N:420-422). Label "At the door, test an incorrect door code" (N:236) | core:574-580 | WRONG | S |
| D6 | CHECKPOINTS, `get_progress`, `set_hearts`, `set_form`, `cheat_solve`, `auto_answer` | — | unchanged (N:231-235, 347-380, 469-474) | core:325-338, 581-591 | OK | — |
| D7 | Stage chain | Stage 1 → Stage 2 | Open → Stage 1 → Cutscene 1-2 → Stage 2 → Cutscene 2-3 → Stage 3 → Ending (new demo_hub.py:24-32). The cutscene passes the handoff through and forces form ≥ 1 (cutscene_1_2.py:93-103) | top cpe_escape_top.v:60-81 | out of Stage 1 scope (note only) | — |

### 2.7 Verification tooling

| # | Item | Status | Effort |
|---|---|---|---|
| V1 | `cos:23` imports `ROOT/demo_py` = the OLD file. The new `stage1_demo.py` and `card_assets.py` must replace it (`player_sprite.py` is byte-identical). | WRONG | S |
| V2 | cos `scenario_full`: needs the intro taps after help, P2 confirm with `r` instead of `u` (cos:262), P5 entry with the new keys (cos:280; from AAA: `d`×2, `r`, `u`×11 (or `d`×15), `r`, `d`×4), and SW14 after the first correct P1 (the notebook guide gate) | WRONG | S |
| V3 | cos `scenario_items` enters wrong answers to steer the smart hint (cos:315-318). These are now rejected, so a new scenario is needed: Undo of P4, Freeze stops movement, Slow ×0.1, the double decrement | WRONG | M |
| V4 | Snapshot must add: `intro_idx`, `notebook_guide_pending`, `feedback` (−1/0/1), a cmsg id, `card_backs`, `find_near()` id, the notes count (cos:93-108, tbc:72-76) | MISSING | S |
| V5 | The harness writes `g.sw` directly and bypasses `poll()` (cos:130). It must emulate `poll()` side effects: an SW15 edge sets `show_help`, and a SW change in the WB/paper/twos close-up calls `clear_feedback()` | MISSING | S |
| V6 | `verify_puzzles.py` still proves the NEW puzzles (its clue table equals N:1239-1245) | OK | — |

---

## 3) Puzzle and door-code verification (computed from the NEW code)

Throwaway script: `/private/tmp/claude-501/-Users-admin/b09debd9-9ce1-48fd-9055-dc8158849ad4/scratchpad/verify_new.py`. It imports the NEW `stage1_demo.py` headless and uses its own `p2_table`, `p3_table` and `wrap`.

| Item | NEW source | Computed | RTL constant | Match |
|---|---|---|---|---|
| P1 A | `0x2A - 0b10011 - 0o21` (N:45) | 42 − 19 − 17 = **6**, SW3..0 = 0110 | `ANS_A = 6` core:62 | OK |
| P2 truth | `0xF888` (N:46) | equals AB + CD for all 16 minterms. Accepted inputs (≤4 literals): only {AB, CD} in either slot order | `P2_TRUTH = F888` core:63; p2_ok literal check core:254-255 | OK |
| B | popcount(0xF888) (N:47) | **7** (P3 reference circuit G1=NAND(A,B), G2=NAND(C,D), G3=NAND(G1,G2), F=G3 gives 0xF888) | `ans_b <= popcount16(p3_t)` core:502 (only 7 once P0 is fixed) | OK |
| P4 | `0b11110100` (N:48) | (−12) & 0xFF = 0xF4 = 11110100 (unsigned 244) | `P4_ANSWER` core:64 | OK |
| C | popcount(0xF4) (N:49) | **5** | core:510 | OK |
| P5 | `PC_PASS = "CPE"` (N:50). Clues (N:1239-1245): (FB,EX,CA) 2/0, (FB,CA,X) 1/0, (CA,AS,PI) 2/1, (PI,AS,FB) 1/0, (AS,EX,FB) 1/0 | brute force over all 120 ordered triples of the 6 apps: **one solution, Canva-Pinterest-Explorer → "CPE"** | `PW0..2 = 2,15,4` core:67 | OK |
| Lock 1 | `str(ord(PC_PASS[-1]))` (N:51) | 'E' = 0x45 = 69, so **6 9** | `L1C = {6,9}` core:68 | OK |
| Lock 2 | `_PRE=[A,B,C,S//10,S%10]`, order (3,1,4,0,2) (N:52-54) | S = 6+7+5 = 18, row 6 7 5 1 8, reordered **1 7 8 6 5**. Manual example 2 4 6 8 9 → 8 4 9 2 6 checks | `L2C = {1,7,8,6,5}` core:69 | OK |

Text-fit check, measured with the real Pygame font:

* Every new close-up message fits in at most 2 lines at 610 px (the longest is 112 characters, the P3 wrong message).
* Every new note fits in 1 line at 480 px.
* For the RTL fonts the same 112-character message needs 3 lines at 8×16 in 407 px (about 50 characters per line). It fits in 2 lines only with the 6×12 font (about 67 characters per line). The longest note ("- P4 correct answer: 11110100 (unsigned 244 / signed -12).", 58 characters) is wider than the 6×12 notebook column (320 px, about 53 characters), so `scr` must wrap it.

---

## 4) New assets referenced by Stage 1

New assets dir: `drive_assets/Digi-of-Adventure-main/assets/`. "Same as old" was checked by md5 against `Digi-of-Adventure-FPGA/assets/`.

| Filename as written in code | Where | Exists in new assets | Notes |
|---|---|---|---|
| `intro_char.png` (fallbacks `exam_guide.png`, `classmate.png`) | N:183 | **yes** (640×640 RGBA). The fallbacks do not exist | Fits the 32×32 pixel-art grid (98.5 %). Pygame strips white corners and crops tight (N:190-210) |
| `app_logo_canva.png`, `app_logo_pinterest.png`, `app_logo_explorer.png`, `app_logo_appstore.png`, `app_logo_x.png`, `app_logo_facebook.png` | N:1213-1220 | **all yes** (436-706 px). Not pixel art | Drawn at 22×22. The FPGA needs about 6 small images or a text fallback (Q4) |
| `<career>_<item>.png` for the round 2/3 items: `air_/earth_/water_` + `shard`, `slow`, `hint_smart`, `freeze`, `undo` (built in new card_assets.py `get_image`: `f"{cat}_{item_lower}"`, then `item_lower`) | card_assets.py `get_image` | **all 15 yes**. `*_freeze.png` are 375×375 and do not fit a 32-grid (needs resampling). Bare `shard.png` etc. do not exist (not needed) | `*_hint_hard.png` and `*_heart_loss.png` also exist but Stage 1 never shows them (hint_hard is round 1 only, and round 1 uses `*_r1`) |
| `finalexam.jpg` | N:247 | yes, identical to old | — |
| `air/earth/water_back.png`, `_r1.png`, `_card1..3.png`; `eartg_card1` → `earth_card1` | card_assets.py | yes, identical to old | `water_card*.png.png` duplicates are ignored |
| `player_form{0-2}_*` | player_sprite.py (identical file) | yes, the checked files are identical | — |
| `closeup_<id>.png` | N:1081 | **no** (none in old or new) | Placeholders, as before |
| "air_hint_smart - Copy.png", "air_freeze.png~RFe323b48.TMP", Untitled*.png | — | present but never referenced | ignore |

ROM impact: the sprite ROM has 64 slots, 0-62 used and 63 free (asset_convert.py:15-21). Stage 1 now needs at least 1 TA + 15 item fronts + 6 logos = 22 more images. BRAM is estimated at 132/135 (ARCHITECTURE.md:54-66). **This does not fit as is.** See Q4.

---

## 5) Recommended work items, in order

Every item ends with a check that can be run.

1. **Sync the reference.** Copy the NEW `stage1_demo.py` and `card_assets.py` into `Digi-of-Adventure-FPGA/demo_py/` (user action; this audit is read-only). Keep the old copy for diffing.
   *Test:* `python3 fpga/tools/verify_puzzles.py` still PASSes (it is independent of the file); `cosim_s1.py gen full` runs without exceptions.
2. **Cosim harness first.**
   * Add the snapshot fields from V4 to `cos` and `tbc`.
   * Emulate `poll()` side effects from V5.
   * Rewrite the scenarios from V2/V3: `full`; `death`; `items2` (P4 undo, Freeze 10 s / player frozen, Slow ×0.1, double decrement, smart hint); `gates` (help → intro skip via back, notebook guide, SW15 reopen).

   *Test:* the Pygame side generates traces, and the RTL compare FAILs at the expected first tick (the intro).
3. **Geometry (G1-G4).**
   * col:42 width 160.
   * core:85 laptop3 r 160.
   * core:82 pc ay 650.
   * scr:46,51 debug view.
   * spec:82 OBJ "LAPTOP 1"/"LAPTOP 2".

   *Test:* cosim `full` walk segments match; a frame check of the debug view.
4. **commit() rework (P0-P5, P8, U2, U5).**
   * Only correct answers set done/right/value.
   * Add a `feedback` register (none/correct/incorrect) and drive a cond for the colour.
   * Add CMSG ids for the 12 CORRECT/INCORRECT messages, STORED ("Stored in Term"+n+"..."), NOTERM, LOCK1, WRONG.
   * Toasts: "Puzzle n correct - saved to Notebook" and "Incorrect - try again".
   * Notes: one typed entry per correct puzzle, deduplicated (P2 keyed by its eqn value), with the new texts and 2-line wrap.
   * P2 keys U/D/tap/R with `p2_eq` updated even when the answer is wrong.
   * P5 keys L/R and U(−1)/D(+1).
   * Clear feedback on SW[7:0] change in WB/paper/twos (F6) and on close-up entry (F7).

   *Test:* cosim `full` plus a new `wrong` scenario (one wrong attempt per puzzle: state must be unchanged except cmsg/feedback).
5. **Gates (F1-F5, F3 order).**
   * Add `intro_idx` (2 bits plus valid) after help in Q_TOP.
   * Add `nb_guide_pending/seen` after the intro.
   * Set `intro_idx=0` on `enter` and on `reset_stage(1)`; clear it on `reset_stage(0)`.
   * Add the SW15 edge → `show_help` rule (as decided in Q3).

   *Test:* cosim `gates`; and the intro returns after a standalone replay.
6. **Items (C1, I1-I3, I6).**
   * Add a parameter or table input to `card_deck` so that Stage 1 round 1 = {HINT_HARD, HINT_HARD, ARMOR} while `s2_core` keeps its own table.
   * `inventory`: widen `freeze_f` to 10 bits and set 600 frames in store_mode 0.
   * `speed`: 0 while freeze; Slow = ×0.1. Implement 0.6 exactly in tenths; for form≥1 (0.72) either go to hundredths or decide per Q5.
   * Undo = P4 only.
   * Second timer decrement in the map branch. It must land **before** the candidate position is computed: today `q_x <= cx_i` is latched in Q_DISP (core:411), so add one wait state after the second `inv_tick`.

   *Test:* cosim `items2`, including the tick where slow_f goes 2→0 in map mode.
7. **Demo hooks (D2-D5) and handoff (C3, D1).**
   * Add a `card_backs` register (2×2 bits plus a count).
   * Add `out_career` and `out_card_backs`, padded at exit by the LFSR rule (N:328-333). This changes the LFSR state, so trace it.
   * Fix the `jump_to` career default to 1, keep it across jumps, and handle the intro and card_backs per key.
   * `door_wrong` = 99999 at the door.

   *Test:* a demo-op scenario in cosim (call `jump_to`/`do_action` from the harness, mirror them with `demo_op`), compare career and card_backs.
8. **Screens (U1, U3, U4, U6, P1-P9 texts, C5, G7).**
   * Update `ui_screens.py`/`ui_spec.py` texts verbatim.
   * Add the intro box, the notebook-guide overlay and the [SEARCH] label (needs `find_near` every map tick plus a `NEAR_OBJ` field/cond).
   * Remove the card name strip.

   *Test:* `ui_compile.py --preview` for the new states; re-baseline the 16-frame `tb_frame.v` check.
9. **Art (G6, C4, P6) after the BRAM decision in Q4.**
   * Convert `intro_char.png` to the free slot 63 first.
   * Item fronts and logos as decided.

   *Test:* `asset_convert.py` preview; frame check.
10. **Docs.** Update STATUS.md §2 decision 1 (BOOST is reverted by the new upstream), the VERIFICATION.md cosim numbers, and the s1_core header (core:13 "x0.5 slow").

---

## 6) Open questions (only where the code is genuinely ambiguous)

1. **Round 1 yellow card.** STATUS.md §2.1 records a decision with you: yellow = Speed Boost, and the FPGA copy of the demo was "fixed" to match. The new upstream says yellow = HINT_HARD and comments it explicitly (N:88-89). Does the new file override that decision? (This report assumes yes, because NEW is the source of truth.)
2. **Double timer decrement in map mode** (N:677-678 and 685-686). Is it intended, given that "10 seconds" then lasts about 5 s while walking but 10 s in a close-up or the notebook? It looks like a merge leftover. Port it as is for cosim exactness, or ask upstream to drop one of the two?
3. **SW15 on real hardware.** Pygame clears `sw[15]` when help is closed with BTNC (N:649-650), which a physical switch cannot do. Proposed rule: help opens on any SW15 edge to 1, closes on an edge to 0 or on tap/back, and is open at power-on regardless of the switch. Please confirm. (Stage 2 already uses SW15 for its inventory, so this rule is Stage 1 only.)
4. **Art budget.** The sprite ROM has 1 free slot and BRAM is at about 132/135. Options:
   * (a) TA in slot 63, item fronts and logos as text fallbacks. Pygame also falls back to text when a file is missing, so the behaviour is defined.
   * (b) Grow `spr.mem` to 128 images (+about 14 BRAM36) and shrink something else, e.g. the Stage 2 room ×2 upscale (ARCHITECTURE.md:69).
   * (c) A separate small logo ROM (6 × 22×22).

   Which one?
5. **Slow ×0.1 for form ≥ 1** gives 0.72 px/tick, which needs a hundredths position. In Stage 1 that form is reachable only through the demo menu (set_form/F1-F4), since normal play starts at form 0 and the clear screen ends the stage. Is hundredths precision required, or is a documented deviation acceptable?
6. **`stage1_test.py`** is not used by any launcher. Can it be ignored for good, or is it a planned replacement? (It differs from N in Freeze, Slow, Undo, the intro, the handoff and the geometry.)
