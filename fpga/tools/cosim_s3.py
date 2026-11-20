#!/usr/bin/env python3
"""cosim_s3.py - Stage 3: RTL (s3_core.v) vs the fixed-point model (s3_model.py), bit-exact, tick by tick.
(The model is checked against the original float stage3_demo.py by `python3 fpga/tools/s3_model.py`.)
  gen  -> sim/s3_<sc>_stim.mem + s3_<sc>_expect.txt     cmp -> PASS / first differences
Stim word: [0] left [1] right [2] jump (BTNU) [3] skill (BTND) [4] start (BTNC) [8] checkpoint [23:16] metres
"""
import os
import sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import s3_model as M  # noqa: E402
import ui_spec  # noqa: E402


def packed(m):
    """publish() as the RTL packs it: fields[24*k +: 24], conds[k], renderer phases"""
    F, C, (cpx, wave, hill) = M.publish(m)
    fv = 0
    for k, v in F.items():
        fv |= (v & 0xFFFFFF) << (24 * ui_spec.FIELD3[k])
    cv = 1                                   # condition 0 = constant 1 (ui_composer contract)
    for k, v in C.items():
        if v:
            cv |= 1 << ui_spec.COND3[k]
    return "%0768x %064x %d %d %d" % (fv, cv, cpx, wave, hill)

SIM = os.path.join(HERE, "..", "sim")
SCEN = {"run": (0, 3000, "plan"), "careless": (0, 1600, "careless"), "skill": (0, 1400, "skill"),
        "lose": (0, 7300, "idle"), "cp90": (90, 1500, "plan"), "cp140": (140, 1500, "plan"),
        "cp185": (185, 1500, "plan"), "cp225": (225, 1200, "plan")}


def gen(name):
    x0, n, mode = SCEN[name]
    _, S, D = M.load_level()
    m = M.Model(S, D)
    stim, trace, pending, t0, pub = [], [], [], 0, []
    for t in range(n):
        demo = 0
        if t == 0 and x0:
            m.reset(); m.px, m.py = x0 * M.Q, 30 * M.Q
            demo = (1 << 8) | (x0 << 16)
            act = (0, 0, 0, 0, 0)
        elif m.st != "play":
            act = (0, 0, 0, 0, 1 if t % 40 == 1 else 0)
        elif mode == "careless":
            act = (0, 1, 0, 0, 0)
        elif mode == "idle":
            act = (0, 0, 0, 0, 0)
        elif mode == "skill":                     # run into the first animal, then use the skill
            act = (0, 1, 0, 1 if (m.hits == 1 and t % 30 == 0) else 0, 0)
        else:
            if t % 6 == 0:
                pending, t0 = M.plan(m), t
            act = (0, 1, 1 if (t - t0) in pending else 0, 1 if (m.hits == 1 and not m.used) else 0, 0)
        if not demo:
            m.frame(*act)
        stim.append(demo | act[0] | act[1] << 1 | act[2] << 2 | act[3] << 3 | act[4] << 4)
        trace.append(m.snap())
        pub.append(packed(m))
    with open(os.path.join(SIM, "s3_%s_expectf.txt" % name), "w") as f:
        f.writelines("%d %s\n" % (i, p) for i, p in enumerate(pub))
    with open(os.path.join(SIM, "s3_%s_stim.mem" % name), "w") as f:
        f.writelines("%08X\n" % w for w in stim)
    with open(os.path.join(SIM, "s3_%s_expect.txt" % name), "w") as f:
        f.writelines("%d %s\n" % (i, " ".join(str(v) for v in t)) for i, t in enumerate(trace))
    pyg = pygame_check(stim)
    print(("s3 %s: Pygame %%s;  %d ticks, max x %.1f m, states %s" % (name, n, max(t[0] for t in trace) / M.Q,
                                                       sorted(set(t[5] for t in trace)))) % pyg)
    return pyg.startswith("PASS")


def pygame_check(stim):
    """the same stimulus into the original float Pygame code: discrete state equal, positions within 2 cm"""
    s3, _, _ = M.load_level()
    _, S, D = M.load_level()
    m = M.Model(S, D)
    g = s3.Game()
    worst = 0.0
    for t, w in enumerate(stim):
        kl, kr, jp, sk, stt = w & 1, w >> 1 & 1, w >> 2 & 1, w >> 3 & 1, w >> 4 & 1
        if w >> 8 & 1:
            x0 = w >> 16 & 255
            m.reset(); m.px, m.py = x0 * M.Q, 30 * M.Q
            g.reset(); g.p["x"], g.p["y"] = float(x0), 30.0
            continue
        m.frame(kl, kr, jp, sk, stt)
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
        d = max(abs(g.p["x"] - m.px / M.Q), abs(g.p["y"] - m.py / M.Q))
        worst = max(worst, d)
        if g.st != m.st or g.hits != m.hits or g.used != m.used or d > 0.02:
            # exact tie: the exact position is ON the finish line, Pygame's float sum is a hair short of it
            if g.st == "play" and m.st == "win" and abs(g.p["x"] + g.p["w"] - LEN_WIN) < 1e-9:
                return "PASS (max %.4f m; compared up to tick %d: finish-line float tie, Pygame x+w = %r)" % (
                    worst, t, g.p["x"] + g.p["w"])
            return "DIFF at tick %d (%s/%s hits %d/%d x %.3f/%.3f)" % (t, g.st, m.st, g.hits, m.hits, g.p["x"], m.px / M.Q)
    return "PASS (max %.4f m)" % worst


LEN_WIN = 249.0


def cmp(name):
    e = [l.split() for l in open(os.path.join(SIM, "s3_%s_expect.txt" % name))]
    g = [l.split() for l in open(os.path.join(SIM, "s3_%s_rtl.txt" % name))]
    bad = 0
    for a, b in zip(e, g):
        if a != b:
            if bad < 4:
                print("tick %s: %s" % (a[0], "; ".join("%s model=%s rtl=%s" % (h, x, y)
                                                      for h, x, y in zip(M.HEADER, a[1:], b[1:]) if x != y)))
            bad += 1
    bad += len(e) != len(g)
    # display side: every field / condition / renderer phase, every tick
    ef = [l.split() for l in open(os.path.join(SIM, "s3_%s_expectf.txt" % name))]
    gf = [l.split() for l in open(os.path.join(SIM, "s3_%s_rtlf.txt" % name))]
    fbad = 0
    names = {24 * v: k for k, v in ui_spec.FIELD3.items()}
    cnames = {v: k for k, v in ui_spec.COND3.items()}
    for a, b in zip(ef, gf):
        if a != b:
            if fbad < 4:
                fa, fb = int(a[1], 16), int(b[1].replace("x", "0"), 16)
                ca, cb = int(a[2], 16), int(b[2].replace("x", "0"), 16)
                d = ["F3_%s model=%d rtl=%d" % (names[sh], fa >> sh & 0xFFFFFF, fb >> sh & 0xFFFFFF)
                     for sh in names if (fa >> sh & 0xFFFFFF) != (fb >> sh & 0xFFFFFF)]
                d += ["C3_%s model=%d rtl=%d" % (cnames[k], ca >> k & 1, cb >> k & 1) for k in cnames
                      if k < 252 and (ca >> k & 1) != (cb >> k & 1)]
                d += ["renderer %s model=%s rtl=%s" % (h, x, y) for h, x, y in zip(("cam", "wave", "hill"), a[3:], b[3:])
                      if x != y]
                print("tick %s display: %s" % (a[0], "; ".join(d[:6])))
            fbad += 1
    fbad += len(ef) != len(gf)
    ok = bad == 0 and fbad == 0
    print("COSIM S3 %s: %s (%d ticks: %d state / %d display differing)" % (name, "PASS" if ok else "FAIL", len(e),
                                                                           bad, fbad))
    return ok


if __name__ == "__main__":
    names = sys.argv[2:] or list(SCEN)
    if sys.argv[1] == "gen":
        sys.exit(0 if all([gen(n) for n in names]) else 1)
    else:
        sys.exit(0 if all([cmp(n) for n in names]) else 1)
