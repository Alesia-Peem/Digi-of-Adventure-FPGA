#!/usr/bin/env python3
"""cr_assets.py - Campus Run (onlystage_3/) data for the hardware. The game's own loader and constructors
are imported, so path fallbacks, spawn lists and spawn snapping are exactly the game's.

Collision grid: one word per map column (0..249); bit r = the cell whose world y is r (0 = bottom row).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True
sys.path.insert(0, ROOT)

import onlystage_3.settings as C          # noqa: E402
from onlystage_3.level import Level       # noqa: E402
from onlystage_3.game import Game         # noqa: E402

_maps = None


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
