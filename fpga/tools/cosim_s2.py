#!/usr/bin/env python3
"""cosim_s2.py - verify the Verilog Stage 2 (s2_core.v) against demo_py/stage2_demo.py, tick by tick.

  python3 fpga/tools/cosim_s2.py gen [scenario]   -> sim/s2_<sc>_stim.mem + s2_<sc>_expect.txt
  vvp sim/build/tb_s2_cosim.vvp +STIM=.. +OUT=..  -> sim/s2_<sc>_rtl.txt
  python3 fpga/tools/cosim_s2.py cmp [scenario]   -> first differences, PASS / FAIL

Exact arithmetic in the harness (same logic, exact numbers - see docs/VERIFICATION.md):
  dt = Fraction(1, 60); speed() returns 312 / 156 exactly; the wall-slide factor 0.7 is Fraction(7, 10);
  timers (slow_t, skill_t, play_t, flash, zoom t) are snapped to whole ticks after every update;
  the walk-cycle timer counts whole ticks. TEST_MODE = False (the real game, as on the FPGA).
"""
import collections
import inspect
import os
import sys
import textwrap
from fractions import Fraction

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "demo_py"))
import pygame  # noqa: E402

SIM = os.path.join(ROOT, "fpga", "sim")
SEED = 0x1D2C


class FakeTime:
    t = Fraction(0)

    @classmethod
    def time(cls):
        return cls.t


class Keys:
    down = set()

    def __getitem__(self, k):
        return k in self.down


KEYS = Keys()


def load():
    pygame.display.init()
    pygame.font.init()
    pygame.display.set_mode((64, 64))
    import stage2_demo as s2
    s2.TEST_MODE = False
    s2.time = FakeTime
    s2.Fraction = Fraction
    pygame.key.get_pressed = lambda: KEYS
    s2.Game.speed = lambda self: Fraction(156) if self.slow_t > 0 else Fraction(312)
    src = textwrap.dedent(inspect.getsource(s2.Game.map_update)).replace("0.7", "Fraction(7, 10)")
    ns = {}
    exec(src, s2.__dict__, ns)
    s2.Game.map_update = ns["map_update"]
    PS = s2.PlayerSprite

    def update(self, dt, dx, dy, moving):
        if dx:
            self.dir = "right" if dx > 0 else "left"
        elif dy:
            self.dir = "front" if dy > 0 else "back"
        self.moving = moving
        self.t = self.t + 1 if moving else 0

    def stop(self):
        self.moving, self.t = False, 0

    PS.update, PS.stop = update, stop
    orig_reset = s2.Game.reset_stage

    def reset_stage(self, full=False):          # positions as exact fractions
        orig_reset(self, full)
        self.px, self.py = Fraction(int(self.px)), Fraction(int(self.py))
        self.play_t = self.skill_t = self.slow_t = self.flash = Fraction(0)
    s2.Game.reset_stage = reset_stage
    g = s2.Game()
    g.spr.t = 0
    g.lfsr = SEED
    return s2, g


def q60(v):
    return Fraction(round(v * 60), 60)


DIRS = {"front": 0, "back": 1, "left": 2, "right": 3}
NPC = {"off": 0, "to_player": 1, "talk": 2, "to_seat": 3, "sit": 4}
TAGS = {"intro": 1, "info": 2, "ask": 3, "verdict": 4}
HEADER = ("px py cu cur page ptotal spots hints rnd codes whash wcnt wcur wpick hearts armor hh hs un fr shard boost "
          "slow lfsr deck round cursor face career npc nx ny talk tag ti skill used play zoom zt hp state help intro "
          "cut dir pose inv notes").split()


def snapshot(s2, g):
    d = g.deck
    srcs = [None] + s2.SRC_LIST
    wl = [srcs.index(g.w.get(k)) for k in s2.SINKS]
    whash = sum((i + 1) * v for i, v in enumerate(wl)) % 1000003
    pose = 0
    if g.spr.moving:
        pose = {"stand": 0, "stepl": 1, "stepr": 2}[("stand", "stepl", "stand", "stepr")[
            int(Fraction(g.spr.t, 60) / Fraction(14, 100)) % 4]]
    n = g.npc
    t = g.talk
    cur = {"whiteboard": 0, "door": 1, "bench": 2}[g.cur.kind] if (g.mode == "closeup" and g.cur) else 0
    return [int(g.px * 100), int(g.py * 100), int(g.mode == "closeup"), cur, g.page, g.parts_total(),
            sum(1 << i for i, sp in enumerate(s2.ITEM_SPOTS) if sp.id in g.done_spots),
            sum(1 << i for i, h in enumerate(s2.HINT_SPOTS) if h.id in g.read_hints),
            g.rnd, -1 if g.codes is None else g.codes[0] * 8 + g.codes[1], whash, len(g.w), g.wcur,
            int(g.wsrc is not None), g.hearts, g.armor, g.hh, g.hs, g.undo, g.freeze, g.shard, int(g.boost),
            int(g.slow_t > 0), g.lfsr, int(d["active"]), d["round"] if d["active"] else 0,
            d["cursor"] if d["active"] else 0,
            -1 if (not d["active"] or d["face"] is None) else d["face"], -1 if g.career is None else g.career,
            NPC[n["state"]], (int(round(n["x"] * 64)) >> 6) if n["state"] != "off" else 0,
            (int(round(n["y"] * 64)) >> 6) if n["state"] != "off" else 0,
            int(t is not None), TAGS[t["tag"]] if t else 0, t["i"] if t else 0,
            int(g.skill_t * 60), int(g.skill_used), min(8191, int(g.play_t * 60)), int(g.zoom is not None),
            int(g.zoom["t"] * 60) if g.zoom else 0, int(g.hint_popup is not None),
            {"play": 0, "over": 1, "clear": 2}[g.state], int(g.show_help), int(g.intro_started),
            int(g.cutscene), DIRS[g.spr.dir], pose, g.inv_cur, min(8, len(g.notes))]


class Runner:
    def __init__(self):
        self.s2, self.g = load()
        self.stim, self.trace, self.sw, self.tick = [], [], [0] * 16, 0

    def step(self, held=(), ev=()):
        g = self.g
        m = {"u": pygame.K_UP, "d": pygame.K_DOWN, "l": pygame.K_LEFT, "r": pygame.K_RIGHT}
        KEYS.down = {m[h] for h in held}
        e = dict(up=0, down=0, left=0, right=0, tap=0, back=0, skill=0, click=None, rclick=None)
        for x in ev:
            e[{"u": "up", "d": "down", "l": "left", "r": "right", "tap": "tap", "back": "back"}[x]] = 1
        g.sw = [bool(v) for v in self.sw]
        FakeTime.t = Fraction(self.tick, 60)
        g.update(Fraction(1, 60), e)
        for a in ("slow_t", "skill_t", "play_t", "flash"):
            setattr(g, a, q60(getattr(g, a)))
        if g.zoom:
            g.zoom["t"] = q60(g.zoom["t"])
        lvl = sum(1 << i for i, k in enumerate("udlr") if k in held)
        evb = sum(1 << i for i, k in enumerate(["u", "d", "l", "r", "tap", "back"]) if k in ev)
        self.stim.append(lvl | (evb << 5) | (sum(v << i for i, v in enumerate(self.sw)) << 11))
        self.trace.append(snapshot(self.s2, g))
        self.tick += 1

    def wait(self, n=1):
        for _ in range(n):
            self.step()

    def press(self, *k, n=1):
        for _ in range(n):
            self.step(ev=k)
            self.step()

    def set_sw(self, i, v):
        self.sw[i] = v
        self.wait()

    def cards(self, moves=("r",)):
        for m in moves:
            self.press(m)
        self.press("tap")
        self.press("tap")

    def settle(self, card_moves=("l",)):
        """finish card rounds / talks / popups so the player can walk"""
        g = self.g
        for _ in range(60):
            if g.deck["active"]:
                self.cards(card_moves)
            elif g.talk:
                self.press("tap")
            elif g.hint_popup:
                self.press("tap")
            elif g.cutscene or g.zoom:
                self.wait(5)
            elif g.mode == "closeup":
                self.press("back")
            else:
                return
        raise AssertionError("cannot settle")

    def walk_to(self, ax, ay, want):
        """follow find_path() on the demo's own reach grid until find_near() gives `want`"""
        g = self.g
        for _ in range(40):
            self.settle()
            f = g.find_near()
            if f and f[1] is want:
                return
            path = g.find_path((g.px, g.py), (ax, ay))
            last, stuck, last_h = None, 0, True
            for _ in range(900):
                self.settle()
                f = g.find_near()
                if f and f[1] is want:
                    return
                j = min(range(len(path)), key=lambda i: (path[i][0] - g.px) ** 2 + (path[i][1] - g.py) ** 2)
                if j >= len(path) - 1:
                    break
                tx, ty = path[min(len(path) - 1, j + (8 if stuck else 3))]
                dx, dy = tx - g.px, ty - g.py
                horiz = abs(dx) >= abs(dy)
                if stuck:                                # blocked: try the other axis than last time
                    horiz = not last_h
                    if horiz and dx == 0:
                        dx = 1
                    if not horiz and dy == 0:
                        dy = 1
                last_h = horiz
                k = ("r" if dx > 0 else "l") if horiz else ("d" if dy > 0 else "u")
                self.step(held=(k,), ev=(k,))
                pos = (g.px, g.py)
                stuck = (pos == last)
                last = pos
            # final approach: step in the direction that makes `want` win find_near() by the largest margin
            for _ in range(60):
                self.settle()
                f = g.find_near()
                if f and f[1] is want:
                    return
                sp = float(g.speed()) / 60
                best = None
                for k, (ddx, ddy) in (("r", (1, 0)), ("l", (-1, 0)), ("d", (0, 1)), ("u", (0, -1))):
                    x, y = float(g.px) + ddx * sp, float(g.py) + ddy * sp
                    if g.blocked(x, y):
                        continue
                    m = self.margin(x, y, want)
                    if best is None or m > best[0]:
                        best = (m, k)
                if best is None:
                    break
                self.step(held=(best[1],), ev=(best[1],))
        raise AssertionError("could not reach %s" % (want.id if hasattr(want, "id") else want))

    def margin(self, x, y, want):
        import math
        g, s2 = self.g, self.s2
        cands = list(s2.OBJS) + ([s2.NPC_OBJ] if g.npc["state"] == "sit" else []) + \
            [sp for sp in s2.ITEM_SPOTS if sp.id not in g.done_spots] + \
            [h for h in s2.HINT_SPOTS if h.id not in g.read_hints]
        sc = lambda o: math.hypot(x - o.ax, y - o.ay) / o.r  # noqa: E731
        others = min([sc(o) for o in cands if o is not want] + [9])
        return min(others, 1.0) - sc(want)

    def bench_wire(self, plan):
        """wire `plan` = [(sink index, source index)] with the keyboard editor (page 1 of the bench)"""
        g = self.g
        srcs = [None] + self.s2.SRC_LIST
        for sink, src in plan:
            while g.wcur != sink:
                diff = (sink - g.wcur) % 55
                if diff >= 6 and diff <= 27:
                    self.press("d")
                elif diff > 27 and (55 - diff) >= 6:
                    self.press("u")
                elif diff <= 27:
                    self.press("r")
                else:
                    self.press("l")
            self.press("tap")                       # open the source picker
            cur = srcs.index(g.w.get(self.s2.SINKS[sink]))
            steps = (src - cur) % 28
            if steps <= 14:
                self.press("d", n=steps)
            else:
                self.press("u", n=28 - steps)
            self.press("tap")

    def write(self, name):
        os.makedirs(SIM, exist_ok=True)
        with open(os.path.join(SIM, "s2_%s_stim.mem" % name), "w") as f:
            for w in self.stim:
                f.write("%08X\n" % w)
        with open(os.path.join(SIM, "s2_%s_expect.txt" % name), "w") as f:
            for i, t in enumerate(self.trace):
                f.write("%d %s\n" % (i, " ".join(str(v) for v in t)))
        print("scenario %s: %d ticks" % (name, len(self.stim)))


def scenario_full(r):
    s2, g = r.s2, r.g
    r.wait(3); r.press("tap"); r.wait(2)
    r.cards(("r",))                                      # round 1
    r.settle()                                           # Boss walks in, 8 intro lines, walks to his desk
    # read two hints, then collect every part (round 2 appears at 9 parts)
    for h in (s2.HINT_SPOTS[7], s2.HINT_SPOTS[8]):
        r.walk_to(h.ax, h.ay, h); r.press("tap"); r.settle()
    for sp in s2.ITEM_SPOTS:
        r.walk_to(sp.ax, sp.ay, sp); r.press("tap"); r.settle()
    # SW15 inventory: try every item once
    r.set_sw(15, 1)
    for _ in range(4):
        r.press("tap"); r.settle(); r.set_sw(15, 1); r.press("r")
    r.set_sw(15, 0)
    bench = s2.OBJS[2]
    r.walk_to(bench.ax, bench.ay, bench); r.press("tap"); r.press("tap")   # power on -> breadboard
    srcs = [None] + s2.SRC_LIST
    plan = [(s2.SINKS.index(k), srcs.index(v)) for k, v in s2.REF]
    r.bench_wire(plan[:20])
    r.set_sw(0, 1); r.set_sw(1, 1); r.wait(5)            # test input on the DIP switch
    r.press("back"); r.press("back")
    npc = s2.NPC_OBJ
    r.walk_to(npc.ax, npc.ay, npc); r.press("tap")       # ask: the circuit is not finished -> fails
    r.press("tap")
    for _ in range(5):
        r.press("tap")
    r.settle()
    r.walk_to(bench.ax, bench.ay, bench); r.press("tap"); r.press("tap")
    r.bench_wire(plan[20:])
    r.press("back"); r.press("back")
    for _ in range(3):                                   # 3 QA tests (round 3 cards after 2)
        r.walk_to(npc.ax, npc.ay, npc); r.press("tap"); r.press("tap")
        for _ in range(5):
            r.press("tap")
        r.settle()
        if g.rnd >= 3:
            break
    door = s2.OBJS[1]
    r.walk_to(door.ax, door.ay, door); r.press("tap"); r.press("tap")
    r.wait(5)
    assert g.state == "clear", g.state
    r.press("tap"); r.wait(3)


SCENARIOS = {"full": scenario_full}


def compare(name):
    exp = [l.split() for l in open(os.path.join(SIM, "s2_%s_expect.txt" % name))]
    got = [l.split() for l in open(os.path.join(SIM, "s2_%s_rtl.txt" % name))]
    bad = 0
    for i in range(min(len(exp), len(got))):
        if exp[i] != got[i]:
            if bad < 6:
                print("tick %s: %s" % (exp[i][0], "; ".join("%s pygame=%s rtl=%s" % (h, a, b) for h, a, b in
                                                          zip(HEADER, exp[i][1:], got[i][1:]) if a != b)))
            bad += 1
    if len(exp) != len(got):
        print("length differs: pygame %d, rtl %d" % (len(exp), len(got)))
        bad += 1
    print("COSIM S2 %s: %s (%d ticks compared, %d differing)" % (name, "PASS" if bad == 0 else "FAIL",
                                                                  min(len(exp), len(got)), bad))
    return bad == 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "gen"
    names = sys.argv[2:] or list(SCENARIOS)
    if cmd == "gen":
        for n in names:
            r = Runner()
            SCENARIOS[n](r)
            r.write(n)
    else:
        sys.exit(0 if all([compare(n) for n in names]) else 1)
