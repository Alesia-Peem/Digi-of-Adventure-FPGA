#!/usr/bin/env python3
"""stage2_assets.py - everything Stage 2 needs that is computed FROM the Pygame code itself.

  python3 fpga/tools/stage2_assets.py      (run from anywhere; needs pygame, Pillow, numpy)

Outputs (fpga/mem/ and fpga/rtl/stage2/):
  s2_mask.mem      walkable mask of make_walk_mask(), run-length coded: one 120-bit word per row y=176..525,
                   12 x 10-bit x-positions where the value toggles (relative to x=100, padded with 1023).
                   walkable(x, y) = number of toggles <= x-100 is odd.
  s2_npc.mem       the Boss trajectory, one word per game tick: {walk, x*64 (16b), y*64 (16b)}
                   produced by running stage2_demo's own npc_update() at dt = 1/60:
                   path 1 = door -> player (intro, player at SPAWN), path 2 = -> desk + chair.
  s2_wire.mem      for every (sink, source): wire end points + middle height of the Manhattan route
                   {x_src 10b, y_src 9b, x_sink 10b, y_sink 9b, y_mid 9b} in FPGA game-area pixels.
  s2_btile.mem / s2_bmap.mem / s2_bpal.mem   static part of draw_board() as 8x8 tiles, 64 colours.
  rtl/stage2/s2_consts.vh   anchors / positions / tables as Verilog functions.
"""
import os
import sys

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "demo_py_old"))  # old reference until its phase ports the NEW game
import numpy as np  # noqa: E402
import pygame  # noqa: E402
from PIL import Image  # noqa: E402

MEM = os.path.join(ROOT, "fpga", "mem")
RTL = os.path.join(ROOT, "fpga", "rtl", "stage2")
G = lambda v: int(round(v * 2 / 3))  # noqa: E731   960x540 UI -> 640x360 game area


def load():
    pygame.display.init()
    pygame.font.init()
    pygame.display.set_mode((8, 8))
    import stage2_demo as s2
    return s2, s2.Game()


def write(path, words, digits):
    with open(path, "w") as f:
        for w in words:
            f.write("%0*X\n" % (digits, w))


# ---------------------------------------------------------------- walk mask
def mask_rom(s2, g):
    m = (np.asarray(pygame.surfarray.array3d(g.walk))[:, :, 0] >= 128).T   # [y][x]
    assert not m[:176].any() and not m[526:].any() and not m[:, :100].any() and not m[:, 930:].any()
    words = []
    for y in range(176, 526):
        row = m[y, 100:930].astype(int)
        tog = list(np.nonzero(np.diff(np.concatenate([[0], row])))[0])   # index where value changes
        assert len(tog) <= 12, (y, len(tog))
        tog += [1023] * (12 - len(tog))
        w = 0
        for i, t in enumerate(tog):
            w |= int(t) << (10 * i)
        words.append(w)
    # self-check against blocked()
    def walk(x, y):
        if not (176 <= y < 526 and 100 <= x < 930):
            return False
        w = words[y - 176]
        n = sum(1 for i in range(12) if ((w >> (10 * i)) & 1023) <= x - 100)
        return n % 2 == 1
    for (x, y) in [(682, 300), (150, 200), (600, 450), (700, 500), (500, 230)]:
        assert walk(x, y) == bool(m[y, x]), (x, y)
    write(os.path.join(MEM, "s2_mask.mem"), words, 30)
    return m


# ---------------------------------------------------------------- Boss trajectory
def npc_rom(s2, g):
    g.start_intro()
    p1 = []
    while g.npc["state"] == "to_player":
        g.npc_update(1 / 60)
        p1.append((g.npc["x"], g.npc["y"], g.npc["walk"]))
    g.talk = None
    g.talk_done_intro = None
    n = g.npc
    n["state"] = "to_seat"
    n["path"] = g.find_path((n["x"], n["y"]), (s2.NPC_OBJ.ax, s2.NPC_OBJ.ay)) + [s2.NPC_SEAT]
    p2 = []
    while g.npc["state"] == "to_seat":
        g.npc_update(1 / 60)
        p2.append((g.npc["x"], g.npc["y"], g.npc["walk"]))
    words = [(int(w) << 32) | (int(round(x * 64)) << 16) | int(round(y * 64)) for x, y, w in p1 + p2]
    write(os.path.join(MEM, "s2_npc.mem"), words, 9)
    return len(p1), len(p2)


# ---------------------------------------------------------------- wires
def wire_rom(s2):
    words = []
    for sink in s2.SINKS:
        bx, by = s2.SINK_POS[sink]
        for src in [None] + s2.SRC_LIST:
            if src is None:
                words.append(0)
                continue
            ax, ay = min(s2.SRC_POS[src], key=lambda p: (p[0] - bx) ** 2 + (p[1] - by) ** 2)
            if abs(by - ay) < 40:          # wire_pts(): short hop / same height -> bulge
                if by != ay:
                    off = 26 if by > ay else -26
                else:
                    off = -45 if ay < 300 else 45
                ym = (ay + by) / 2 + off * 3 / 4
            else:
                ym = (ay + by) / 2
            words.append((G(ax) << 37) | (G(ay) << 28) | (G(bx) << 18) | (G(by) << 9) | max(0, G(ym)))
    write(os.path.join(MEM, "s2_wire.mem"), words, 12)


# ---------------------------------------------------------------- static breadboard picture
def board_static(s2, g):
    ui = pygame.Surface((s2.UW, s2.UH))
    ui.fill((18, 20, 26))
    muted = (143, 161, 184)
    pygame.draw.rect(ui, (34, 40, 54), (0, 0, s2.UW, 44))
    g.txt(ui, "DECODER BENCH", 120, 8, g.f_l)
    for i in range(2):                                     # QA target boxes (contents are dynamic)
        x, y = 16 + i * 262, 48
        pygame.draw.rect(ui, (27, 41, 64), (x, y, 254, 66), border_radius=6)
        pygame.draw.rect(ui, (45, 64, 94), (x, y, 254, 66), 2, border_radius=6)
    pygame.draw.rect(ui, (17, 26, 43), (548, 48, 84, 66), border_radius=6)
    g.ctxt(ui, "QA TEST", 590, 56, g.f_tiny, muted)
    r = s2.BTN_CLEAR
    pygame.draw.rect(ui, (27, 41, 64), r, border_radius=5)
    g.ctxt(ui, "CLEAR ALL", r.centerx, r.y + 9, g.f_s, (255, 255, 255))
    ui.blit(g.bb_surf, (16, 116))
    pygame.draw.rect(ui, (120, 110, 90), (16, 116, 928, 384), 3)
    for kind, y in s2.RAIL_LINES:
        red = kind == "1"
        pygame.draw.line(ui, (210, 60, 60) if red else (60, 90, 220), (184, y), (560, y), 4)
        g.txt(ui, "+5V" if red else "GND", 187, y + 4, g.f_tiny, (190, 40, 40) if red else (50, 70, 190))
    for u in s2.IC_X:
        g.draw_ic(ui, u)
    pygame.draw.rect(ui, (70, 74, 84), (24, 124, 140, 74), border_radius=6)
    g.txt(ui, "BENCH DC SUPPLY", 32, 128, g.f_tiny, (225, 228, 235))
    pygame.draw.rect(ui, (10, 30, 14), (34, 144, 80, 26), border_radius=3)
    g.txt(ui, "5.00 V", 44, 148, g.f_m, (90, 255, 110))
    pygame.draw.circle(ui, (210, 50, 50), (130, 160), 6)
    pygame.draw.circle(ui, (30, 30, 36), (150, 160), 6)
    g.txt(ui, "+5V / GND rails", 32, 180, g.f_tiny, (205, 208, 220))
    pygame.draw.rect(ui, (36, 84, 190), (28, 212, 120, 112), border_radius=4)
    g.txt(ui, "DIP SWITCH", 36, 214, g.f_tiny, (225, 235, 255))
    for i, (n, swi) in enumerate((("C", 2), ("B", 1), ("A", 0))):
        y = 238 + i * 32
        pygame.draw.rect(ui, (16, 40, 100), (54, y - 8, 66, 16), border_radius=3)
        g.txt(ui, n, 36, y - 7, g.f_s, (255, 255, 255))
        g.txt(ui, "SW%d" % swi, 124, y - 5, g.f_tiny, (200, 215, 255))
        pygame.draw.line(ui, (150, 150, 158), (148, y), (160, y), 3)
    g.txt(ui, "+5V", 164, 207, g.f_tiny, (190, 40, 40))
    for i, n in enumerate("CBA"):
        x = 46 + i * 36
        pygame.draw.line(ui, (170, 170, 175), (x, 326), (x, 392), 3)
        pygame.draw.rect(ui, (214, 180, 120), (x - 7, 340, 14, 38), border_radius=6)
        for j, col in enumerate([(150, 90, 40), (20, 20, 20), (235, 120, 30)]):
            pygame.draw.rect(ui, col, (x - 7, 345 + j * 9, 14, 4))
        g.txt(ui, n, x - 3, 400, g.f_tiny, (60, 60, 55))
    g.txt(ui, "10k pull-downs: lower end to GND", 30, 418, g.f_tiny, (95, 95, 85))
    for i, s in enumerate(s2.SEGS):
        y = 150 + i * 48
        g.draw_resistor(ui, 668, y, [(200, 40, 40), (200, 40, 40), (150, 90, 40)])
        g.txt(ui, "220", 656, y - 21, g.f_tiny, (95, 95, 85))
    pygame.draw.rect(ui, (12, 12, 16), (770, 128, 160, 230), border_radius=8)
    s2.draw_set(ui, "", 800, 150, 100, 180, (40, 22, 24))
    for i, s in enumerate(s2.SEGS):
        g.txt(ui, s, 774, 136 + i * 32, g.f_tiny, (200, 200, 210))
    g.txt(ui, "COM", 902, 306, g.f_tiny, (60, 60, 55))
    g.ctxt(ui, "7-SEGMENT (common cathode)", 850, 336, g.f_tiny, (180, 180, 195))
    pygame.draw.rect(ui, (17, 26, 43), (770, 366, 160, 56), border_radius=6)
    pygame.draw.rect(ui, (17, 26, 43), (770, 430, 160, 62), border_radius=6)
    g.txt(ui, "POWER", 778, 434, g.f_tiny, muted)
    for i, u in enumerate(s2.UNITS):
        g.txt(ui, u, 780 + i * 36, 464, g.f_tiny, muted)
    for src, pts in s2.SRC_POS.items():                    # source nodes
        for p in pts:
            pygame.draw.circle(ui, s2.src_color(src), p, 7)
            pygame.draw.circle(ui, (20, 20, 26), p, 7, 2)
    for sink in s2.SINKS:                                  # empty sink pins (white + ring)
        p = s2.SINK_POS[sink]
        ring = (215, 60, 60) if sink.endswith(".vcc") else ((80, 110, 230) if (sink.endswith(".gnd") or sink in
                                                             ("pd.C", "pd.B", "pd.A", "seg.com")) else (20, 20, 26))
        pygame.draw.circle(ui, (245, 245, 250), p, 7)
        pygame.draw.circle(ui, ring, p, 7, 3 if ring != (20, 20, 26) else 2)
    for lbl, p in (("C", (160, 238)), ("B", (160, 270)), ("A", (160, 302))):
        g.txt(ui, lbl, p[0] + 10, p[1] - 8, g.f_s, (40, 40, 40))
    pygame.draw.rect(ui, (34, 40, 54), (0, 502, s2.UW, 38))
    g.txt(ui, "Keys: L/R pin, U/D row, BTNC wire (U/D source, BTNC done), hold BTNC back | SW2-0 = test | "
              "Done? leave the bench and ask the Boss", 14, 524, g.f_tiny, (140, 150, 180))
    a = pygame.surfarray.array3d(ui).transpose(1, 0, 2)
    full = Image.fromarray(a)
    return full.resize((640, 360), Image.LANCZOS), full


def board_rom(img, full):
    """64-colour palette: every solid colour Pygame drew (>= 20 px at full resolution, so small coloured
    pins survive the downscale) + the most frequent remaining colours; 6 bit per pixel, 8x8 tiles."""
    import collections
    q12 = lambda a: np.minimum((a.astype(int) + 8) // 17, 15)  # noqa: E731
    key = lambda c: c[..., 0] * 256 + c[..., 1] * 16 + c[..., 2]  # noqa: E731
    seed = [k for k, n in collections.Counter(key(q12(np.asarray(full))).flatten().tolist()).most_common() if n >= 20]
    c = q12(np.asarray(img))
    freq = [k for k, _ in collections.Counter(key(c).flatten().tolist()).most_common()]
    pal = []
    for k in seed + freq:
        if k not in pal:
            pal.append(k)
        if len(pal) == 64:
            break
    pal += [0] * (64 - len(pal))
    P = np.array([[k >> 8, (k >> 4) & 15, k & 15] for k in pal])
    arr = ((c[:, :, None, :] - P[None, None]) ** 2).sum(-1).argmin(-1).astype(np.uint8)
    tiles, idx, tmap = [], {}, []
    for ty in range(45):
        for tx in range(80):
            t = arr[ty * 8:ty * 8 + 8, tx * 8:tx * 8 + 8].tobytes()
            if t not in idx:
                idx[t] = len(tiles)
                tiles.append(t)
            tmap.append(idx[t])
    assert len(tiles) <= 1024, len(tiles)
    words = []
    for t in tiles:                                        # one 48-bit word per tile row (8 x 6 bit, x0 = MSB)
        b = np.frombuffer(t, dtype=np.uint8).reshape(8, 8)
        for y in range(8):
            w = 0
            for x in range(8):
                w = (w << 6) | int(b[y, x])
            words.append(w)
    write(os.path.join(MEM, "s2_btile.mem"), words, 12)
    write(os.path.join(MEM, "s2_bmap.mem"), tmap, 3)
    write(os.path.join(MEM, "s2_bpal.mem"), pal, 3)
    os.makedirs(os.path.join(MEM, "preview"), exist_ok=True)
    Image.fromarray((P[arr] * 17).astype("uint8")).save(os.path.join(MEM, "preview", "s2_board_static.png"))
    return len(tiles)


# ---------------------------------------------------------------- constants for the RTL
def consts(s2, g, l1, l2):
    L = ["// s2_consts.vh - GENERATED by fpga/tools/stage2_assets.py from demo_py/stage2_demo.py. Do not edit.",
         "localparam integer NPC_L1 = %d, NPC_L2 = %d;   // ticks of Boss path 1 / path 2" % (l1, l2),
         "localparam integer N_SINKS = %d, N_SRC = %d;" % (len(s2.SINKS), len(s2.SRC_LIST))]

    def fn(name, width, items, comment=""):
        L.append("function [%d:0] %s(input [7:0] i);  %s" % (width - 1, name, comment))
        L.append("    case (i)")
        for k, v in enumerate(items):
            L.append("        8'd%d: %s = %d;" % (k, name, v))
        L.append("        default: %s = 0;" % name)
        L.append("    endcase")
        L.append("endfunction")
    spots = s2.ITEM_SPOTS
    parts = [k for k, _, _ in s2.PARTS]
    fn("it_ax", 12, [sp.ax for sp in spots], "// item spot: walkable anchor x")
    fn("it_ay", 12, [sp.ay for sp in spots])
    fn("it_part", 4, [parts.index(sp.part) for sp in spots], "// part type (PARTS order)")
    fn("it_ix", 12, [sp.ix for sp in spots], "// position in the picture (glow / zoom target)")
    fn("it_iy", 12, [sp.iy for sp in spots])
    fn("hi_ax", 12, [h.ax for h in s2.HINT_SPOTS], "// hint spot anchors")
    fn("hi_ay", 12, [h.ay for h in s2.HINT_SPOTS])
    fn("part_qty", 4, [q for _, _, q in s2.PARTS])
    objs = s2.OBJS + [s2.NPC_OBJ]
    fn("ob_ax", 12, [o.ax for o in objs], "// whiteboard door bench npc")
    fn("ob_ay", 12, [o.ay for o in objs])
    # sinks: unit of power pins, gate/resistor relations are coded in s2_circuit.v; positions for cursors
    fn("sink_x", 10, [G(s2.SINK_POS[s][0]) for s in s2.SINKS], "// sink pin, game-area px")
    fn("sink_y", 9, [G(s2.SINK_POS[s][1]) for s in s2.SINKS])
    # REF wiring (exact hint): sink index -> correct source index (1..27, 0 = none)
    srcs = [None] + s2.SRC_LIST
    ref = dict(s2.REF)
    fn("ref_src", 5, [srcs.index(ref[s]) if s in ref else 0 for s in s2.SINKS], "// REF build: source per sink")
    order = [s2.SINKS.index(s) for s, _ in s2.REF]
    fn("ref_order", 6, order, "// REF list order (wiring_hint walks it)")
    zf, zi = zoom_lut()
    fn("zoom_f", 10, zf, "// zoom factor x256 for zoom tick 0..90")
    fn("zoom_inv_lut", 17, zi, "// 65536 / zoom factor")
    import math
    fn("glow_r", 5, [int(round((16 + 3 * math.sin(i / 60 * 7)) * 2 / 3)) for i in range(54)],
       "// skill glow radius (game px) for (tick mod 54); 16 + 3 sin(7 t) UI px")
    idx = {x: i for i, x in enumerate(s2.SINKS)}
    L.append("// sink indices used by the circuit evaluator (SINKS order of stage2_demo.py)")
    for u in s2.UNITS:
        L.append("localparam [5:0] SK_%s_VCC = 6'd%d, SK_%s_GND = 6'd%d;" % (u, idx[u + ".vcc"], u, idx[u + ".gnd"]))
    L.append("localparam [5:0] SK_DIPVCC = 6'd%d, SK_PDC = 6'd%d, SK_PDB = 6'd%d, SK_PDA = 6'd%d, SK_SEGCOM = 6'd%d;"
             % (idx["dip.vcc"], idx["pd.C"], idx["pd.B"], idx["pd.A"], idx["seg.com"]))
    L.append("localparam [5:0] SK_S0 = 6'd%d, SK_D0 = 6'd%d;   // resistor inputs s_a.. / display pins d_a.."
             % (idx["sa"], idx["da"]))
    gates = ["N1", "N2", "N3"] + ["A%d" % i for i in range(1, 5)] + ["O%d" % i for i in range(1, 9)]
    fn("gate_in_a", 6, [idx[g + ".a"] for g in gates], "// gate (source 6..20 -> index 0..14) input sinks")
    fn("gate_in_b", 6, [idx.get(g + ".b", 63) for g in gates])
    L.append("// golden segments {g,f,e,d,c,b,a} of input code k (GOLD)")
    fn("gold_segs", 7, [sum(1 << "abcdefg".index(c) for c in s2.GOLD.get(k, "")) for k in range(8)])
    with open(os.path.join(RTL, "s2_consts.vh"), "w") as f:
        f.write("\n".join(L) + "\n")


# ---------------------------------------------------------------- texts (exact strings of stage2_demo.py)
def texts(s2):
    import json
    srcs = [None] + s2.SRC_LIST
    found = ["Found %s (%s)" % (s2.PART_SHORT[sp.part], sp.name) for sp in s2.ITEM_SPOTS]
    t = {
        "spot_name": [sp.name for sp in s2.ITEM_SPOTS],
        "spot_xy": [(sp.ix, sp.iy) for sp in s2.ITEM_SPOTS],
        "spot_clue": ["Clue: " + sp.clue for sp in s2.ITEM_SPOTS],
        "part_label": [n for _, n, _ in s2.PARTS],
        "part_short": [s2.PART_SHORT[k] for k, _, _ in s2.PARTS],
        "part_qty": [q for _, _, q in s2.PARTS],
        "hint_title": [h.title for h in s2.HINT_SPOTS],
        "hint_text": [h.text for h in s2.HINT_SPOTS],
        "intro": list(s2.INTRO_LINES),
        "sink_name": [s2.sink_name(x) for x in s2.SINKS],
        "src_name": [s2.src_name(x) for x in srcs],
        "char_name": [s2.CHAR_NAME.get(k, "?") for k in range(8)],
        "gold": [s2.GOLD.get(k, "") for k in range(8)],
        "item_text": {k: list(v) for k, v in s2.ITEM_TEXT.items()},
        # notebook entries, one table: 0 none | 1..18 found | 19..27 hint titles | 28 installed | 29 boss
        # | 30..38 "QA test t: Boss says g/2 correct" (t = 1..3, g = 0..2)
        "note": [""] + found + ["Hint: " + h.title for h in s2.HINT_SPOTS] +
                ["All parts installed. Bench powered on.", "Boss: bring the finished circuit to me (desk on the right)."] +
                ["QA test %d: Boss says %d/2 correct" % (tt, gg) for tt in (1, 2, 3) for gg in (0, 1, 2)],
    }
    with open(os.path.join(HERE, "s2_text.json"), "w") as f:
        json.dump(t, f, indent=1)


def zoom_lut():
    """apply_zoom(): f = 1 + 1.6 * smoothstep(e(k)), k = t / 1.5 s; per tick t = 0..89 (Q8 and 65536/f)"""
    zf, zi = [], []
    for t in range(91):
        k = t / 90
        e = min(1.0, k / 0.25) if k < 0.5 else min(1.0, (1.0 - k) / 0.25)
        e = e * e * (3 - 2 * e)
        f = 1.0 + (s2_ZOOM_MAX - 1.0) * e
        zf.append(int(round(f * 256)))
        zi.append(int(round(65536 / f)))
    return zf, zi


s2_ZOOM_MAX = 2.6


if __name__ == "__main__":
    os.makedirs(RTL, exist_ok=True)
    s2, g = load()
    mask_rom(s2, g)
    l1, l2 = npc_rom(s2, s2.Game())
    wire_rom(s2)
    n_tiles = board_rom(*board_static(s2, g))
    consts(s2, g, l1, l2)
    texts(s2)
    print("stage 2 assets: mask 350 rows, Boss path %d + %d ticks, %d board tiles, %d x %d wire table"
          % (l1, l2, n_tiles, len(s2.SINKS), len(s2.SRC_LIST) + 1))
