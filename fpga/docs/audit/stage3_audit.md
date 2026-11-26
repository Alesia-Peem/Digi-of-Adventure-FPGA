# Stage 3 audit: "Campus Run" (new authoritative Stage 3) vs. the existing FPGA port

Date: 2026-11-26. This audit only read files and ran throwaway scripts. The only file it wrote is this one.

Abbreviations used in citations:
`NEW` = `/Users/admin/FPGA-Projects/drive_assets/Digi-of-Adventure-main/onlystage_3/`,
`WRAP` = `/Users/admin/FPGA-Projects/drive_assets/Digi-of-Adventure-main/demo_py/stage3_demo.py`,
`FPGA` = `/Users/admin/FPGA-Projects/Digi-of-Adventure-FPGA/fpga/`.
Every number marked **(measured)** came from scripts that load the real `level.py`, `game.py` and `render.py`. The scripts ran with `python3 -I` and Pillow 11.2.1.

---

## 1. Summary

* **The new Stage 3 is a completely different game from the one the FPGA ports.** The existing `s3_core.v` follows the old single-file `stage3_demo.py`. That game was one 250 m level built from 43 hand-coded solids, with hills, plants, Thai text and a 3-hit reporter. Campus Run has **three** 250×11-tile Tiled levels (S6→S4, S4→CB2, N17→N16) and four animal behaviours (patrol / walk / fly / pop). It also has a delayed-path reporter chaser with an interview freeze, two skills (Cloak in levels 1–2, Phase in level 3), moving and sinking lifts, a "?" block with a milk-tea power-up, and a double jump whose gravity is recomputed with a square root and a division. **No game rule in `s3_core.v` carries over.** What carries over is the engineering pattern: the sequencer, 2 physics steps per 60 Hz tick, the fixed-point "Q" idea, the bit-serial square root, publishing to fields and conds, and the cosim flow.
* **Shared features are not used by Campus Run.** It has no hearts, no Speed Boost / Freeze / armor / shards, and no lose state (infinite retries, 120 s per attempt). A grep of `NEW/*.py` for boost, freeze, armor, heart, shard and handoff finds 0 hits. The hub wrapper only *tries* to set `hearts` and `form` (`WRAP:71-74`), and the `hasattr` guards are always false. The handoff dict therefore passes through unchanged. The player art is form 2 (gown) and form 3 (gold) plus "right2" variants for the skills. The gown PNGs are byte-identical (same MD5) to the form-2 sprites the FPGA already stores in `spr.mem`.
* **The display model maps well to the existing engine.** The world is 20×11 tiles of 32 px, so the 640×352 world fits 1:1 on the 640-px VGA width. The HUD is drawn at 640×360, which is exactly the FPGA game-area size. A scrolling tile background mode can be modelled on the existing Stage-2 breadboard tile mode (`bg_mode 4`). The display-list sprite primitive needs an extension for arbitrary sizes, separate x/y scale, clipping and alpha.
* **Block RAM is the blocking problem.** The existing design is estimated at ≈132 of 135 BRAM36 (not confirmed by Vivado). Removing the old Stage 3 frees about 4. Campus Run needs about **40 BRAM36** with all three levels resident at full tile resolution (4 bpp with a palette per tile). A reduced variant with landmark buildings at half resolution needs about **24**. **Neither fits without freeing BRAM elsewhere.** The realistic lever is the two 42-BRAM36 Stage 1/2 room pictures: halving their resolution frees about 62, and 4 bpp frees 28. External memory (QSPI or DDR2) is the alternative, but it adds risk. This needs a decision from you (D1).
* **Proposed plan.** Write a new `cr_core.v` (entity FSMs, grid collision, 32-bit fixed point with 1 m = 600·4096 units, so every horizontal speed is an exact number of units per 1/120 s tick). Add renderer `bg_mode 5` (32-px tile layer with sub-tile scroll, 4 bpp tiles with a palette per tile, and a low-resolution parallax backdrop) and a `SPRITE2` primitive. Keep `ui_composer` unchanged. Verify in three layers, as before: (1) original `game.py` vs `cr_model.py` within a tolerance with identical discrete events, (2) `cr_model.py` vs RTL bit-exact on every tick, (3) RTL frames vs a Python frame model pixel-exact.

---

## 2. Campus Run specification

### 2.1 Code map

| File | Role |
|---|---|
| `NEW/settings.py` (96 lines) | all constants (physics, timers, spawns, routes, asset names, questions) |
| `NEW/game.py` (630 lines) | `Game` (modes, stages, player physics, enemies, reporter, skills, lifts, puzzle, door); pure logic, no drawing |
| `NEW/level.py` (264 lines) | Tiled `.tmj`/`.tsx` loader, path fallbacks, unit-box solids/water, `surfaces()` |
| `NEW/render.py` (216 lines) | `draw_frame(g)` → 640×360 PIL image |
| `NEW/hud.py` (180 lines) | clock, skill panel, route bar, interview card, modal screens |
| `NEW/pixel_type.py` (28 lines) | 5×7 column-packed pixel font (`title()`) |
| `NEW/winter_art.py` (75 lines) | cosmetic effects: snowfall, night stars, wind, footprints, sparkles |
| `NEW/owner_mode.py` (43 lines) | F1/F2/F3 stage select (debug) |
| `NEW/board/nexys_pad.v` | UART gamepad only: 5 buttons → 0xA0\|bits at 200 Hz; shows 0xD0..0xD5 skill digit on AN0 |
| `WRAP` | hub wrapper (`Game.start/poll/update/draw`, `ACTIONS=[win]`) + standalone Tk app |

The engine runs headless and deterministically once `random` is seeded. A 40 s scripted run of level 1 took 0.8 s and produced the expected event sequence (cloak refused → chase → interview → splash restart) plus a correct frame **(measured)**.

### 2.2 Modes, screens and level flow

| Mode | Entered | Behaviour | Screen |
|---|---|---|---|
| `ready` | only `Game.__init__` (`game.py:182-185`) | waits; Space/Enter → `play` (`WRAP:302`, `WRAP:224-231`) | "HOW TO PLAY" modal (`hud.py:144-161`) |
| `play` | `restart()` always sets it (`game.py:231`) | `step()` runs | world + HUD; interview card or notice (`render.py:206-213`) |
| `pause` | Enter/BTND toggles (`WRAP:118-121`, `WRAP:221-224`) | no steps | "PAUSED" modal with the route (`hud.py:178-180`) |
| `clear` | door reached in level 1 or 2 (`game.py:621-625`) | 2.0 s countdown `LEVEL_CLEAR_TIME` (`settings.py:11`), then `stage += 1` and `restart()` (`game.py:529-535`) | "STAGE CLEAR" + "NEXT ..." (`hud.py:164-174`) |
| `win` | door reached in level 3 with `gold` (`game.py:626-628`) | Enter → `new_game()` (standalone) or `exit_requested` (hub, `WRAP:138-143`) | "Congratulations, graduate!" (`hud.py:175-177`) |

* Note: `WRAP.start()` calls `new_game()`, which sets `play` immediately (`game.py:234-236` → `restart`). The `ready` check at `WRAP:67-68` is dead code, so the HOW TO PLAY screen never appears under the hub.
* There are **no checkpoints and no lives.** Every failure (fall, water, time-up) calls `restart()` at the current level's spawn with full time, skill restored, and enemies re-created (`game.py:542-544`, `game.py:571-574`). "Retry stage" and the R key are the same `restart()` (`WRAP:114-116`). `new_game()` returns to level 1.
* Routes and spawns: `ROUTES={1:(S6,S4),2:(S4,CB2),3:(N17,N16)}` and `SPAWNS={1:(6,3),2:(5,3),3:(6,3)}` (`settings.py:9-10`). The ground at all three spawns is at y=2 **(measured)**, so the player spawns 1 m in the air and falls.
* Doors (`game.py:217-223`): L1 `Box(245,2,5,2.3)`, L2 `Box(247.2,2,1.5,2.3)` (`settings.py:22`), L3 `Box(246,2,4,2.3)`. Entering requires `door.x ≤ p.x ≤ door.x+w` **and** box overlap (`game.py:621`). L2 and L3 also require `gold` (`game.py:622`). `gold` is always true in L3 (`game.py:230`), so in practice only L2 needs the tea. Without it the game shows "Hit the ? block, then collect the milk tea." (`game.py:630`).

### 2.3 Units, timestep and input

* World unit is the **metre = 1 tile = 32 px** (`render.py:9`, `level.py:1`). The origin is bottom-left with y up (`level.py:250`). A tile in row r of the map has `y = 10 - r`.
* The fixed step is **`TICK = 1/120 s`** (`settings.py:8`). The wrappers accumulate wall time (capped at 0.25 s) and run `step()` while `acc ≥ TICK` (`WRAP:131-136`, `WRAP:372-380`).
* Input per step is `axis ∈ {-1,0,1}`, `jump` (bool) and `skill` (bool) (`game.py:528`). Jump presses are counted: each step consumes one (`jump = jumps>0`, `jumps -= 1`, cleared after a restart: `WRAP:133-134`). The skill flag is edge-triggered.
* Wrapper key bits: 1 left, 2 right, 4 jump, 8 skill, 16 menu (`WRAP:27`). The Nexys board through `nexys_pad.v` maps BTNL/BTNR to move, BTNU to jump, **BTNC to skill** and **BTND to start/pause** (`NEW/README.md:19-25`, `hud.py:153-154`).

### 2.4 Player physics (`game.py:275-336`)

| Quantity | Value | Source |
|---|---|---|
| Body box | 0.63 × 1.5 m, x is the centre, y is the feet | `settings.py:14`, `game.py:21-22` |
| Drawn size | 1.12 × 1.5 m (36×48 px); ×1.08 while "enlarged"; ×1.5 more in Phase | `render.py:183-199` |
| Run speed | 5 m/s (1/24 m = 1.333 px per step) | `settings.py:12` |
| Gravity G | `8·JUMP_HEIGHT/JUMP_TIME² = 8·2.5/0.49 = 40.816 m/s²` | `game.py:8`, `settings.py:15` |
| First jump | `vy = G·0.7/2 = 14.286 m/s`, apex 2.5 m at 0.35 s, lands after 0.7 s | `game.py:277-280` |
| Coyote time | 0.15 s (`grace`, reset to 0.15 every grounded step, decremented in air); applies only while `jumps==0` | `settings.py:6`, `game.py:277`, `game.py:327`, `game.py:332` |
| Jump buffer | 0.15 s: a press sets `buffer`; `try_jump()` runs every step while buffer>0, and again on the landing step | `settings.py:7`, `game.py:299-302`, `game.py:328-329`, `game.py:333` |
| Double jump | only if `jumps==1` (after a real first jump) and `elapsed < DOUBLE_TIME-0.08 = 1.12 s` | `game.py:281` |
| Double-jump shape | apex = takeoff + 4.5 m; lands back at takeoff height exactly 1.2 s after the first takeoff; horizontal range 5.5 m: `g' = 2(√rise+√4.5)²/remaining²`, `vy = √(2g'·rise)`, `speed = clamp((5.5-5·elapsed)/remaining,0,5)` with `rise = max(.02, takeoff+4.5-y)` | `settings.py:16`, `game.py:290-295` |
| Anti-double-jump near ground | if falling and a block top lies within `reach = -vy·buffer + ½g·buffer²` below the feet, the press is kept for the landing instead of spending the double jump | `game.py:283-289` |
| On landing | `grace=0.15, jumps=0, speed=5, gravity=G` | `game.py:326-327` |

Worked examples **(measured with the same formulas)**: a double jump 1 step after takeoff gives g'=25.0 m/s², vy=14.8 m/s, speed 4.58 m/s. At the apex (0.35 s): g'=34.6, vy=11.8, speed 4.41. At 1.0 s (already 6 m below takeoff over a pit): **g'=1447 m/s², vy=175 m/s (1.46 m per step)**. The last case is an extreme but legal value, and the fixed-point widths must cover it (see §7).

Integration (`game.py:312-314`) is exact for constant gravity: `dy = vy·dt - ½g·dt²; vy -= g·dt`. Walking off a ledge without jumping leaves `jumps=0`. After the coyote time runs out, no jump of any kind is possible in the air.

### 2.5 Collision method

* **Level geometry is a list of unit boxes**, one `Box(x, y, 1, 1)` per solid tile cell (`level.py:242-252`). There is no merging and no object layers. The `objectgroup` branch exists (`level.py:232-241`), but no map has one **(measured)**. Per level: L1 456 solid + 254 water + 68 decor cells, L2 506 + 155 + 48, L3 666 + 0 + 56 **(measured)**.
* A tile's role comes from `TILESET_KIND` by tileset stem: S4, S6, N16 and N17 are `decor`; `water_1`, `water1_1`, `water1_2` and `water_2_2` are `water`; `waterkonmai_2` is `solid` (`settings.py:32-34`, `settings.py:88`). Anything else is `material(layer name "Tile Layer 1")` = `solid` (`level.py:39-44`, `level.py:251`).
* `game.blocks` = level solids + the puzzle box (L2) + lift boxes (L3), in that order (`game.py:225-227`).
* `Box.touches` uses strict overlap with ε = 1e-7 m (`level.py:25-28`).
* **X pass** (`game.py:306-311`): move, clamp to `[w/2, 250-w/2]`, then push out of each touching block in the "nearby" list (±0.1 m), but only when `axis≠0`. A lift moving into a standing player does not push.
* **Y pass** (`game.py:312-325`): a sweep test per block. A landing needs `dy≤0 and old_y ≥ top-ε and y ≤ top+ε`. A head bump needs `dy>0 and old_y+H ≤ b.y+ε and y+H ≥ b.y-ε`. Blocks are visited in list order (map rows top→bottom), so a fast fall snaps to the **highest** crossed top and a fast rise to the **lowest** crossed bottom. Hitting the bottom of the puzzle opens it.
* **Death** (`game.py:571-574`): `y < -1`, or touching a water box while `not grounded and grace ≤ 0`. Both lead to `restart()`.
* `Level.surfaces(x)` gives the tops of the solid boxes in column `floor(x)` that have no solid directly above them (`level.py:261-264`). Animals use it.
* **FPGA consequence:** every solid is a grid-aligned unit cell, apart from the puzzle (also grid-aligned) and the 2 lifts (non-grid y). Collision can therefore be a lookup in a 250×11-bit solid map plus 3 special boxes instead of a list scan. The model must prove this matches the list-order semantics above (§6, item 3).

### 2.6 Camera and background

* `camera = clamp(p.x - 7, 0, width - 20)` is continuous and sub-pixel; screen x = `round((wx - cam)·32)` (`game.py:336`, `render.py:75-76`).
* Parallax: the background is scaled to 704×352 and shifted by `round(64·cam/230)` px (`render.py:89-94`). Backgrounds: L1 `sunset_2.png`, L2 `mountains_1.png`, L3 `night_3.png` (`settings.py:20`).
* The world frame is 640×352 (`render.py:67`) and is **resized to 640×360 with NEAREST** (`render.py:200`). This is a non-integer 352→360 vertical stretch that duplicates 8 rows. The HUD is drawn after the resize at 640×360. Rows 0–3 are then painted INK (`render.py:202`).
* Level 1 vertical datum shift (`render.py:71-74`) is **0 px** with the current maps **(measured)**.

### 2.7 Entities

Totals **(measured)**:

| Level | Animals | Patrol | Walk | Fly (goose) | Pop (ant) | Followers | Lifts | Puzzle |
|---|---|---|---|---|---|---|---|---|
| 1 S6→S4 (`game.py:50-85`) | 36 | 28 (20 snail, 8 squirrel) | 3 | 0 | 5 | 2 | — | — |
| 2 S4→CB2 (`game.py:88-116`) | 23 | 9 | 4 | 5 | 5 | 0 | — | (240,5) |
| 3 N17→N16 (`game.py:118-158`) | 44 | 27 | 4 | 9 | 4 | 5 | 2 | — |

A static upper bound on animals inside a 22-column window is 10 / 6 / 16 **(measured, approximate: it assumes patrol ranges, not simulation)**.

Common animal data:
* Height `ANIMAL_HEIGHT = 1.5/1.75 = 0.857 m` (27 px). Hit width is `0.857·1.05 = 0.9 m` for the goose and `0.857·0.77 = 0.66 m` for others (`settings.py:31`, `game.py:605-606`). Speed `ENEMY_SPEED = 2 m/s` (`settings.py:13`). Animals start facing −1.
* Activation: `camera + 20 + early ≥ trigger`, where `early = 5` for L2 walkers and flyers and for L3 flyers, else 0 (`game.py:339-341`). Patrol groups share their first member's trigger.
* Spawn snap: `walk/patrol/pop` y snaps to the nearest surface at restart (`game.py:209-216`).
* Skin: `random.choice` from a per-level list (`game.py:45`, `settings.py:43-50`, `settings.py:90-93`). This is cosmetic only.

Motions (`game.py:338-391`):

| Motion | Behaviour |
|---|---|
| `patrol` | x += dir·2·dt and reflects at bounds `(lo-.5, hi-.5)`. It follows a surface within ±1 m, otherwise it reverts x and reverses direction (`game.py:368-378`). |
| follower | Replays its leader's `(x, y, dir)` delayed by `1/ENEMY_SPEED = 0.5 s` = 60 steps, using a deque per follower (`game.py:345-354`). |
| `walk` | Walks forever at dir −1. Steps up ≤1 m when vy≈0, then falls with gravity 30 m/s² onto `level.solids` (`fall_item`, `game.py:394-400`). If it enters water it records `waterline`, sinks at 2.8 m/s and dies when submerged. It also dies at x<−3 or y<−2 (`game.py:379-391`). |
| `fly` (goose) | Constant y, x += −2·dt. The drawn bob `0.06·sin(9t)` is visual only (`render.py:133`). |
| `pop` (ant) | 6 s cycle: hidden 2 s, rise 1 s, above 2 s, fall 1 s (`settings.py:86`). `exposure ∈ [0,1]`. The hitbox and the drawn crop are `h·exposure` above the log top (`game.py:355-361`, `game.py:609-610`, `render.py:134-138`). |

Contacts are edge-triggered per animal index (`self.contacts`, `game.py:598-617`) and are ignored in L3 while Phase is active (`game.py:613`).

**Lifts** (L3 only, `game.py:161-178`, `game.py:226`, `game.py:559-567`). `Lift(163, 4.0, oscillate)` moves its top between 3 and 5 m at 0.8 m/s. `Lift(208, 5.0, sinking)` sinks at 0.6 m/s while ridden and rises back otherwise, clamped to [3, 5] (`settings.py:95-96`). The box is `(col-1, top-1, 2, 1)`. A rider is carried by the top delta before `move()`. Lifts are drawn from the 2×1-tile maps `mai_3.tmj` / `maidown_3.tmj` with the transparent top cropped away (`render.py:47-55`, `render.py:112-116`).

**Puzzle and tea** (L2, `game.py:323-325`, `game.py:576-582`). A head bump on `Box(240,5)` spawns the tea at (240.5, 6) with vy=6. The tea moves +2.6 m/s up to x=241.9 and falls at 24 m/s² onto blocks. Touching its 1.25×1.7 m box sets `gold=True` and `tea_growth_until = time+3` (sprite ×1.08 for 3 s).

**Reporter** (`game.py:412-526`, `game.py:583-597`):
* First animal hit, with no protection active → `chase=True` and the message "A reporter is coming..." (`game.py:522-526`). A hit sets `protection = 0.65 s` (`game.py:516`).
* Chase: the player's route is recorded every step and the reporter stands on the oldest point at least `REPORTER_DELAY = 0.28 s` old (`game.py:437-441`). It stays ≥ `REPORTER_GAP = 1.15 m` behind the facing direction. If that spot is blocked or unsupported, `place_reporter()` searches all blocks within ±10 m for the lowest `(score, x, y)` free spot, where `score = |Δx| + 1.6|Δy| (+2 if within 0.85 m of the player)` (`game.py:412-435`, `game.py:443-463`). Trail points are stored in a 512-entry deque (`game.py:465-476`).
* A second hit during the chase → **interview**: 5 s (`settings.py:18`), 2 questions drawn with `random.sample` from 15 (`settings.py:65-83`), and the reporter is placed 1.3 m in front. The world freezes (`step()` returns early after the timers) while time keeps running. Afterwards there is 1.0 s of protection (`game.py:517-521`, `game.py:551-555`). Question 0 shows while more than 2.5 s remain, then question 1 (`game.py:259-260`).
* No hit counter persists: after an interview the next hit starts a new chase.

**Skills.** Once per attempt; `skill_used` is reset in `restart()`. The duration is `SKILL_TIME = 5 s` (`settings.py:18`).
* **Cloak** (L1–2, `game.py:262-273`): only while `chase`, otherwise the message "Use Cloak when a reporter is following." and no use. It sets chase=False, `cloak_follow = 0.6 s` (the reporter keeps following and shows "?"), then `retreat = 2 s` at 3 m/s back along its trail (with a gravity fallback), then the reporter disappears (`game.py:478-511`, `game.py:584-597`). Hits are blocked only while cloak_follow or retreat is running (`game.py:514`). The player is drawn with the cloak sprite at alpha 180/255 plus 3 ghosts (`render.py:196-199`).
* **Phase** (L3, `game.py:265-267`): animal contacts are ignored for 5 s, and the sprite is drawn ×1.5 (×1.62 in total in L3, because gold is always ×1.08). There is a 0.45 s flash ring at the start and at the end (`game.py:547-548`, `render.py:187-195`). Block collision is unchanged.
* `cloak_digit = ceil(skill)` clamped to 0..5 in play/pause (`game.py:253-256`). This is the only value sent to the board's 7-seg (0xD0|digit, `WRAP:347-355`; `nexys_pad.v` shows it on AN0).

### 2.8 Timer, score and win/lose

* `TIME_LIMIT = 120 s` per attempt (`settings.py:5`). It counts down during play **and** during interviews. At ≤0 the result is "Time up! Skill restored" and a restart (`game.py:541-544`).
* There is no score. `progress = clamp(100·(x-spawn)/(door.x-spawn), 0, 99)`, and 100 in clear/win (`game.py:246-250`). At ≥92 % a one-time encouragement message appears (`game.py:618-620`).
* Messages last 2 s (`game.py:238-239`).
* Win = level 3 door (`game.py:626-628`). **There is no lose state.**

### 2.9 HUD (`hud.py`, all at 640×360)

* Top bar: 4 px INK (`render.py:202`).
* Clock plate (12,13)-(101,38): generated 32×32 frost clock icon + "x" + `ceil(remaining)` in the 5×7 font at ×2 (`hud.py:97-103`).
* Skill plate (492,9)-(632,53): 35×35 icon (ready or used), ability name, then `READY` / `nS` / `USED`, plus 5 pips (`hud.py:104-114`).
* Route bar (134,333)-(506,355): from/to labels, 25 cells of 9-px fill with `n = clamp(round((progress/4 - i)·9), 0, 9)`, and the "%" value (`hud.py:116-130`).
* Interview card (42,229)-(598,322) with a "CPE REPORTER" ribbon, 2 question lines (17-px font) and 5 countdown pips (`hud.py:132-139`).
* Notice plate centred at y 293–325 (`render.py:209-213`).
* Modals dim the screen (alpha 134/255 of (6,30,49)) and draw plate + ribbon + text (`hud.py:141-180`).
* Fonts: Pillow `ImageFont.load_default(size)` (proportional, sizes 10–21) and the 5×7 `pixel_type` font at ×1/×2. A Thai font is used only if a string contains Thai, and **no runtime string does** (all questions and messages are English). The old Thai bitmap ROM is therefore no longer needed.
* "Plates" are 6 nested notched polygons plus corner rivets (`hud.py:48-64`).

### 2.10 Cosmetic effects (not gameplay)

* Snowfall: 42 points in L2 (`winter_art.py:5-13`).
* Night stars: 35 points in L3 (`winter_art.py:67-75`).
* Wind: 3 animated polylines in L1–2 (`winter_art.py:42-53`).
* Footprints: up to 72, fading over 2 s, for the player and walking animals (`game.py:402-410`, `winter_art.py:15-39`).
* Water bob lines: 2 per water tile (`render.py:108-111`).
* Tea sparkles (7), skill particles (9), flash ring (16 lines).

### 2.11 Shared features and handoff

| Shared feature | In Campus Run |
|---|---|
| Hearts | **Not present.** `WRAP` shows `handoff["hearts"]` on the panel only. |
| Speed Boost / Freeze / armor / shards | **Not present.** Passed through unchanged by `get_handoff()` (`WRAP:80-86`). |
| Player forms | Fixed by the game: gown = form 2 art, cloak = form 2 "right2", gold = form 3, phase = form 3 "right2" (`settings.py:36-40`, `settings.py:89`). `handoff["form"]` is ignored. Only right-facing art exists; left facing is a mirror (`render.py:14-15`). |
| Handoff from Stage 2 | Read only to display hearts. Stage 3 always starts at level 1. |
| Hub action | `win` jumps to the win screen (`WRAP:88-93`). There are no `CHECKPOINTS` or `jump_to`. `owner_mode.py` offers F1–F3 stage select. |

**Wrapper bug.** The panel text `f"H{hearts} StG3-{cloak}"` is 9 characters and is cut with `[:8]`, so **the skill digit is never shown** in the hub's 7-seg mock (`WRAP:153-154`).

---

## 3. Asset and BRAM inventory

### 3.1 What is actually referenced (measured through `level.py`, including its fallbacks)

| Group | Files (source size) | Used as | Count / size on screen | Unique colours |
|---|---|---|---|---|
| Generic tiles | 13 + 20 + 11 tilesets of one 640×640 image each (`assets/photo/*_1/_2`, `tiled_3/*_3`; `water_1`/`water_2_2` are 1254²) | 32×32 tiles (NEAREST from 640) | 30 unique generic tiles | 24-bit: L1 33 015, L2 22 380, L3 24 983 (all tiles of the level) |
| Landmark buildings | `location/S4.png` 5120² (L1 40 tiles, L2 24), `location/S6.png` 5120² (L1 28), `N17.png` 5120² (L2 24, L3 28), `assets/N16.png` 1254² declared 5210×5120 (L3 28) | 8×8 grid of 640-px tiles → 32 px each; decor role | 169 unique tiles | (in the totals above) |
| Lift planks | `tiled_3/mai_3.png`, `maidown_3.png` 640² | via `mai_3.tmj` / `maidown_3.tmj` (2×1) | 2 | 2 / 106 |
| **All tiles** | | | **199 unique 32×32 images** (215 before content/flip dedupe); L1 80, L2 67, L3 64. Only flag 0x80000000 (H-flip) is used, 239 / 213 / 287 flipped cells. No animations. All layer alphas = 1. | 1 529 distinct 4:4:4 colours; 54 tiles have transparency; 48 759 semi-alpha pixels |
| Tile maps | `map_1/2/3.tmj`: **250×11 tiles, tile 640×640 in Tiled, one CSV tile layer "Tile Layer 1", no object layers**; `mai_3/maidown_3.tmj` 2×1 | | 778 / 709 / 722 non-empty cells | |
| Player | 12 PNGs 640×640: gown, cloak, gold, phase × stand/stepl/stepr | 36×48; 39×52 (×1.08); phase 58×78 (×1.62) | 12 sources, 21 size variants | 105–383 per image; cloak and phase have 700–1 600 semi-alpha px |
| Reporter | `reporter_stand/step.png` 1024² (P-mode) | 32×48 | 2 | 84 / 96 |
| Animals | 20 PNGs (ant ×3 1280×640; goose ×3, snail ×10, squirrel ×4 at 640²) | cropped to the alpha box, 27 px high, 27–34 px wide | 20 (16 605 px in total) | 25–184 |
| Items | `milk_tea_2.png` 640² → 36×54; `puzzle_2.png` 1254² → 32×32 | | 2 | 944 / 541 |
| Skill icons | 4 × 32×32 native | 35×35 | 4 | 7–12 |
| Clock | generated 32×32 (`hud.py:78-95`); `clock_640.png` unused (`CLOCK=None`, `settings.py:51`) | | 1 | ~12 |
| Backgrounds | `sunset_2.png` 640×360, `mountains_1.png` 640×360, `night_3.png` 1672×941 | 704×352 | 3 | 12 116 / 9 991 / 21 201 |
| Fonts | Pillow default TTF; `pixel_type` 43 glyphs × 5 bytes; `NotoSansThai` (unused at runtime) | | | |

Native resolution check **(measured)**: the generic floor/soil tiles, gown sprites and geese are pixel art on a 32-grid, so 32×32 storage is lossless before quantisation. Landmarks, tea, puzzle, snails, squirrels, ants, the reporter and the form-3 / right2 player art are not 32-grid art; their 32-px result is a NEAREST sample. The gown PNGs are MD5-identical to the FPGA's `assets/player_form2_right_*.png`, which are already in `spr.mem`.

### 3.2 BRAM cost (BRAM36 = 32 Kbit for widths 1/2/4/8, 36 Kbit for 9/18/36)

| Item | Format | Bits | BRAM36 | Quality (measured PSNR vs 32-px RGBA, opaque px, 4:4:4) |
|---|---|---|---|---|
| Tiles, 199 × 32×32 | 8 bpp, one 255-colour palette | 1 630 208 | **50** | 30.6 dB |
| | 6 bpp, one 64-colour palette (4+2-bit split) | 1 222 656 | **38** | 25.5 dB |
| | **4 bpp + 15-colour palette per tile** (+199×16×12 b palette) | 815 104 + 38 208 | **25 + 1** | mean 28.5 dB, worst tile 18.6 dB |
| | 4 bpp, one 15-colour palette per level | 815 104 | 25 | 19.3–20.9 dB (poor) |
| | hybrid: 30 generic full-res 4 bpp + 169 landmark tiles stored 16×16 (×2) 4 bpp | 122 880 + 173 056 | **≈ 10** | landmarks visibly softer; my 16-px test scored 16.6 dB overall, but that metric is unfair to scaled detail → **needs a visual preview** |
| | per-level cache (only the current level resident, loaded from QSPI) 4 bpp | ≤ 80 tiles = 327 680 | 10 + 1 | as the per-tile palette option |
| Tile maps | 3 × 250×11 × 9 bit (8-bit tile id + H-flip) | 74 250 | **3** (one 4K×9 per level; 2 if packed) | exact |
| Tile attributes | 199 × {role 2 b, palette id} | < 2 K | LUT | exact |
| Collision grid | 3 × 250×11 × 1 bit (solid) | 8 250 | LUT / distributed RAM | exact |
| Sprites, stored at drawn size | cloak 3×36×48, gold 3×39×52, phase 3×58×78, reporter 2×32×48, 20 animals, tea 36×54, block, 4 icons, clock ≈ 52 600 px; gown reuses `spr.mem` | 4 bpp + palette per sprite: ≈ 210 K | **≈ 7** (8 bpp: 13) | per-sprite 15 colours not measured; cloak/phase semi-alpha must be thresholded or given 1–2 alpha levels |
| Backgrounds | 88×44 ×8 upscale, 16 colours, ×3 | 46 464 | **2** | 31.4 / 33.1 / 28.5 dB (sunset / mountains / night) |
| | 176×88 ×4 upscale, 16 colours, ×3 | 185 856 | 6 | 32.2 / 35.2 / 29.1 dB |
| | vertical gradient only | 0 | 0 | 26.3 / 26.8 / 23.4 dB |
| Reporter trail | 512 × (x, y, dir) ≈ 72 b | 36 864 | **1** | — |
| Route FIFO (34), follower delay lines (5 × 61), footprints (72) | | | LUTRAM | — |
| **Campus Run total, all levels resident, per-tile palette** | | | **≈ 40** | |
| **Campus Run total, hybrid landmarks** | | | **≈ 24** | |

### 3.3 Budget

`ARCHITECTURE.md` §3 estimates **≈132 of 135** in use (not confirmed by Vivado). Removing the old Stage 3 frees `s3_txt.mem` (12 K×8 = 3) and the sine/solid/text-index ROMs (≤1). That leaves **≈7 BRAM36** free.

| Option | Stage 1/2 rooms | Campus Run | Total (est.) | Fits? |
|---|---|---|---|---|
| O0 | unchanged (42+42) | 24–40 | 149–165 | **no** |
| O1 | both rooms 320×179 6 bpp, ×2 upscale (precedent: the 50T note in `ARCHITECTURE.md:69-70`), frees ≈62 | 40 (full) | ≈106 | yes, ≈29 margin |
| O2 | both rooms 4 bpp 640×358, frees 28 | 24 (hybrid) | ≈124 | yes, ≈11 margin |
| O3 | unchanged | tiles/maps/bg streamed from QSPI or DDR2 | ≈ 132−4+~10 | only with external memory (new clock domain or SPI engine, larger risk) |

---

## 4. Reuse vs rewrite of the existing RTL and tools

| Item | Verdict | Notes |
|---|---|---|
| `rtl/stage3/s3_core.v` (469 lines) | **Rewrite** as `cr_core.v` | The game rules do not match: 43 fixed solids, plants, hills, 3-hit logic, a single level, `px ≥ cam` clamp, Q = 120·65536. Reusable ideas and snippets: the module port shape (`gtick`, `ev_*`, `fields/conds`, `seg_chars`, `leds`, `demo_cmd`), the sequencer style, **2 physics steps per 60 Hz tick** (`R_FRAME`/`R_NEXT`, `s3_core.v:165`, `s3_core.v:277`), the bit-serial square root `R_SQRT` (`s3_core.v:155-164`), reciprocal-multiply helpers, and the publish-to-slots pattern (`R_P0..R_PEND`, `s3_core.v:320-343`). Estimated code reuse is about 15 %. |
| `rtl/stage3/s3_consts.vh` (840 lines, generated) | **Rewrite** (generator) | Replace with per-level entity tables, door/spawn constants and the collision grid, all generated from `level.py` + `game.py`. |
| `rtl/video/line_renderer.v` (712 lines) | **Keep core; extend** | Keep: display list, line buffers, premultiplied "over" blending, RECT/CLRBG/CIRCLE/TEXT/SPRITE, scan-out pipeline. **Remove:** Stage-3 type-7 subs WATER/TERRAIN/TEXTIMG/HILLS and their ROMs (`s3_solid`, `s3_txt`, `s3_tidx`, `sin256`). **Add:** `bg_mode 5` tile layer, cloned from the `bg_mode 4` breadboard prefetch (map → tile → palette, `line_renderer.v:623-655`) but with 32-px tiles, `cam_px mod 32` fine scroll, 4 bpp + palette per tile, index 0 = transparent → backdrop ROM (88×44 ×8 with parallax offset), and procedural water-bob lines. **Add:** type-7 sub `SPRITE2` (any w×h up to about 64×80, separate x/y step, flip, top/bottom/left/right clip for ant exposure, waterline and reporter wall clip, 5-bit alpha for cloak/ghosts, 4-bpp ROM + palette per image). The existing SPRITE is 32×32-only with one step for both axes (`line_renderer.v:23-24`, `S_SPIX`). **Add:** a "world line" flag that maps screen line → `floor(y·352/360)` to reproduce `render.py:200`. |
| `rtl/ui/ui_composer.v` (362 lines) | **Reuse as is** (optionally +1 opcode) | Fields/conds VM, TEXTT pointer tables (question / message selection), NUM, field-driven RECT widths (route bar) and SPR are enough for every HUD and modal screen. Optional: an `SPR2` op that emits a `SPRITE2` entry from a slot field, and a 5×7 `pixel_type` font added to `font8x16.mem` (43 glyphs, tiny). |
| `rtl/common/*` (input_hub, tick_gen, lfsr16, seven_seg, button_unit) | **Reuse** | `heart_system` / `inventory` are not used by Campus Run (pass the handoff through). |
| `rtl/top/cpe_escape_top.v` | **Modify** | Swap the `s3_core` instance, renderer parameters, Stage-3 button mapping and 7-seg/LED source; demo menu op → level select (F1–F3 analogue) and "win". |
| `tools/s3_model.py` (502 lines) | **Rewrite** as `cr_model.py` | Keep the structure: integer model plus `compare_*` against the original. |
| `tools/stage3_assets.py`, `ui_screens_s3.py`, `s3_text.json` | **Rewrite / delete** | The new converter must **import `onlystage_3.level.Level`** so the path fallbacks are reproduced exactly (see §7). There is no Thai text. |
| `tools/cosim_s3.py`, `tb/tb_s3_cosim.v` | **Adapt** | Keep the gen/cmp flow and stim format: bits for left/right/jump/skill/start plus a demo command. Change the trace columns. |
| `tools/frame_check.py` | **Extend** | Add the bg_mode 5 / SPRITE2 Python reference. |

---

## 5. Proposed FPGA architecture for Campus Run

### 5.1 Number format

* Length: **1 m = Q = 600·4096 = 2 457 600 units**, stored in **32-bit signed** registers (±873 m). Every horizontal speed in the game (5, 2, 2.6, 3, 0.8, 0.6, 2.8 m/s) moves a whole number of units per 1/120 s step, because Q/120 is a multiple of 5·4096.
* Pixel conversion is `x·32/Q` = `x/76 800`, done as a reciprocal multiply.
* Vertical velocity is kept in units per step and gravity in units per step² (rounded). This is the same approach as the old model, and it agreed with the float game within mm.
* The double-jump `g'`, `vy` and `speed` are computed once per double jump with a sequential divider (~40 clk) and the existing bit-serial square root. Widths must allow vy up to about 600 m/s and g' up to about 11 000 m/s² (worst case in §2.4); 48-bit intermediates are enough.
* Timers count steps: 120 s = 14 400; 5 s = 600; 0.65 s = 78; 0.15 s = 18; 0.6 s = 72; 2 s = 240; 0.45 s = 54; route delay 0.28 s → oldest entry ≥ 33.6 steps; follower delay 60 steps; ant cycle 240/120/240/120. The exact `EPS` tie rules must be checked against the float game, as the old port did ("timer flips at step N").

### 5.2 `cr_core.v`: sequencer per 1/120 s step

The order follows `step()` (`game.py:528-630`):

1. Clear countdown → next level.
2. Time, notice, flash, phase-end flash, skill, protection.
3. Interview (early exit).
4. Cast.
5. Lifts (2 boxes).
6. `move()`:
   - buffer / `try_jump`;
   - X pass over a ≤2×3-cell grid window plus puzzle and lifts;
   - Y sweep: column scan from the top row down, keeping "first match" semantics;
   - grounded / coyote.
7. Death check (grid water bits).
8. Tea.
9. Route FIFO push.
10. Reporter FSM.
11. Entity loop (≤44 per level, one per few clocks; contact test against the player).
12. Near-finish check.
13. Door.

Sub-blocks:
* **Collision grid:** 3 × 250×11 bits for solid and water, one-cycle lookup. `surfaces(x)` = scan the 11 cells of one column.
* **Entity table:** a ROM per level with species, motion, x0, y0, bounds, trigger, leader index and skin. State registers per entity: x, y, vy, dir, active, alive, age, exposure, waterline flag.
* **Follower delay lines:** 5 × 64 entries in LUTRAM.
* **Reporter FSM:** IDLE / CHASE / INTERVIEW / CLOAK_FOLLOW / RETREAT. It uses a 64-entry route FIFO and a 512-entry trail RAM (1 BRAM36). `place_reporter()` becomes one pass over the solid cells in ±10 columns (≤ 231 + 3 boxes): it computes the score (×1.6 as a constant multiply) and the free-space check, and keeps the lexicographic minimum `(score, x, y)`. This is the same result as Python's `sorted()` followed by "first free".
* **RNG:** `lfsr16` for the skin choice and the question pair. The model uses the same LFSR. In the comparison against the original, `random.choice` / `random.sample` are monkey-patched to draw from that LFSR so the original game sees identical choices.
* **Cycle budget:** a 60 Hz tick has 1.67 M clocks. Two steps with ≤44 entities, a place-reporter scan of about 2 k clocks and a few k for the rest use well under 1 %.

### 5.3 Publish (once per 60 Hz frame) → fields/conds

* `cam_px`, parallax offset and level id go to the renderer.
* Sprite slots carry {x, y, image, flip, clip rows, alpha}:
  - player + 3 cloak ghosts;
  - reporter (+ "?" label);
  - tea;
  - puzzle state;
  - 2 lifts;
  - **16 animal slots** (static upper bound; overflow must raise the existing debug LED).
* HUD values: `ceil(remaining)`, skill digit / ready / used, progress and the 25 route-cell fills, interview remaining and question ids, message id, mode and stage.

### 5.4 Renderer

**Layer 0, `bg_mode 5`, per pixel at scan-out:**
1. Backdrop pixel: 88×44 4-bpp ROM per level, ×8, x + parallax offset.
2. Tile pixel: map ROM → tile id/flip → 4-bpp tile ROM → palette per tile; index 0 = transparent.
3. Water-bob line test for water tiles.
4. Stars/snow optionally generated from a hash per pixel.

**Display list (painter's order as `render.py:101-199`):** lifts, footprints (optional), puzzle, tea, animals, reporter, player effects, cloak ghosts, player, then HUD primitives in 360-line space.

**Line budget:** 3 200 clk per line. A sprite costs about 3 clk per source pixel, so 16 animals + reporter + 58-px player ≈ 1 800 clk worst case. The plates must be emitted as an outline plus a fill, not as 6 full nested fills (the interview card alone would cost about 3 300 clk per line).

### 5.5 Board I/O (needs decision D3)

* Follow Campus Run's own mapping: BTNL/BTNR move, BTNU jump, **BTNC skill, BTND start/pause** (`NEW/README.md:19-25`).
* 7-seg suggestion: `H3 1 120 5` = hearts from the handoff, level, `ceil(remaining)`, skill digit (blank when 0). The original shows only the skill digit.
* LEDs: progress bar plus chase / interview / skill.

---

## 6. Ordered work items (each with a pass criterion)

| # | Work item | Test / done when | Effort |
|---|---|---|---|
| 1 | Decisions D1–D6 (§7) | written in STATUS.md | S |
| 2 | `cr_assets.py`: import `level.py`, dedupe tiles and flips, quantise (per-tile palette), maps, collision/water grid, entity tables, sprites, backdrops; write preview PNGs and a BRAM report | the reconstructed level image from mems equals `level.cells` composited (exact before quantisation); the BRAM report matches §3.2 | M |
| 3 | `cr_model.py` player physics plus grid collision | vs `game.Game` with identical inputs: x/y within 1 mm, same `grounded/jumps/buffer/grace` on every step, over jump / double-jump sweeps (press at every step 1..135 of a jump), coyote and buffer edges, wall push, head bump, a fast fall onto stacked tiles | L |
| 4 | Model: enemies (patrol, follower, walk + water, fly, pop) and contacts | same alive/active/contact sets on every step; positions ≤1 mm; skins via the shared LFSR | M |
| 5 | Model: reporter (chase, place_reporter, interview, cloak follow/retreat), Phase, lifts, puzzle/tea, door/clear/win, time-up, deaths | identical event sequence (mode, stage, chase, interview, skill_used, message ids) in scenarios per level: plan (bot reaches the door), careless, skill, interview, water/pit, lift ride, time-out (14 400 steps), restart | L |
| 6 | Scenario generator / bot that clears each level (or recorded human input via the wrapper) | each level cleared in the original and in the model | M |
| 7 | Renderer `bg_mode 5` + backdrop + parallax + 352→360 row map | `frame_check`: RTL frame = Python frame model, pixel-exact, for 3 levels × several cameras | M/L |
| 8 | Renderer `SPRITE2` (+ `ui_composer` SPR2 op if chosen) | unit TB: sizes, flip, clip, alpha vs a Python reference | M |
| 9 | `cr_core.v` player + collision (items 3 ported) | `tb_cr_cosim`: RTL = model bit-exact on every step | M/L |
| 10 | `cr_core.v` entities | same, scenarios from item 4 | M |
| 11 | `cr_core.v` reporter / skills / interview / lifts / tea / flow | same, scenarios from item 5 | L |
| 12 | `ui_screens_cr.py`: HUD, modals, interview, notices (plates as rect stacks; 5×7 font) | frame check pixel-exact vs the frame model; visual review vs `draw_frame()` | M |
| 13 | Publish + top integration, buttons, 7-seg, LEDs, demo menu (level select, win); remove old Stage 3 | top elaborates; `run_tests.sh` sections 6/8 replaced; overflow LED never set in the scenarios | M |
| 14 | BRAM freeing per D1 (`asset_convert.py` room format change) plus Stage 1/2 frame-check updates | Stage 1/2 cosims still PASS; previews approved | S/M |
| 15 | Vivado synth/impl: BRAM utilisation and timing (wide multiplies in publish may need a pipeline stage) | utilisation ≤ 135 BRAM36, timing met at 100 MHz; board test | M |

---

## 7. Risks and open questions

**Decisions needed**

* **D1 – BRAM (blocking).** Campus Run cannot fit in the about 7 free BRAM36. Choose O1 (halve the Stage 1/2 room resolution), O2 (4-bpp rooms + Campus Run landmarks at half resolution), or O3 (external memory). The 132 baseline itself is an unconfirmed estimate, so run Vivado early (item 15) before committing.
* **D2 – Visual approximations.** Per-tile 15-colour palettes (worst tile 18.6 dB), semi-transparent pixels thresholded (48 759 in tiles; cloak/phase sprites up to about 1 600 each), backdrops at 88×44, and Pillow's proportional fonts replaced by bitmap fonts. Decide whether footprints, snow, stars, wind, sparkles and particles are kept, approximated or dropped: they cost display-list entries (limit 256) and line time.
* **D3 – Buttons.** Campus Run uses BTNC = skill and BTND = start/pause. The current FPGA Stage 3 uses BTNC = start/jump and BTND = skill, and `input_hub` gives BTNC tap / long-press meanings. Which convention wins?
* **D4 – Shared features.** Campus Run ignores hearts, items and the handoff form. Port as-is (as was done for the old Stage 3), or change the Python first?
* **D5 – Hub semantics.** The FPGA could skip the HOW TO PLAY screen like the hub, or show it like the standalone app.
* **D6 – Cutscenes.** The new `demo_py` hub also lists `open`, `cutscene_1_2`, `cutscene_2_3` and `cutscene_ending` (`demo_py/demo_hub.py:24-31`). They are outside this audit and not covered by any estimate.

**Technical risks**

* **Float vs fixed ties.** `Box.touches` uses ε = 1e-7 m, the reporter route uses `time - 0.28 + EPS`, and follower age is a float. As in the old port, exact-boundary cases can differ by one step. Report them as documented "tie" events rather than failures.
* **Extreme double-jump values.** Late double jumps produce g' up to about 10⁴ m/s² and vy up to about 600 m/s, with multi-tile moves per step. The Y-sweep "first match in list order" semantics must be reproduced exactly (highest top when falling, lowest bottom when rising, then puzzle and lifts last in the list).
* **Grid collision equivalence.** The Python checks blocks in list order with the player box updated in place. I argued in §2.5 that the grid lookup is equivalent for unit tiles at ≤ 1/24 m per step horizontally; the model tests (item 3) must confirm it.
* **Asset path fallbacks.** The `map_3.tmj` tilesets point to a non-existent `../../../obby_digital/ด่านที่ 3/...` folder. `level.py:154-210` repairs this with filename searches (`rglob("konmai1_3.png")`). `N16` has two different files: `location/N16.png` and `assets/N16.png` have different MD5s, and the code uses **`assets/N16.png`**. Its 1254² size is rescaled from the declared 5210×5120. I am not sure which N16 is intended; please confirm. Also, the README mentions `map_2(1).tmj` while `settings.py:19` uses `map_2.tmj`.
* **Python randomness.** Skins and questions come from Python's `random`. Matching them requires patching the original in the harness (§5.2).
* **Display-list and line budget.** 16 animal slots is a static estimate, not a simulation. Nested plates are expensive. Measure the worst lines in the frame model.
* **352→360 stretch.** Without the world-line mapping, frames cannot match `draw_frame()` pixel-for-pixel.
* **Wrapper bug.** The 7-seg mock drops the skill digit (`WRAP:153-154`).
* **Test regression.** `run_tests.sh` section 6 tests the old Stage 3. Keep it until the new cosim replaces it, then update `ARCHITECTURE.md` §7 and `STATUS.md`, which currently describe the old game as "ported".
* **Not verified here.** Synthesis, timing and actual BRAM inference (small ROMs may land in LUTs). Per-sprite palette quality was not measured. The landmark half-resolution quality needs a visual check, not my PSNR number.
