# Stage 2 (Internship) audit: NEW Pygame against the FPGA port

Date: 2026-11-26. Read-only audit. No RTL or tool files were changed.

Abbreviations used in citations:

| Tag | Path |
|---|---|
| **N** | `drive_assets/Digi-of-Adventure-main/demo_py/stage2_demo.py` (NEW, source of truth, 2124 lines) |
| **O** | `Digi-of-Adventure-FPGA/demo_py/stage2_demo.py` (OLD, the version the co-sim used, 1780 lines) |
| core | `fpga/rtl/stage2/s2_core.v` |
| walk | `fpga/rtl/stage2/s2_walk.v` |
| deck | `fpga/rtl/common/card_deck.v` |
| inv | `fpga/rtl/common/inventory.v` |
| top | `fpga/rtl/top/cpe_escape_top.v` |
| gen | `fpga/tools/stage2_assets.py` |
| scr | `fpga/tools/ui_screens_s2.py` |
| spec | `fpga/tools/ui_spec.py` |
| cos | `fpga/tools/cosim_s2.py` |

## 1. Summary

**Which file counts.** `demo_hub.py` loads only `stage2_demo` (`demo_hub.py:28`, `("Stage 2", "stage2_demo", "Game")`). `open.py` does not import any stage. The other two files are not loaded:
- `teststage2.py` is `stage2_demo.py` plus a DELETE button (`CUR_DEL` / `BTN_DEL` / `delete_wire()`). That is the only difference.
- `stage2_สำรอง.py` is byte-identical to the copy already in the FPGA repo, so it is an old backup.

The diff is 1431 lines and 68 hunks. The circuit puzzle itself did not change: `SINKS`, `SRC_LIST`, `GATES`, `REF`, `GOLD`, `SINK_POS`, the `val()`/`seg_val()`/`levels()` rules, all 18 item spots, all 9 hint spots and `INTRO_LINES` are identical. Most of the other systems around the puzzle did change:

1. **Cards.** Round 1 is gone from Stage 2, because the career and 2 card backs now come from Stage 1.
   - Round 2 opens at **8** parts (was 9). The new items are SHARD, HINT_SMART and FREEZE.
   - An optional "4th card" (round 3) opens at **18** parts, but only if the 3 recorded card backs are all different. It can be skipped with Esc / hold BTNC. Its items are HINT_HARD, HINT_SMART and HEART_LOSS.
   - Every pick appends the chosen slot to `card_backs`, which goes to Stage 3 and the ending.
2. **Items.**
   - FREEZE now freezes the player for 10 s as soon as the card is turned.
   - HEART_LOSS is new: it costs 1 heart at once, or 1 armor if you have one.
   - UNDO and SLOW can no longer be granted. The Undo inventory slot does nothing.
   - HINT_HARD lost its guards and now gives the same "wire X to Y" hint as the smart hint. Used before the bench is powered on, it **crashes Python** (TypeError).
3. **Skill.** It can be used once at any time. The 2-minute wait and the map-only rule were removed.
4. **Walking.** The feet box is 16×8 (was 20×10). FLOOR is 2 px taller. Five solids were changed or removed. Wall-slide is now a sideways "glide" probe of 4 to 20 px. Because of this, 18 of the 31 anchors move and the Boss path is 1 tick shorter.
5. **Breadboard editor.**
   - The keyboard cursor visits all 103 stops (54 pins, 47 source dots, CLEAR, UNDO) and moves geometrically.
   - You can pick a source first, then press on a pin.
   - A new UNDO button keeps up to 200 history levels.
   - Each QA box shows the circuit's live output ("your output").
   - The +5V/GND supply terminals are now sources.
6. **Zoom / UI.** The part zoom lasts 2.2 s and can be closed with BTNC after 0.8 s. A "FOUND!" card is drawn during it. Card faces now use `{career}_{item}` pictures. The Boss uses `Boss.png`, mirrored when he walks left. Several dialogue and UI texts changed.
7. **Handoff (fixes the STATUS.md finding).** `start(handoff)`, `get_handoff()`, `jump_to()`, `do_action()`, `get_progress()`, `set_hearts()`, `set_form()` and `toggle_debug()` now all exist (N:636-754). The STATUS.md line "stage2_demo.py has no start, get_handoff, jump_to…" is **resolved in NEW**.
   - In: hearts, form, armor, boost, shards, career, card_backs.
   - Out: the same plus the card_backs list.

**RTL state.** The FPGA port still implements OLD in every area above. 37 of the 38 table rows need a change (only #18 is OK) (table below). Most are small or medium. Three are large:
- the card system with backs and the per-stage item table, together with the handoff ports;
- the breadboard editor (cursor stops, source-first wiring, a 200-level undo history);
- the sprite and UI growth (Boss sprite, 15 card faces, FOUND card). The sprite ROM has 1 free slot and BRAM is about 132 of 135, per STATUS.md §5.

All assets that NEW needs exist (§4). The co-simulation must be regenerated after copying NEW (and NEW `card_assets.py`) into `Digi-of-Adventure-FPGA/demo_py/`.

## 2. Change table

Status: **OK** = the RTL already matches NEW. **WRONG** = the RTL implements OLD behaviour that NEW changed. **MISSING** = the RTL has nothing for it. Effort: S < ½ day, M = 1-2 days, L = more than 2 days.

### 2.1 Flow and cards

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| 1 | Card round 1 in Stage 2 | Opened at stage start; it picked the career (O:543, O:647) | Never runs: `r_run[1] = r_done[1] = True` at reset (N:621-622). Career = handoff career or `card_backs[0]` (N:619-620, N:640-646) | core:270 (`r_run/r_done <= 0`), core:345 (round 1 trigger) | WRONG | S |
| 2 | Boss intro start | After card round 1 | First tick after help, because `r_done[1]` is already true (N:1167) | core:370 (same condition, only the r_done reset differs) | WRONG (follows from #1) | S |
| 3 | Round 2 trigger | 9 parts (O:119) | 8 parts (`CARD2_AT = 8`, N:190, N:849). Also blocked while the zoom runs (`or self.zoom`, N:847) | core:346 (`>= 5'd9`, no zoom check) | WRONG | S |
| 4 | Round 3 trigger | `r_done[2] and rnd >= 2` (after 2 QA tests) | `r_done[2]`, parts ≥ 18, `len(card_backs) == 3` and all 3 different (N:851-858) | core:348 | WRONG | M |
| 5 | Round 3 can be skipped | no | Esc / hold BTNC before turning a card: deck closes, `r_done[3]`, toast "Skipped optional 4th card." (N:875-878). Prompt "L/R choose   BTNC pick   Esc skip" (N:1856) | deck:68-80 (no back input) | MISSING | S |
| 6 | Card backs recorded | not recorded | Each turned card appends its slot (`cursor`, 0..2) to `card_backs` (N:869-873). Reset sets 2 random backs `lfsr_pick(3)` twice (N:619). **This consumes LFSR steps at every reset**, including the game-over restart | none | MISSING | M |
| 7 | Item table per round | 1 {HINT_HARD, BOOST, ARMOR}, 2 {SHARD, SLOW, HINT_SMART}, 3 {FREEZE, UNDO, SHARD} (O:362) | 1 {HINT_HARD, SHARD, FREEZE} (not reachable), 2 {SHARD, HINT_SMART, FREEZE}, 3 {HINT_HARD, HINT_SMART, HEART_LOSS} (N:434-438) | deck:49-55 (`item_of`, shared with Stage 1, whose NEW table differs again) | WRONG | S (a per-stage item table input) |
| 8 | Card title | "PICK A CARD  (ROUND n)" | "PICK A CARD" (N:1809) | scr:422-424 | WRONG | S |
| 9 | Card face picture | back art plus a name strip | face picture `{air\|earth\|water}_{item}` (card_assets `get_image`). No name strip and no gold frame (`CARD_BACKS = True`, N:188, N:1846) | core:766 `cimg` (back art only), scr:429-433 (name strip) | WRONG | L (15 new sprites, see #34) |

### 2.2 Items, hearts and the skill

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| 10 | FREEZE item | stored in the inventory; using it said "No moving obstacles here" (O:370) | On grant: `freeze_t = 10.0` and the player cannot move (`speed()` = 0, N:888, N:1201-1203). HUD "FREEZE %.0fs" at (290,14), f_m, colour (140,220,255) (N:1926-1927). The counter never rises, so the Freeze slot always says "You do not have this item." (N:1128-1129). Text "You are frozen in place for 10 seconds." (N:447) | inv:75 (store_mode → `n_freeze`), core:459-460 | WRONG | M |
| 11 | Freeze timer rule | — | Counts down only after the talk/cutscene early-returns and before the zoom check (N:1172). It pauses during cards, talk, cutscene, help and over. Needs 600 frames | inv:57-60 (decrements on `tick` at Q_TOP, core:332); `freeze_f` is **9 bits (max 511) < 600** (inv:36) | WRONG | S |
| 12 | HEART_LOSS item (new) | — | With armor: armor −1, toast "ARMOR PROTECTED!". Otherwise hearts −1, toast "Heart Loss card! -1 heart", **no red flash**. At 0 hearts: state over, 3 s (N:897-905). Text "Heart Loss" / "Oops! You lost 1 heart immediately!" (N:449) | game_defs.vh:3-4 (no ID); heart_system `damage` would flash and say "QA failed" (core:714-716) | MISSING | M |
| 13 | UNDO item | stored; used from the inventory (O:888 ff.) | Never granted. The `use_item` branch was removed, so pressing BTNC on the Undo slot does nothing and shows no toast (N:1119-1132) | core:455-458 | WRONG | S |
| 14 | HINT_HARD use | Guards "Not useful now/yet". Non-exact hint "Segment s must be ON/OFF…" | No guards. Always the REF hint "Try this next: wire the X to the Y." / "Every segment already matches. Show it to the Boss." (N:1098-1105, N:1120-1122). **With `codes is None` (bench not yet on) Python raises TypeError**, see §6 Q1 | core:443-447 (guards), core:661-663 (HD_SEG path) | WRONG | S |
| 15 | HINT_SMART "nothing left" text | "Not useful now: nothing left to hint." | "Nothing left to hint." (N:1126) | spec:156 | WRONG | S |
| 16 | Skill use | Needs `play_t ≥ 120 s` and map mode (toasts "Skill recharging", "Use the skill while walking…") | Only "already on" / "already used" checks; usable once at any time, also in close-up. Toast "WORKSHOP SHIRT: hidden parts revealed!" (N:1194-1199). The button still counts down to 2:00 (N:1936-1941) and the help still says "(after 2 min)" (N:1906) | core:431-435, spec:159-161 | WRONG | S |
| 17 | QA verdict lines | mid pass "Test n of 3 passed! That covered X and Y. I still have to check…"; fail "+ Your armor takes the hit / That costs you a heart." | mid pass "Test %d of %d passed!"; fail "Not right. Go back to the bench and fix it." (N:1080, N:1083) | scr:461-470, spec:170-171, core:820, core:875-878 | WRONG | S |
| 18 | `damage()` (failed QA) | — | unchanged (N:1086-1095) | core:404, core:714-716 | OK | — |
| 19 | Game-over restart | `reset_stage()`: hearts 3, armor/shards/boost 0 | Same, and also **new random `card_backs` (2 LFSR picks) and career = backs[0]**. The handed-over career, backs and armor are lost (N:600-628) | core:276 (`inv_restore` puts back the entry armor) | WRONG vs NEW (see §6 Q2) | S |

### 2.3 Walking and map

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| 20 | Feet box | 20×10 (`FEET_HW, FEET_H = 10, 10`, O:17) | 16×8 (N:21). Sample points x±8, y−8, y−4 (mid), y (N:1207-1213) | walk:2-3, walk:35, walk:51 (±10, −10, −5) | WRONG | S |
| 21 | FLOOR and SOLIDS | FLOOR h 350, rows 176..525 | FLOOR h 352 (N:398). Water-cooler x 178→172, counter x 150→140, black chair removed, 3 bottom chairs removed, bottom-left partition shortened to y 484, flat bottom box removed (N:399-422). Walkable rows 176..**527**; most toggles in one row = 10 (checked) | gen:51-52 (assert `not m[526:].any()` will **fail**), walk:18 (DEPTH 350), walk:45 (`<= 525`) | WRONG | S |
| 22 | Wall slide | ±0.7·sp sideways together with the full forward step | `move_axis()`: if the straight step is blocked, try sideways offsets 4,8,12,16,20 px (+ then −) at the forward position. On the first free probe, move **only sideways** by `min(off, max(1, sp))` if that spot is free (N:1242-1255) | core:151-167, core:474-507 | WRONG | M |
| 23 | Anchors (map_update/find_near) | from OLD flood fill | 18 of 31 anchors moved, e.g. whiteboard (190,300)→(182,300), bottle (162,400)→(150,400), door (622,186)→(622,184) (checked by running both files) | `s2_consts.vh` it_ax/it_ay/hi_ax/hi_ay/ob_ax/ob_ay (generated by gen:259-271) | WRONG (stale) | S (regenerate) |
| 24 | Boss path | 59 + 162 ticks | 59 + **161** ticks (checked). NEW also tracks `n["dir"]` (N:1008-1010): right/front/back are used, "back" when seated | `s2_npc.mem` + NPC_L1/L2 (gen:77-94); no dir bits | WRONG | S (regenerate) + M (dir) |
| 25 | Part zoom | 1.5 s = 90 ticks | 2.2 s = 132 ticks (N:501). BTNC closes it once `t > 0.8` (first allowed at tick 49), and that tap is consumed (N:1173-1175) | core:335 (`zt == 89`), `zt` is **7 bits** (core:85), gen:334-345 (LUT `k = t/90`) | WRONG | S |
| 26 | "FOUND!" card during the zoom | — | 300×190 card: "FOUND!", part icon (`part_<key>.png`, otherwise drawn), label, "n / q   \|   Parts n / 18". Fades in from k = 0.18; sits at y 330 or 70 depending on the zoomed y (N:1987-2051) | none | MISSING | M |

### 2.4 Breadboard editor

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| 27 | Cursor stops and movement | 55 stops (54 pins + CLEAR); L/R ±1, U/D ±6 with wrap (O:238) | 103 stops: 54 pins, 47 `CUR_SRC` dots (order N1..O8, Ra..Rg, C, B, A, 11×'1', 11×'0'), CLEAR = 101, UNDO = 102 (N:309-312). Arrows run `cursor_step()`: projection ≥ 4, score = along + 3·across, lowest index wins ties (N:1358-1374) | core:64 (`CUR_CLEAR = 54`), core:603-606 | WRONG | M (static 103×4 next-stop ROM generated by the tool) |
| 28 | Source-first wiring | — | BTNC on a source dot toggles `msel` (N:1343-1344, N:1415-1422). BTNC on a pin while `msel` is set wires it with `rec_undo` (N:1345-1349). Back cancels `msel` (N:1287-1288). CLEAR also clears `msel` | none | MISSING | M |
| 29 | UNDO button with history | one level (item only) | `w_hist` keeps up to 200 states. `rec_undo` pushes on every change (N:951-954). UNDO pops until the state differs, else shows "Nothing to undo." (N:956-964). The history is cleared on `new_round()` (N:936). Cursor stop 102 / button (636,58,146,34) (N:314, N:1694) | core:76 (`undo_w` one level) | MISSING | L (a 200×270-bit store; BRAM is tight) |
| 30 | QA box "your output" | "tested by / Boss" | live `on_of(k)` digit for each QA code (N:1583-1585) | scr:259-260; core:704-706 evaluates only `code3` every tick | WRONG | M |
| 31 | Supply terminals as sources | — | `SUPPLY_5V` (130,160) and `SUPPLY_GND` (150,160) added to `SRC_POS["1"/"0"]` (N:304-306). 3 wires now start at the terminal (U1.vcc←'0', dip.vcc←'1', dip.vcc←'0') | `s2_wire.mem` (gen:98-117) | WRONG (stale) | S (regenerate) |
| 32 | Static board picture | resistor x 668 lead 36; "click the +5V / GND rails"; no segment letters | resistor x 666 lead 56; "red = +5V, blue = GND (or the rails)"; yellow segment letters A-G; "7-SEGMENT" moved to y 346; UNDO button (N:1694-1743) | gen:120-200 (a hand copy of `draw_board`, not generated from it) | WRONG | S |
| 33 | Footer texts | — | "Press BTNC to undo the last wire change", "<src>  -> press BTNC to pick it, then move to a white pin", "Selected: %s  ->  now click a white pin", new controls line; cursor = black and orange rings r 15 at any stop (N:1779-1802) | scr:285-305 | WRONG | S |

### 2.5 Assets, texts, handoff and demo hooks

| # | Change | Old | New | RTL file:line | Status | Effort |
|---|---|---|---|---|---|---|
| 34 | Boss sprite | rectangles (npc_*.png did not exist) | `BossSprite`: `Boss*.png`. Only `Boss.png` exists, so the standing image is used for every state including seated, scaled to 62 px, and mirrored when dir is "left" (N:55-118, N:1525-1532) | scr:34-46 (rectangles); sprite ROM full (asset_convert.py, 63 of 64 used) | MISSING | L (shared with #9) |
| 35 | Texts | — | Whiteboard page 0 now 12 lines ("2. Bring them to the decoder bench" / "   to the middle right."), y 66 + 30·i (N:1590-1597). Clear screen: "BTNC: continue to the next stage" when not standalone (N:2096). FREEZE/HEART_LOSS item texts (N:447-449) | scr:161-167, scr:490 (always "play again"; top passes `has_next = 0`, top:118, but stage 3 follows), spec:141-149 | WRONG | S |
| 36 | Handoff IN | none (STATUS: "no start()") | `start(handoff)`: `reset_stage(True)`, `show_help = False`. Hearts clamped 1..3, form 0..3, armor 0..3, boost, shards. Career + card_backs[:2] (or career + card2, or random) (N:636-651) | core:21-26 (armor/shard/boost only; hearts reset to 3, form = 1, no career/backs inputs); top:77 sets `s2_help <= 1` on entry from Stage 1 | WRONG / MISSING | M |
| 37 | Handoff OUT | none | `get_handoff()`: hearts, form, armor, boost, shards, career, card_backs (2..4 entries) (N:653-662). `cutscene_ending.resolve_ending()` uses career + the most-picked back | core:28-31 (armor/shard/boost/form only; no hearts/career/backs) | MISSING | M |
| 38 | Demo hooks | ACTIONS auto_wire/skill_ready/armor | CHECKPOINTS start, parts (8 parts + round-2 deck open), bench (18 parts, backs = [0,1,2], round 3 open, page 1), qa3 (REF wired, rnd 3), clear (N:544-550, N:682-728). ACTIONS give_parts, bench_check, give_armor, wrong_qa = `damage()` (N:551-556, N:730-754) | core:682-701 (ops 6-15; no jump_to checkpoints, no wrong_qa) | MISSING | M |

Unchanged and **OK**: circuit evaluation (s2_circuit.v), GOLD, REF hint order, item/hint spots and their texts, intro lines, `npc_interact`, `judge` scoring, door, whiteboard pages 1-2, bench page 0, notebook, LEDs/7-seg panel, `hide_legs` lanes, skill reveal on intro line 3 (core:394), `lfsr_pick` / `card_start` shuffle, `make_pairs`.

## 3. Puzzle verification

I ran the throwaway script `.../scratchpad/s2a/probe.py` with `python3 -I`. It imports OLD and NEW side by side and calls their own functions.

**Decoder.** For both OLD and NEW, wiring `REF` (53 wires) gives exactly `GOLD[k]` from `seg_val()` for all six input codes:

| Code CBA | Character | Segments |
|---|---|---|
| 001 | C | adef |
| 010 | P | abefg |
| 011 | E | adefg |
| 100 | - | g |
| 101 | 3 | abcdg |
| 110 | 9 | abcdfg |

`SINKS`, `SRC_LIST`, `GATES`, `REF`, `GOLD` and `SINK_POS` are identical in both files. Only `SRC_POS["1"]` and `SRC_POS["0"]` gained a supply-terminal point each. The correct solution and the hint answers are therefore unchanged, and the RTL tables `ref_src`, `ref_order` and `gold_segs` stay valid.

**QA pairs.** `make_pairs` and `new_round` are unchanged. `new_round` now also clears `w_hist`.

**Behaviour checks:**

| Check | Result |
|---|---|
| `use_item("HINT_HARD")` with `codes = None` | `TypeError: 'NoneType' object is not iterable` |
| after `grant("FREEZE")` | `freeze = 0`, `freeze_t = 10`, `speed() = 0` |
| `use_item("FREEZE")` after that | "You do not have this item." |
| `use_item("UNDO")` | no toast |
| `try_skill()` at `play_t = 0` | succeeds, `skill_t = 10` |
| `grant("HEART_LOSS")` at 1 heart, no armor | hearts 0, state "over", toast "Heart Loss card! -1 heart", flash 0 |
| `reset_stage(True)` from LFSR 0x1D2C | LFSR becomes 0x74B0 (2 picks), backs [0,0], career 0 |
| cursor stops | `CUR_SRC` = 47, `CUR_CLEAR` = 101, `CUR_UNDO` = 102, `N_CUR` = 103 |

## 4. Assets referenced by NEW Stage 2

The asset folder is `drive_assets/Digi-of-Adventure-main/assets/`. Every file that also exists in `Digi-of-Adventure-FPGA/assets/` has the same MD5, so no existing asset changed.

| Name (as looked up) | Used for | Exists? |
|---|---|---|
| `bg.jpg` (fallback `internship.jpg`) | room (N:566) | yes, same as FPGA; `internship.*` no (not needed) |
| `player_form{0,1,2}_{back,front,left,right}_{stand,stepl,stepr}.png` | player | yes (form2 has front/right only, as before) |
| `Boss.png` (any `Boss*` file) | Boss sprite (N:55-118) | **yes, NEW**, 640×640 |
| `npc_stand.png`, `npc_sit.png` | old Boss fallback (N:570) | no (fallback only) |
| `{air,earth,water}_card{1,2,3}.png` (`eartg_card1` is tried first) | card backs, rounds 2-3 | yes (`eartg_card1` no; `earth_card1` used) |
| `{air,earth,water}_{hint_hard,shard,freeze,hint_smart,heart_loss}.png` | card faces (`card_assets.get_image`, item_name) | **yes, all 15, NEW** (640×640; `*_freeze` are 375×375) |
| `hint_hard`, `shard`, `freeze`, `hint_smart`, `heart_loss` (plain) | face fallback | no (not needed) |
| `{air,earth,water}_back.png`, `_r1.png` | round-1 cards | yes, but round 1 cannot be reached in Stage 2 |
| `part_{not,and,or,seg,dip,r10k,r220,bb,psu}.png` | FOUND-card icon (N:1989) | no; the drawn fallback icons are used (N:1998-2029) |
| `closeup_{whiteboard,door,bench}.png` | close-up background (N:1558) | no (same as OLD) |
| `card_assets.py` (NEW) | `draw_card(..., item_name=)` returns a tuple | NEW signature; the FPGA repo copy is OLD, so NEW stage2 raises TypeError with it |

Unused files that sit next to these: `*_slow.png`, `*_undo.png`, `* - Copy.png`, `water_card*.png.png`, `air_freeze.png~RFe323b48.TMP`.

## 5. Work items (in order, each testable)

1. **Sync the sources.** Copy NEW `stage2_demo.py` and NEW `card_assets.py` into `Digi-of-Adventure-FPGA/demo_py/`.
   - Test: `python3 -I fpga/tools/stage2_assets.py` imports without error.
2. **Generator: mask and ROMs** (#21, #23, #24, #31). In gen:51-52, allow rows 176..527 (352 rows). Regenerate `s2_mask.mem`, `s2_npc.mem` (161 ticks), `s2_wire.mem` and `s2_consts.vh`. Add the Boss dir to each `s2_npc.mem` word (2 bits).
   - Test: the generator self-check at gen:64-71 passes; NPC_L2 = 161; the 18 anchors match §2 #23.
3. **s2_walk.v** (#20, #21). Use ±8 / −8 / −4 offsets, DEPTH 352 and the in-row limit 527.
   - Test: a unit test of `blocked()` on about 10k random points against NEW `Game.blocked`.
4. **Movement glide** (#22). Replace the 0.7 slide (core:151-167, core:474-507) with the `move_axis` probe loop (5 offsets × 2 signs, then the sideways-only step `min(off, max(1, sp))`). Speed is 0 while frozen.
   - Test: a co-sim scenario that walks into desk corners and the bottom lane (y 502-527).
5. **Zoom** (#25, #26). Widen `zt` to 8 bits, end at 132, regenerate the LUT with `k = t/132`, and add tap-dismiss when `zt ≥ 49` (the tap is consumed). Add the FOUND card to scr with a new alpha field.
   - Test: co-sim ticks 0-140 after a pickup, with and without a tap.
6. **Cards** (#1-#8, #6).
   - Reset `r_run` and `r_done` to 3'b001 and drop the round-1 trigger.
   - Round 2 at ≥ 8 parts and `!zoom_on`. Round 3 at 18 parts plus 3 different backs.
   - Add a `back` skip input to card_deck.
   - Add a back register file (4×2 bits plus a count). On every entry or restart, do the 2 `lfsr_pick(3)` draws.
   - Give card_deck a per-stage item table input (Stage 1 has its own NEW table).
   - Test: co-sim of rounds 2 and 3 (taken and skipped); LFSR equal after `enter`.
7. **Inventory and items** (#10-#14). Add `IT_HEART_LOSS`.
   - FREEZE in store_mode: set `freeze_f = 600` (widen to 10 bits) and stop storing it. Decrement only in Q_MAIN after the cutscene check (N:1172).
   - Undo slot: no-op.
   - Freeze slot: always NOITEM.
   - HEART_LOSS: an armor-or-heart path without flash, with its own toast, and over at 0.
   - HINT_HARD: drop the guards (see §6 Q1 for `codes_v = 0`) and always use the REF path.
   - Test: co-sim; use every item in every state.
8. **Skill** (#16). Remove the SKILL_WAIT and mode_cu checks in core:431-434 and change the SK_GO text.
   - Test: press SW13 at `play_t` = 1 s, once in the map and once in close-up.
9. **Breadboard editor** (#27-#33).
   - Generate a 103×4 `cursor_step` ROM in the tool.
   - Add an `msel` register and the source-first flow.
   - Add an UNDO stop and button with a 200-entry history (BRAM or LUTRAM, 270 bits per entry). Clear it in `new_round`.
   - Add the `ev_job 1` evaluation every tick for the "your output" boxes.
   - Update the hand copy in `board_static` (gen:120-200) and the footer texts.
   - Test: co-sim scenario `bench` that wires half of REF source-first through cursor stops, uses UNDO ×5 and CLEAR, then UNDO.
10. **Texts and UI** (#15, #17, #35). Update spec S2_ITEM/S2_DESC (+HEART_LOSS, FREEZE), S2_TOAST, S2_TALK FAIL/PASSMID, the whiteboard lines, the card title, the clear-screen footer and the FREEZE HUD.
    - Test: `ui_compile` builds; frame_check screenshots compared with Pygame.
11. **Sprites** (#9, #34). Grow the sprite ROM by Boss + 15 faces (+1 if `Boss_sit` is ever added), or reuse slots. This needs a BRAM budget decision (§6 Q4).
    - Test: frame_check of a card face-up and the Boss walking left.
12. **Handoff ports** (#19, #36, #37). Add to s2_core: `in_hearts`, `in_form`, `in_career`, `in_backs[3:0]`, `in_backs_v`, and `out_hearts`, `out_career`, `out_backs`, `out_nbacks`. Wire them in top with Stage 1 (Stage 1 must export career/backs) and Stage 3. Decide `s2_help` (§6 Q3).
    - Test: a tb that enters Stage 2 with handoff {hearts 2, armor 1, career 2, backs [0,2]} and checks the state against NEW `start()`.
13. **Demo hooks** (#38). Add the Stage-2 jump_to ops (parts / bench / qa3 / clear) and the wrong_qa op, exactly as N:682-754.
    - Test: tb plus the menu.
14. **Co-sim** (cos). Update `speed` (0 while frozen; 312/156 otherwise), patch `move_axis` instead of the `"0.7"` text in `map_update` (cos:55-61), snap `freeze_t` and the zoom to ticks, add snapshot columns (freeze, backs, nbacks, msel, cursor 0..102, history depth), and rewrite `scenario_full`: no round 1, round 2 at 8, round 3 at 18 or skipped, HEART_LOSS, FREEZE.
    - Test: PASS on every scenario.
15. **Update STATUS.md.** The "no start/get_handoff" finding is resolved; the decision-1 note (BOOST in Stage 2) is no longer true.

## 6. Open questions (real ambiguities)

1. **HINT_HARD before the bench is powered on crashes NEW Python** (`TypeError`, N:1122 → N:1100 → N:943). It can happen: round 3 grants HINT_HARD at 18 parts, before the bench is opened. What should the FPGA do there? Options: keep OLD's toast "Not useful yet: power on the decoder bench first.", or fix the Python first.
2. **Game-over restart** (N:600-628). It loses the handed-over career, card backs, armor, shards and boost, and re-randomises the career. Is this intended, or should restart restore the stage-entry handoff, as the FPGA `inv_restore` does today?
3. **Help screen on entry.** The hub `start()` hides it (N:638), while standalone `main()` shows it. Which applies to the board's Stage 1 → Stage 2 transition (top:77 shows it today)?
4. **Skill.** Is "usable at once" (N:1194-1199) intended? The button still counts down to 2:00 and the help says "(after 2 min)".
5. **Sprite budget.** There is 1 free sprite slot and about 3 BRAM left. Should the 15 card-face pictures and the Boss be added at 32×32, or should the faces fall back to back art plus a name, as now? This changes how closely the screens match Pygame.
6. **`teststage2.py` DELETE button.** It is not loaded by `demo_hub`. Should it become part of Stage 2?
7. **Undo history depth.** Is the exact 200-level history required on the FPGA? It needs about 54 kbit, or a journal.
