#!/usr/bin/env python3
"""cr_cosim.py - the original onlystage_3 game (float) against cr_model.py (integers), same input every step.

A script is a list of (axis, jump, skill), one per 1/120 s step.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)

import cr_assets as A       # noqa: E402
import cr_model as M        # noqa: E402
import onlystage_3.settings as C   # noqa: E402
from collections import namedtuple  # noqa: E402

Report = namedtuple("Report", "worst_mm first_diff ties deaths")
_tables = None


def tables():
    """{stage: (solid columns, water columns, entities)} - what the model and the hardware are built from"""
    global _tables
    if _tables is None:
        _tables = {s: A.grid(L) + (A.entities(s),) for s, L in A.load_maps().items()}
    return _tables


def original(stage, physics_only=False):
    """the float game at the start of a stage. physics_only: no animals and no lifts"""
    g = A.Game(A.load_maps())
    g.stage = stage
    g.restart()
    if physics_only:
        _strip(g)
    return g


def _strip(g):
    g.enemies = []
    g.blocks = g.blocks[:len(g.blocks) - len(g.lifts)]
    g.lifts = []


def model(stage):
    m = M.Model(tables())
    m.stage = stage
    m.restart()
    return m


def teleport(g, m, x, y, grounded=True):
    """put both players at (x, y) metres, standing (or falling) at rest"""
    g.p.x, g.p.y, g.p.vy, g.p.grounded = float(x), float(y), 0., grounded
    g.camera = min(max(g.p.x - 7, 0), g.level.width - 20)
    m.teleport(round(x * M.Q), round(y * M.Q), grounded)


def state_of_game(g):
    p = g.p
    return (("grounded", bool(p.grounded)), ("jumps", p.jumps), ("buffered", p.buffer > 0), ("grace", p.grace > 0),
            ("facing", p.direction), ("walking", bool(p.walking)))


def state_of_model(m):
    return (("grounded", m.grounded), ("jumps", m.jumps), ("buffered", m.buffer > 0), ("grace", m.grace > 0),
            ("facing", m.facing), ("walking", m.walking))


def compare(script, stage, setup=None):
    """run both from the stage start (or setup(g, m)); positions in mm, first discrete difference as text"""
    g, m = original(stage, physics_only=True), model(stage)
    if setup:
        setup(g, m)
    worst, deaths = 0., 0
    for t, (axis, jump, skill) in enumerate(script):
        g.step(C.TICK, axis, jump, skill)
        m.step(axis, jump, skill)
        died = g.time == 0                  # restart() puts the clock back to 0
        if died:
            deaths += 1
            _strip(g)
        mm = 1000 * max(abs(g.p.x - m.x_units() / M.Q), abs(g.p.y - m.y_units() / M.Q), abs(g.camera - m.cam / M.Q))
        worst = max(worst, mm)
        diff = ["%s game=%r model=%r" % (k, a, b) for (k, a), (_, b) in zip(state_of_game(g), state_of_model(m)) if a != b]
        if died != m.died:
            diff.append("died game=%r model=%r" % (died, m.died))
        if diff or mm > 1:
            return Report(worst, "step %d: %s (x %.4f/%.4f y %.4f/%.4f)" %
                          (t, "; ".join(diff) or "%.3f mm apart" % mm, g.p.x, m.x_units() / M.Q, g.p.y, m.y_units() / M.Q),
                          [], deaths)
    return Report(worst, None, [], deaths)
