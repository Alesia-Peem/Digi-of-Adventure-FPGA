# Audit: game flow, cutscenes, card art, assets and BRAM

Scope: everything except Stage 1/2/3 gameplay. NEW = `drive_assets/Digi-of-Adventure-main/` (authoritative).
OLD = `Digi-of-Adventure-FPGA/demo_py` + `assets/` (what the FPGA port follows today).
Paths below: `new:` = `drive_assets/Digi-of-Adventure-main/demo_py/`, `fpga:` = `Digi-of-Adventure-FPGA/fpga/`.
Throwaway analysis scripts: `/private/tmp/claude-501/-Users-admin/b09debd9-9ce1-48fd-9055-dc8158849ad4/scratchpad/{inv,spr,pal,recol,cur,scale}.py`.

---------------------------------------------------------------------------------------------------

## 1) Summary

* The new final game is 7 screens chained in one sequence: **Open (title + 6 story pictures) → Stage 1 →
  Cutscene 1-2 → Stage 2 → Cutscene 2-3 → Stage 3 → Ending (graduation summary + 1 of 9 career endings)
  → Play Again → Open**. The only code that chains them is `demo_hub.py`. Its docstring says the final
  submission does not import it, but no other entry point exists in the new code (see section 9).
* The ending is picked by **career** (colour of the Stage-1 round-1 card) × **the card position
  (left/middle/right) picked most often** in the later card rounds of Stage 1 and Stage 2. Ties go to the
  position picked most recently. This needs a new handoff (`career`, `card_backs`) that the FPGA does not
  carry today.
* **Card art changed only for revealed cards in rounds 2+.** Each now shows a per-career item face
  (`{air,earth,water}_{freeze,heart_loss,hint_hard,hint_smart,shard,slow,undo}`), 21 names / **16 new
  unique images**. All card files shared with OLD are byte-identical. Junk files (0-byte "- Copy",
  `.png.png`, `Untitled*`, a `~RF…TMP`) are not referenced by any code.
* **The BRAM is already full.** Per-ROM mapping of the current RTL gives **≈137 BRAM36** (range 134.5–140,
  depending on whether 5 tiny ROMs become LUTs). The old "≈132" estimate is about 5 low: the UI ROMs take
  14, not 11. Vivado has never been run (there is no `fpga/vivado/reports/`). `ui_prog.mem` is 2018/2048
  full. The new content needs **20 full-screen pictures**: **≈150 BRAM36 even at 320×180×4 bit**, and
  RLE does not help (121–424). **Pictures cannot live in BRAM.**
* **Recommendation:** add one **QSPI-flash picture streamer**. It stores 640×360, 8-bit-indexed pictures
  plus a 256-colour palette per picture (4.6 MB in the 16 MiB flash, needs 13.8 MB/s on average,
  25 MB/s available at SCK = 50 MHz). Move the **Stage-1 room (bg_s1) to the same streamer** to free
  42 BRAM36. That pays for the new item-card ROM (+4), a doubled UI program ROM (+5.5) and FIFOs (+1),
  which brings the total to ≈106/135. Crossfades become fades from black. DDR2 is not needed.

---------------------------------------------------------------------------------------------------

## 2) Final game flow

```
 power-up / Play Again
        │
        ▼
 ┌──────────────── OPEN (open.py) ─────────────────┐   handoff = {hearts 3, form 0, armor 0, boost F, shards 0}
 │ page 0 title.png (nearest fit)                   │   open.py:126-128
 │ pages 1..6 = 1.jpg..6.jpg (stops at first gap)   │   open.py:46-65, 110-114
 │ next = BTNC/Space/Enter/Right/D/click            │   open.py:188-189, 210-220
 │ back = Left/A/Backspace/right-click              │   open.py:185-191, 159-161
 │ Esc  = skip straight to Stage 1                  │   open.py:192-193, 206-207
 │ last page: "ENTER THE ROOM" button → Stage 1     │   open.py:15-16, 211-218, 249-261
 └──────────────────────────────────────────────────┘
        │ exit_requested (go_stage1)                     demo_hub.py:242-247 → next_stage() :77-84
        ▼
 STAGE 1 (stage1_demo.py)  → get_handoff(): hearts, form, armor, boost, shards,
        │                    career (round-1 colour), card_backs = 2 picked POSITIONS (padded by LFSR)
        │                    stage1_demo.py:327-342, picks appended :512-513
        ▼
 CUTSCENE 1-2 (cutscene_1_2.py) – form := max(1, form)   cutscene_1_2.py:97; passes handoff through :102-103
        ▼
 STAGE 2 (stage2_demo.py) – takes card_backs[:2] + career   stage2_demo.py:637-651
        │                    appends position of each pick in rounds 2 (and optional 3)   :870-873, :849-857
        │                    get_handoff() adds career + card_backs                       :653-662
        ▼
 CUTSCENE 2-3 (cutscene_2_3.py) – form := max(2, form)    cutscene_2_3.py:93
        ▼
 STAGE 3 (stage3_demo.py) – passes the whole handoff dict through (career/card_backs kept)  stage3_demo.py:64-86
        │ exits only on mode "win" + confirm                                                 stage3_demo.py:137-141
        ▼
 ENDING (cutscene_ending.py)
   step 0  graduation summary (procedural)  ──BTNC──►  step 1  ending{N}.png
                                ◄──Left/Backspace──       │ BTNC/Esc/click after 1.2 s lock
                                                          ▼
                                     modal "RETURN TO THE BEGINNING?"  [Keep Viewing]* / [Play Again]
                                                          │ Play Again
        ┌─────────────────────────────────────────────────┘ exit_requested
        ▼  demo_hub.py:243-245: last tab → switch(0, None) = OPEN with a fresh handoff
```

Registry order = flow order: `demo_hub.py:24-32`. The hub calls `next_stage()` with
`get_handoff()` of the finished screen (`demo_hub.py:77-84`).

FPGA today (`fpga:rtl/top/cpe_escape_top.v:53-89`): boot → Stage 1 → Stage 2 → Stage 3, and Stage 3 never
exits (`fpga:rtl/stage3/s3_core.v:22,41` ties `exit_req` to 0, so BTNC replays Stage 3). The `stage` register
is 2 bits. There is no title, no story, no cutscene, no ending, and no career/card_backs handoff
(`s2_core` starts its own `card_deck` with `set_career(1'b0)`, `fpga:rtl/stage2/s2_core.v:107`).

---------------------------------------------------------------------------------------------------

## 3) Cutscenes and ending spec

All screens use a 960×540 UI that the FPGA scales by 2/3 into its 640×360 game area. The panel under the
UI is the board's 7-segment display, LEDs and hint text. The 7-seg text is truncated to 8 characters
(`text[:8]`).

### 3.1 Open (`open.py`)
| item | value |
|---|---|
| pictures | `title.png` 1920×1080 (palette PNG). Fit with **nearest** (`smooth=False`, :105). `1.jpg`–`6.jpg` (2752×1536, except `5.jpg` 993×556) use smoothscale (:112). All are letterboxed into 960×540 on black (:68-76). |
| transitions | Crossfade old→new over **0.45 s** (`FADE_S`, :17, :241-245). `next` during a fade completes the fade (:149-151). |
| title page | No "click to continue" and no counter (:247). The picture itself contains "PRESS BTNC TO PLAY". |
| pages 1-5 | Blinking "click to continue" at bottom-right, white with a black shadow offset by 2 px, `int(t*1.6)%2==0` (:262-267). Counter "i / 6" at (16, UH-30) (:269-275). |
| page 6 (last) | After the fade ends: button `ENTER_BTN` 250×54 centred at (506,405) (FPGA: 167×36 at (337,270)), radius 10. Background (18,28,60); border and text pulse `235+20·pulse`, where `pulse = 0.5+0.5·|(1.2t mod 2)−1|`. Hover colours apply to the mouse only (:249-261). A keyboard `next` on the last page = enter (:216-218). A click enters only inside the button (:211-213). |
| inputs | next: Space/Enter/Right/D/left-click. back: Left/A/Backspace/right-click (also back to the title). skip: Esc goes straight to Stage 1 (:206-207). |
| 7-seg | `"H3  OPEn"` (:227). Needs the characters **O, P, E, n**. |
| exit | `enter()` → `exit_requested` (:163-165). The handoff is unchanged. |

### 3.2 Cutscene 1-2 (`cutscene_1_2.py`)
| item | value |
|---|---|
| picture | `cutscene1_2.png` 1920×1080, smoothscale fit, letterbox colour (12,14,20) (:39-63) |
| motion | **Slow zoom**: `zoom = 1 + 0.08·min(1, t/12)`, centred, recomputed every frame (:170-173). **Fade in from black** over 0.6 s (:181-185). |
| caption box | Rect (40,396,880,124). Fill (14,18,28) at alpha 220, 2-px border (255,230,120) with radius 10 (:188-192). Tag "STAGE 1  ->  STAGE 2" (:194-195). |
| text (3 lines, one per BTNC) | 1 "You cracked the Final Exam door locks and escaped Room CPE1119!" 2 "STAGE EVOLUTION: Student Uniform  ->  Workshop Shirt" 3 "Next stop: your Engineering Internship. Time to put your hardware skills to work." (:17-21). Word-wrapped to width 836 at font 28 (:139-150). |
| prompt | "BTNC: Next" blinks with `int(2t)%2`. On the last line it shows "BTNC: Enter Stage 2 >>" without blinking (:201-204). Counter "i / 3" (:206-207). |
| inputs | next (Space/Enter/Right/D/click): during the fade it completes the fade, otherwise it shows the next line, and after the last line it finishes (:125-131). Esc finishes immediately (:122-124). There is **no back**. |
| 7-seg | `"H3 CUt1-2"` truncated to **`"H3 CUt1-"`** (:157-158). Needs **C, U, t, -**. |
| handoff | `form = max(1, form)` (:97) |

### 3.3 Cutscene 2-3 (`cutscene_2_3.py`)
| item | value |
|---|---|
| pictures | `cut23_1.png`, `cut23_2.png`, `cut23_3.png`, all 1920×1080 palette PNGs, **nearest** fit (`transform.scale`, :48) |
| transitions | Crossfade over 0.4 s (:19, :169-174). `next` during a fade completes it. |
| bottom bar | 40 px at UH-40, colour (12,15,24) at alpha 205, 1-px line (90,100,130) (:184-187). Counter "i / 3" at the left. Centred yellow subtitle. Prompt at the right: "BTNC: Next >>" blinking, last slide "BTNC: Enter Stage 3 >>" steady (:189-199). |
| subtitles | 1 "Stage 2 Clear — Internship Complete!" (contains a non-ASCII **em dash**: the font ROM is 7-bit, so map it to `-`). 2 "Received: Graduation Gown". 3 "Character Evolved! Ready for Stage 3." (:9-13) |
| inputs | next = advance / finish after slide 3. back (Left/A/Backspace/right-click) = previous slide with crossfade. Esc = finish (:123-142). |
| 7-seg | `"H3 CUt2-3"` truncated to **`"H3 CUt2-"`** (:155-156) |
| handoff | `form = max(2, form)` (:93) |

### 3.4 Ending (`cutscene_ending.py`)
**Selection** (`resolve_ending`, :136-150):
* `career` = handoff career (0 green/AIR, 1 yellow/EARTH, 2 red/WATER). An invalid value becomes 0.
* `picks` = `card_backs` = list of **slot positions** 0/1/2. These are the positions picked in Stage 1
  rounds 2 and 3, then Stage 2 round 2 and the optional round 3, so 3–4 entries. Stage 1 pads its 2 entries
  with LFSR values if rounds were skipped (`stage1_demo.py:327-333`).
* `most_pos = argmax(count, last index)`, so a tie goes to the most recent pick. With no picks it is 1.
* `ending = ENDING_MAP[career][most_pos]` (:25-29):

| career | left (pos 0) | middle (pos 1) | right (pos 2) |
|---|---|---|---|
| 0 Green/AIR | 3 Astronaut (Fart) | 1 Fried Grasshopper Seller (Wing) | 2 Aircon Technician (Plane) |
| 1 Yellow/EARTH | 4 Noodle Seller (Boat) | 5 Software Engineer (Wrench) | 6 Lottery Seller (Money) |
| 2 Red/WATER | 7 Fisherman (Worm) | 8 Pirate (Flag) | 9 Subsea Network Engineer (Plug) |

I checked the card art. `air_card1/2/3` = fart / wing / plane, `earth_card*` = boat / wrench / coin,
`water_card*` = worm / flag / plug, which matches `CARD_NAMES` (:37-41). The stage files'
`SYMBOLS` (`stage1_demo.py`, `["WING","PLANE","FART"]`…) list the green names in another order. They are
only fallback text when an image is missing, so they do not affect the ending.

**Step 0, graduation summary** (all procedural, :334-417):
* Background: bands 12 px tall with `tone = 16+18·y/540`, colour (tone, tone+6, tone+24).
* 42 confetti squares (:175-184). Each has `cy = (y0 + t·spd) mod 560 − 10` and
  `cx = (x0 + 14·sin(2t + y0)) mod 960`. Size 3–7, five colours.
* "CONGRATULATIONS, GRADUATE!" (font 44, y 62). Sub-line "You cleared Stage 3 and officially graduated from CPE!" (y 104).
* Panel (110,142,740,300) at alpha 225 with a gold border.
* Portrait (138,176,170,210): grad sprite 132 px tall that bobs `±4·sin(3t)`, plus "Class of CPE".
  The sprite is `player_form{2|3}_front_stand.png`. **form3 art does not exist, so the Pygame build always
  shows form 2** (:104-116, :167-170, :362-363).
* "YOUR CARD JOURNEY", "Career Color: <Green|Yellow|Red>" in the career colour.
* 3 slots 138×140, step 158. Each shows card art `get_image(2, career, pos, False)` = `{career}_card{pos+1}`
  at **84×84**, plus "<Name>: x<count>". The most-picked slot is highlighted (:383-403).
* "Most Picked: <Name> Card  ->  Ending #N".
* Blinking prompt "BTNC (Space / Click): Reveal Your Ending Career >>".

**Step 1, reveal** (:419-447):
* Shows `ending{N}.png` (1920×1080, smoothscale fit).
* After `REVEAL_LOCK_S` = 1.2 s, a pill 370×22 at alpha 185 appears at the bottom:
  "Space / Click: Finish Options   |   Left: Summary".
* The pictures contain Thai paragraph text. I checked a 640×360, 256-colour render of `ending5.png`: it is
  readable. At 320×180 it would not be.

**Confirm modal** (:446-480):
* Full-screen black overlay at alpha 165. Box (250,172,460,196).
* "RETURN TO THE BEGINNING?" / "Leave your ending screen and start a new game?"
* Buttons "Keep Viewing" (default, choice 0) and "Play Again" (choice 1).
* Hint "BTNL / BTNR: Select | BTNC / Space: Confirm | Click a button".

**Inputs / state machine** (:268-326):
* Step 0:
  * Esc → step 1 at once.
  * next / Right / click → completes the fade if it is still running, else goes to step 1.
  * Every step entry fades in from black over 0.6 s (:512-516).
* Step 1:
  * Left or Backspace → step 0.
  * After the 1.2 s lock, next / Esc / click → opens the modal.
* Modal:
  * L/R toggle the choice.
  * next confirms. Keep Viewing closes the modal.
  * Esc / Backspace closes the modal.
  * A click on Play Again finishes. Any other click closes the modal.
* Finish = `exit_requested`, and the hub restarts at Open.

**Panel and 7-seg**:
* 7-seg `"H3 End-N"` needs **E, n, d, -**.
* Panel status "Ending N/9: <title>". The hint changes per state (:482-503).

**Hub hooks**: `CHECKPOINTS` grad/reveal, `ACTIONS` end_1..end_9 (:154-161), `jump_to`, `do_action`,
`get_progress` (:204-232).

### 3.5 Seven-segment characters missing on the FPGA
`fpga:rtl/common/seven_seg.v:24-40` has 0-9 H - blank E P C A F L O U d S. **`n` (ceg) and `t` (defg) are
missing.** Add them as codes 23 and 24.

---------------------------------------------------------------------------------------------------

## 4) Cards / items art changes

**`card_assets.py` diff (OLD → NEW)**:
* The default `card_size` changed from `None` (native size) to `(170,170)`. Every card is smoothscaled to the
  slot (`new:card_assets.py:28, 69`). The stages already passed (170,170).
* `get_image(..., item_name=None)` was added (:76-97). For rounds 2+ a **revealed** card first tries
  `"{career}_{item.lower()}"`, then `"{item.lower()}"`, then the slot back `{career}_card{pos+1}`.
* `draw_card` forwards `item_name` (:107-115). The old `get_round_card` was removed and its table renamed
  to `R2_TO_5_BACK_NAMES`.
* Round 1 is unchanged: back = `{c}_back`, revealed = `{c}_r1` by the colour index of the slot.

**Callers**: Stage 1 passes the item key (`new:stage1_demo.py:1323-1329`, `CARD_ITEMS` :89-91: r2 SHARD/SLOW/HINT_SMART,
r3 FREEZE/UNDO/SHARD). Stage 2 does the same (`new:stage2_demo.py:1814-1828`, `CARD_ITEMS` :434-438: r2 SHARD/HINT_SMART/FREEZE,
r3 HINT_HARD/HINT_SMART/HEART_LOSS. Round 1 is never played in Stage 2 because `r_done[1]=True` at :621-622).

**Images now used** (all exist, all byte-identical to OLD where shared):

| group | files | used by |
|---|---|---|
| round-1 back | air_back, earth_back, water_back (**3 identical copies**) | S1 round 1 |
| round-1 face | air_r1 (= air_hint_hard, identical), earth_r1 (= earth_hint_hard, identical), water_r1 (shield = Armor, unique) | S1 round 1 |
| rounds 2+ back | {air,earth,water}_card{1,2,3} | S1/S2 rounds 2-3 face-down, ending summary (84×84) |
| rounds 2+ face (**NEW**) | {c}_shard, {c}_slow, {c}_hint_smart (= {c}_hint_hard, identical), {c}_freeze, {c}_undo, {c}_hint_hard, {c}_heart_loss | S1 r2/r3, S2 r2/r3 |

That is 21 face names and **16 unique new 32×32 images**: freeze, heart_loss, shard, slow and undo × 3,
plus water_hint_hard. air/earth hint_hard already exist as r1.
* The `*_freeze` files are 375×375 (card at x 55..302) and are not 32×32 pixel art. Every other card is
  640×640, which is 32×32 art scaled ×20.
* The face colours cannot be produced by a palette swap of one image per item: the per-career pixel maps
  conflict (scratchpad `recol.py`). So the 16 faces must be stored separately.
* Combined 12-bit colours: current sprites + cards = 75 (the ROM palette has 76 including the generated form3).
  Adding the 16 faces gives **166 > 127**, which overflows the 7-bit `spr` index. The freeze cards bring
  most of the new colours.

**Junk files in NEW `assets/`** (none is referenced: grep for `Copy|Untitled|TMP|.png.png|Zone` in
`demo_py/*.py` and `onlystage_3/*.py` finds nothing):

| file | size | note |
|---|---|---|
| `{air,earth,water}_hint_smart - Copy.png` | 0 B | empty |
| `water_card{1,2,3}.png.png` | 0 B | empty. OLD had them as `…png.png:Zone.Identifier` (Windows ADS) |
| `Untitled{114,116,125,215,216,217}_*.png` | 0 B | empty. OLD had 3 as `:Zone.Identifier` |
| `air_freeze.png~RFe323b48.TMP` | 68 679 B | Office temp: a 666×375 RGBA PNG that differs from the real `air_freeze.png` (375×375) |
| `finalexam.mem` | — | stray memory file. The FPGA tool regenerates from `finalexam.jpg` |

Other asset notes (code references with no file present, so the fallbacks run):
* `closeup_*.png` (S1/S2), `npc_stand.png`, `npc_sit.png`, `part_*.png` (S2), `player_form3_*`.
* `eartg_card1` is a fallback name only. `earth_card1.png` exists.

Pygame side note (Stage-1 agent): `draw_card` now returns a tuple. In `new:stage1_demo.py:1327-1331`,
`if not drew_img:` is therefore always False and the fallback text never draws. This is harmless while
all images exist.

---------------------------------------------------------------------------------------------------

## 5) Asset and BRAM inventory

BRAM figures: minimum RAMB36 equivalents over the 7-series configurations (36K: 32K×1…512×72, 18K
halves), with the width split across configurations. I checked these against the existing bg ROM
(640×358×6 = exactly 42). For 640×360 the FPGA game area is 1:1. Fitting keeps the aspect ratio, so the
2752×1536 JPGs become 640×357.

### 5.1 Full-screen pictures (new content unless noted)
`u12` = unique colours after 4:4:4 truncation at that size. PSNR is measured against the 4:4:4 image after
median-cut quantisation without dither.

| file | native | mode | uniq 24-bit / 12-bit (native) | 640×360: u12, PSNR p64 / p256 | 320×180: PSNR p16 / p256 | BRAM36 640×360 4b/6b/8b | BRAM36 320×180 4b/6b/8b |
|---|---|---|---|---|---|---|---|
| title.png | 1920×1080 | P | 256 / 128 | 263, 39.3 / 68.1 | 30.3 / 99 | 28.5 / 43 / 56.5 | 7.5 / 11.5 / 14.5 |
| 1.jpg | 2752×1536 | RGB | 72 162 / 533 | 403, 32.1 / 48.6 | 24.3 / 48.3 | 28 / 42 / 56 | 7 / 10.5 / 14 |
| 2.jpg | 2752×1536 | RGB | 41 164 / 385 | 293, 34.8 / 59.8 | 27.7 / 66.8 | 28 / 42 / 56 | 7 / 10.5 / 14 |
| 3.jpg | 2752×1536 | RGB | 10 863 / 207 | 134, 50.2 / 99 | 30.4 / 99 | 28 / 42 / 56 | 7 / 10.5 / 14 |
| 4.jpg | 2752×1536 | RGB | 46 536 / 350 | 278, 36.5 / 67.0 | 29.1 / 99 | 28 / 42 / 56 | 7 / 10.5 / 14 |
| 5.jpg | 993×556 | RGB | 10 184 / 194 | 166, 45.6 / 99 | 31.5 / 99 | 28 / 42 / 56 | 7 / 10.5 / 14 |
| 6.jpg | 2752×1536 | RGB | 25 866 / 264 | 206, 40.5 / 99 | 29.0 / 99 | 28 / 42 / 56 | 7 / 10.5 / 14 |
| cutscene1_2.png | 1920×1080 | P | 255 / 69 | 267, 41.2 / 70.0 | 26.0 / 67.5 | 28.5 / 43 / 56.5 | 7.5 / 11.5 / 14.5 |
| cut23_1.png | 1920×1080 | P | 256 / 138 | 545, 32.3 / 45.4 | 25.4 / 44.7 | 28.5 / 43 / 56.5 | 7.5 / 11.5 / 14.5 |
| cut23_2.png | 1920×1080 | P | 256 / 143 | 528, 32.7 / 44.9 | 24.7 / 44.7 | 28.5 / 43 / 56.5 | 7.5 / 11.5 / 14.5 |
| cut23_3.png | 1920×1080 | P | 255 / 82 | 280, 41.4 / 65.6 | 23.6 / 70.4 | 28.5 / 43 / 56.5 | 7.5 / 11.5 / 14.5 |
| ending1.png | 1920×1080 | RGB | 139 350 / 818 | 664, 32.3 / 43.2 | 24.9 / 42.8 | 28.5 / 43 / 56.5 | 7.5 / 11.5 / 14.5 |
| ending2.png | 1920×1080 | RGB | 86 748 / 623 | 503, 33.9 / 49.1 | 25.0 / 49.9 | same | same |
| ending3.png | 1920×1080 | RGB | 73 084 / 659 | 526, 32.6 / 47.7 | 25.9 / 47.6 | same | same |
| ending4.png | 1920×1080 | RGB | 110 778 / 709 | 567, 33.7 / 47.4 | 26.0 / 46.6 | same | same |
| ending5.png | 1920×1080 | RGB | 84 806 / 550 | 469, 33.6 / 48.5 | 25.0 / 48.0 | same | same |
| ending6.png | 1920×1080 | RGB | 148 940 / 860 | 712, 32.3 / 43.6 | 24.2 / 43.0 | same | same |
| ending7.png | 1920×1080 | RGB | 143 687 / 699 | 579, 32.2 / 44.2 | 25.5 / 44.1 | same | same |
| ending8.png | 1920×1080 | RGB | 129 485 / 628 | 516, 32.4 / 46.8 | 25.4 / 46.2 | same | same |
| ending9.png | 1920×1080 | RGB | 124 168 / 868 | 647, 33.2 / 45.4 | 26.3 / 44.8 | same | same |
| finalexam.jpg (S1, existing) | 2752×1536 | RGB | 97 985 / 1100 | 578, 36.1 / 48.5 | 29.4 / 51.8 | in ROM: 640×358×6 = **42** | |
| bg.jpg (S2, existing) | 2752×1536 | RGB | 222 451 / 1552 | 1016, 30.4 / 39.8 | 25.8 / 40.8 | in ROM: 640×358×6 = **42** | |

* **20 new full screens**, and only one is visible at a time.
* None of them is clean integer-upscaled pixel art. The block-uniformity test (scratchpad `scale.py`) is
  below 0.97 at k=2.
* 8×8 tile dedup at 320×180 leaves 188–851 unique tiles out of 900. That is useless.
* Per-line RLE totals: 640×360 at 64 colours = 1 952 784 B ≈ **424 BRAM36**. 320×180 at 16 colours =
  558 390 B ≈ **121 BRAM36**.
* Raw totals: 320×180×4 bit = 20 × 7.5 = **150**. 640×360×8 bit = 20 × 56.5 = **1130**.

### 5.2 Sprites, cards, small art referenced by new code
| file(s) | native | 32×32 art? | 12-bit colours (native) | FPGA storage |
|---|---|---|---|---|
| player_form{0,1}_{4 dirs}_{3 poses}, player_form2_{front,right}_* (30 files) | 640×640 | yes (×20) | 98–125 per frame | `spr.mem`, 48 slots (form3 generated) |
| {c}_back ×3 (identical) | 640×640 | yes | 14 | `spr` slots 48-50 (2 are wasted duplicates) |
| {c}_r1 ×3 | 640×640 | yes | 15 / 20 / 52 | slots 51-53 |
| {c}_card{1..3} ×9 | 640×640 | yes | 11–44 | slots 54-62 |
| **{c}_shard/slow/undo/heart_loss/hint_hard ×3** | 640×640 | yes | 11–67 | **new**: 13 images |
| **{c}_freeze ×3** | 375×375 | no (resample) | 170 / 231 / 177 | **new**: 3 images |
| intro_char.png (S1) | 640×640 | yes | 112 | Stage-1 agent's scope (not in ROM today) |
| Boss.png (S2) | 640×640 | yes | 99 | Stage-2 agent's scope |
| app_logo_{appstore,canva,explorer,facebook,pinterest,x}.png (S1) | 706/436/436/435×436/500/500 | no (x: 100×100 ×5) | 60–516 | Stage-1 agent's scope |

New ROM need for the 16 item faces: a separate `card_face.mem` of 16×1024×8 bit = **4 BRAM36** with its own
palette of up to 255 colours. Alternatives: widen `spr` to 96 slots × 8 bit = 24 (+10), or quantise the freeze
cards to fit 7 bit and use 96 slots × 7 = 21 (+7). The display-list `SPRITE.img` field is 6 bits
(`fpga:rtl/video/line_renderer.v:25`). Bits [21:0] are free, so one more image-bank bit fits.

### 5.3 Current BRAM use (from `rom_sync` instances + inferred RAMs)
| memory | depth × width (declared) | file fill | BRAM36 |
|---|---|---|---|
| bg_s1 / bg_s2 (`line_renderer.v:600-601`) | 229 120 × 6 each | full | 42 + 42 |
| spr (`:128`) | 65 536 × 7 | 63/64 images | 14 |
| ui_str (`ui_composer.v:63`) | 32 768 × 8 | last used 17 376 | 8 |
| ui_prog (`ui_composer.v:62`) | 2 048 × 96 | **2018 / 2048 used** | 5.5 |
| ui_ptr (`:64`) | 512 × 15 | 493 / 512 | 0.5 |
| s2_btile (`line_renderer.v:634`) | **8 192** × 48 (file 7 216) | | 11 |
| s2_bmap / s2_wire / s2_mask / s2_npc | 3600×10 / 1512×47 / 350×120 / 256×33 | | 1.5 / 2.5 / 2 / 0.5 |
| s3_txt (`:238`) | 12 288 × 8 | 10 226 | 3 |
| font8x16 / circ | 4096×8 / 1024×8 | | 1 / 0.5 |
| dl_mem, tx_mem, lb0, lb1 (`line_renderer.v:102-133`) | 256×64, 4096×7, 2×640×17 | | 1 + 1 + 0.5 + 0.5 |
| spr_pal, sin256, s3_solid, s3_tidx, 3×64×12 palettes | 128×12, 256×8, 64×49, 64×32 | | 0 (if LUT) … 3 (if BRAM) |
| **total** | | | **≈137 (134.5–140)** of 135 |

* The old docs table (`fpga:docs/ARCHITECTURE.md:54-67`) puts the UI ROMs at "~11". They are **14**:
  5.5 + 8 + 0.5.
* No Vivado utilisation report exists, so all of this is still an estimate. A synthesis run is the first
  task in section 8.

---------------------------------------------------------------------------------------------------

## 6) Memory strategy recommendation

**Demand if everything goes in BRAM**: 137 (today) + 150 (20 pictures, even at the worst-quality
320×180×4 bit) + 4 (item faces) + 5.5 (ui_prog ×2, because it is full and needs title, cutscene, summary and
modal screens) ≈ **297**. That cannot fit.

Options, ranked from least to most fidelity loss:

| # | strategy | fidelity | BRAM | complexity / risk |
|---|---|---|---|---|
| A | **QSPI flash streamer, 640×360, 8-bit index + 256-colour palette per picture** | PSNR 39.8–99 dB vs 4:4:4 (≥43 dB for every new picture). Thai ending text readable. Crossfade becomes fade from black. Optional zoom. | +1 (FIFO + palette) | M: STARTUPE2 + QSPI FSM + line FIFO + a new bg_mode |
| B | DDR2 (MIG) frame buffer, loaded from flash at boot | Exact: crossfades, zoom, 12-bit | +2–4 | L/XL: MIG IP, 200 MHz ref clock, second clock domain + CDC (breaks the single-clock design, `ARCHITECTURE.md` §2). **Still needs the flash reader from A** to fill the DDR. |
| C | Flash streamer at 320×180, 8-bit, ×2 upscale | Ending Thai text illegible. PSNR ~43–99 | +1 | M, needs only 3.5 MB/s, so Dual-SPI works |
| D | BRAM only, 320×180×4 bit, shared palette, RLE | Poor (16 colours: 23.6–31.5 dB) and still 121–150 BRAM | ✗ does not fit | — |

**Flash numbers for A** (checked against the facts in this repo; the part facts are to be confirmed, see §9):

* Data: 20 × 640×360 B = **4 608 000 B** + 20 × 256 × 2 B palettes. With bg_s1 moved as well,
  + 229 120 B.
* The XC7A100T bitstream is ≈3.8 MB. Put the pictures at 0x0040_0000. They end below 0x0090_0000, so they
  fit in the 16 MiB flash.
* Bandwidth: 640 B per active line, 360 lines per 16.68 ms frame = **13.8 MB/s average**, and one line
  (640 B) must arrive in one line time of 31.8 µs = **20.1 MB/s peak** with a small FIFO.
* Quad I/O read at SCK = 100 MHz/2 = 50 MHz gives **25 MB/s**. A line takes 25.6 µs plus about 20 SCK of
  command/address/dummy. That is 81 % of the line time, which is OK.
* Read the frame as one continuous stream (stop SCK during blanking with CS held low) into a 2-line
  FIFO (1280×8, 0.5 BRAM36).
* Fallbacks if 50 MHz via STARTUPE2 does not close timing:
  * 4-bit index at 640×360 needs 10 MB/s, at a cost in fidelity.
  * Option C needs 3.5 MB/s.
* Free BRAM: also stream the **Stage-1 room** (bg_mode 1 uses a 2× camera, so each line reads 320
  contiguous stored pixels from row `(cam_y+y)/2`; one quad read with continuous-mode per line). That
  removes `u_bg1` = **−42 BRAM36**. The Stage-2 room stays in BRAM because its zoom mode and wire overlay
  are timing-tight. Budget after the change: 137 − 42 + 4 + 5.5 + 1 ≈ **105.5 / 135**.
* Fades: draw a full-screen black `RECT` with alpha `(1−fade)·16` in the display list. The premultiplied
  blend already exists (`line_renderer.v:16`), so this needs no new hardware. Crossfades between two
  pictures (open.py 0.45 s, cut23 0.4 s) need two streams, 27.6 MB/s > 25. Render them as a
  0.45 s / 0.4 s **fade-in from black of the new picture**. That is the only visible deviation.
* Zoom (cutscene 1-2, ≤ 8 %): per output line, source row = `180 + (y−180)/zoom`, with an x-step DDA. That
  is one seek per line (≈0.24 µs in continuous-read mode) and can reuse the bg_mode-2 zoom arithmetic. It is
  optional and can be dropped first if time is short.
* Programming: `write_cfgmem -format mcs -size 16 -interface SPIx4 -loadbit "up 0 cpe_escape_top.bit"
  -loaddata "up 0x400000 pictures.bin"`, then Hardware Manager → configuration memory. Icarus simulation
  needs a small behavioural QSPI model that reads `pictures.bin`.

**Recommend A, with bg_s1 also moved to the streamer.** It is the only option that fits, keeps the ending
text readable and stays in one clock domain. B (DDR2) only adds exact crossfades and costs a second clock
domain plus MIG.

---------------------------------------------------------------------------------------------------

## 7) demo_hub parity (`demo_hub.py` OLD → NEW, and `demo_menu.v`)

`demo_hub.py` changes:
* REGISTRY grows from 3 to 7 tabs: **Open, Stage 1, Cutscene 1-2, Stage 2, Cutscene 2-3, Stage 3, Ending**
  (`:24-32`).
* The menu is 30 px wider. Tabs are laid out 3 per row (`:89, 102-107`). A tab is enabled unless it failed
  to load (`not self.errors[i]`; before, only loaded tabs were enabled).
* Tab labels are shrunk to fit (`:206-212`).
* **When the last screen exits, the hub wraps to tab 0 with a fresh handoff** (`:243-245`). Before, it
  called `next_stage()` and reported "No next stage".
* The rest is unchanged: F10/menu, checkpoints (`CHECKPOINTS`/`get_progress`/`jump_to`), shortcuts
  (`ACTIONS`/`do_action`), Hearts 1-3, Form 1-4, Collision debug, Restart stage, "Skip to next stage >>"
  (with handoff).
* Quirk: `select(i)` passes `form = i` (the tab index, `:74-75`). With 7 tabs, picking "Stage 2" sets
  form 3 and "Stage 3" sets form 5. This is a demo-hub bug. Use the form each screen expects (see §9).

`demo_menu.v` today (`fpga:rtl/top/demo_menu.v`) has 15 commands in a 4-bit `sel`. Only 13 (Stage 1) and 14
(Stage 2/3 by SW0) switch screens. Needed for parity:

1. "Go to screen": op 13 with SW[2:0] = 0..6 (Open, S1, C12, S2, C23, S3, End), each starting with the
   hub's default handoff. This replaces op 14.
2. "Skip to next screen >>" with handoff (`next_stage`).
3. Ending shortcuts: end_1..end_9 (SW[3:0] = N), and checkpoints grad/reveal.
4. The Stage 3 "win" action (`stage3_demo.py:55`) already maps to the S3 command set (Stage-3 agent).
5. Widen `sel`/`op` to 5 bits. The 7-seg shows "dE nn", so up to 31 commands fit.
6. Show the current screen on the 7-seg like the Pygame panels: "OPEn", "CUt1-", "CUt2-", "End-N".

The top stage manager needs a 3-bit screen register, and a Stage-3 `exit_req` (win + BTNC). It must also
carry `career` (2 bits), `career_valid` and up to 4 picks × 2 bits from s1_core through s2_core to the
ending. s2_core must take career and picks in instead of starting fresh.

---------------------------------------------------------------------------------------------------

## 8) Ordered, testable work items

| # | item | test | effort |
|---|---|---|---|
| 1 | Run Vivado synthesis of the current design and record real BRAM use (confirms or refutes the ≈137 here) | `report_utilization`: RAMB36/RAMB18 per instance | S |
| 2 | Stage manager: 3-bit screen register, Open → S1 → C12 → S2 → C23 → S3 → End → Open; s3 `exit_req` on win+BTNC | Icarus TB drives each exit and checks the sequence and handoff (form ≥1 after C12, ≥2 after C23) | S |
| 3 | Career + picks handoff: s1 → s2 (stop the s2 self-init) → end. `resolve_ending` in RTL (counts, tie → most recent, empty → middle) | Python model vs RTL for all 3 × (3³ + 3⁴) pick sequences | S |
| 4 | 7-seg `n`, `t` glyphs + screen strings ("H3  OPEn", "H3 CUt1-", "H3 CUt2-", "H3 End-N") | TB checks `chars`; visual check on the board | S |
| 5 | QSPI flash model (sim) + `pictures.bin` packer in `asset_convert.py` (640×360, letterboxed exactly as `fit()`: nearest for title/cut23, smooth for the rest; 256-colour palette per picture; header/offset table) | Packer round-trip → preview PNGs; PSNR ≥ the values in §5.1 | S |
| 6 | Flash streamer: STARTUPE2 CCLK, QIOR continuous read, 2-line FIFO, palette RAM, new `bg_mode 5` | Icarus frame dump == preview PNG bit-exact (`tools/frame_check.py`); on board: title picture | M |
| 7 | Move bg_s1 to the streamer (per-line seek with camera) and remove `u_bg1` | Existing Stage-1 cosim frames unchanged; BRAM −42 in report | M |
| 8 | Item-face ROM (16 × 32×32 × 8 bit) + SPRITE bank bit; card face for rounds 2+ = item art, hint_smart → hint_hard image | TB per round/item/career → image index table derived from `card_assets.get_image` | S |
| 9 | ui_prog 4096 deep, ui_ptr 1024 | ui_compile assembles everything; ROM fill report | S |
| 10 | Open screens: title, 6 pages, counter, blinking prompt, ENTER button pulse, next/back/skip, fade from black | Cosim vs scripted input sequence of `open.py` | M |
| 11 | Cutscene 1-2 (caption box, 3 lines wrapped like `_wrap`, fade, optional zoom) and Cutscene 2-3 (3 slides, bar, back, em dash → '-') | Cosim screenshots vs Pygame at fixed t | M |
| 12 | Ending: summary screen (gradient bands, 42 confetti, sprite bob, 3 card slots, counts), reveal + 1.2 s lock + pill, confirm modal state machine | Cosim of every input path in §3.4; frame compare at fixed t | M |
| 13 | demo_menu parity (§7) | TB: each command lands on the right screen/state | S |
| 14 | `write_cfgmem` flow + docs (STATUS/ARCHITECTURE memory table refresh) | Board boot from flash shows the title | S |

---------------------------------------------------------------------------------------------------

## 9) Open questions (real ambiguities only)

1. **Final entry point.** `demo_hub.py:2-3` says "The final submission does not import this file", but no
   other new file chains the screens. Each screen's `main()` is standalone and restarts itself.
   Assumption: final = hub order with `DEMO_MENU = False`. Confirm.
2. **Board mapping for Esc vs Backspace/Left.** The Pygame cutscenes separate *skip* (Esc) from *back*
   (Left/A/Backspace). The FPGA convention so far is long-press BTNC = Esc/Backspace "back"
   (`stage1_demo.py:448`). Which button means skip, and which means back, on Open, C23 and Ending?
3. **Form after the hub tab jump** (`select(i)` → form = tab index) is a demo bug. Which form should the
   FPGA demo menu use per screen (0 / 1 / 2)?
4. **Flash device on the specific board.** The Nexys A7 reference manual lists a 16 MiB Quad-SPI flash
   (Spansion S25FL128S). Confirm the chip marking, the QE bit and latency/dummy cycles for the QIOR read
   before fixing the streamer timing. Also confirm the QSPI_DQ/CSN pins in Digilent's master XDC. The
   project's `nexys_a7.xdc` has none.
5. **Crossfade and zoom fidelity.** Is a fade from black acceptable in place of the 0.45 s / 0.4 s
   crossfades, and may the 8 % zoom in cutscene 1-2 be dropped? Both are possible only with DDR2 (option B).
6. **Ending sprite for form 3.** Pygame shows form 2 (no form3 file). The FPGA has a generated gold form 3.
   Should it match Pygame (form 2)?
