#!/usr/bin/env python3
"""cr_cosim.py - the original onlystage_3 game (float) against cr_model.py (integers), same input every step.

A script is a list of (axis, jump, skill), one per 1/120 s step.
"""
import os
import random
import sys
from math import ceil

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


MESSAGES = {
    "": 0, "New game": 1, "Time up!  Skill restored": 2, "Splash!  Skill restored": 3, "Fell!  Skill restored": 4,
    "Stage 2   /   S4 to CB2": 5, "Stage 3   /   N17 to N16": 6, "Use Cloak when a reporter is following.": 7,
    "Pick up the milk tea!": 8, "Tea Time Awakening! Superyasai Power: Phase Through Every Obstacle!": 9,
    "A reporter is coming to interview you!": 10, "Just a little further to Red Building! You've got this!": 11,
    "Almost at CB2! Keep pushing!": 12, "Graduation Ceremony is right ahead! Hang in there!": 13,
    "Hit the ? block, then collect the milk tea.": 14}
MODES = {"play": M.PLAY, "pause": M.PAUSE, "clear": M.CLEAR, "win": M.WIN}


def full_state(g):
    """(discrete things that must be identical, positions in metres that must be within 1 mm)"""
    p = g.p
    shown = bool(g.chase or g.cloak_follow or g.interview or g.retreat_left)
    d = dict(mode=MODES[g.mode], stage=g.stage, grounded=bool(p.grounded), jumps=p.jumps, facing=p.direction,
             chase=bool(g.chase), interview=g.interview > 0, follow=g.cloak_follow > 0, retreat=g.retreat_left > 0,
             protected=g.protection > 0, used=bool(g.skill_used), digit=g.cloak_digit, flash=g.flash > 0,
             message=MESSAGES[g.message], notice=g.notice > 0, gold=bool(g.gold), opened=bool(g.opened),
             tea=g.tea is not None, near=bool(g.near_finish_seen), seconds=max(0, ceil(g.remaining)),
             progress=g.progress, contacts=sorted(g.contacts), alive=[e.alive for e in g.enemies],
             clearing=g.mode == "clear", question=g.question_index if g.interview else 0,
             questions=[C.QUESTIONS.index(q) for q in g.questions], grown=g.time < g.tea_growth_until)
    pos = {"player x": p.x, "player y": p.y}
    if g.tea:
        pos.update({"tea x": g.tea.x, "tea y": g.tea.y})
    for i, lift in enumerate(g.lifts):
        pos["lift %d" % i] = lift.top
    if shown:
        d.update(visible=bool(g.reporter_visible), reporter_facing=g.reporter.direction,
                 reporter_walking=bool(g.reporter_walking))
        if g.reporter_visible:
            pos.update({"reporter x": g.reporter.x, "reporter y": g.reporter.y})
    return d, pos


def full_state_model(m):
    shown = bool(m.chase or m.follow or m.interview or m.retreat)
    d = dict(mode=m.mode, stage=m.stage, grounded=m.grounded, jumps=m.jumps, facing=m.facing,
             chase=m.chase, interview=m.interview > 0, follow=m.follow > 0, retreat=m.retreat > 0,
             protected=m.protection > 0, used=m.used, digit=m.skill_digit, flash=m.flash > 0,
             message=m.message, notice=m.notice > 0, gold=m.gold, opened=m.opened,
             tea=m.tea is not None, near=m.near, seconds=m.seconds, progress=m.progress,
             contacts=sorted(m.contacts), alive=[e.alive for e in m.ents], clearing=m.mode == M.CLEAR,
             question=m.question_index if m.interview else 0, questions=list(m.questions), grown=m.grow > 0)
    pos = {"player x": m.x_units() / M.Q, "player y": m.y_units() / M.Q}
    if m.tea:
        pos.update({"tea x": m.tea[0] / M.Q, "tea y": m.tea[1] / M.Q})
    for i, lift in enumerate(m.lifts):
        pos["lift %d" % i] = lift[1] / M.Q
    if shown:
        d.update(visible=m.rvisible, reporter_facing=m.rdir, reporter_walking=m.rwalking)
        if m.rvisible:
            pos.update({"reporter x": m.rx / M.Q, "reporter y": m.ry / M.F / M.Q})
    return d, pos


class Run:
    """one game and one model, stepped together; .check() after every step records the first difference"""

    def __init__(self, stage, seed=M.SEED, setup=None):
        self.g, self.m = original(stage, seed=seed), model(stage, seed=seed)
        self.t, self.worst, self.first_diff, self.ties = 0, 0., None, []
        self.seen = set()
        self.late_notice = False
        self.m.wakes = self.wakes
        if setup:
            setup(self.g, self.m)

    def wakes(self, a, reach):
        """TIE "wake-up": camera + 20 is exactly on the animal's trigger. The game's camera comes from a float x
        that is 1e-14 short or over depending on the path taken, so the model is given the game's answer here
        (and only here). The hardware uses >=."""
        exact = reach >= a.trigger
        if abs(reach - a.trigger) > 2:
            return exact
        i = next(i for i, other in enumerate(self.m.ents) if other is a)
        answer = self.g.enemies[i].active                 # the game has already taken this step
        if answer != exact:
            self.ties.append((self.t, "wake-up of animal %d" % i))
        return answer

    def step(self, axis=0, jump=False, skill=False, menu=False):
        g, m = self.g, self.m
        if menu:
            if g.mode in ("play", "pause"):
                g.mode = "pause" if g.mode == "play" else "play"
            m.pause_toggle()
        g.step(C.TICK, axis, jump, skill)
        m.step(axis, jump, skill)
        self.check()
        self.t += 1

    def check(self):
        (a, pa), (b, pb) = full_state(self.g), full_state_model(self.m)
        for k, v in a.items():
            if v and k in ("chase", "interview", "follow", "retreat", "used", "gold", "tea", "near", "opened"):
                self.seen.add(k)
        self.seen.add("message %d" % a["message"])
        self.seen.add("mode %d stage %d" % (a["mode"], a["stage"]))
        diff = ["%s game=%r model=%r" % (k, a.get(k), b.get(k)) for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
        if diff == ["grown game=False model=True"] or diff == ["grown game=True model=False"]:
            self.ties.append((self.t, "tea growth ends one step apart (sprite size only)"))
            diff = []
        # TIE "progress boundary": the player is exactly on a whole percent; the game's float x is 1e-12 short of
        # it, so progress (and at 92 % the near-finish message) lags the integers by one step
        keys = {d.split()[0] for d in diff}
        m = self.m
        span = M.DOORS[m.stage][0] - M.SPAWNS[m.stage][0] * M.Q
        off = 100 * (m.px - M.SPAWNS[m.stage][0] * M.Q) % span
        if "progress" in keys and keys <= {"progress", "near", "message", "notice"} and min(off, span - off) <= 200:
            self.ties.append((self.t, "progress boundary"))
            self.late_notice |= "near" in keys
            diff = []
        elif keys == {"notice"} and self.late_notice:
            self.ties.append((self.t, "near-finish message ends one step apart"))
            diff = []
        for k in set(pa) & set(pb):
            mm = 1000 * abs(pa[k] - pb[k])
            self.worst = max(self.worst, mm)
            if mm > 1:
                diff.append("%s %.4f/%.4f" % (k, pa[k], pb[k]))
        if diff and not self.first_diff:
            self.first_diff = "step %d (stage %d): %s" % (self.t, a["stage"], "; ".join(diff[:6]))

    def hold(self, n, axis=0, **kw):
        for _ in range(n):
            if self.first_diff:
                break
            self.step(axis, **kw)
        return self

    def until(self, what, n, axis=0):
        """step until what(game) - fails loudly if the situation never happens"""
        for _ in range(n):
            if what(self.g) or self.first_diff:
                return self
            self.step(axis)
        raise AssertionError("situation not reached in %d steps (first diff: %s)" % (n, self.first_diff))

    def put(self, x, y, grounded=True):
        teleport(self.g, self.m, x, y, grounded)
        return self


def compare_animals(stage, steps, seed=1):
    """drag both players along the level (so every animal wakes up and some are touched) and compare every
    animal on every step. hit() is only recorded here. Returns (Report, statistics)."""
    rng = random.Random(seed)
    g, m = original(stage), model(stage)
    g.blocks = g.blocks[:len(g.blocks) - len(g.lifts)]
    g.lifts = []
    m.extra, m.lifts = m.extra[:len(m.extra) - len(m.lifts)], []
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
