# CPE Escape on FPGA - architecture

Target: Digilent **Nexys A7-100T** (XC7A100T-1CSG324C), Vivado, Verilog-2001.
Reference: the Pygame demos in `demo_py/` (Stage 1 = `stage1_demo.py` + `player_sprite.py` + `card_assets.py`).

## 1. The big picture

```
 buttons/switches ─► input_hub ─► (events once per game tick, 60 Hz)
                                        │
                                        ▼
                    s1_core  (Stage 1 game logic = Game.update() of stage1_demo.py)
                      ├─ lfsr16        FEATURE 3  random numbers (same formula as Pygame)
                      ├─ card_deck     FEATURE 3  3-card rounds, shuffle, reveal, career
                      ├─ inventory     FEATURE 3  armor / shards / boost / slow / freeze
                      ├─ heart_system  hearts, armor absorbs, damage ONLY from the door
                      ├─ sprite_anim   FEATURE 1+2 facing + walk cycle
                      └─ s1_collision  FEATURE 1  floor + furniture (pure geometry)
                                        │  FIELDS (128 numbers) + CONDS (256 booleans) + camera
                                        ▼
                    ui_composer  ("UI virtual machine", runs once per frame in vblank)
                      program ROM ui_prog.mem = every Pygame draw_* function, compiled
                                        │  display list (≤256 primitives) + text RAM
                                        ▼
 vga_timing ─────►  line_renderer  ── background ROM (room picture) + display list ─► VGA pins
 seven_seg / LEDs ◄─ s1_core (H3 + live values, LED0..11 like draw_panel())
```

Why it is split like this:

* **Game logic never draws.** `s1_core` only publishes numbers (`F_HEARTS`, `F_PSX`...) and booleans
  (`C_CU_WB`, `C_DONE1`...). The list is in `tools/ui_spec.py`; `ui_compile.py` generates
  `rtl/ui/ui_map.vh` from it, so Verilog and screens can never disagree.
* **Screens are data, not Verilog.** `tools/ui_screens.py` describes every screen with the *same numbers*
  as the Pygame `draw_*` code (×2/3 because the Pygame UI is 960×540 and the FPGA game area is 640×360).
  Adding Stage 2 and 3 screens = adding Python, not new hardware.
* **Painter's order is kept.** The renderer paints primitives in list order with the same "over" alpha
  blend as Pygame `blit`/`set_alpha`, so overlays (lights off, cards, notebook, red flash, help) stack
  exactly like in Pygame.

## 2. Clock, reset, timing

* One clock: 100 MHz `CLK100MHZ`. The 25 MHz VGA pixel rate is a *clock enable* (`pix_ce`, 1 cycle in 4),
  so there is no clock-domain crossing anywhere.
* Reset: `CPU_RESETN` → `reset_sync` (asynchronous assert, synchronous release) → active-high `rst`.
* Game time: `tick_gen` makes an exact 60.000 Hz tick (`PERIOD = 1 666 667` cycles). All game timing
  (speed 6.0 px/tick, 0.14 s walk frames, Slow 600 ticks, Freeze 300, toast 150, OUT OF HEARTS 180) is
  counted in ticks → independent of the 59.5 Hz VGA refresh.
* Buttons: 2-FF synchroniser → 10 ms debounce → `press` / `tap` (released before 0.8 s) / `long_press`
  (0.8 s, = "back"). `input_hub` latches every event until the next tick so nothing is lost or doubled.

## 3. Memory budget (Block RAM, XC7A100T has 135 × 36 Kb)

| ROM / RAM | size | why this format | ≈ BRAM36 |
|---|---|---|---|
| Stage 1 room `bg_s1.mem` | 640×358 × 6 bit | finalexam.jpg is pixel art (~688 px native); 64-colour palette per room is visually identical to 256 colours (`mem/preview/`) | 42 |
| Stage 2 room `bg_s2.mem` | 640×358 × 6 bit | bg.jpg, same treatment, ready for the Stage 2 port | 42 |
| sprites + cards `spr.mem` | 64 × 32×32 × 7 bit | the PNGs are exactly 32×32 pixel art scaled to 640×640 → stored losslessly | 14 |
| fonts `font8x16.mem` | 2 fonts × 128 × 16 rows | 8×16 (f_m/f_l) and 6×12 (f_s/f_tiny) | 1 |
| UI program / strings / pointers | 2048×96 b, 32 K×8 b, 512×15 b | compiled screens of both stages | ~11 |
| display list, text RAM, 2 line buffers | 256×64, 4096×7, 2×640×17 | | ~4 |
| Stage 2 walk mask `s2_mask.mem` | 350 rows × 120 bit (run-length) | 12 toggle positions per row, 1 read per row | 2 |
| Stage 2 breadboard `s2_btile/bmap/bpal` | 902 tiles 8×8×6 bit + 80×45 map | static part of draw_board(), 64 colours | 11 |
| Stage 2 wire table `s2_wire.mem` | 54×28 × 47 bit | end points of every possible wire | 2 |
| Stage 3 Thai text `s3_txt.mem` | 12 K × 8 bit (10 226 bytes used) | 49 strings / digits as 1-bit bitmaps of the demo's font | 3 |
| Stage 3 solids, text index, sine | 64×49, 64×32, 256×8 | small (may become LUT ROM) | ≤ 1 |
| **total (estimate, not yet confirmed by Vivado)** | | | **≈ 132 of 135** |

The XC7A50T (Nexys A7-50T) has only 75 BRAM36: it cannot hold both rooms. `create_project.tcl 50t`
warns about this. (Option for a 50T: store Stage 2's room at 320×179 and upscale ×2.)

## 4. The display engine

`line_renderer.v` keeps two **line buffers** (640 entries). While line *N* is sent to the monitor,
the engine walks the display list and paints line *N+1* (3 200 clock cycles per line available).
An entry stores `{k, R, G, B}` = "background × k/16 + RGB" (premultiplied alpha), so a dark overlay
painted *after* the player darkens the player too, exactly like Pygame.

Primitives: `RECT`, `CLRBG`, `CIRCLE` (filled or ring, half-widths from `circ.mem`), `TEXT`
(8×16, 16×32 or 6×12 font), `SPRITE` (32×32 image, scale 1..4, optional mirror), `WIRES` (Stage 2) and
the Stage 3 group: `WATER`, `TERRAIN`, `TEXTIMG`, `HILLS` (section 8).

Background per pixel (`bg_mode`): solid colour (close-ups), Stage-1 room with camera (stored pixel =
2×2 screen pixels, `addr = ((cam_y+y)/2)*640 + (cam_x+x)/2`), Stage-2 room 1:1 or zoomed, Stage-2
breadboard tile map, Stage-3 sky (8-bit vertical gradient, 2×2 ordered dither to the 4-bit DAC).

Big pictures (rooms, cutscenes, endings) live in the QSPI flash at `PIC_BASE` = 0x400000 (`tools/pic_pack.py`:
"CPEP" header, per picture a 256 × 12-bit palette + w × h index bytes). `pic_stream.v` loads the palette on
`pic_load` (vblank) and fetches one whole row per `row_req` with a single `0x6B` quad read (`qspi_reader.v`,
SCK 50 MHz, 640 B ≈ 2 650 clk < 3 200 clk per line) into a ping-pong 2 × 1024-byte row buffer (w ≤ 768 B = line budget): one line of
latency (row of request k−1 readable via `rd_x` → `rd_rgb`, 2 clk, during line k); repeated rows are not re-fetched.
`bg_mode 5` shows such a picture 1:1: `line_renderer` requests game row L at hcount 640 of VGA line L+58 (shown on
line L+60 after the next request), reads `rd_x` = x, and uses `bg_color` outside w × h. Every background (all modes) is
then faded: channel → ⌊c · fade / 16⌋ (fade 0..16) before the display list is composed on top unfaded.

**Flash pins (`qspi_io.v`).** The only Xilinx primitives of the design: SCK leaves through `STARTUPE2.USRCCLKO`
(the CCLK pin has no user I/O), each `QSPI_DQ[i]` goes through an `IOBUF` (T = ~oe), `QSPI_CSN` is a plain
output. Under `` `ifdef SIMULATION `` (all Icarus runs, `run_tests.sh` passes `-DSIMULATION`; Vivado never
defines it) the module is behavioural and exposes the flash clock on `sim_sck`, which testbenches connect to
`tb/flash_model.v` (`dut.u_qio.sim_sck`); in synthesis `sim_sck` = 0 and is left unconnected.

**Screen sequence (`rtl/top/stage_mgr.v`).** `BOOT → OPEN → S1 → C12 → S2 → C23 → S3 → END → OPEN`. Stages
leave with their `exit_req` (Stage 3: BTNC on the WIN screen, taken by the top from `C3_WIN`); the picture
screens (placeholders until Phase 5: title, cutscene 1-2, cutscene 2-3, ending 1) leave on a BTNC tap. A change
is requested, then applied in the next vblank: in that cycle the stage `*_enter` pulse fires, or, for a
picture screen, `pic_load` + `pic_id` fire together with the switch to `bg_mode 5`. On a picture screen the
top feeds the composer only condition 0 (no `IS_S1/2/3`), so the UI program draws nothing and the picture is
shown alone. A BTNC press held across a transition does not act on the new screen. Demo menu 13/14 jump
straight to a stage (no cutscene). The handoff (armor, shard, boost) is latched at the stage exit; `form`
never decreases (≥ 1 after C12, ≥ 2 after C23).

## 5. Stage 1 game logic (`s1_core.v`)

Per tick the sequencer runs exactly the order of `Game.update()`:

1. 7 × LFSR step  2. flash / toast timers  3. help → clear → over screens
4. Slow/Freeze timers  5. `card_trigger()` (+ shuffle: step LFSR until `lfsr & 7 < 6`)
6. cards **or** notebook (SW14) **or** map (`blocked()` X then Y, sprite update, `find_near()` on BTNC)
   **or** close-up handler of the current object.

Positions are *world pixels with one decimal* (`px_i`, `px_f` tenths) so 6.0 / 7.2 / 3.0 / 3.6 px per
tick are exact. `blocked()` is `s1_collision.v`: the floor trapezoid of the demo compared in integers
(`100·x < 60000 − 76·(y−355)` ...) plus the 8 furniture rectangles with pygame `colliderect` rules.

Puzzles (all checked by `tools/verify_puzzles.py`):

| | where | input | correct answer | logged in notebook |
|---|---|---|---|---|
| P1 | whiteboard | SW3..0 | 0x2A − 0b10011 − 0o21 = **6** | A = value |
| P2 | paper (K-map, Gray order) | SW7..4 letters, SW3..0 plain/inverted, T1..T3 | **AB + CD** (≤ 4 literals) | equation |
| P3 | laptop 1 (NAND editor) | U/D/L/R | truth table = 0xF888 | B = number of 1s = **7** |
| P4 | laptop 2 | SW7..0 | −12 = **11110100** | C = number of 1s = **5** |
| P5 | PC (after the projector clue, lights off) | letters | **CPE** | — |
| Door 1 | | 2 digits | ord('E') = **69** | − heart if wrong |
| Door 2 | | 5 digits | row 6 7 5 1 8 → order 4-2-5-1-3 → **17865** | − heart if wrong |

Like the Pygame demo, wrong puzzle answers are *not* reported and never cost a heart; only the door
(`door_dmg` → `heart_system`) can.

## 6. Stage 2 game logic (`s2_core.v`)

Same sequencer idea as Stage 1, following `Game._update()` of `stage2_demo.py`. Specific parts:

| Pygame | FPGA |
|---|---|
| `make_walk_mask()` + `blocked()` (8 sample points of the 20×10 feet box) | `s2_walk.v`: run-length mask ROM made from Pygame's own mask, 3 row reads per query |
| wall slide `sp * 0.7` | positions in hundredths of a pixel, 5.20 / 3.64 px exact |
| Boss: BFS path + `npc_update()` | the trajectory is deterministic (the intro always starts at SPAWN), so `stage2_assets.py` records it from `npc_update()` itself → `s2_npc.mem`, played back one entry per tick |
| `val()` recursion over the breadboard | `s2_circuit.v`: explicit stack, same `seen` rule for wiring loops; run for the 7 segments + 27 sources every tick (wire colours, live display) and for the two QA inputs (judge, hints) |
| 54 bezier wires | `WIRES` primitive in the renderer: Manhattan route (up/down to the curve's middle height, across, into the pin), drawn straight from the wiring register |
| camera push-in on a found part (`apply_zoom`) | room ROM sampled through `zoom_o + screen × 65536/f`, the same transform applied by the composer to the world primitives (player, Boss, glow) |
| 41 px player (`SPR_H = 62`) | fractional sprite scaling (step = 32/41 × 256) |
| inventory overlay, Stage-2 item rules | `inventory.v` with `store_mode = 1` |

## 7. Stage 3 game logic (`s3_core.v`)

`stage3_demo.py` is a physics game (float metres, fixed `DT = 1/120 s`, two steps per 60 Hz frame).
Floats are not an option on the FPGA, so the port has **two** reference levels:

```
stage3_demo.py (float)  ──same inputs──►  tools/s3_model.py (integers)  ──bit exact──►  s3_core.v
                 positions within 2 mm, same states / hits / skill        every value, every tick
```

**Number format.** 1 m = `Q = 120·65536` units. Then every horizontal speed of the demo
(5, 2, 1, 14 m/s) moves a *whole* number of units per 1/120 s step - the drift that a Q16 format gets
(1/120 is not a binary fraction; 4 mm after 20 m, enough to move a collision by one step) is gone.
Vertical speeds are stored per step (`py += vy`, no division). 250 m = 1.97·10⁹ units → 36-bit registers.
Timers count steps; their start values are the step counts at which the demo's float timer actually
flips (`1.5 s → 181`, `0.1 s → 13`, `5 s → 600`, `1.8 s → 217`, `120 s → 14 400`).
Divisions by 24 / 10 / 120 (`upd_rep`, the double-jump √) are reciprocal multiplies, identical in model
and RTL. The double jump `vy = √(2·25·h)` uses a bit-serial integer square root (30 clocks).

**Sequencer.** One solid or animal per clock, in the demo's order: events → `do_jump()` / `skill()` →
2 × `step()` = timers, `step_p()` (move x, 43 solids in x, gravity, 43 solids in y), `upd_a()` for the
23 animals (walkers call `surf()` = another 43-solid scan), hit test, `upd_rep()`. Worst case ≈ 1 600
clocks per tick (of 1.67 M).

**Display.** After every tick the *publish* states turn metres into screen pixels (32 px/m) and fill
**slots**: up to 6 animals, 2 falling animals (drawn *before* the water, like the demo), 3 plants. The
screen program (`ui_screens_s3.py`) draws `draw()`/`hud()`/`panel()` of the demo around those anchors.
New renderer primitives (type 7):

| primitive | per scan line | demo code |
|---|---|---|
| `HILLS` | `y ≥ 200 − 35·sin(x·0.54 + phase)` from a 256-entry sine ROM, 1 px / clock | hill polygon |
| `WATER` | `y ≥ 296 + 2·sin(x·2.04 + phase)`, alpha 14/16 | `water_layer` polygon |
| `TERRAIN` | walks the 43-entry solid ROM; per kind: grass strip, stone / crate grid + checker, bridge planks, log + end circle | `draw_terrain()` |
| `TEXTIMG` | 1-bit bitmap rows from `s3_txt.mem` | `txt()` with the Thai font |

Thai text: the hardware has no Thai shaping, so `stage3_assets.py` renders every Thai string *with the
demo's own Pygame font* (Tahoma Bold / regular on this Mac, as `make_font()` chooses) into 1-bit
bitmaps; numbers are assembled from per-digit bitmaps (`D13_*`, `D14_*`) selected by fields.

## 8. Board I/O

| | use |
|---|---|
| BTNU/D/L/R | walk (held) / move cursors (pressed); Stage 3: L/R run, U jump, D skill |
| BTNC | tap = interact / confirm, hold 0.8 s = back; Stage 3: start / jump (= Space) |
| SW0..SW7 | puzzle inputs (as in the demo panel) |
| SW12 | demo menu (on-board `demo_hub.py`) |
| SW13 | Stage 2: workshop-shirt skill (rising edge) |
| SW14 | notebook |
| SW15 | Stage 2: inventory |
| 7-seg | `H3` + live value (dial value, patch value, door digits, PC letters, `PA55`, `dEAd`); Stage 3: `3-m ss` time left + metres |
| LED0-2 | hearts, LED3 armor, LED4-8 puzzles answered, LED9 lights, LED10 freeze, LED11 slow; Stage 3: LED0-9 distance, LED10 skill ready, LED11 skill used, LED12 reporter, LED13 interview |
| LED14 | render overflow (debug, should stay off), LED15 demo menu active |
| RGB LED16 | career colour (green/yellow/red), RGB LED17 red damage flash |
