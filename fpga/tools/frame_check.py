#!/usr/bin/env python3
"""frame_check.py - pixel-exact check of the RTL video pipeline against the Python model.

  python3 fpga/tools/frame_check.py pick [scenario]   -> chooses one tick per distinct screen (help, cards,
                                                          every close-up page, notebook, clear ...) and writes
                                                          fpga/sim/frame_ticks.txt
  vvp sim/build/tb_frame.vvp +STIM=... +SNAP=...       -> RTL captures those frames (sim/frames/f<tick>.ppm)
  python3 fpga/tools/frame_check.py cmp                -> renders the same fields with ui_compile's model,
                                                          compares pixel by pixel, writes sim/frames/cmp_<tick>.png
                                                          (left: RTL VGA output, right: model, red = different)
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ui_compile  # noqa: E402

FPGA = os.path.abspath(os.path.join(HERE, ".."))
SIM = os.path.join(FPGA, "sim")
FR = os.path.join(SIM, "frames")


def pick(scenario="full", limit=16):
    rows = [list(map(int, l.split())) for l in open(os.path.join(SIM, "s1_%s_expect.txt" % scenario))]
    stim = [int(l, 16) for l in open(os.path.join(SIM, "s1_%s_stim.mem" % scenario))]
    seen, ticks = set(), []
    for i in range(2, len(rows)):
        r, p = rows[i], rows[i - 1]
        key = (r[27], r[11], r[14] >= 0, r[3], r[4], r[5], r[15], r[16], (stim[i] >> (11 + 14)) & 1)
        # take a tick where the screen was already the same one tick earlier (settled)
        pkey = (p[27], p[11], p[14] >= 0, p[3], p[4], p[5], p[15], p[16], (stim[i - 1] >> (11 + 14)) & 1)
        if key == pkey and key not in seen:
            seen.add(key)
            ticks.append(i)
    ticks = ticks[:limit]
    with open(os.path.join(SIM, "frame_ticks.txt"), "w") as f:
        for t in ticks:
            f.write("%X\n" % t)
    print("picked %d ticks: %s" % (len(ticks), ticks))


def read_ppm(path):
    with open(path) as f:
        tok = f.read().split()
    w, h = int(tok[1]), int(tok[2])
    a = np.array(list(map(int, tok[4:])), dtype=np.int32).reshape(h, w, 3)
    return (a * 17).astype("uint8")


def pick2(limit=16):
    """Stage 2: one tick per distinct screen of the s2 'full' scenario"""
    rows = [list(map(int, l.split())) for l in open(os.path.join(SIM, "s2_full_expect.txt"))]
    stim = [int(l, 16) for l in open(os.path.join(SIM, "s2_full_stim.mem"))]
    seen, ticks = set(), []
    for i in range(2, len(rows)):
        def key(k):
            r = rows[k]
            sw = stim[k] >> 11
            return (r[44], r[25], r[28] >= 0, r[3], r[4], r[5], r[33], r[42], r[40] > 0, r[43], (sw >> 14) & 1,
                    (sw >> 15) & 1, r[37] > 0, r[30])
        if key(i) == key(i - 1) and key(i) not in seen:
            seen.add(key(i))
            ticks.append(i)
    ticks = ticks[:limit]
    with open(os.path.join(SIM, "frame_ticks2.txt"), "w") as f:
        for t in ticks:
            f.write("%X\n" % t)
    print("picked %d ticks: %s" % (len(ticks), ticks))


def pick3(scenario, limit=6):
    """Stage 3: first settled tick of each distinct screen (state, reporter, interview, message, falling)"""
    rows = [list(map(int, l.split())) for l in open(os.path.join(SIM, "s3_%s_expect.txt" % scenario))]
    seen, ticks = set(), []
    for i in range(2, len(rows)):
        def key(k):
            r = rows[k]
            return (r[6], r[11] > 0, r[15] >= 0, r[12] > 0, r[8], r[10])
        if key(i) == key(i - 1) and key(i) not in seen:
            seen.add(key(i))
            ticks.append(i)
    ticks = ticks[:limit]
    with open(os.path.join(SIM, "frame_ticks3_%s.txt" % scenario), "w") as f:
        for t in ticks:
            f.write("%X\n" % t)
    print("picked %d ticks: %s" % (len(ticks), ticks))


def cmp():
    prog = ui_compile.build()
    assets = ui_compile.Assets()
    ok_all = True
    pngs = []
    tickfile = sys.argv[2] if len(sys.argv) > 2 else "frame_ticks.txt"
    ticks = [int(l, 16) for l in open(os.path.join(SIM, tickfile))]
    for tick in ticks:
        base = os.path.basename(tickfile)
        pre = ("h%s_" % base[len("frame_ticks3_"):-4]) if base.startswith("frame_ticks3_") else \
            "g" if "2" in base else "f"
        fp = os.path.join(FR, "%s%d_fields.txt" % (pre, tick))
        if not os.path.isfile(fp):
            print("tick %5d: not captured" % tick)
            ok_all = False
            continue
        fields, conds, bg = {}, {}, None
        zoom, wl, wires, s3 = (0, 0, 65536), [0] * 54, None, (0, 0, 0)
        for line in open(fp):
            t = line.split()
            if t[0] == "bg":
                bg = (int(t[1]), int(t[2]), 0, (int(t[3]), int(t[4])))
            elif t[0] == "s3":
                s3 = (int(t[1]), int(t[2]), int(t[3]))
            elif t[0] == "zoom":
                zoom = (int(t[1]), int(t[2]), int(t[3]))
            elif t[0] == "wires":
                wires = [int(t[1]), int(t[3]) if int(t[2]) else None]
            elif t[0] == "w":
                wl[int(t[1])] = int(t[2])
            elif t[0] == "f":
                fields[int(t[1])] = int(t[2]) if t[2].lstrip("-").isdigit() else 0   # X (uninitialised) -> 0
            elif t[0] == "c":
                conds[int(t[1])] = 1
        if pre.startswith("h"):
            conds[252] = 1
        elif pre == "g":
            conds[253] = 1
        else:
            conds[254] = 1
        dl, tx = ui_compile.Composer(prog).run(fields, conds)
        model = ui_compile.render(dl, tx, assets, *bg, zoom=zoom,
                                  wires=(wl, wires[0], wires[1]) if wires else None, s3=s3)
        rtl = read_ppm(os.path.join(FR, "%s%d.ppm" % (pre, tick)))
        diff = np.any(model != rtl, axis=2)
        n = int(diff.sum())
        ok_all &= (n == 0)
        mark = rtl.copy()
        mark[diff] = (255, 0, 0)
        side = np.concatenate([rtl, model, mark], axis=1)
        out = os.path.join(FR, "cmp_%s%d.png" % (pre, tick))
        Image.fromarray(side).save(out)
        pngs.append(out)
        print("tick %5d: %6d differing pixels  (%d primitives) %s" % (tick, n, len(dl) - 1, "OK" if n == 0 else "DIFF"))
    print("FRAME CHECK: %s" % ("PASS" if ok_all and pngs else "FAIL"))
    return ok_all


if __name__ == "__main__":
    if sys.argv[1] == "pick":
        pick(*(sys.argv[2:3] or ["full"]))
    elif sys.argv[1] == "pick2":
        pick2()
    elif sys.argv[1] == "pick3":
        pick3(sys.argv[2])
    else:
        sys.exit(0 if cmp() else 1)
