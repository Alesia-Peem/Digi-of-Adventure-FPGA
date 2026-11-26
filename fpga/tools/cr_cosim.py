#!/usr/bin/env python3
"""cr_cosim.py - the original onlystage_3 game (float) against cr_model.py (integers), same input every step.

A script is a list of (axis, jump, skill), one per 1/120 s step.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)

import cr_assets as A       # noqa: E402
import cr_model as M        # noqa: E402
import onlystage_3.game as G  # noqa: E402
import onlystage_3.settings as C   # noqa: E402
from collections import namedtuple  # noqa: E402

Report = namedtuple("Report", "worst_mm first_diff ties deaths")
_tables = None


def tables():
    """{stage: (solid columns, water columns, entities)} - what the model and the hardware are built from"""
    global _tables
    if _tables is None:
        _tables = {}
        for s, L in A.load_maps().items():
            ents = A.entities(s)
            for e, edges in zip(ents, A.edge_bits(s)):
                e["nskins"] = len(A.skins(s)[e["species"]])
                e["edges"] = edges
            _tables[s] = A.grid(L) + (ents,)
    return _tables


class Shim:
    """stands in for the `random` module inside game.py, drawing from the model's generator in call order"""
    def __init__(self, seed):
        self.lfsr = M.Lfsr16(seed)

    def choice(self, seq):
        return seq[self.lfsr.choice(len(seq))]

    def sample(self, seq, k):
        assert k == 2
        return [seq[i] for i in self.lfsr.pair(len(seq))]


def original(stage, physics_only=False, seed=M.SEED):
    """the float game at the start of a stage. physics_only: no animals and no lifts"""
    G.random = Shim(seed)
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


def model(stage, physics_only=False, seed=M.SEED):
    m = M.Model(tables(), seed)
    m.stage = stage
    m.no_animals = physics_only
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
    g, m = original(stage, physics_only=True), model(stage, physics_only=True)
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


def compare_animals(stage, steps, seed=1):
    """drag both players along the level (so every animal wakes up and some are touched) and compare every
    animal on every step. hit() is only recorded here. Returns (Report, statistics)."""
    rng = random.Random(seed)
    g, m = original(stage), model(stage)
    g.blocks = g.blocks[:len(g.blocks) - len(g.lifts)]
    g.lifts = []
    hits = [0, 0]
    g.hit = lambda: hits.__setitem__(0, hits[0] + 1)
    m.hit = lambda: hits.__setitem__(1, hits[1] + 1)
    solid = tables()[stage][0]
    worst, stats = 0., dict(contacts=0, woke=set())
    lift = 0
    for t in range(steps):
        x = 2 + 240 * t / steps
        if t % 90 == 0:
            lift = rng.choice((0, 0, 0, 1, 2))
        y = (solid[int(x)].bit_length() or 9) + lift
        teleport(g, m, x, y)
        g.step(C.TICK)
        m.step()
        if g.time == 0 or m.died:
            return Report(worst, "step %d: the dragged player died at x %.2f" % (t, x), [], 1), stats
        for i, (e, a) in enumerate(zip(g.enemies, m.ents)):
            diff = []
            if (e.active, e.alive) != (a.active, a.alive):
                diff.append("active/alive game=%r model=%r" % ((e.active, e.alive), (a.active, a.alive)))
            mm = 1000 * max(abs(e.x - a.x / M.Q), abs(e.y - a.y / M.Q))
            worst = max(worst, mm)
            if mm > 1:
                diff.append("%.3f mm apart" % mm)
            if e.direction != a.direction:
                diff.append("direction")
            if abs(e.exposure - a.exposure / 120) > 1e-6:
                diff.append("exposure %.4f/%.4f" % (e.exposure, a.exposure / 120))
            if A.skins(stage)[e.species][a.skin] != e.skin:
                diff.append("skin")
            if diff:
                return Report(worst, "step %d animal %d (%s %s): %s" %
                              (t, i, e.species, e.motion, "; ".join(diff)), [], 0), stats
            if e.active:
                stats["woke"].add(i)
        if g.contacts != m.contacts:
            return Report(worst, "step %d: contacts game=%s model=%s" % (t, g.contacts, m.contacts), [], 0), stats
        if hits[0] != hits[1]:
            return Report(worst, "step %d: hits %d/%d" % (t, hits[0], hits[1]), [], 0), stats
        stats["contacts"] = hits[0]
    stats["sank"] = sum(e.waterline is not None for e in g.enemies)
    stats["dead"] = sum(not e.alive for e in g.enemies)
    return Report(worst, None, [], 0), stats
