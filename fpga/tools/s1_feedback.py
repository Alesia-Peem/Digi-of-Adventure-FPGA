#!/usr/bin/env python3
"""s1_feedback.py - targeted check of the Stage 1 answer feedback (commit() / clear_feedback()) of s1_core.v
against the NEW demo_py/stage1_demo.py.

  python3 fpga/tools/s1_feedback.py gen   -> plays one scripted session per puzzle close-up on the NEW Pygame game
                                            (headless) and writes fpga/sim/s1_fb_stim.mem (inputs per tick) and
                                            fpga/sim/s1_fb_expect.txt (one JSON row of Pygame state per tick)
  vvp sim/build/tb_s1_feedback.vvp        -> replays the inputs on s1_core.v, writes fpga/sim/s1_fb_rtl.txt
  python3 fpga/tools/s1_feedback.py cmp   -> turns the RTL ids into strings with ui_spec.TABLES and compares
                                            every tick: done, right, A/B/C, page, close-up message, p2 equation,
                                            the toast started in that tick, and the notebook notes

What is compared comes from the NEW game itself (its commit(), clear_feedback(), poll() and puzzle handlers run
here); nothing is typed in by hand. Only the close-up handlers are exercised: the help screen, the TA intro
(F1), the card rounds and the notebook-guide gate (F2) are switched off on both sides before the script
starts, because they are not part of this slice.

Controls: the new P2 / P5 key mapping is out of scope of this slice, so the script uses abstract actions that
each side maps to its own keys (P2: next slot = Pygame BTND / RTL BTNR, confirm = Pygame BTNR / RTL BTNU;
P5: next box = Pygame BTNR / RTL BTND, letter+1 = Pygame BTND / RTL BTNR, letter-1 = Pygame BTNU / RTL BTNL).
The one message that names a new key ("Stored in Term%d. ... press BTNR to check.") is a KNOWN DIFF: the RTL
keeps the old "Stored in T%d." text with the old keys. It is reported on every tick where it occurs.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.pop("COSIM_DEMO", None)          # always the NEW game in demo_py/
import cosim_s1  # noqa: E402  (sets up headless pygame + demo_py on sys.path)
import pygame  # noqa: E402

SIM = cosim_s1.SIM
OBJ_IDS = cosim_s1.OBJ_IDS
TICK = 1.0 / 60

# abstract action -> (Pygame event, RTL event)
ACT = {
    "tap": ("tap", "tap"), "back": ("back", "back"),
    "p2next": ("down", "r"), "p2conf": ("right", "u"),
    "p3l": ("left", "l"), "p3r": ("right", "r"), "p3u": ("up", "u"), "p3d": ("down", "d"),
    "p5box": ("right", "d"), "p5up": ("down", "r"), "p5dn": ("up", "l"),
}
EVBIT = {"u": 0, "d": 1, "l": 2, "r": 3, "tap": 4, "back": 5}


def script():
    """list of steps: ("enter", obj) | ("sw", value) | (action,) ; every action tick is followed by an idle tick"""
    s = []
    A = lambda a, n=1: s.extend([(a,)] * n)  # noqa: E731
    # ---- puzzle 1, whiteboard: wrong, switch change clears, correct, correct again (no 2nd note), wrong after
    s.append(("enter", "whiteboard")); A("tap")
    s.append(("sw", 5)); A("tap")
    s.append(("sw", 6)); A("tap"); A("tap")
    s.append(("sw", 5)); A("tap")
    s.append(("sw", 0)); A("back")
    # ---- puzzle 2, paper: empty confirm, wrong expression, store clears on a switch change, correct
    s.append(("enter", "paper")); A("tap")
    A("p2conf")
    s.append(("sw", 0xC0)); A("tap"); A("p2conf")
    s.append(("sw", 0xCC)); A("tap")
    s.append(("sw", 0xCD))                                   # F6: clears "Stored ..."
    s.append(("sw", 0xCC)); A("tap"); A("p2next")
    s.append(("sw", 0x33)); A("tap"); A("p2conf"); A("p2conf")
    s.append(("sw", 0x30))                                   # F6 after CORRECT
    s.append(("sw", 0xCC)); A("tap"); A("p2conf")            # AB + AB: wrong after correct (done stays)
    A("p2next", 2); s.append(("sw", 0x33)); A("tap"); A("p2conf")    # CD + AB: a 2nd, different P2 note
    s.append(("sw", 0)); A("back")
    # ---- puzzle 3, laptop 1 (NAND): wrong circuit, a key clears, reference circuit, correct
    s.append(("enter", "laptop3")); A("tap"); A("tap")
    for c in range(1, 9):
        A("p3r")
        A("p3u", {1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 8: 2}.get(c, 0))
    A("tap"); A("p3d"); A("tap"); A("p3u"); A("tap"); A("back")
    # ---- puzzle 4, laptop 2 (two's complement): wrong, switch change clears, correct
    s.append(("enter", "laptop4")); A("tap")
    s.append(("sw", 0xF5)); A("tap")
    s.append(("sw", 0xF4)); A("tap")
    s.append(("sw", 0x00)); A("back")
    # ---- puzzle 5, teacher PC: wrong login (no note), a key clears, CPE, correct
    s.append(("enter", "pc")); A("tap"); A("p5up")
    A("p5up"); A("p5box"); A("p5dn", 11); A("p5box"); A("p5up", 4); A("p5dn"); A("tap")
    A("p5up"); A("tap"); A("tap")
    return s


# ====================================================================== Pygame side
def py_row(g, toast):
    ans = lambda k: -1 if g.ans[k] is None else g.ans[k]  # noqa: E731
    cur = OBJ_IDS.index(g.cur.id) if (g.mode == "closeup" and g.cur) else -1
    return dict(cu=int(g.mode == "closeup"), cur=cur, page=g.page,
                done=sum(int(b) << i for i, b in enumerate(g.done)),
                right=sum(int(b) << i for i, b in enumerate(g.right)),
                A=ans("A"), B=ans("B"), C=ans("C"), cmsg=g.cmsg, eq=g.p2_eq, toast=toast,
                notes=["- " + n for n in g.notes])


def gen():
    mod, g = cosim_s1.load_game()
    # out of this slice: help, TA intro, card rounds, notebook-guide gate -> off on both sides (see tb)
    g.show_help, g.intro_idx, g.notebook_guide_seen = False, None, True
    g.r_run = {1: True, 2: True, 3: True}
    g.r_done = {1: True, 2: True, 3: True}
    said = []
    orig_say = g.say
    g.say = lambda text, secs=2.5: (said.append(text), orig_say(text, secs))
    sw = [0] * 16
    stim, rows = [], []
    tick = [0]

    def step(act=None, setup=None):
        said.clear()
        e = dict(up=0, down=0, left=0, right=0, tap=0, back=0)
        word = sum(v << i for i, v in enumerate(sw)) << 11
        if setup is not None:                  # put the player into a close-up (page 0) between two ticks
            g.mode, g.cur, g.page, g.cmsg, g.feedback = "closeup", next(o for o in mod.OBJS if o.id == setup), \
                0, "", None
            word = (1 << 31) | OBJ_IDS.index(setup)
        else:
            if act:
                pe, re_ = ACT[act]
                e[pe] = 1
                word |= 1 << (5 + EVBIT[re_])
            cosim_s1.FakeTime.t = cosim_s1.Fraction(tick[0], 60)
            g.update(TICK, e)
            tick[0] += 1
        stim.append(word)
        rows.append(py_row(g, said[-1] if said else ""))

    for st in script():
        if st[0] == "enter":
            step(setup=st[1])
        elif st[0] == "sw":
            new = [st[1] >> i & 1 for i in range(8)]
            evs = [pygame.event.Event(pygame.KEYDOWN, key=pygame.K_1 + i) for i in range(8) if new[i] != sw[i]]
            g.poll(evs)                        # real poll(): toggles g.sw and calls clear_feedback()
            sw[:8] = new
            assert [int(b) for b in g.sw[:8]] == sw[:8]
            step()
        else:
            step(st[0])
            step()
    with open(os.path.join(SIM, "s1_fb_stim.mem"), "w") as f:
        f.write("".join("%08X\n" % w for w in stim))
    with open(os.path.join(SIM, "s1_fb_expect.txt"), "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in rows))
    print("s1_feedback: %d ticks generated from demo_py/stage1_demo.py" % len(rows))


# ====================================================================== RTL side
def rtl_rows():
    import ui_spec
    import ui_compile
    T = ui_spec.TABLES
    fmt = lambda v, f: ui_compile.Composer.fmt(ui_compile.Composer, v, f, 0)  # noqa: E731
    rows = []
    for line in open(os.path.join(SIM, "s1_fb_rtl.txt")):
        v = list(map(int, line.split()))
        (_, cu, cur, page, done, right, av, a, b, c, cmsg, cmsg_p, toast, toast_t, p2eq, note_n) = v[:16]
        nt = v[16:24]
        txt = T["CMSG"][cmsg][1]
        if cmsg < len(T["CMSG_SUFFIX"]) and T["CMSG_SUFFIX"][cmsg][1]:
            txt += str(cmsg_p) + T["CMSG_SUFFIX"][cmsg][1]
        notes = []
        for k in range(note_n):
            notes.append(T["NOTE"][nt[k]][1])          # every Stage 1 note is a fixed text now
        rows.append(dict(cu=cu, cur=cur if cu else -1, page=page, done=done, right=right,
                         A=a if av & 1 else -1, B=b if av & 2 else -1, C=c if av & 4 else -1, cmsg=txt,
                         eq=fmt(p2eq, 6), toast=T["TOAST"][toast][1] if toast_t == 150 else "", notes=notes))
    return rows


def known_diff(key, py, rt):
    """differences that belong to work outside this slice (documented in the module docstring)"""
    import re
    if key == "cmsg":
        m = re.match(r"Stored in Term(\d)\. Continue setting the other terms, then press BTNR to check\.$", py)
        return bool(m) and rt == "Stored in T%s." % m.group(1)
    return False


def cmp():
    exp = [json.loads(l) for l in open(os.path.join(SIM, "s1_fb_expect.txt"))]
    rtl = rtl_rows()
    bad, known = 0, 0
    if len(exp) != len(rtl):
        print("tick count differs: Pygame %d, RTL %d" % (len(exp), len(rtl)))
        bad += 1
    for i, (e, r) in enumerate(zip(exp, rtl)):
        for k in e:
            if e[k] == r[k]:
                continue
            if known_diff(k, e[k], r[k]):
                known += 1
                continue
            bad += 1
            if bad <= 25:
                print("tick %3d %-6s Pygame %r\n         %-6s RTL    %r" % (i, k, e[k], "", r[k]))
    nc = sum(1 for e in exp if e["toast"])
    print("s1_feedback: %d ticks, %d toasts, %d notes at the end; %d known diffs (P2 'Stored' text, old keys)"
          % (len(exp), nc, len(exp[-1]["notes"]) if exp else 0, known))
    print("S1_FEEDBACK: %s (%d mismatches)" % ("PASS" if bad == 0 else "FAIL", bad))
    return bad == 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "gen"
    if cmd == "gen":
        gen()
    elif cmd == "cmp":
        sys.exit(0 if cmp() else 1)
    else:
        sys.exit("usage: s1_feedback.py gen|cmp")
