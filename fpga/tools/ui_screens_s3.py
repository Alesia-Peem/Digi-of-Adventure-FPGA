"""ui_screens_s3.py - STAGE 3 screens = Game.draw() / hud() / panel() of demo_py/stage3_demo.py.

Scale: the demo draws 1280x720 at 64 px per metre; the FPGA game area is 640x360 at 32 px per metre, so
every demo pixel value is halved and every metre offset becomes round(m * 32).
World objects are drawn relative to an anchor published by s3_core (OFS): x = object centre on screen,
y = screen row of its feet. rect()/circ() helpers below take the demo's own metre numbers.
Thai text = 1-bit bitmaps rendered from the demo's own font (stage3_assets.py), numbers = digit bitmaps.
"""
import json
import os

from ui_compile import S3_HILLS, S3_TERRAIN, S3_TIMG, S3_WATER

HERE = os.path.dirname(os.path.abspath(__file__))
TXT = json.load(open(os.path.join(HERE, "s3_text.json")))
N_AS, N_FS, N_PS = 6, 2, 3

WHITE, YELLOW, GREY, RED = 0xFFF, 0xFC4, 0xAAB, 0xF65
PANEL, HUDBOX = 0x012, 0x123


def M(v):
    return int(round(v * 32))


def r(p, x, y, w, h, col, cond=None):
    """demo rect(x, y, w, h) relative to the anchor (metres, y up)"""
    x0, x1 = M(x), M(x + w)
    p.rect(x0, -M(y + h), max(x1, x0 + 1), -M(y), col, cond=cond)


def R(rad):
    """circle radius: the demo passes rad*64 to pygame (truncated to whole pixels), halved"""
    return max(1, int(rad * 64) // 2)


def c(p, x, y, rad, col, cond=None):
    p.circ(M(x), -M(y), R(rad), col, cond=cond)


def timg(p, tid, x, cy, col, align="left", cond=None, field=None):
    """txt() of the demo: bitmap tid, vertically centred on cy; tid with field = digit (tid + value)"""
    t = TXT[tid]
    w, h = t["w"], t["h"]
    left = x - w // 2 if align == "center" else x - w if align == "right" else x
    p.s3(S3_TIMG, left, int(cy - h / 2), tid=t["i"], field=field, col=col, cond=cond)
    return left + w


def width(*tids):
    return sum(TXT[t]["w"] for t in tids)


# ---------------------------------------------------------------------------------------- world
def eyes(p, y, sfx):
    c(p, -.14, y, .1, WHITE); c(p, .14, y, .1, WHITE)
    for f, cond in ((1, sfx), (-1, "!" + sfx)):
        c(p, -.14 + f * .03, y, .05, 0x111, cond=cond); c(p, .14 + f * .03, y, .05, 0x111, cond=cond)


def walker(p, kind, sfx):
    """draw_animal() t1 / t2 (anchor = centre x, feet)"""
    if kind == 1:
        c(p, 0, .45, .5, 0xA63); r(p, -.4, 0, .8, .2, 0x532); eyes(p, .55, sfx)
    else:
        c(p, 0, .45, .5, 0x75C)
        for i in range(-2, 3):
            r(p, i * .18 - .05, .85, .1, .2, 0x438)
        eyes(p, .5, sfx); r(p, -.3, .2, .6, .06, 0x325)


def character(p, cx, l1, l2, fy, fcond, body, cap, mic):
    """character() of the demo; anchors: cx (x + .45), legs l1 = cx + swing, l2 = cx - swing, feet fy"""
    p.ofs(fx=l1, fy=fy)
    r(p, -.32, 0, .26, .55, 0x246)
    p.ofs(fx=l2, fy=fy)
    r(p, .06, 0, .26, .55, 0x246)
    p.ofs(fx=cx, fy=fy)
    r(p, -.4, .5, .8, .6, body); c(p, 0, 1.2, .3, 0xEC9)
    r(p, -.33, 1.36, .66, .2, cap)
    r(p, 0, 1.32, .5, .09, cap, cond=fcond); r(p, -.5, 1.32, .5, .09, cap, cond="!" + fcond)
    c(p, .12, 1.2, .05, 0x111, cond=fcond); c(p, -.12, 1.2, .05, 0x111, cond="!" + fcond)
    if mic:
        for f, cond in ((1, fcond), (-1, "!" + fcond)):
            r(p, f * .5 - .04, .65, .08, .45, 0x444, cond=cond); c(p, f * .5, 1.13, .1, 0x222, cond=cond)
        r(p, -.25, .7, .5, .14, WHITE)


def draw_world(p):
    p.s3(S3_HILLS)
    for i in range(6):                                           # clouds
        p.ofs(fx="CL%d" % i)
        cy = 8.6 + (i % 3) * .8
        for o in (-.5, 0, .6):
            p.circ(M(o), 360 - M(cy + (0 if o else .2)), R(.55), 0xEFF)
    for i in range(N_PS):                                        # draw_plant()
        with p.when("P%d_V" % i):
            p.ofs(fx="P%d_X" % i, fy="P%d_Y" % i)
            r(p, -.15, -3, .3, 3.3, 0x384); c(p, 0, .5, .55, 0x3A4)
            r(p, -.45, .35, .9, .3, 0x712, cond="P%d_OPEN" % i)
            r(p, -.45, .35, .9, .15, 0x712, cond="!P%d_OPEN" % i)
            for k in range(-2, 3):
                r(p, k * .18 - .04, .38, .08, .12, WHITE)
            c(p, 0, .75, .08, 0x111)
    for i in range(N_FS):                                        # falling animals: before the water
        with p.when("F%d_V" % i):
            p.ofs(fx="F%d_X" % i, fy="F%d_Y" % i)
            with p.when("!F%d_T2" % i):
                walker(p, 1, "F%d_F" % i)
            with p.when("F%d_T2" % i):
                walker(p, 2, "F%d_F" % i)
    p.ofs()
    p.s3(S3_WATER)
    p.s3(S3_TERRAIN)
    with p.when("FLAG"):                                         # finish flag at 248 m
        p.ofs(fx="FLAGX")
        p.rect(0, 360 - M(6), M(.12), 360 - M(2), 0xEEE)
        p.rect(M(.12), 360 - M(5.9), M(1.32), 360 - M(4.8), 0xD43)
    for i in range(N_AS):                                        # animals
        with p.when("A%d_V" % i):
            p.ofs(fx="A%d_X" % i, fy="A%d_Y" % i)
            with p.when("A%d_T1" % i):
                walker(p, 1, "A%d_F" % i)
            with p.when("A%d_T2" % i):
                walker(p, 2, "A%d_F" % i)
            with p.when("A%d_T4" % i):
                c(p, 0, .35, .5, 0xD43)
                p.ofs(fx="A%d_X" % i, fy="A%d_YW" % i)           # wing: y + sin(gt*14) * .25
                r(p, -.1, .35, .5, .12, 0xA22)
                p.ofs(fx="A%d_X" % i, fy="A%d_Y" % i)
                c(p, -.35, .4, .15, 0xEB2); c(p, -.15, .5, .09, WHITE); c(p, -.17, .5, .045, 0x111)
    with p.when("REP"):
        character(p, "RCX", "RL1", "RL2", "RY", "RF", 0xE82, 0x222, True)
    with p.when("PLAYER"):
        character(p, "PCX", "PL1", "PL2", "PY", "PF", 0x37D, 0xD33, False)
    p.ofs()


# ---------------------------------------------------------------------------------------- HUD / panels
def hud(p):
    p.rect(7, 6, 122, 28, HUDBOX, alpha=10); p.rect(470, 6, 633, 28, HUDBOX, alpha=10)
    p.rect(220, 6, 420, 14, HUDBOX, alpha=10)
    for col, cond in ((RED, "TBLINK"), (WHITE, "!TBLINK")):     # 'เวลา m:ss'
        x = timg(p, "TIME", 13, 17.5, col, cond=cond)
        x = timg(p, "D13_0", x, 17.5, col, cond=cond, field="TM")
        x = timg(p, "D13_10", x, 17.5, col, cond=cond)
        x = timg(p, "D13_0", x, 17.5, col, cond=cond, field="TS1")
        timg(p, "D13_0", x, 17.5, col, cond=cond, field="TS2")
    p.rect(220, 6, 0, 0, YELLOW, f1=("PBX1", "PBY1"))           # progress bar
    # skill, right aligned at x = 627
    timg(p, "SKILL", 627 - width("SKILL", "SK_USED"), 17.5, GREY, cond="SK_USED")
    timg(p, "SK_USED", 627, 17.5, GREY, "right", cond="SK_USED")
    with p.when("SK_READY"):
        for col, cond in ((YELLOW, "SK_BLINK"), (WHITE, "!SK_BLINK")):
            timg(p, "SKILL", 627 - width("SKILL", "SK_READY"), 17.5, col, cond=cond)
            timg(p, "SK_READY", 627, 17.5, col, "right", cond=cond)
    with p.when("!SK_USED"):
        with p.when("!SK_READY"):
            timg(p, "SKILL", 627 - width("SKILL", "SK_WAIT"), 17.5, WHITE)
            timg(p, "SK_WAIT", 627, 17.5, WHITE, "right")
    with p.when("MSG"):
        p.rect(190, 38, 450, 60, HUDBOX, alpha=11)
        timg(p, "MSG_SKILL", 320, 49.5, WHITE, "center", cond="MSG_SKILL")
        timg(p, "MSG_HIT", 320, 49.5, WHITE, "center", cond="!MSG_SKILL")


def talk(p):
    with p.when("TALK"):
        p.rect(60, 240, 580, 335, PANEL, alpha=14)
        timg(p, "REP", 75, 257.5, YELLOW)
        timg(p, "TALK1", 75, 285, WHITE, cond="TALK1")
        timg(p, "TALK2", 75, 285, WHITE, cond="!TALK1")
        x = timg(p, "TALK_A", 75, 315, YELLOW)
        x = timg(p, "D14_0", x, 315, YELLOW, field="TALKD")
        timg(p, "SEC", x, 315, YELLOW)


def panel(p, title, cond):
    p.rect(0, 0, 640, 360, PANEL, alpha=12, cond=cond)
    timg(p, title, 320, 100, WHITE, "center", cond=cond)


def number_line(p, head, tail, digits, dconds, cy, tenth=None):
    """centred '<head><digits>[.<tenth>]<tail>' with 1..3 integer digits (one variant per digit count)"""
    for n, dc in zip((1, 2, 3), dconds):
        wid = width(head, tail) + 8 * n + ((4 + 8) if tenth else 0)
        with p.when(dc):
            x = timg(p, head, 320 - wid // 2, cy, WHITE)
            for f in digits[3 - n:]:
                x = timg(p, "D14_0", x, cy, WHITE, field=f)
            if tenth:
                x = timg(p, "D14_10", x, cy, WHITE)
                x = timg(p, "D14_0", x, cy, WHITE, field=tenth)
            timg(p, tail, x, cy, WHITE)


def panels(p):
    with p.when("DEAD"):
        p.rect(0, 0, 640, 360, 0x148, alpha=9)
        timg(p, "DEAD", 320, 180, WHITE, "center")
    with p.when("MENU"):
        panel(p, "TITLE", None)
        for i in range(5):
            timg(p, "M%d" % (i + 1), 320, 140 + i * 22, WHITE, "center")
        timg(p, "MSUB", 320, 300, YELLOW, "center")
    with p.when("WIN"):
        panel(p, "WIN", None)
        number_line(p, "WIN_A", "SEC", ("W1", "W2", "W3"), ("WD1", "WD2", "WD3"), 140, tenth="WT")
        timg(p, "WSUB", 320, 300, YELLOW, "center")
    with p.when("LOSE"):
        panel(p, "LOSE", None)
        number_line(p, "LOSE_A", "LOSE_B", ("L1", "L2", "L3"), ("LD1", "LD2", "LD3"), 140)
        timg(p, "LSUB", 320, 300, YELLOW, "center")


def build(p):
    p.stage(3)
    with p.when("IS_S3"):
        draw_world(p)
        hud(p)
        talk(p)
        panels(p)
    p.stage(1)
