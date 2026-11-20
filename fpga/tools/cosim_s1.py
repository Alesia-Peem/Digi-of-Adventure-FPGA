#!/usr/bin/env python3
"""cosim_s1.py - verify the Verilog Stage 1 against the ORIGINAL Pygame code, tick by tick.

  python3 fpga/tools/cosim_s1.py gen [scenario]   -> runs demo_py/stage1_demo.py headless with a scripted
                                                     player, writes fpga/sim/s1_<scenario>_stim.mem (inputs per
                                                     tick) and s1_<scenario>_expect.txt (Pygame state per tick)
  vvp ... tb_s1_cosim (+STIM=.. +OUT=..)          -> replays the same inputs on s1_core.v, writes the RTL trace
  python3 fpga/tools/cosim_s1.py cmp [scenario]   -> compares both traces, prints the first difference

Exactness: the Pygame game runs with dt = 1/60 and a fake clock that returns Fraction(tick, 60), the LFSR
of both sides starts from the same seed, so card shuffles must match bit for bit.
Scenarios: "full" (whole stage incl. a wrong door code and the clear screen), "death" (3 wrong codes ->
OUT OF HEARTS -> restart), "items" (undo / hint / shard checks via the demo jumps).
"""
import collections
import os
import sys
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
    def __init__(self):
        self.down = set()

    def __getitem__(self, k):
        return k in self.down


KEYS = Keys()


def load_game():
    pygame.display.init()
    pygame.font.init()
    pygame.display.set_mode((64, 64))
    import stage1_demo
    import player_sprite
    stage1_demo.time = FakeTime
    # Exact arithmetic for the walk-cycle timer (same logic as player_sprite.py, but t counts whole ticks):
    # with float t += 1/60 the frame switch at an exact multiple of 0.14 s depends on rounding noise.
    PS = player_sprite.PlayerSprite

    def reset(self):
        self.dir, self.t, self.moving = "front", 0, False

    def stop(self):
        self.moving, self.t = False, 0

    def update(self, dt, dx, dy, moved):
        if dx:
            self.dir = "right" if dx > 0 else "left"
        elif dy:
            self.dir = "front" if dy > 0 else "back"
        if moved:
            if self.moving:
                self.t += 1
            else:
                self.moving, self.t = True, 0
        else:
            self.stop()

    PS.reset, PS.stop, PS.update = reset, stop, update
    PS.pose = property(lambda self: "stand" if not self.moving else
                       player_sprite.WALK_CYCLE[int(Fraction(self.t, 60) / Fraction(14, 100)) % 4])
    pygame.key.get_pressed = lambda: KEYS
    g = stage1_demo.Game()
    g.lfsr = SEED
    return stage1_demo, g


OBJ_IDS = ["whiteboard", "paper", "laptop3", "laptop4", "projector", "pc", "lightsw", "door"]
DIRS = {"front": 0, "back": 1, "left": 2, "right": 3}
POSES = {"stand": 0, "stepl": 1, "stepr": 2}


def snapshot(g):
    """state compared with the RTL - same order as tb_s1_cosim.v prints it"""
    d = g.deck
    cur = OBJ_IDS.index(g.cur.id) if (g.mode == "closeup" and g.cur) else 0
    ans = lambda k: -1 if g.ans[k] is None else g.ans[k]  # noqa: E731
    return [round(g.px * 10), round(g.py * 10), int(g.mode == "closeup"), cur, g.page,
            sum(int(b) << i for i, b in enumerate(g.done)), sum(int(b) << i for i, b in enumerate(g.right)),
            g.hearts, g.armor, g.lfsr, int(d["active"]), d["round"] if d["active"] else 0,
            d["cursor"] if d["active"] else 0, -1 if (not d["active"] or d["face"] is None) else d["face"],
            {"play": 0, "over": 1, "clear": 2}[g.state], int(g.lights), g.door_layer,
            ans("A"), ans("B"), ans("C"), DIRS[g.sprite.dir], POSES[g.sprite.pose], g.form,
            -1 if g.career is None else g.career, g.inv["shard"], int(g.inv["boost"]), int(g.show_help),
            int(g.slow_t > 0), int(g.freeze_t > 0)]


HEADER = ("px10 py10 cu cur page done right hearts armor lfsr deck round cursor face state lights layer "
          "A B C dir pose form career shard boost help slow freeze").split()


class Runner:
    def __init__(self):
        self.mod, self.g = load_game()
        self.stim, self.trace = [], []
        self.sw = [0] * 16
        self.tick = 0

    # ---- one game update with the given held keys and events
    def step(self, held=(), ev=()):
        g = self.g
        KEYS.down = set()
        m = {"u": pygame.K_UP, "d": pygame.K_DOWN, "l": pygame.K_LEFT, "r": pygame.K_RIGHT}
        for h in held:
            KEYS.down.add(m[h])
        e = dict(up=0, down=0, left=0, right=0, tap=0, back=0)
        names = {"u": "up", "d": "down", "l": "left", "r": "right", "tap": "tap", "back": "back"}
        for x in ev:
            e[names[x]] = 1
        g.sw = [bool(v) for v in self.sw]
        FakeTime.t = Fraction(self.tick, 60)
        g.update(Fraction(1, 60) * 1.0, e)
        lvl = sum(1 << i for i, k in enumerate("udlr") if k in held)
        evb = sum(1 << i for i, k in enumerate(["u", "d", "l", "r", "tap", "back"]) if k in ev)
        swv = sum(v << i for i, v in enumerate(self.sw))
        self.stim.append(lvl | (evb << 5) | (swv << 11))
        self.trace.append(snapshot(g))
        self.tick += 1

    def wait(self, n=1):
        for _ in range(n):
            self.step()

    def press(self, *keys, n=1):
        for _ in range(n):
            self.step(ev=keys)
            self.step()

    def set_sw(self, value, mask=0xFF):
        for i in range(16):
            if mask >> i & 1:
                self.sw[i] = value >> i & 1
        self.wait(1)

    def cards(self, moves=("r",)):
        """play one card round: move the cursor, reveal, close"""
        assert self.g.deck["active"], "no card round open"
        for m in moves:
            self.press(m)
        self.press("tap")
        self.press("tap")

    # ---- walking: BFS on the movement grid of this speed, using the Pygame blocked() itself
    def ensure_map(self):
        """finish an open card round (planned cursor moves per round), then leave any close-up"""
        g = self.g
        for _ in range(6):
            if g.deck["active"]:
                self.cards(self.card_moves.get(g.deck["round"], ()))
            elif g.mode == "closeup":
                self.back()
            else:
                return

    card_moves = {1: ("r",), 2: ("l",), 3: ()}

    def goto(self, obj_id):
        for _ in range(8):                       # re-plan if the speed changed (Slow card) on the way
            if self._walk(obj_id):
                return
        raise AssertionError("could not reach %s" % obj_id)

    def _walk(self, obj_id):
        self.ensure_map()
        g = self.g
        o = next(x for x in self.mod.OBJS if x.id == obj_id)
        sp = g.speed() / 60.0
        bonus = 30 if g.form >= 1 else 0
        start = (0, 0)
        x0, y0 = g.px, g.py
        pos = lambda c: (x0 + c[0] * sp, y0 + c[1] * sp)  # noqa: E731

        def score(obj, x, y):
            return ((x - obj.ax) ** 2 + (y - obj.ay) ** 2) ** 0.5 / (obj.r + bonus)

        def ok_goal(c):            # well inside the radius AND the best object there (find_near rule)
            x, y = pos(c)
            s = score(o, x, y)
            return s <= 0.85 and all(score(b, x, y) > s + 0.05 for b in self.mod.OBJS if b is not o)

        prev, todo = {start: None}, collections.deque([start])
        goal = None
        while todo:
            c = todo.popleft()
            if ok_goal(c):
                goal = c
                break
            for d, (dx, dy) in (("r", (1, 0)), ("l", (-1, 0)), ("d", (0, 1)), ("u", (0, -1))):
                n = (c[0] + dx, c[1] + dy)
                if n in prev or abs(n[0]) > 400 or abs(n[1]) > 250:
                    continue
                if not g.blocked(*pos(n)):
                    prev[n] = (c, d)
                    todo.append(n)
        assert goal is not None, "no path to %s" % obj_id
        moves = []
        c = goal
        while prev[c]:
            c, d = prev[c]
            moves.append(d)
        moves.reverse()
        for i, d in enumerate(moves):
            if g.speed() / 60.0 != sp:
                self.step()
                return False
            self.step(held=(d,), ev=(d,) if (i == 0 or moves[i - 1] != d) else ())
        self.step()
        near = g.find_near()
        return near is not None and near.id == obj_id

    def open(self, obj_id):
        self.goto(obj_id)
        self.press("tap")
        assert self.g.mode == "closeup" and self.g.cur.id == obj_id

    def back(self, n=1):
        for _ in range(n):
            self.press("back")

    def write(self, name):
        os.makedirs(SIM, exist_ok=True)
        with open(os.path.join(SIM, "s1_%s_stim.mem" % name), "w") as f:
            for w in self.stim:
                f.write("%08X\n" % w)
        with open(os.path.join(SIM, "s1_%s_expect.txt" % name), "w") as f:
            for i, t in enumerate(self.trace):
                f.write("%d %s\n" % (i, " ".join(str(v) for v in t)))
        print("scenario %s: %d ticks -> %s" % (name, len(self.stim), SIM))


# ================================================================== scenarios
def scenario_full(r):
    g = r.g
    r.wait(3)
    r.press("tap")                      # close HOW TO PLAY
    r.wait(2)
    r.cards(("r",))                      # round 1: career card
    # puzzle 1 - whiteboard: 42 - 19 - 17 = 6 -> SW3..0 = 0110
    r.open("whiteboard"); r.press("tap"); r.set_sw(0x06); r.press("tap"); r.back(2)
    # puzzle 2 - paper: T1 = AB (used A,B / plain A,B), T2 = CD, confirm with BTNU
    r.open("paper"); r.press("tap")
    r.set_sw(0xCC); r.press("tap"); r.press("r"); r.set_sw(0x33); r.press("tap"); r.press("u")
    r.back(2)
    # notebook (SW14) for a moment
    r.sw[14] = 1; r.wait(20); r.sw[14] = 0; r.wait(2)
    # puzzle 3 - NAND laptop: G1=NAND(A,B) G2=NAND(C,D) G3=NAND(G1,G2) F=G3
    r.open("laptop3"); r.press("tap")
    for f, ups in enumerate([0, 1, 2, 3, 4, 5, 0, 0, 2]):
        r.press("u", n=ups)
        if f < 8:
            r.press("r")
    r.press("tap"); r.back(2)
    # puzzle 4 - two's complement of 12 = 11110100
    r.open("laptop4"); r.press("tap"); r.set_sw(0xF4); r.press("tap"); r.back(2)
    # lights off, look at the projector, puzzle 5 on the teacher PC (first a wrong try)
    r.open("lightsw"); r.press("tap"); r.back()
    r.open("projector"); r.wait(10); r.back()
    r.open("pc")
    r.press("tap")                       # AAA -> refused
    r.press("r", n=2); r.press("d"); r.press("l", n=11); r.press("d"); r.press("r", n=4); r.press("tap")
    r.press("d"); r.press("d"); r.press("u")
    r.back(); r.back()
    r.open("lightsw"); r.press("tap"); r.back()
    # door: layer 1 wrong once (-1 heart unless armor), then 69, then 17865
    r.open("door")
    r.press("tap")                       # 00 -> wrong
    r.wait(30)
    r.press("u", n=6); r.press("r"); r.press("d"); r.press("tap")
    for k, dgt in enumerate([1, 7, 8, 6, 5]):
        r.press("u", n=dgt)
        if k < 4:
            r.press("r")
    r.press("tap")
    r.wait(5)
    assert g.state == "clear", g.state
    r.press("tap")                       # continue (standalone: play again)
    r.wait(5)


def scenario_death(r):
    r.wait(2); r.press("tap"); r.wait(2); r.cards(("l",))
    r.open("door")
    for _ in range(4):                   # (armor may absorb one) -> out of hearts
        r.press("tap"); r.wait(3)
        if r.g.state == "over":
            break
    r.wait(200)                          # 3 s "OUT OF HEARTS", then the stage restarts
    r.wait(5)


def scenario_items(r):
    """Undo / smart hint / shard paths, with wrong answers so the hint picks a puzzle by truth."""
    r.card_moves = {1: ("r", "r"), 2: ("l", "l"), 3: ("r",)}
    r.wait(2); r.press("tap"); r.wait(2); r.cards(("r", "r"))
    r.open("whiteboard"); r.press("tap"); r.set_sw(0x05); r.press("tap"); r.back(2)   # wrong A = 5
    r.open("laptop4"); r.press("tap"); r.set_sw(0x0C); r.press("tap"); r.back(2)      # wrong C
    r.open("laptop3"); r.press("tap"); r.press("tap"); r.back(2)                       # wrong circuit
    r.open("paper"); r.press("tap"); r.set_sw(0xCC); r.press("tap"); r.press("u"); r.back(2)
    r.open("pc"); r.press("r", n=2); r.press("d"); r.press("l", n=11); r.press("d"); r.press("r", n=4)
    r.press("tap"); r.back(); r.back()
    r.ensure_map()
    r.wait(30)


SCENARIOS = {"full": scenario_full, "death": scenario_death, "items": scenario_items}


def compare(name):
    exp = [l.split() for l in open(os.path.join(SIM, "s1_%s_expect.txt" % name))]
    got = [l.split() for l in open(os.path.join(SIM, "s1_%s_rtl.txt" % name))]
    n = min(len(exp), len(got))
    bad = 0
    for i in range(n):
        if exp[i] != got[i]:
            if bad < 5:
                diffs = ["%s pygame=%s rtl=%s" % (h, a, b) for h, a, b in zip(HEADER, exp[i][1:], got[i][1:]) if a != b]
                print("tick %s: %s" % (exp[i][0], "; ".join(diffs)))
            bad += 1
    if len(exp) != len(got):
        print("length differs: pygame %d ticks, rtl %d ticks" % (len(exp), len(got)))
        bad += 1
    print("COSIM %s: %s (%d ticks compared, %d differing)" % (name, "PASS" if bad == 0 else "FAIL", n, bad))
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
        ok = all([compare(n) for n in names])
        sys.exit(0 if ok else 1)
