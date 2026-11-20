#!/usr/bin/env python3
"""s3_model.py - Stage 3 (stage3_demo.py) game logic in the FPGA's number format (bit-exact with s3_core.v).

Number format (chosen so that the demo's 1/120 s step is EXACT, see docs/ARCHITECTURE.md section 7):
  length    1 m = Q = 120 * 65536 units  -> 5, 2, 1, 14 m/s x 1/120 s are whole numbers of units per step
  velocity  vertical speeds are kept PER STEP (units moved in one 1/120 s step): py += vy, no division
  timers    whole physics steps; the start values are the step counts at which the float demo's
            timer crosses its test (1.5 s -> 181, 0.1 s -> 13, 5 s -> 600, 1.8 s -> 217, 120 s -> 14400)
  divisions by 24 / 10 / 120 are reciprocal multiplies (div24, div10, div120) - same formula in the RTL.
Every function below is the demo function with the same name, same order of operations.
`compare_pygame` / cosim_s3.py run this model and the original float Pygame code with the same inputs.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
Q = 120 * 65536            # units per metre
STEP = 65536               # 1 m/s moves STEP units per physics step
T_HC, T_COY, T_TALK, T_MSG, T_GAME, T_DEAD = 181, 13, 600, 217, 14400, 66
T_TALK_HALF = 300          # talk > 2.5 s  <=>  more than 300 steps left
G1 = 22282                 # 40.8 m/s^2: speed change per step (40.8 / 14400 m per step^2)
G2 = 13653                 # 25 m/s^2
VJ = 936509                # 14.29 m/s per step
GA = 10923                 # 20 m/s^2 (falling animals)
VA = 163840                # 2.5 m/s per step
EPS = 786                  # hit() epsilon 1e-4 m
SURF_DY = 7942963          # surf(): y + 1.01


def q(v):
    return int(round(v * Q))


def div24(v):
    return (v * 11184811) >> 28


def div10(v):
    return (v * 26843546) >> 28


def div120(v):
    return (v * 2236963) >> 28


def isqrt(v):
    return math.isqrt(v)


def scr(x):
    """metres (units) -> screen pixels at 32 px per metre (floor), as the RTL computes it"""
    return ((x >> 15) * 8738) >> 16


class Solid:
    def __init__(self, s):
        self.x, self.y, self.w, self.h, self.top = q(s["x"]), q(s["y"]), q(s["w"]), q(s["h"]), q(s["top"])
        self.wall = s["k"] == "w"


def load_level():
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    sys.path.insert(0, os.path.join(ROOT, "demo_py"))
    import stage3_demo as s3
    return s3, [Solid(s) for s in s3.solids], s3.DEF


def hit(ax, ay, aw, ah, bx, by, bw, bh):
    return ax < bx + bw - EPS and ax + aw > bx + EPS and ay < by + bh - EPS and ay + ah > by + EPS


def plant_r(u):
    """opening of a plant at phase u (steps, 0..599); continuous, so float boundary noise cannot matter"""
    if u < 96:
        return u * 163840
    if u < 336:
        return 2 * Q
    if u < 432:
        return 2 * Q - (u - 336) * 163840
    return 0


class Model:
    W, H = q(.9), q(1.5)

    def __init__(self, solids, defs):
        self.S, self.D = solids, defs
        self.reset()
        self.st = "menu"

    def surf(self, x, y):
        b = None
        for s in self.S:
            if not s.wall and s.x <= x <= s.x + s.w and s.top <= y + SURF_DY and (b is None or s.top > b):
                b = s.top
        return b

    def reset(self):
        self.px, self.py, self.vy, self.g = 2 * Q, 4 * Q, 0, G1
        self.jumps, self.ly, self.coy, self.f, self.run = 0, 4 * Q, 0, 1, 0
        self.A = []
        for d in self.D:
            a = dict(on=d["trig"] < -90, dir=-1, dead=False, ph=int(round(d.get("ph", 0) * 120)) % 600,
                     ya=q(d["y"]), cy=q(d["y"]), r=0, t=d["t"], x=q(d["x"]), trig=q(d["trig"]),
                     patrol=d["m"] == "p", a=q(d.get("a", 0)), b=q(d.get("b", 0)), fall=False, vy=0)
            if a["t"] < 3:
                s = self.surf(a["x"] + q(.5), a["ya"])
                if s is not None:
                    a["cy"] = s
            self.A.append(a)
        self.gt, self.hits, self.hc, self.used = 0, 0, 0, False
        self.rep, self.talk = None, 0
        self.st, self.msg_u, self.msg = "play", 0, 0
        self.cam, self.dd = 0, 0

    def flash(self, m):
        self.msg, self.msg_u = m, T_MSG

    def do_jump(self):
        if self.st != "play" or self.talk > 0:
            return
        if self.coy > 0 and self.jumps == 0:
            self.vy, self.g, self.jumps, self.ly, self.coy = VJ, G1, 1, self.py, 0
        elif self.jumps < 2:
            if self.jumps == 0:
                self.ly = self.py
            self.g = G2
            self.vy = div120(isqrt(50 * max(q(.5), self.ly + q(4.5) - self.py) * Q))
            self.jumps = 2

    def skill(self):
        if self.st != "play" or self.talk > 0:
            return
        if not self.used and self.hits == 1:
            self.used, self.hits = True, 0
            self.rep["st"] = "out"
            self.flash(1)

    def on_hit(self):
        self.hits += 1
        self.hc = T_HC
        if self.hits == 1:
            self.rep = {"x": self.cam - 2 * Q, "y": self.py, "st": "in"}
            self.flash(2)
        else:
            self.talk = T_TALK
            self.hc = 1 << 20                       # 99 s: never runs out while talking

    def upd_rep(self):
        r = self.rep
        if not r:
            return
        if r["st"] == "out":
            r["x"] -= 14 * STEP
            if r["x"] < self.cam - 3 * Q:
                self.rep = None
            return
        off = q(1.4) if self.talk > 0 else q(2.4)
        r["x"] += div24(self.px - off - r["x"])
        s = self.surf(r["x"] + q(.45), self.py + q(.6))
        ty = self.py if s is None else s
        r["y"] += div10(ty - r["y"])

    def step_p(self, kl, kr):
        d = (1 if kr else 0) - (1 if kl else 0)
        if d:
            self.f = d
        self.run += abs(d)
        self.px += d * 5 * STEP
        if self.px < self.cam:
            self.px = self.cam
        if d:
            for s in self.S:
                if hit(self.px, self.py, self.W, self.H, s.x, s.y, s.w, s.h):
                    self.px = s.x - self.W if d > 0 else s.x + s.w
        self.vy -= self.g
        self.py += self.vy
        gr = False
        for s in self.S:
            if hit(self.px, self.py, self.W, self.H, s.x, s.y, s.w, s.h):
                if self.vy <= 0:
                    self.py = s.top
                    gr = True
                else:
                    self.py = s.y - self.H
                self.vy = 0
        if gr:
            self.jumps, self.g, self.coy = 0, G1, T_COY
        else:
            self.coy -= 1

    def upd_a(self, a):
        if a["dead"]:
            return
        if not a["on"]:
            if self.cam + 20 * Q >= a["trig"]:
                a["on"] = True
            else:
                return
        if a["t"] == 3:
            a["ph"] = (a["ph"] + 1) % 600
            a["r"] = plant_r(a["ph"])
            a["cy"] = a["ya"] + a["r"]
            return
        if a["t"] == 4:
            a["x"] -= 2 * STEP
            if a["x"] < self.cam - 3 * Q:
                a["dead"] = True
            return
        if a["fall"]:
            a["vy"] -= GA
            if a["cy"] < 2 * Q and a["vy"] < -VA:
                a["vy"] = -VA
            a["cy"] += a["vy"]
            a["x"] += a["dir"] * STEP
            if a["cy"] < -q(1.5) or a["x"] < self.cam - 3 * Q:
                a["dead"] = True
            return
        a["x"] += a["dir"] * 2 * STEP
        if a["patrol"]:
            if a["x"] < a["a"]:
                a["x"], a["dir"] = a["a"], 1
            if a["x"] + Q > a["b"]:
                a["x"], a["dir"] = a["b"] - Q, -1
        elif a["x"] < self.cam - 3 * Q:
            a["dead"] = True
            return
        s = self.surf(a["x"] + q(.5), a["ya"])
        if s is None:
            a["fall"], a["vy"] = True, 0
        else:
            a["cy"] = s

    def step(self, kl, kr):
        self.gt += 1
        if self.gt >= T_GAME:
            self.st = "lose"
            return
        self.cam = min(max(self.px - 6 * Q, 0), 230 * Q)
        if self.msg_u > 0:
            self.msg_u -= 1
        if self.talk > 0:
            self.upd_rep()
            self.talk -= 1
            if self.talk <= 0:
                self.talk, self.hits, self.hc = 0, 0, T_HC
                if self.rep:
                    self.rep["st"] = "out"
            return
        self.step_p(kl, kr)
        self.hc -= 1
        for a in self.A:
            self.upd_a(a)
        for a in self.A:
            if a["dead"] or not a["on"] or a["fall"]:
                continue
            if a["t"] == 3:
                if a["r"] < q(.6):
                    continue
                b = (a["x"] + q(.15), a["cy"], q(.7), Q)
            else:
                b = (a["x"] + q(.1), a["cy"] + q(.05), q(.8), q(.7) if a["t"] == 4 else q(.9))
            if not hit(self.px, self.py, self.W, self.H, *b):
                continue
            if self.hc <= 0:
                self.on_hit()
                break
        self.upd_rep()
        if self.py < Q:
            self.st, self.dd = "dead", T_DEAD
            return
        if self.px + self.W >= 249 * Q:
            self.st = "win"

    def frame(self, kl, kr, jump, skill, start):
        """one 60 Hz tick: events first (like main()), then 2 physics steps / the dead timer"""
        if start and self.st not in ("play", "dead"):
            self.reset()
        elif jump:
            self.do_jump()
        if skill:
            self.skill()
        if self.st == "play":
            for _ in range(2):
                if self.st == "play":
                    self.step(kl, kr)
        elif self.st == "dead":
            self.dd -= 1
            if self.dd <= 0:
                self.reset()

    def snap(self):
        nalive = sum(1 for a in self.A if not a["dead"])
        rep = self.rep
        return [self.px, self.py, self.vy, self.jumps, self.coy, ["menu", "play", "dead", "win", "lose"].index(self.st),
                self.gt, self.hits, self.hc, int(self.used), self.talk, self.msg_u, self.cam, nalive,
                -1 if rep is None else rep["x"], -1 if rep is None else rep["y"],
                sum(a["x"] for a in self.A) & 0xFFFFFF, sum(a["cy"] for a in self.A) & 0xFFFFFF]


# ---------------------------------------------------------------- display (fields for the UI program)
def _load_sin():
    vals = [int(l, 16) for l in open(os.path.join(ROOT, "fpga", "mem", "sin256.mem"))]
    return [v - 256 if v > 127 else v for v in vals]


SIN = None
CLOUD_BASE = [int(round(i * 7.3 * 32)) for i in range(6)]
N_AS, N_FS, N_PS = 6, 2, 3


def publish(m):
    """fields / conditions / renderer inputs of one tick (s3_core.v publishes the same numbers)"""
    global SIN
    if SIN is None:
        SIN = _load_sin()
    F, C = {}, {}
    cpx = scr(m.cam)
    F["CAMPX"] = cpx
    swp = SIN[((m.run * 311519) >> 16) & 255]
    swg = SIN[((m.gt * 311519) >> 16) & 255]
    sw_p, sw_r = (swp * 41 + 512) >> 10, (swg * 41 + 512) >> 10
    F["PCX"] = scr(m.px + q(.45)) - cpx
    F["PL1"], F["PL2"] = F["PCX"] + sw_p, F["PCX"] - sw_p
    F["PY"] = 360 - scr(m.py)
    C["PLAYER"] = m.st != "dead"
    C["PF"] = m.f > 0
    r = m.rep
    C["REP"] = r is not None
    if r:
        F["RCX"] = scr(r["x"] + q(.45)) - cpx
        F["RL1"], F["RL2"] = F["RCX"] + sw_r, F["RCX"] - sw_r
        F["RY"] = 360 - scr(r["y"])
        C["RF"] = r["st"] != "out"
    F["FLAGX"] = 7936 - cpx
    C["FLAG"] = F["FLAGX"] < 700
    shift = ((m.cam >> 16) * 3495) >> 16
    for i in range(6):
        v = CLOUD_BASE[i] - shift + 1920
        for _ in range(3):
            if v >= 960:
                v -= 960
        F["CL%d" % i] = v - 128
    na = nf = npl = 0
    wv = SIN[((m.gt * 311519) >> 16) & 255] * 15481
    for a in m.A:
        if a["dead"]:
            continue
        ax = scr(a["x"] + q(.5)) - cpx
        if not -40 <= ax <= 680:
            continue
        ay = 360 - scr(a["cy"])
        if a["t"] == 3:
            if npl < N_PS:
                F["P%d_X" % npl], F["P%d_Y" % npl] = ax, ay
                C["P%d_V" % npl], C["P%d_OPEN" % npl] = True, a["r"] > q(.6)
                npl += 1
        elif a["fall"]:
            if nf < N_FS:
                F["F%d_X" % nf], F["F%d_Y" % nf] = ax, ay
                C["F%d_V" % nf], C["F%d_T2" % nf], C["F%d_F" % nf] = True, a["t"] == 2, a["dir"] > 0
                nf += 1
        elif na < N_AS:
            F["A%d_X" % na], F["A%d_Y" % na] = ax, ay
            if a["t"] == 4:
                F["A%d_YW" % na] = 360 - scr(a["cy"] + wv)
            C["A%d_V" % na] = True
            C["A%d_T%d" % (na, a["t"])] = True
            C["A%d_F" % na] = a["dir"] > 0
            na += 1
    rem = T_GAME - m.gt
    tm = 2 if rem >= 14400 else 1 if rem >= 7200 else 0
    secs = ((rem - tm * 7200) * 34953) >> 22
    F["TM"], F["TS1"] = tm, (secs * 205) >> 11
    F["TS2"] = secs - 10 * F["TS1"]
    C["TBLINK"] = rem < 1800 and ((m.gt * 52429) >> 21) & 1 == 1
    prog = ((m.px >> 16) * 437) >> 16
    F["PBX1"], F["PBY1"] = 220 + min(200, max(0, prog)), 14
    C["SK_USED"] = m.used
    C["SK_READY"] = (not m.used) and m.hits == 1
    C["SK_BLINK"] = ((m.gt * 69906) >> 21) & 1 == 1
    C["MSG"], C["MSG_SKILL"] = m.msg_u > 0, m.msg == 1
    C["TALK"], C["TALK1"] = m.talk > 0, m.talk > T_TALK_HALF
    F["TALKD"] = ((m.talk + 119) * 34953) >> 22
    tt = ((m.gt + 6) * 87382) >> 20
    ip = (tt * 6554) >> 16
    F["WT"] = tt - 10 * ip
    F["W1"] = (ip * 656) >> 16
    F["W2"] = (((ip - 100 * F["W1"]) * 6554) >> 16)
    F["W3"] = ip - 100 * F["W1"] - 10 * F["W2"]
    C["WD1"], C["WD2"], C["WD3"] = ip < 10, 10 <= ip < 100, ip >= 100
    lm = ((m.px >> 16) * 34953) >> 22
    F["L1"] = (lm * 656) >> 16
    F["L2"] = (((lm - 100 * F["L1"]) * 6554) >> 16)
    F["L3"] = lm - 100 * F["L1"] - 10 * F["L2"]
    C["LD1"], C["LD2"], C["LD3"] = lm < 10, 10 <= lm < 100, lm >= 100
    for k, n in (("MENU", "menu"), ("PLAY", "play"), ("DEAD", "dead"), ("WIN", "win"), ("LOSE", "lose")):
        C[k] = m.st == n
    wave = (((m.cam >> 13) * 4450 + m.gt * 55629) >> 16) & 255
    hill = ((m.cam >> 13) * 91138 >> 16) & 0xFFFF
    return F, C, (cpx, wave, hill)


HEADER = "px py vy jumps coy st gt hits hc used talk msg cam alive repx repy ax_sum acy_sum".split()


# ---------------------------------------------------------------- scripted player (drives both sides)
def bot(m, t):
    """simple runner: hold right, jump at gaps / animals, double jump near the apex"""
    if m.st != "play":
        return (0, 0, 0, 0, 1 if t % 40 == 0 else 0)
    ahead_ground = m.surf(m.px + q(1.6), m.py + Q) is not None
    animal = any((not a["dead"]) and a["on"] and 0 < a["x"] - m.px < q(2.2) and abs(a["cy"] - m.py) < q(2.5)
                 for a in m.A)
    jump = 0
    if m.jumps == 0 and m.coy > 0 and (not ahead_ground or animal):
        jump = 1
    elif m.jumps == 1 and m.vy < q(1) // 120 and (not ahead_ground):
        jump = 1
    skill = 1 if (m.hits == 1 and t % 120 == 60) else 0
    return (0, 1, jump, skill, 0)


OPTS = [()] + [(k,) for k in range(0, 24, 4)] + [(k, k + d) for k in range(0, 24, 4) for d in (8, 12, 16)]


def plan(m, horizon=120):
    """lookahead planner: try a few jump timings in a copy of the model, keep the best (no fall, no hit)"""
    import copy
    best = None
    for opt in OPTS:
        c = copy.deepcopy(m)
        for k in range(horizon):
            c.frame(0, 1, 1 if k in opt else 0, 0, 0)
            if c.st != "play":
                break
        score = c.px - (10 ** 9 if c.st == "dead" else 0) - c.hits * 4 * Q + (10 ** 9 if c.st == "win" else 0)
        if best is None or score > best[0]:
            best = (score, opt)
    return list(best[1])


def run_model(n=4000, careless=False):
    _, S, D = load_level()
    m = Model(S, D)
    stim, trace, pending, t0 = [], [], [], 0
    for t in range(n):
        if m.st != "play":
            act = (0, 0, 0, 0, 1 if t % 40 == 0 else 0)
        elif careless:
            act = bot(m, t) if m.hits == 0 and t > 900 else (0, 1, 0, 0, 0)
        else:
            if t % 6 == 0:
                pending, t0 = plan(m), t
            k = t - t0
            act = (0, 1, 1 if k in pending else 0, 1 if (m.hits == 1 and not m.used) else 0, 0)
        m.frame(*act)
        stim.append(act)
        trace.append(m.snap())
        if m.st in ("win", "lose") and t > 50 and stim[-2][4] == 0 and len(stim) > n - 1:
            break
    return stim, trace


def compare_pygame(n=4000, careless=False):
    """same inputs into the ORIGINAL float code; positions must stay within 2 cm, discrete states equal"""
    s3, S, D = load_level()
    stim, trace = run_model(n, careless)
    g = s3.Game()
    worst, first_bad = 0.0, None
    for t, ((kl, kr, jp, sk, stt), mt) in enumerate(zip(stim, trace)):
        if stt and g.st not in ("play", "dead"):
            g.reset()
        elif jp:
            g.do_jump()
        if sk:
            g.skill()
        if g.st == "play":
            for _ in range(2):
                if g.st == "play":
                    g.step(1 / 120, {"l": kl, "r": kr})
        elif g.st == "dead":
            g.dd -= 1 / 60
            if g.dd <= 0:
                g.reset()
        st = ["menu", "play", "dead", "win", "lose"].index(g.st)
        dpos = max(abs(g.p["x"] - mt[0] / Q), abs(g.p["y"] - mt[1] / Q))
        worst = max(worst, dpos)
        if (st != mt[5] or g.hits != mt[7] or g.p["jumps"] != mt[3] or dpos > 0.02) and first_bad is None:
            first_bad = (t, st, mt[5], g.hits, mt[7], g.p["x"], mt[0] / Q, g.p["y"], mt[1] / Q)
    print("model vs Pygame (float): %d ticks, largest position difference %.5f m, final state %s / %s"
          % (n, worst, g.st, ["menu", "play", "dead", "win", "lose"][trace[-1][5]]))
    if first_bad:
        print("  first difference at tick %d: state %s/%s hits %s/%s x %.4f/%.4f y %.4f/%.4f" % first_bad)
    return first_bad is None


if __name__ == "__main__":
    ok = compare_pygame(int(sys.argv[1]) if len(sys.argv) > 1 else 4000, "careless" in sys.argv)
    print("S3 MODEL vs PYGAME:", "PASS" if ok else "DIFF")
