#!/usr/bin/env python3
"""frame_check.py - pixel-exact check of the RTL video pipeline against the Python model.

  python3 fpga/tools/frame_check.py pick [scenario]   -> chooses one tick per distinct screen (help, cards,
                                                          every close-up page, notebook, clear ...) and writes
                                                          fpga/sim/frame_ticks.txt
  vvp sim/build/tb_frame.vvp +STIM=... +SNAP=...       -> RTL captures those frames (sim/frames/f<tick>.ppm)
  python3 fpga/tools/frame_check.py cmp                -> renders the same fields with ui_compile's model,
                                                          compares pixel by pixel, writes sim/frames/cmp_<tick>.png
                                                          (left: RTL VGA output, right: model, red = different)
  python3 fpga/tools/frame_check.py picgen             -> bg_mode 5 picture scenes and bg_mode 1/2 room scenes
                                                          (camera, zoom, clamps, missing flash) for tb/tb_frame_pic.v
  python3 fpga/tools/frame_check.py piccmp [scene..]   -> compares sim/frames/<scene>.ppm with the model
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


# ====================================================================== bg_mode 5: streamed picture
# Scenes for tb_frame_pic.v (real pic_stream + qspi_reader + flash_model + mem/pictures.hex -> line_renderer).
# Display list on top of the picture: a half-transparent panel, a scale-2 text and an opaque square, so the
# composition order (faded background first, then the list, list NOT faded) is checked pixel exactly.
#   name: (picture, pic id (pic_map.vh), w, h, fade, bg_color, flash programmed?)
PIC_SCENES = {
    "pic_title":   ("TITLE", 2, 640, 360, 16, 0x123, True),
    "pic_fade8":   ("TITLE", 2, 640, 360, 8, 0x123, True),
    "pic_room_f5": ("S1_ROOM", 0, 640, 358, 5, 0x0F7, True),    # rows 358-359: bg_color (faded too)
    "pic_missing": ("TITLE", 2, 640, 360, 16, 0x123, False),     # flash erased: pic_stream stripes
}
# Stage rooms streamed from the flash (bg_mode 1 = Stage 1 camera / 2x upscale, bg_mode 2 = Stage 2 1:1 or zoom),
# same display list on top, fade 16. `chg` = camera / zoom written by the testbench at VGA line 200 of the
# captured frame: the renderer latches them once per frame (vblank), so the model ignores `chg`.
#   name: (picture, pic id, bg_mode, (cam_x, cam_y), (zoom_ox, zoom_oy, zoom_inv), chg or None, flash programmed?)
ROOM_SCENES = {
    "room1_max":   ("S1_ROOM", 0, 1, (640, 354), (0, 0, 65536), None, True),            # largest camera
    "room1_odd":   ("S1_ROOM", 0, 1, (333, 77), (0, 0, 65536), ((100, 10), (0, 0, 65536)), True),
    "room1_miss":  ("S1_ROOM", 0, 1, (333, 77), (0, 0, 65536), None, False),            # stripes show through
    "room2_zoom":  ("S2_ROOM", 1, 2, (0, 0), (37, 21, 47000), None, True),               # fractional zoom
    "room2_clamp": ("S2_ROOM", 1, 2, (0, 0), (400, 300, 32768), ((0, 0), (0, 0, 65536)), True),   # sx/sy clamps
}
PIC_TEXT = "CPE ESCAPE"


def pic_list():
    """display list (ui_compile.render tuples) + text RAM used by every picture scene"""
    tx = [32] * 4096
    for i, ch in enumerate(PIC_TEXT):
        tx[i] = ord(ch)
    dl = [("RECT", 40, 250, 600, 330, 0x000, 8),                 # 50 % black panel
          ("TEXT", 60, 274, 0xFF0, 1, 0, len(PIC_TEXT), 0),      # scale-2 text, opaque
          ("RECT", 600, 10, 630, 40, 0xF00, 16),                 # opaque red square
          ("END",)]
    return dl, tx


def pic_encode(e):
    """64-bit display-list word (line_renderer.v header)"""
    if e[0] == "RECT":
        _, x0, y0, x1, y1, c, a = e
        return (1 << 61) | ((x0 & 0x7FF) << 50) | ((y0 & 0x3FF) << 40) | ((x1 & 0x7FF) << 29) | \
            ((y1 & 0x3FF) << 19) | (c << 7) | (a << 2)
    if e[0] == "TEXT":
        _, x0, y0, c, sc2, start, n, sml = e
        return (4 << 61) | ((x0 & 0x7FF) << 50) | ((y0 & 0x3FF) << 40) | (c << 28) | (sc2 << 27) | \
            (start << 15) | (n << 8) | (sml << 7)
    return 0


def fade12(c, fade):
    """R8 fade rule (line_renderer.v fade4): every 4-bit channel c -> floor(c * fade / 16), fade 0..16
    (values above 16 count as 16)"""
    f = min(fade, 16)
    return (((c >> 8 & 15) * f >> 4) << 8) | (((c >> 4 & 15) * f >> 4) << 4) | ((c & 15) * f >> 4)


def picgen():
    """writes sim/pic_dl.mem, sim/pic_tx.mem and sim/pic_scenes.txt (one line per scene: plusargs)"""
    dl, tx = pic_list()
    with open(os.path.join(SIM, "pic_dl.mem"), "w") as f:
        for e in dl:
            f.write("%016X\n" % pic_encode(e))
    with open(os.path.join(SIM, "pic_tx.mem"), "w") as f:
        for v in tx:
            f.write("%02X\n" % v)
    with open(os.path.join(SIM, "pic_scenes.txt"), "w") as f:
        for name, (_, pid, w, h, fade, bgc, prog) in PIC_SCENES.items():
            f.write("%s +NAME=%s +PICID=%d +PICW=%d +PICH=%d +FADE=%d +BGC=%d%s\n"
                    % (name, name, pid, w, h, fade, bgc, "" if prog else " +ZERO"))
        for name, (_, pid, mode, cam, zoom, chg, prog) in ROOM_SCENES.items():
            cam2, zoom2 = chg if chg else (cam, zoom)
            f.write("%s +NAME=%s +PICID=%d +PICW=640 +PICH=358 +FADE=16 +BGC=291 +MODE=%d +CAMX=%d +CAMY=%d "
                    "+ZOX=%d +ZOY=%d +ZINV=%d +CAMX2=%d +CAMY2=%d +ZOX2=%d +ZOY2=%d +ZINV2=%d%s\n"
                    % ((name, name, pid, mode) + cam + zoom + cam2 + zoom2 + ("" if prog else " +ZERO",)))
    print("picgen: %d scenes, %d primitives" % (len(PIC_SCENES) + len(ROOM_SCENES), len(dl) - 1))


def room_model(name):
    """640x480 RGB model frame of a room scene (bg_mode 1 / 2): ui_compile.render with the room colours of
    mem/preview/pic_<room>.png (ui_compile.Assets) and the frame's camera / zoom (the values before `chg`)"""
    _, _, mode, cam, zoom, _, prog = ROOM_SCENES[name]
    assets = ui_compile.Assets()
    dl, tx = pic_list()
    if prog:
        return ui_compile.render(dl, tx, assets, mode, 0x123, cam=cam, zoom=zoom)
    # flash missing: pic_stream stripes, shown row = requested source row sy, column = rd_x = sx
    bgrow = np.zeros((360, 640), dtype=np.int32)
    for y in range(360):
        for x in range(640):
            if mode == 1:
                sy, sx = (cam[1] + y) >> 1, (cam[0] + x) >> 1
            else:
                sy = min(zoom[1] + ((y * zoom[2]) >> 16), 357)
                sx = min(zoom[0] + ((x * zoom[2]) >> 16), 639)
            bgrow[y, x] = 0xF0F if ((sx + sy) >> 4) & 1 else 0x000
    assets.board = (bgrow, list(range(4096)))
    return ui_compile.render(dl, tx, assets, 4, 0x123)


def pic_model(name):
    """640x480 RGB model frame of a picture scene (bg_mode 5)"""
    if name in ROOM_SCENES:
        return room_model(name)
    pic, _, w, h, fade, bgc, prog = PIC_SCENES[name]
    if prog:
        a = np.array(Image.open(os.path.join(FPGA, "mem", "preview", "pic_%s.png" % pic)).convert("RGB"),
                     dtype=np.int32)
        assert a.shape[1] == w and a.shape[0] == h, (name, a.shape)
        assert not np.any(a % 17), "preview is not 4:4:4"
        a //= 17
        src = lambda y, x: (a[y, x, 0] << 8) | (a[y, x, 1] << 4) | a[y, x, 2]   # noqa: E731
    else:
        # pic_stream.v stripes while `missing`: row shown on game line y = src_row y (clamped to h-1)
        src = lambda y, x: 0xF0F if ((x + min(y, h - 1)) >> 4) & 1 else 0x000   # noqa: E731
    bgrow = np.zeros((360, 640), dtype=np.int32)
    pal = []
    for y in range(360):
        for x in range(640):
            c = src(y, x) if (y < h and x < w) else bgc       # R9: outside w x h -> bg_color
            bgrow[y, x] = len(pal)
            pal.append(fade12(int(c), fade))                  # R8: fade the background only
    # The renderer model composes the display list over a per-pixel background array in bg_mode 4
    # (Stage-2 board path); feeding it the faded picture gives exactly line_renderer's bg_mode 5.
    assets = ui_compile.Assets()
    assets.board = (bgrow, pal)
    dl, tx = pic_list()
    return ui_compile.render(dl, tx, assets, 4, bgc)


def piccmp(names):
    ok_all = True
    for name in names:
        p = os.path.join(FR, "%s.ppm" % name)
        if not os.path.isfile(p):
            print("%-12s: not captured" % name)
            ok_all = False
            continue
        rtl = read_ppm(p)
        model = pic_model(name)
        diff = np.any(model != rtl, axis=2)
        n = int(diff.sum())
        ok_all &= (n == 0)
        mark = rtl.copy()
        mark[diff] = (255, 0, 0)
        Image.fromarray(np.concatenate([rtl, model, mark], axis=1)).save(os.path.join(FR, "cmp_%s.png" % name))
        if n:
            ys, xs = np.nonzero(diff)
            print("  first diff at vga (%d,%d): rtl %s model %s" % (xs[0], ys[0], rtl[ys[0], xs[0]] // 17,
                                                                   model[ys[0], xs[0]] // 17))
        print("%-12s: %6d differing pixels %s" % (name, n, "OK" if n == 0 else "DIFF"))
    print("PIC FRAME CHECK: %s" % ("PASS" if ok_all else "FAIL"))
    return ok_all


if __name__ == "__main__":
    if sys.argv[1] == "picgen":
        picgen()
    elif sys.argv[1] == "piccmp":
        sys.exit(0 if piccmp(sys.argv[2:] or list(PIC_SCENES) + list(ROOM_SCENES)) else 1)
    elif sys.argv[1] == "pick":
        pick(*(sys.argv[2:3] or ["full"]))
    elif sys.argv[1] == "pick2":
        pick2()
    elif sys.argv[1] == "pick3":
        pick3(sys.argv[2])
    else:
        sys.exit(0 if cmp() else 1)
