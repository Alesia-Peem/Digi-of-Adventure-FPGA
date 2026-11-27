#!/usr/bin/env python3
"""cr_assets.py - Campus Run (onlystage_3/) data for the hardware. The game's own loader and constructors
are imported, so path fallbacks, spawn lists and spawn snapping are exactly the game's.

Collision grid: one word per map column (0..249); bit r = the cell whose world y is r (0 = bottom row).

Run `python3 -I fpga/tools/cr_assets.py` to write (committed) fpga/mem/cr_*.mem, mem/preview/cr_*.png and
rtl/stage3/cr_consts.vh. Level index 0..2 = stage 1..3.
  cr_solid / cr_water  addr level*256+col, 11 bit
  cr_map               addr level*4096+row*256+col (row 0 = TOP), 9 bit {hflip, tile id}; tile 0 = empty
  cr_tiles             addr id*1024+y*32+x, 4 bit; index 0 = transparent
  cr_tpal              addr id*16+index, 12 bit 0x0RGB
  cr_ent               addr level*64+i, one word per animal (fields: ENT_FIELDS, LSB first)
  cr_spr / cr_spal     4-bit pixels of all sprites back to back / 16 x 0xARGB per sprite (A = 0..15, the
                       sprite's own see-through-ness), stored facing right as drawn
  cr_stab              per sprite {width, height[7:0], offset[23:0]}
  cr_edge              addr pattern*512+k, 1 bit: edge_bits() of the animals (ent field "edge" = pattern)
  cr_fpexp             addr t0 (step a footprint was made), 1 bit: does it expire at exactly 240 steps
Tiles are hard-edged at alpha 128 (decision D2); sprites keep their alpha in the palette.
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)

import onlystage_3.settings as C          # noqa: E402
from onlystage_3.level import Level       # noqa: E402
from onlystage_3.game import Game, Actor  # noqa: E402,F401
import onlystage_3.render as render       # noqa: E402
import onlystage_3.hud as hud             # noqa: E402

FPGA = os.path.abspath(os.path.join(HERE, ".."))
MEM = os.path.join(FPGA, "mem")
VH = os.path.join(FPGA, "rtl", "stage3", "cr_consts.vh")
Q = 600 * 4096                             # fixed-point units per metre
SPECIES = ("snail", "squirrel", "ant", "goose")
MOTIONS = ("patrol", "walk", "fly", "pop")
# (name, width) from bit 0 upwards; positions are signed units
ENT_FIELDS = (("x", 32), ("y", 32), ("base_y", 32), ("lo", 32), ("hi", 32), ("trigger", 32),
              ("species", 2), ("motion", 2), ("leader1", 6), ("active", 1), ("nskins", 3),
              ("edge", 7))             # edge: which cr_edge pattern

_maps = None
_tileset = None
_sprites = None


def load_maps():
    """{stage: Level}, loaded once"""
    global _maps
    if _maps is None:
        _maps = {s: Level(C.ASSETS / name) for s, name in C.MAPS.items()}
    return _maps


def grid(level):
    """(solid, water): column words. Raises if the map stops being a grid of unit cells."""
    out = []
    for boxes in (level.solids, level.water):
        cols = [0] * level.width
        for b in boxes:
            x, y = int(b.x), int(b.y)
            if (b.x, b.y, b.w, b.h) != (x, y, 1, 1) or not (0 <= x < level.width and 0 <= y < level.height):
                raise ValueError("not a unit cell inside the map: %r" % (b,))
            cols[x] |= 1 << y
        out.append(cols)
    return out[0], out[1]


def surfaces_mask(solid_col):
    """cells with no solid directly above: their tops are Level.surfaces()"""
    return solid_col & ~(solid_col >> 1)


def entities(stage):
    """the animals of a stage right after Game.restart() (spawn snap done), construction order, no skins"""
    g = Game(load_maps())
    g.stage = stage
    g.restart()
    index = {id(e): i for i, e in enumerate(g.enemies)}   # by identity: Animals can compare equal
    out = []
    for e in g.enemies:
        lo, hi = e.bounds if e.bounds is not None else (0, 0)
        out.append(dict(species=e.species, motion=e.motion, x=e.x, y=e.y, base_y=e.base_y, lo=lo, hi=hi,
                        trigger=e.trigger, leader=-1 if e.leader is None else index[id(e.leader)],
                        active=bool(e.active)))
    return out


def skins(stage):
    """{species: [files]} in the order random.choice() sees them in the game"""
    if stage == 2:
        return {k: list(v) for k, v in C.ANIMALS.items()}
    table = C.STAGE_ONE_ANIMALS if stage == 1 else C.STAGE_THREE_ANIMALS
    return {k: [n for n in names if (C.ASSETS / n).is_file()] or list(C.ANIMALS[k]) for k, names in table.items()}


# ---------------- which side of a mark the float game is on ----------------
EDGE_MARKS = 512          # more than 14400 steps / 30
_edges = {}


def edge_bits(stage):
    """one int per animal. A walking or patrolling animal reaches a half-metre mark every 30 steps, where the
    exact position sits on a tile edge or a patrol bound and the game's float sum is 1e-13 to one side of it.
    Bit k = at the k-th mark reached, the float is already past it: below a tile edge (whole metre), or beyond
    the bound in the direction of travel (half metre). Recorded by running the game's own update_enemy()."""
    if stage not in _edges:
        g = Game(load_maps())
        g.stage = stage
        g.restart()
        g.camera = 1e6                                   # everything awake
        out = []
        for e in g.enemies:
            follower, e.leader = e.leader is not None, None
            bits, k = 0, 0
            if e.motion in ("walk", "patrol", "fly"):
                for _ in range(60 if follower else C.TIME_LIMIT * 120):     # a follower only walks at first
                    if not e.alive or e.waterline is not None:
                        break
                    raw, d = e.x + e.direction * C.ENEMY_SPEED * C.TICK, e.direction
                    mark = round(raw * 2) / 2
                    if abs(raw - mark) < 1e-6:
                        if (raw < mark) if mark == int(mark) or d < 0 else (raw > mark):
                            bits |= 1 << k
                        k += 1
                    g.update_enemy(e, C.TICK)
            assert k <= EDGE_MARKS
            out.append(bits)
        _edges[stage] = out
    return _edges[stage]


# ---------------- tiles ----------------
class TileSet:
    def __init__(self):
        self.images = [np.zeros((32, 32, 4), np.uint8)]    # tile 0 = empty
        self.maps = {}                                     # stage -> [row 0 = top][col] = (id, hflip)
        self.lifts = [[], []]                              # [oscillating, sinking] -> two (id, hflip)
        self._ids = {}

    def add(self, img):
        a = np.array(img.convert("RGBA"))
        if a.shape[0] < 32:                                # upper_plank() crops the transparent top
            a = np.concatenate([a, np.zeros((32 - a.shape[0], 32, 4), np.uint8)])
        for flip, view in ((0, a), (1, a[:, ::-1])):
            tid = self._ids.get(view.tobytes())
            if tid is not None:
                return tid, flip
        tid = len(self.images)
        self.images.append(a)
        self._ids[a.tobytes()] = tid
        return tid, 0


def tileset():
    """every tile as draw_frame() draws it, deduplicated up to a horizontal flip"""
    global _tileset
    if _tileset is None:
        T = TileSet()
        for stage, level in load_maps().items():
            rows = [[(0, 0)] * level.width for _ in range(level.height)]
            for b, _, ts, num, flags, alpha in level.cells:
                img = ts.image(num, flags, alpha, 0.)
                if stage == 3 and ts.data["name"] in ("mai_3", "maidown_3"):
                    img = render.upper_plank(img, flip=ts.data["name"] != "maidown_3")
                row, col = level.height - 1 - int(b.y), int(b.x)
                if rows[row][col] != (0, 0):
                    raise ValueError("two tiles in one cell, stage %d (%d,%d)" % (stage, col, row))
                rows[row][col] = T.add(img)
            T.maps[stage] = rows
        for sinking in (False, True):
            for _, _, ts, num, flags, alpha in render.platform_art(sinking):
                T.lifts[int(sinking)].append(
                    T.add(render.upper_plank(ts.image(num, flags, alpha, 0.), flip=not sinking)))
        _tileset = T
    return _tileset


# ---------------- 15 colours + transparent ----------------
def _refine(pix, pal):
    """k-means on the 4:4:4 grid; pix and pal are float arrays in 0..15"""
    for _ in range(8):
        near = ((pix[:, None, :] - pal[None, :, :]) ** 2).sum(2).argmin(1)
        new = np.array([pix[near == k].mean(0) if (near == k).any() else pal[k] for k in range(len(pal))])
        new = np.round(new)
        if np.array_equal(new, pal):
            break
        pal = new
    return pal


def _quantise_hard(rgba):
    """(indices h x w, palette of 16 x 0x0RGB). Index 0 = transparent (alpha < 128)."""
    opaque = rgba[:, :, 3] >= 128
    idx = np.zeros(rgba.shape[:2], np.uint8)
    colours = np.zeros((0, 3))
    if opaque.any():
        rgb = rgba[:, :, :3][opaque]
        pix = rgb.astype(float) / 17.
        colours = np.unique(np.round(pix), axis=0)
        if len(colours) > 15:
            strip = Image.fromarray(rgb.reshape(1, -1, 3), "RGB").quantize(
                15, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
            start = np.array(strip.getpalette(), float).reshape(-1, 3)[:15]
            colours = _refine(pix, np.round(start / 17.))
        near = ((pix[:, None, :] - colours[None, :, :]) ** 2).sum(2).argmin(1)
        idx[opaque] = near + 1
    pal = [0] + [int(r) << 8 | int(g) << 4 | int(b) for r, g, b in colours]
    return idx, pal + [0] * (16 - len(pal))


def decode(idx, pal):
    """the RGB image of the palette colours (alpha ignored; index 0 gives black here)"""
    table = np.array([[(c >> 8 & 15) * 17, (c >> 4 & 15) * 17, (c & 15) * 17] for c in pal], np.uint8)
    return table[idx]


def _spread_seeds(colours, counts, n):
    """start colours far apart, so a colour used by only a few pixels (an eye) still gets its own entry"""
    chosen = [int(counts.argmax())]
    dist = ((colours - colours[chosen[0]]) ** 2).sum(1)
    while len(chosen) < n:
        k = int((dist * counts ** 0.25).argmax())
        chosen.append(k)
        dist = np.minimum(dist, ((colours - colours[k]) ** 2).sum(1))
    return colours[chosen]


def _quantise_soft(rgba):
    """sprites: palette entries 0xARGB, so see-through art stays see-through"""
    levels = np.round(rgba.astype(float) / 17.)
    visible = levels[:, :, 3] > 0
    idx = np.zeros(rgba.shape[:2], np.uint8)
    pix = levels[visible]                                    # r g b a in 0..15
    colours, counts = np.unique(pix, axis=0, return_counts=True)
    if len(colours) > 15:
        colours = _refine(pix, _spread_seeds(colours, counts.astype(float), 15))
    idx[visible] = ((pix[:, None, :] - colours[None, :, :]) ** 2).sum(2).argmin(1) + 1
    pal = [0] + [int(a) << 12 | int(r) << 8 | int(g) << 4 | int(b) for r, g, b, a in colours]
    return idx, pal + [0] * (16 - len(pal))


def quantise(rgba, soft=False):
    """(indices h x w, 16 palette words). Index 0 = nothing drawn.
    soft=False (tiles): 0x0RGB, hard edge at alpha 128.  soft=True (sprites): 0xARGB."""
    return _quantise_soft(rgba) if soft else _quantise_hard(rgba)


# ---------------- sprites, at the size they are drawn ----------------
def _player_size(scale):
    return round(1.12 * scale * 32), round(C.PLAYER_HEIGHT * scale * 32)      # render.py actor()


def sprite_images():
    """{(name, width, height): RGBA array}, in ROM order"""
    global _sprites
    if _sprites is not None:
        return _sprites
    out = {}

    def add(name, img):
        a = np.array(img.convert("RGBA"))
        out[(name, a.shape[1], a.shape[0])] = a

    gold = C.GOLD_SCALE
    for form, scales in (("gown", (1.0,)), ("cloak", (1.0, gold)), ("gold", (1.0, gold)), ("phase", (gold * 1.5,))):
        for scale in scales:
            for name in C.PLAYER[form]:
                add(name, render.sprite(name, _player_size(scale)))
    for name in C.REPORTER:
        add(name, render.sprite(name, (32, round(C.REPORTER_HEIGHT * 32))))
    for stage in (1, 2, 3):
        used = {e["species"] for e in entities(stage)}
        for species, names in skins(stage).items():
            if species in used:
                for name in names:
                    add(name, render.animal_sprite(name, 1))
    add(C.TEA, render.collectible(C.TEA))
    add(C.BLOCK, render.sprite(C.BLOCK, (32, 32)))
    for pair in C.SKILL_ICONS.values():
        for name in pair:
            add(name, render.sprite(name, (35, 35)))
    add("clock", hud.frost_clock())
    _sprites = out
    return out


# ---------------- entity words ----------------
def entity_fields(e, skin_lists):
    out = {}
    for key in ("x", "y", "base_y", "lo", "hi", "trigger"):
        units = e[key] * Q
        if units != int(units):
            raise ValueError("%s=%r is not a whole number of units" % (key, e[key]))
        out[key] = int(units)
    out.update(species=SPECIES.index(e["species"]), motion=MOTIONS.index(e["motion"]), leader1=e["leader"] + 1,
               active=int(e["active"]), nskins=len(skin_lists[e["species"]]))
    return out


def _lsb(name):
    names = [n for n, _ in ENT_FIELDS]
    return sum(w for _, w in ENT_FIELDS[:names.index(name)])


def pack_entity(fields):
    word, shift = 0, 0
    for name, width in ENT_FIELDS:
        word |= (fields.get(name, 0) & ((1 << width) - 1)) << shift
        shift += width
    return word


def unpack_entity(word):
    out = {}
    for name, width in ENT_FIELDS:
        v = word & ((1 << width) - 1)
        if width == 32 and v >> 31:
            v -= 1 << 32
        out[name] = v
        word >>= width
    return out


# ---------------- files ----------------
def _bram36(depth, width):
    """36-Kbit blocks for a depth x width ROM (aspect ratios of the 7-series RAMB36)"""
    for w, d in ((1, 32768), (2, 16384), (4, 8192), (9, 4096), (18, 2048), (36, 1024)):
        if width <= w:
            return -(-depth // d)
    return -(-depth // 1024) * -(-width // 36)


def memories():
    """{name: (width in bits, [words])}"""
    T = tileset()
    out = {}
    solid, water = [0] * 768, [0] * 768
    mp = [0] * (3 * 4096)
    ent = [0] * (3 * 64)
    for stage, level in load_maps().items():
        base = stage - 1
        s, w = grid(level)
        solid[base * 256:base * 256 + level.width] = s
        water[base * 256:base * 256 + level.width] = w
        for row in range(level.height):
            for col in range(level.width):
                tid, flip = T.maps[stage][row][col]
                mp[base * 4096 + row * 256 + col] = flip << 8 | tid
        for i, e in enumerate(entities(stage)):
            ent[base * 64 + i] = pack_entity(entity_fields(e, skins(stage)))
    patterns = []                                            # distinct edge_bits(), each stored once
    for stage in (1, 2, 3):
        for i, bits in enumerate(edge_bits(stage)):
            if bits not in patterns:
                patterns.append(bits)
            ent[(stage - 1) * 64 + i] |= patterns.index(bits) << _lsb("edge")
    assert len(patterns) <= 128, len(patterns)
    out["edge"] = (1, [bits >> k & 1 for bits in patterns for k in range(EDGE_MARKS)])
    tiles, tpal = [], []
    for img in T.images:
        idx, pal = quantise(img)
        tiles += [int(v) for v in idx.reshape(-1)]
        tpal += pal
    spr, spal, stab = [], [], []
    for (_, w, h), img in sprite_images().items():
        idx, pal = quantise(img, soft=True)
        stab.append(w << 32 | h << 24 | len(spr))
        spr += [int(v) for v in idx.reshape(-1)]
        spal += pal
    out["solid"], out["water"] = (11, solid), (11, water)
    out["map"] = (9, mp)
    out["tiles"], out["tpal"] = (4, tiles), (12, tpal)
    out["ent"] = (sum(w for _, w in ENT_FIELDS), ent)
    out["spr"], out["spal"], out["stab"] = (4, spr), (16, spal), (43, stab)
    import cr_model as M
    out["fpexp"] = (1, [int(b) for b in M.EXPIRE_240] + [0] * (16384 - len(M.EXPIRE_240)))
    return out


def bram_report(mems=None):
    """[(item, bits, BRAM36)] for the ROMs of this tool; small ones are LUT ROM (0)"""
    mems = mems or memories()
    rows = []
    for name, (width, words) in mems.items():
        bits = width * len(words)
        rows.append((name, bits, 0 if name in ("solid", "water", "ent", "stab") else _bram36(len(words), width)))
    return rows


def _preview(name, img):
    img.save(os.path.join(MEM, "preview", "cr_%s.png" % name))


def write_previews():
    T = tileset()
    shown = []
    for img in T.images:
        idx, pal = quantise(img)
        rgba = np.dstack([decode(idx, pal), np.where(idx == 0, 0, 255).astype(np.uint8)])
        shown.append(Image.fromarray(rgba, "RGBA"))
    for stage, level in load_maps().items():
        bg = render.sprite(C.BACKGROUND[stage], (704, 352)).convert("RGB")
        _preview("bg%d" % stage, bg)
        world = Image.new("RGB", (level.width * 32, level.height * 32), (62, 44, 70))
        for row in range(level.height):
            for col in range(level.width):
                tid, flip = T.maps[stage][row][col]
                if tid:
                    tile = shown[tid].transpose(Image.Transpose.FLIP_LEFT_RIGHT) if flip else shown[tid]
                    world.paste(tile, (col * 32, row * 32), tile)
        _preview("level%d" % stage, world)
    sheet = Image.new("RGB", (8 * 80, -(-len(sprite_images()) // 8) * 80), (90, 120, 90))
    for k, img in enumerate(sprite_images().values()):
        idx, pal = quantise(img, soft=True)
        alpha = np.array([(c >> 12) * 17 for c in pal], np.uint8)[idx]
        tile = Image.fromarray(np.dstack([decode(idx, pal), alpha]), "RGBA")
        sheet.paste(tile, (k % 8 * 80, k // 8 * 80), tile)
    _preview("sprites", sheet)


def write_consts():
    T = tileset()
    lines = ["// cr_consts.vh - GENERATED by tools/cr_assets.py. Do not edit.",
             "localparam CR_TILE_COUNT = %d;" % len(T.images)]
    for stage in (1, 2, 3):
        lines.append("localparam CR_ENT_COUNT%d = %d;" % (stage, len(entities(stage))))
    shift = 0
    for name, width in ENT_FIELDS:
        lines.append("localparam CR_ENT_%s_LSB = %d;" % (name.upper(), shift))
        shift += width
    lines.append("localparam CR_ENT_W = %d;" % shift)
    for k, cells in enumerate(T.lifts):
        for j, (tid, flip) in enumerate(cells):
            lines.append("localparam CR_LIFT%d_CELL%d = 9'h%03X;" % (k, j, flip << 8 | tid))
    lines.append("localparam CR_SPR_COUNT = %d;" % len(sprite_images()))
    for k, (name, w, h) in enumerate(sprite_images()):
        ident = "%s_%dX%d" % (os.path.splitext(name)[0], w, h)
        lines.append("localparam CR_SPR_%s = %d;" % (ident.upper(), k))
    lines += model_consts()
    with open(VH, "w") as f:
        f.write("\n".join(lines) + "\n")


def model_consts():
    """the numbers of cr_model.py, so cr_core.v never types one in. Lengths in units or F-units (_F)."""
    import cr_model as M
    from math import isqrt
    cell = M.Q * M.F
    signed = dict(CELL=cell, HALF_CELL=cell // 2, HALF_Q=M.Q // 2, HALF_F=M.HALF_F, NEAR_F=M.NEAR_F,
                  PH_F=M.PH * M.F, TIE_F=M.TIE_F, TIE_X=M.TIE_X, RUN=M.RUN, RUN_F=M.RUN * M.F, G_F=M.G_F,
                  JUMP_VY_F=M.JUMP_VY_F, DH_F=M.DOUBLE_H * M.F, SQRT_DH=isqrt(M.DOUBLE_H << 16),
                  DOUBLE_RANGE=M.DOUBLE_RANGE, MIN_RISE=M.MIN_RISE, LEVEL_WF=M.LEVEL_W * M.F,
                  SEVEN_Q=7 * M.Q, CAM_MAX=M.LEVEL_W - 20 * M.Q, DEATH_YF=-M.Q * M.F,
                  PUZZLE_XF=M.PUZZLE_X * M.F, PUZZLE_YF=M.PUZZLE_Y * M.F,
                  Q=M.Q, HALF_QU=M.Q // 2, ENEMY=M.ENEMY, SINK_WATER=M.SINK_WATER, WALK_G=M.WALK_G,
                  ANIMAL_H=M.ANIMAL_H, HALF_GOOSE_F=M.HALF_GOOSE * M.F, HALF_OTHER_F=M.HALF_OTHER * M.F,
                  ANT_STEP=M.Q // M.ANT_RAMP, WAKE20=20 * M.Q, WAKE25=25 * M.Q, KILL_X=-3 * M.Q,
                  KILL_Y=-2 * M.Q, H120_M=71582789)
    # floor(ANIMAL_H * e / 120) == (ANIMAL_H * e * H120_M) >> 33 for every exposure e = 0..120
    assert all((M.ANIMAL_H * e * 71582789) >> 33 == M.ANIMAL_H * e // M.ANT_RAMP for e in range(121))
    Q = M.Q
    for s in (1, 2, 3):
        spawn = M.SPAWNS[s][0] * Q
        signed["SPAWN_U%d" % s] = spawn
        signed["SPAN%d" % s] = M.DOORS[s][0] - spawn
        for k, v in zip("XYWH", M.DOORS[s]):
            signed["DOOR%d_%s" % (s, k)] = v
    signed.update(LIFT_LOW=M.LIFT_LOW, LIFT_HIGH=M.LIFT_HIGH, LIFT_SPEED=M.LIFT_SPEED, SINK_SPEED=M.SINK_SPEED,
                  LIFT0_BX_F=162 * cell, LIFT1_BX_F=207 * cell, TEA_VX=M.TEA_VX, TEA_VY=M.TEA_VY, TEA_G=M.TEA_G,
                  TEA_STOP=M.TEA_STOP, TEA_HALF=M.TEA_HALF, TEA_H=M.TEA_H, TEA_X0=M.PUZZLE_X + Q // 2,
                  TEA_Y0=M.PUZZLE_Y + Q, GAP=M.GAP, GAP_STILL=M.GAP_STILL, NEAR_PLAYER=M.NEAR_PLAYER,
                  RETREAT_STEP=M.RETREAT_STEP, FEET=M.FEET, TOL_Y=M.TOL_Y, TOL_X=M.TOL_X, HALF_W=M.HALF_W,
                  PH=M.PH, HIT_AHEAD=13 * Q // 10, TRAIL_DX=Q // 5, TRAIL_DY=7 * Q // 20, TEN_Q=10 * Q,
                  ELEVEN_Q=11 * Q, TWELVE_Q=12 * Q, TWO_Q=2 * Q, THREE_Q=3 * Q,
                  STEP_BOOT=M.STEP_BOOT, STEP_PAW=M.STEP_PAW)
    assert M.LIFT_LOW <= 4 * Q <= M.LIFT_HIGH and 13 * Q % 10 == 0
    timers = dict(COYOTE=M.COYOTE, BUFFER=M.BUFFER, DOUBLE_STEPS=M.DOUBLE_STEPS, DOUBLE_LAST=M.DOUBLE_LAST,
                  T_LIMIT=M.T_LIMIT, T_NOTICE=M.T_NOTICE, T_FLASH=M.T_FLASH, T_PROTECT=M.T_PROTECT,
                  T_PROTECT_AFTER=M.T_PROTECT_AFTER, T_SKILL=M.T_SKILL, T_INTERVIEW=M.T_INTERVIEW,
                  T_FOLLOW=M.T_FOLLOW, T_RETREAT=M.T_RETREAT, T_CLEAR=M.T_CLEAR, T_GROW=M.T_GROW,
                  ROUTE_OLD=M.ROUTE_OLD, QUESTIONS=M.QUESTIONS)
    names = ("NONE NEW TIMEUP SPLASH FELL STAGE2 STAGE3 NEED_CHASE PICK_TEA TEA REPORTER NEAR1 NEAR2 NEAR3 "
             "NEED_TEA").split()
    assert [getattr(M, "MSG_" + n) for n in names] == list(range(15))
    timers.update({"MSG_" + n: i for i, n in enumerate(names)})
    out = ["// ---- cr_model.py constants ----"]
    out += ["localparam signed [47:0] CR_%s = %s48'sd%d;" % (k, "-" if v < 0 else "", abs(v))
            for k, v in signed.items()]          # sized: several do not fit the 32-bit default
    out += ["localparam CR_%s = %d;" % (k, v) for k, v in timers.items()]
    out += ["localparam [2:0] CR_SPAWN_X%d = %d;" % (s, M.SPAWNS[s][0]) for s in (1, 2, 3)]
    out += ["localparam [2:0] CR_SPAWN_Y = %d;" % M.SPAWNS[1][1]]
    assert all(M.SPAWNS[s][1] == M.SPAWNS[1][1] for s in (2, 3))
    return out


def write_all(verbose=True):
    os.makedirs(os.path.join(MEM, "preview"), exist_ok=True)
    mems = memories()
    for name, (width, words) in mems.items():
        digits = (width + 3) // 4
        with open(os.path.join(MEM, "cr_%s.mem" % name), "w") as f:
            f.writelines("%0*X\n" % (digits, v) for v in words)
    write_consts()
    write_previews()
    if verbose:
        print("tiles %d (incl. empty), sprites %d" % (len(tileset().images), len(sprite_images())))
        total = 0
        for name, bits, blocks in bram_report(mems):
            total += blocks
            print("  cr_%-6s %8d bits  %3d BRAM36" % (name, bits, blocks))
        print("  ROM total: %d BRAM36 (estimate, not confirmed by Vivado)" % total)


if __name__ == "__main__":
    write_all()
