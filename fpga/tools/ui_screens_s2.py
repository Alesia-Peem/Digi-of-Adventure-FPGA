"""ui_screens_s2.py - every Stage 2 screen of stage2_demo.py for the UI engine.

Same conventions as ui_screens.py: numbers are the Pygame coordinates (960x540 UI, close-ups in the
640-wide subsurface at x = 160) converted by x 2/3. Fields / conditions are the Stage-2 namespace
(ui_spec.FIELDS2 / CONDS2).
"""
from ui_compile import Program, col12, alpha16
from ui_screens import U, SX, ctext, C, WHITE, GOLD, FOOT, CMSG, draw_box

MUTED = C((143, 161, 184))
SEGS = "abcdefg"


def seven(p, x, y, w, h, cond_fmt, off, on=C((255, 60, 40))):
    """draw_set(): 7 segments, lit ones by condition cond_fmt % index (game-area coordinates)"""
    t = max(3, w // 6)
    h2 = h // 2
    r = {"a": (x + t, y, w - 2 * t, t), "b": (x + w - t, y + t, t, h2 - t), "c": (x + w - t, y + h2, t, h2 - t),
         "d": (x + t, y + h - t, w - 2 * t, t), "e": (x, y + h2, t, h2 - t), "f": (x, y + t, t, h2 - t),
         "g": (x + t, y + h2 - t // 2, w - 2 * t, t)}
    for i, sname in enumerate(SEGS):
        rx, ry, rw, rh = r[sname]
        X0, Y0, X1, Y1 = U(rx), U(ry), U(rx + rw), U(ry + rh)
        if off is not None:
            p.rect(X0, Y0, X1, Y1, off, cond="!" + cond_fmt % i)
        p.rect(X0, Y0, X1, Y1, on, cond=cond_fmt % i)


def sx_ui(x):            # UI x (full 960 surface) -> game area
    return U(x)


# ---------------------------------------------------------------------------- world
def draw_npc(p):
    p.ofs(fx="NPC_X", fy="NPC_Y")
    with p.when("NPC_SIT"):
        p.rect(-7, -20, 7, -4, C((40, 70, 150)))
        p.circ(0, -25, 5, C((240, 200, 160)))
        p.rect(-5, -31, 5, -27, C((60, 40, 30)))
    with p.when("!NPC_SIT"):
        p.rect(-5, -12, 5, 0, C((40, 40, 55)))
        p.rect(-7, -28, 7, -11, C((40, 70, 150)))
        p.rect(-1, -25, 1, -16, C((200, 50, 50)))
        p.circ(0, -33, 5, C((240, 200, 160)))
        p.rect(-5, -39, 5, -35, C((60, 40, 30)))
    p.ofs()


def draw_world(p, spots):
    with p.when("MAP"):
        with p.when("ZOOM"):                            # apply_zoom(): the whole world is scaled
            p.zoom(zf="ZF", zo="ZO")
            p.zoom(zinv="ZINV")
        with p.when("GLOW"):                            # workshop-shirt skill: hidden parts glow
            for i, (ix, iy) in enumerate(spots):
                with p.when("!FOUND%d" % i):
                    p.circ(U(ix), U(iy), 11, C((255, 220, 60)), alpha=alpha16(90))
                    p.circ(U(ix), U(iy), 12, C((255, 230, 90)), ri=10, cond="BLINK")
                    p.circ(U(ix), U(iy), 11, C((255, 230, 90)), ri=9, cond="!BLINK")
        with p.when("NPC_ON"):
            with p.when("NPC_BEHIND"):
                draw_npc(p)
        p.ofs(fx="PSX", fy="PSY", x0=-20, y0=-38)       # 32x32 art drawn 41 px high (SPR_H 62 UI)
        p.spr(0, 0, 0, field="PFRAME", step=200)
        p.ofs()
        with p.when("LEGS"):                            # hide_legs(): picture back in front of the legs
            p.ofs(fx="LEG_X0", fy="LEG_Y0")
            p.clrbg(0, 0, 0, 0, f1=("LEG_X1", "LEG_Y1"))
            p.ofs()
        with p.when("NPC_ON"):
            with p.when("!NPC_BEHIND"):
                draw_npc(p)
        with p.when("PROMPT_ON"):
            p.ofs(fx="PSX", fy="PSY")
            p.textt(0, -55, "S2_PROMPT", "PROMPT", GOLD, font="s", center=True)
            p.ofs()
        p.zoom()


def draw_hud(p):
    for i in range(3):
        p.circ(U(24 + i * 26), U(22), 7, C((230, 50, 60)), cond="HEART%d" % (i + 1))
        p.circ(U(24 + i * 26), U(22), 7, C((80, 50, 50)), cond="!HEART%d" % (i + 1))
    with p.when("ARMOR_ON"):
        p.rect(U(96), U(12), U(114), U(34), C((80, 180, 255)))
        p.text(U(118), U(14), "x", C((120, 200, 255)), font="s")
        p.num(0, 0, "ARMOR", "dec", C((120, 200, 255)), font="s", xcont=True)
    with p.when("SLOW_ON"):
        p.text(U(16), U(40), "SLOW ", C((255, 150, 80)), font="s")
        p.num(0, 0, "SLOW_S", "dec", C((255, 150, 80)), font="s", xcont=True)
        p.text(0, 0, "s", C((255, 150, 80)), font="s", xcont=True)
    with p.when("!BOARD"):
        p.text(570, U(10), "Parts ", C((150, 255, 170)), font="s")
        p.num(0, 0, "PTOTAL", "dec", C((150, 255, 170)), font="s", xcont=True)
        p.text(0, 0, "/18", C((150, 255, 170)), font="s", xcont=True)
        p.text(588, U(28), "QA ", GOLD, font="s")
        p.num(0, 0, "QA_RND", "dec", GOLD, font="s", xcont=True)
        p.text(0, 0, "/3", GOLD, font="s", xcont=True)


def draw_skill_btn(p):
    with p.when("SKILLBTN"):
        x0, y0, x1, y1 = U(960 - 160), U(50), U(960 - 14), U(78)
        cx = (x0 + x1) // 2
        with p.when("SKILL_ON"):
            p.rect(x0, y0, x1, y1, C((40, 120, 60)))
            p.text(cx - 6 * 6, y0 + 3, "SKILL ON  ", WHITE, font="s")
            p.num(0, 0, "SKILL_S", "dec", WHITE, font="s", xcont=True)
            p.text(0, 0, "s", WHITE, font="s", xcont=True)
        with p.when("!SKILL_ON"):
            with p.when("SKILL_USED"):
                p.rect(x0, y0, x1, y1, C((50, 50, 56)))
                ctext(p, cx, y0 + 3, "SKILL USED", C((130, 130, 140)), font="s")
            with p.when("!SKILL_USED"):
                with p.when("SKILL_READY"):
                    p.rect(x0, y0, x1, y1, C((230, 180, 40)), cond="BLINK")
                    p.rect(x0, y0, x1, y1, C((190, 140, 30)), cond="!BLINK")
                    ctext(p, cx, y0 + 3, "SKILL READY (SW13)", C((20, 20, 20)), font="s")
                with p.when("!SKILL_READY"):
                    p.rect(x0, y0, x1, y1, C((50, 50, 56)))
                    p.text(cx - 6 * 6, y0 + 3, "SKILL  ", C((200, 200, 210)), font="s")
                    p.num(0, 0, "SKILL_M", "dec", C((200, 200, 210)), font="s", xcont=True)
                    p.text(0, 0, ":", C((200, 200, 210)), font="s", xcont=True)
                    p.num(0, 0, "SKILL_SS", "dec", C((200, 200, 210)), width=2, font="s", xcont=True)
        p.frame(x0, y0, x1, y1, WHITE, 1)


# ---------------------------------------------------------------------------- close-ups
def frame_top(p):
    p.rect(SX(0), 0, SX(640), U(44), C((70, 74, 90)))
    p.textt(SX(16), U(10), "S2_OBJ", "OBJ", WHITE)


def frame_bottom(p, foot):
    with p.when("CMSG_LOCK"):
        p.textt(SX(16), U(440), "S2_CMSG", "CMSG", CMSG, font="s")
        p.num(0, 0, "QA_RND", "dec", CMSG, font="s", xcont=True)
        p.text(0, 0, " / 3).", CMSG, font="s", xcont=True)
    with p.when("CMSG_MISS"):
        p.textt(SX(16), U(436), "S2_CMSG", "CMSG", CMSG, font="s")
        for line, parts in ((1, range(0, 5)), (2, range(5, 9))):
            first = True
            for pi in parts:
                y = U(436) + 12 * line
                with p.when("MISS%d" % pi):
                    if not first:
                        p.text(SX(16) if first else 0, y, ", ", CMSG, font="s", xcont=True, cond="MSEP%d" % pi)
                    p.textt(SX(16) if first else 0, y, "S2_MISS%d" % pi, "PCOUNT%d" % pi, CMSG, font="s",
                            xcont=not first)
                first = False
    p.rect(SX(0), U(494), SX(640), 360, C((40, 44, 60)))
    for cond, t in foot:
        p.text(SX(16), U(497), t, FOOT, font="s", cond=cond)
    p.text(SX(16), U(518), "Back: hold BTNC (0.8 s)", C((140, 150, 180)), font="s")


def cu_whiteboard(p, T):
    ink = C((30, 40, 130))
    p.rect(SX(40), U(56), SX(600), U(432), C((240, 240, 235)))
    with p.when("PAGE0"):
        lines = ["WORK ORDER #402", "Build the 7-segment decoder.", "1. Hunt for all 18 lab parts in the office.",
                 "   (notes and screens hold hints)", "2. Bring them to the decoder bench.",
                 "3. Wire it, then show it to the Boss.", "", "input CBA -> character",
                 "001 = C   010 = P   011 = E", "100 = -   101 = 3   110 = 9", "(000 and 111 never occur)"]
        for i, l in enumerate(lines):
            if l:
                p.text(SX(62), U(68 + i * 33), l, ink, font="s")
    with p.when("PAGE1"):
        p.text(SX(62), U(68), "EQUIPMENT LIST", ink)
        for i, q in enumerate(T["part_qty"]):
            y = U(112 + i * 30)
            for ok, colr in (("PARTOK%d" % i, C((20, 120, 40))), ("!PARTOK%d" % i, ink)):
                with p.when(ok):
                    p.text(SX(62), y, "[x] " if ok[0] != "!" else "[ ] ", colr, font="s")
                    p.text(0, 0, "%-26s x%d   (" % (T["part_label"][i], q), colr, font="s", xcont=True)
                    p.num(0, 0, "PCOUNT%d" % i, "dec", colr, font="s", xcont=True)
                    p.text(0, 0, " found)", colr, font="s", xcont=True)
        p.text(SX(62), U(396), "Total: ", ink, font="s")
        p.num(0, 0, "PTOTAL", "dec", ink, font="s", xcont=True)
        p.text(0, 0, " / 18", ink, font="s", xcont=True)
    with p.when("PAGE2"):
        p.text(SX(70), U(76), "QA TEST ", ink)
        p.textt(0, 0, "S2_QAN", "QA_RND", ink, xcont=True)
        with p.when("DONE"):
            p.text(SX(70), U(140), "All QA tests passed. Go to the exit door.", C((20, 120, 40)), font="s")
        with p.when("!DONE"):
            p.text(SX(70), U(140), Program.wrap("The QA inputs appear here once the decoder bench is powered on.", 60),
                   ink, font="s", cond="!CODES")
            with p.when("CODES"):
                for i in range(2):
                    p.text(SX(70), U(140 + i * 130), "input CBA = ", ink, font="s")
                    p.num(0, 0, "QA_K%d" % i, "bin", ink, width=3, font="s", xcont=True)
                    p.text(0, 0, "  ->  show ", ink, font="s", xcont=True)
                    p.textt(0, 0, "S2_CHAR", "QA_K%d" % i, ink, font="s", xcont=True)
                    seven(p, 470 + 160, 126 + i * 130, 54, 92, "T%dS%%d" % i, C((215, 215, 210)))
        for i in range(3):                              # which pairs the Boss already checked
            with p.when("CODES"):
                with p.when("QAPASS%d" % i):
                    p.text(SX(70), U(366 + i * 20), "Test %d: " % (i + 1), C((20, 120, 40)), font="s")
                    p.textt(0, 0, "S2_CHAR", "QA_P%d" % (2 * i), C((20, 120, 40)), font="s", xcont=True)
                    p.text(0, 0, " and ", C((20, 120, 40)), font="s", xcont=True)
                    p.textt(0, 0, "S2_CHAR", "QA_P%d" % (2 * i + 1), C((20, 120, 40)), font="s", xcont=True)
                    p.text(0, 0, " - passed", C((20, 120, 40)), font="s", xcont=True)
                p.text(SX(70), U(366 + i * 20), "Test %d: not done yet" % (i + 1), C((90, 90, 100)), font="s",
                       cond="!QAPASS%d" % i)


def cu_door(p):
    p.rect(SX(240), U(56), SX(400), U(306), C((120, 85, 55)))
    p.circ(SX(376), U(185), 6, C((34, 197, 94)), cond="DONE")
    p.circ(SX(376), U(185), 6, C((220, 60, 60)), cond="!DONE")
    ctext(p, SX(320), U(320) - 4, "UNLOCKED", C((34, 197, 94)), font="l", cond="DONE")
    ctext(p, SX(320), U(320) - 4, "LOCKED", C((255, 120, 120)), font="l", cond="!DONE")
    p.text(SX(320) - 8 * 9, U(362), "Decoder QA: ", WHITE)
    p.num(0, 0, "QA_RND", "dec", WHITE, xcont=True)
    p.text(0, 0, " / 3", WHITE, xcont=True)
    ctext(p, SX(320), U(394), "The lock is wired to the decoder bench.", C((200, 200, 210)), font="s", cond="!DONE")


def cu_bench(p, T):
    g = C((110, 255, 130))
    p.rect(SX(40), U(56), SX(600), U(422), C((10, 20, 10)))
    p.text(SX(56), U(64), "DECODER BENCH - PARTS TRAY", g, font="s")
    for i, q in enumerate(T["part_qty"]):
        y = 92 + i * 32
        p.rect(SX(56), U(y), SX(584), U(y + 28), C((30, 70, 40)), cond="PARTOK%d" % i)
        p.rect(SX(56), U(y), SX(584), U(y + 28), C((40, 30, 30)), cond="!PARTOK%d" % i)
        for ok, colr, tag in (("PARTOK%d" % i, g, "[OK]"), ("!PARTOK%d" % i, C((255, 170, 150)), "[  ]")):
            with p.when(ok):
                p.text(SX(64), U(y + 5), tag, g if tag == "[OK]" else C((255, 120, 120)), font="s")
                p.text(SX(120), U(y + 5), "%-27s " % T["part_label"][i], colr, font="s")
                p.num(0, 0, "PCOUNT%d" % i, "dec", colr, font="s", xcont=True)
                p.text(0, 0, " / %d" % q, colr, font="s", xcont=True)
    with p.when("DONE"):
        p.text(SX(56), U(392), "DECODER VERIFIED.", C((255, 255, 120)), font="s")
    with p.when("!DONE"):
        p.text(SX(56), U(392), "All parts on the bench. Ready to power on.", C((255, 255, 120)), font="s", cond="ALL18")
        with p.when("!ALL18"):
            p.text(SX(56), U(392), "Parts ", g, font="s")
            p.num(0, 0, "PTOTAL", "dec", g, font="s", xcont=True)
            p.text(0, 0, " / 18. Search the office, read the hints.", g, font="s", xcont=True)


def draw_board(p):
    """page 1 of the bench: static picture (bg_mode 4) + everything that changes"""
    p.text(430, U(14), "Wires ", MUTED, font="s")
    p.num(0, 0, "WCNT", "dec", MUTED, font="s", xcont=True)
    p.text(0, 0, " / 53   |   Parts ", MUTED, font="s", xcont=True)
    p.num(0, 0, "PTOTAL", "dec", MUTED, font="s", xcont=True)
    p.text(0, 0, "/18", MUTED, font="s", xcont=True)
    with p.when("CODES"):
        for i in range(2):                                      # draw_target(): the 2 QA inputs
            x, y = 16 + i * 262, 48
            seven(p, x + 12, y + 9, 28, 48, "T%dS%%d" % i, C((38, 54, 76)))
            p.text(U(x + 52), U(y + 12), "CBA = ", MUTED, font="s")
            p.num(0, 0, "QA_K%d" % i, "bin", MUTED, width=3, font="s", xcont=True)
            p.text(U(x + 52), U(y + 34), "must show  ", WHITE)
            p.textt(0, 0, "S2_CHAR", "QA_K%d" % i, WHITE, xcont=True)
            p.text(U(x + 178), U(y + 14), "tested by", MUTED, font="s")
            p.text(U(x + 178), U(y + 28), "Boss", MUTED, font="s")
    p.textt(U(590), U(76), "S2_QAN", "QA_RND", WHITE, center=True)
    with p.when("WCLEAR"):
        p.rect(U(790), U(58), U(944), U(92), GOLD)
        ctext(p, U(867), U(67), "CLEAR ALL", C((20, 20, 20)), font="s")
    for i, swi in enumerate((2, 1, 0)):                         # DIP switch levers = SW2..SW0
        y = 238 + i * 32
        p.rect(U(92), U(y - 6), U(118), U(y + 6), C((245, 245, 250)), cond="DSW%d" % swi)
        p.rect(U(56), U(y - 6), U(82), U(y + 6), C((150, 160, 190)), cond="!DSW%d" % swi)
    p.wires()
    seven(p, 800, 150, 100, 180, "SEG%d", None)                 # live decoder output
    ctext(p, U(850) - 30, U(374), "INPUT CBA = ", WHITE, font="s")
    p.num(U(850) + 6, U(374), "CODE3", "bin", WHITE, width=3, font="s")
    with p.when("CODEVALID"):
        p.text(U(850) - 36, U(396), "should show ", MUTED, font="s")
        p.textt(0, 0, "S2_CHAR", "CODE_C", MUTED, font="s", xcont=True)
    ctext(p, U(850), U(396), "(never occurs)", MUTED, font="s", cond="!CODEVALID")
    for i in range(4):
        p.rect(U(780 + i * 36), U(448), U(794 + i * 36), U(462), C((34, 197, 94)), cond="PWR%d" % i)
        p.rect(U(780 + i * 36), U(448), U(794 + i * 36), U(462), C((160, 60, 60)), cond="!PWR%d" % i)
    p.text(U(778), U(478), "DIP ", MUTED, font="s")
    p.text(0, 0, "ok", MUTED, font="s", xcont=True, cond="DIPOK")
    p.text(0, 0, "--", MUTED, font="s", xcont=True, cond="!DIPOK")
    p.text(0, 0, " PD ", MUTED, font="s", xcont=True)
    p.num(0, 0, "PD_N", "dec", MUTED, font="s", xcont=True)
    p.text(0, 0, "/3 COM ", MUTED, font="s", xcont=True)
    p.text(0, 0, "ok", MUTED, font="s", xcont=True, cond="COMOK")
    p.text(0, 0, "--", MUTED, font="s", xcont=True, cond="!COMOK")
    with p.when("WCURSOR"):
        p.ofs(fx="WCUR_X", fy="WCUR_Y")
        p.circ(0, 0, 8, GOLD, ri=6)
        p.ofs()
    # footer line
    with p.when("DONE"):
        p.text(U(14), U(505), "Decoder verified. Leave through the exit door.", C((150, 255, 170)), font="s")
    with p.when("!DONE"):
        with p.when("WCURSOR"):
            colr = GOLD
            p.textt(U(14), U(505), "S2_SINK", "WCUR", GOLD, font="s", cond="WPICK")
            p.text(0, 0, "  <-  ", GOLD, font="s", xcont=True, cond="WPICK")
            p.textt(0, 0, "S2_SRC", "WSRC", GOLD, font="s", xcont=True, cond="WPICK")
            p.textt(U(14), U(505), "S2_SINK", "WCUR", MUTED, font="s", cond="!WPICK")
            p.text(0, 0, "  =  ", MUTED, font="s", xcont=True, cond="!WPICK")
            p.textt(0, 0, "S2_SRC", "WSRC", MUTED, font="s", xcont=True, cond="!WPICK")
        p.text(U(14), U(505), "Press BTNC to remove every wire", MUTED, font="s", cond="WCLEAR")


def draw_closeup(p, T):
    with p.when("CLOSEUP"):
        with p.when("!BOARD"):
            frame_top(p)
            with p.when("CU_WB"):
                cu_whiteboard(p, T)
                frame_bottom(p, [("!PAGE2", "BTNC: next page"), ("PAGE2", "BTNC: first page")])
            with p.when("CU_DOOR"):
                cu_door(p)
                frame_bottom(p, [("DONE", "BTNC: leave the lab"), ("!DONE", "BTNC: try the handle")])
            with p.when("CU_BENCH"):
                cu_bench(p, T)
                frame_bottom(p, [(None, "BTNC: power on / open the breadboard")])
        with p.when("BOARD"):
            draw_board(p)


# ---------------------------------------------------------------------------- overlays
def hint_text(p, prefix_field, x, y, col, font, lh, wrap, txt_cond, seg_cond, wire_cond):
    """one hint (descriptor fields <prefix>_T/A/B/C): text, segment rule or 'wire X to Y'"""
    A, B, Cc = prefix_field + "A", prefix_field + "B", prefix_field + "C"
    p.textt(x, y, "S2_PTEXT", A, col, font=font, lh=lh, wrap=wrap, cond=txt_cond)
    with p.when(seg_cond):
        p.text(x, y, "Segment ", col, font=font)
        p.textt(0, 0, "S2_SEGN", A, col, font=font, xcont=True)
        p.text(0, 0, " must be ", col, font=font, xcont=True)
        p.textt(0, 0, "S2_ONOFF0", B, col, font=font, xcont=True)
        p.text(x, lh - (16 if font == "m" else 12), "for input ", col, font=font, ycont=True)
        p.num(0, 0, Cc, "bin", col, width=3, font=font, xcont=True)
        p.text(0, 0, " and ", col, font=font, xcont=True)
        p.textt(0, 0, "S2_ONOFF1", B, col, font=font, xcont=True)
        p.text(x, lh - (16 if font == "m" else 12), "for input ", col, font=font, ycont=True)
        p.textt(0, 0, "S2_BIN3HI", Cc, col, font=font, xcont=True)
        p.text(0, 0, ".", col, font=font, xcont=True)
    with p.when(wire_cond):
        p.text(x, y, "Try this next: wire the", col, font=font)
        p.textt(x, lh - (16 if font == "m" else 12), "S2_SINK", A, col, font=font, ycont=True)
        p.text(x, lh - (16 if font == "m" else 12), "to the ", col, font=font, ycont=True)
        p.textt(0, 0, "S2_SRC", B, col, font=font, xcont=True)
        p.text(0, 0, ".", col, font=font, xcont=True)


def draw_notebook(p, T):
    with p.when("NOTEBOOK"):
        draw_box(p, 60, 50, 520, 420)
        ctext(p, SX(320), U(62), "NOTEBOOK  (SW14 to close)", WHITE)
        p.text(SX(80), U(92), "Parts ", GOLD, font="s")
        p.num(0, 0, "PTOTAL", "dec", GOLD, font="s", xcont=True)
        p.text(0, 0, " / 18      QA tests passed: ", GOLD, font="s", xcont=True)
        p.num(0, 0, "QA_RND", "dec", GOLD, font="s", xcont=True)
        p.text(0, 0, " / 3", GOLD, font="s", xcont=True)
        for i, q in enumerate(T["part_qty"]):
            x, y = SX(80 + (i % 3) * 170), U(116 + (i // 3) * 18)
            for ok, colr in (("PARTOK%d" % i, C((150, 255, 170))), ("!PARTOK%d" % i, C((230, 230, 230)))):
                p.text(x, y, T["part_short"][i] + " ", colr, font="s", cond=ok)
                p.num(0, 0, "PCOUNT%d" % i, "dec", colr, font="s", xcont=True, cond=ok)
                p.text(0, 0, "/%d" % q, colr, font="s", xcont=True, cond=ok)
        p.text(SX(80), U(198), "Logged Actions & Clues:", FOOT, font="s")
        for k in range(8):
            p.textt(SX(80), U(218) + k * 12, "S2_NOTE", "NOTE%d" % k, C((230, 230, 230)), font="s",
                    cond="NOTE_V%d" % k)
        y = U(218) + 8 * 12 + 4
        p.text(SX(80), y, "Hints Used:", FOOT, font="s")
        for k in range(2):
            with p.when("HN%d_V" % k):
                hint_text(p, "HN%d_" % k, SX(80), y + 14 + k * 38, C((230, 230, 230)), "s", 12, 39,
                          "HN%d_TXT" % k, "HN%d_SEG" % k, "HN%d_WIRE" % k)


def draw_inventory(p):
    with p.when("INV"):
        draw_box(p, 90, 80, 460, 340)
        ctext(p, SX(320), U(94), "INVENTORY  (SW15 to close)", WHITE)
        names = ["Hint(wire)", "Hint(smart)", "Undo", "Freeze"]
        fields = ["INV_HH", "INV_HS", "INV_UN", "INV_FR"]
        for i in range(4):
            x0, y0, x1, y1 = SX(110 + i * 108), U(130), SX(210 + i * 108), U(220)
            cx = (x0 + x1) // 2
            p.rect(x0, y0, x1, y1, GOLD, cond="INVC%d" % i)
            p.rect(x0, y0, x1, y1, C((70, 74, 100)), cond="!INVC%d" % i)
            for c, colr in (("INVC%d" % i, C((20, 20, 20))), ("!INVC%d" % i, WHITE)):
                ctext(p, cx, y0 + 6, names[i], colr, font="s", cond=c)
                p.text(cx - 16, y0 + 28, "x", colr, font="l", cond=c)
                p.num(0, 0, fields[i], "dec", colr, font="l", xcont=True, cond=c)
        p.text(SX(110), U(240), "Parts ", C((150, 255, 170)), font="s")
        p.num(0, 0, "PTOTAL", "dec", C((150, 255, 170)), font="s", xcont=True)
        p.text(0, 0, " / 18  (see the notebook for details)", C((150, 255, 170)), font="s", xcont=True)
        p.text(SX(110), U(268), "Armor x", WHITE, font="s")
        p.num(0, 0, "ARMOR", "dec", WHITE, font="s", xcont=True)
        p.text(0, 0, "   (shields a failed QA penalty)", WHITE, font="s", xcont=True)
        p.text(SX(110), U(294), "Armor shards ", WHITE, font="s")
        p.num(0, 0, "SHARDS", "dec", WHITE, font="s", xcont=True)
        p.text(0, 0, " / 2   (2 shards = 1 armor)", WHITE, font="s", xcont=True)
        p.text(SX(110), U(320), "Speed Boost: yes   (used in Stage 3)", WHITE, font="s", cond="BOOST")
        p.text(SX(110), U(320), "Speed Boost: no   (used in Stage 3)", WHITE, font="s", cond="!BOOST")
        with p.when("SLOW_ON"):
            p.text(SX(110), U(346), "Slow: ", WHITE, font="s")
            p.num(0, 0, "SLOW_S", "dec", WHITE, font="s", xcont=True)
            p.text(0, 0, " s left", WHITE, font="s", xcont=True)
        p.text(SX(110), U(346), "Slow: off", WHITE, font="s", cond="!SLOW_ON")
        ctext(p, SX(320), U(386), "L/R select   BTNC use", FOOT, font="s")


def draw_hint_popup(p):
    with p.when("HINTP"):
        draw_box(p, 60, 150, 520, 220)
        p.textt(SX(320), U(162), "S2_PTITLEU", "HP_B", GOLD, center=True, cond="HP_TXT")
        ctext(p, SX(320), U(162), "HINT", GOLD, cond="!HP_TXT")
        hint_text(p, "HP_", SX(84), U(198), WHITE, "m", 16, 39, "HP_TXT", "HP_SEG", "HP_WIRE")
        ctext(p, SX(320), U(340), "BTNC: close", FOOT, font="s")


def draw_cards(p):
    with p.when("DECK"):
        p.rect(0, 0, 640, 360, 0, alpha=alpha16(205))
        p.text(SX(320) - 8 * 11, U(30), "PICK A CARD  (ROUND ", WHITE)
        p.num(0, 0, "CARD_ROUND", "dec", WHITE, xcont=True)
        p.text(0, 0, ")", WHITE, xcont=True)
        for pos in range(3):
            rx, ry = 65 + pos * 180, 95
            cx, cy = SX(rx + 85), U(ry + 85)
            p.spr(cx - 48, cy - 48, 0, field="CIMG%d" % pos, scale=3)
            with p.when("CF%d" % pos):
                with p.when("!CARD_R1"):
                    p.rect(cx - 48, cy + 48 - 24, cx + 48, cy + 48 - 5, 0, alpha=alpha16(180))
                    p.textt(cx, cy + 48 - 22, "S2_ITEM", "CNAME", GOLD, font="s", center=True)
            p.frame(cx - 52, cy - 52, cx + 52, cy + 52, WHITE, 3, cond="CARD_C%d" % pos)
        with p.when("CARD_FACEUP"):
            p.rect(SX(60), U(310), SX(580), U(400), C((30, 35, 45)))
            p.text(SX(320) - 8 * 8, U(322), "Obtained: ", GOLD)
            p.textt(0, 0, "S2_ITEM", "CNAME", GOLD, xcont=True)
            p.textt(SX(320), U(356), "S2_DESC", "CDESC", C((240, 240, 240)), font="s", center=True)
            ctext(p, SX(320), U(420), "BTNC: continue", FOOT)
        ctext(p, SX(320), U(360), "L/R choose   BTNC pick", FOOT, cond="!CARD_FACEUP")


def draw_talk(p):
    with p.when("TALK"):
        x0, y0, x1, y1 = U(40), U(400), U(920), U(520)
        p.rect(x0, y0, x1, y1, C((14, 18, 28)))
        p.frame(x0, y0, x1, y1, GOLD, 1)
        p.text(U(62), U(410), "Boss", GOLD)
        X, Y = U(62), U(440)
        p.textt(X, Y, "S2_TALK", "TLINE", WHITE, lh=16, wrap=68, cond="TL_STATIC")
        with p.when("TL_ASK2"):
            p.text(X, Y, "QA test ", WHITE)
            p.num(0, 0, "TL_A", "dec", WHITE, xcont=True)
            p.text(0, 0, " of 3: I will check the two inputs of the work order.", WHITE, xcont=True)
            p.text(X, Y + 16, "BTNC = test it     hold BTNC = not yet", WHITE)
        with p.when("TL_VIN"):
            p.text(X, Y, "Input ", WHITE)
            p.num(0, 0, "TL_A", "bin", WHITE, width=3, xcont=True)
            p.text(0, 0, " (must show ", WHITE, xcont=True)
            p.textt(0, 0, "S2_CHAR", "TL_B", WHITE, xcont=True)
            p.text(0, 0, "): correct!", WHITE, xcont=True, cond="TL_VOK")
            p.text(0, 0, "): WRONG.", WHITE, xcont=True, cond="!TL_VOK")
        with p.when("TL_PASSMID"):
            p.text(X, Y, "Test ", WHITE)
            p.num(0, 0, "TL_A", "dec", WHITE, xcont=True)
            p.text(0, 0, " of 3 passed! That covered ", WHITE, xcont=True)
            p.textt(0, 0, "S2_CHAR", "TL_B", WHITE, xcont=True)
            p.text(0, 0, " and ", WHITE, xcont=True)
            p.textt(0, 0, "S2_CHAR", "TL_C", WHITE, xcont=True)
            p.text(0, 0, ".", WHITE, xcont=True)
            p.text(X, Y + 16, "I still have to check the other characters: 2 more tests.", WHITE, cond="!QAPASS0")
            p.text(X, Y + 16, "I still have to check the other characters: 1 more test.", WHITE, cond="QAPASS0")
            p.text(X, Y + 32, "If your circuit is right, just come back and ask me again.", WHITE)
        p.text(U(904) - 6 * 10, U(498), "BTNC: next", FOOT, font="s", cond="!TALK_ASKLAST")
        p.text(U(904) - 6 * 32, U(498), "BTNC: yes     hold BTNC: not yet", FOOT, font="s", cond="TALK_ASKLAST")


def draw_status(p):
    p.rect(0, 0, 640, 360, C((255, 0, 0)), afield="FLASH_A", cond="FLASH_ON")
    with p.when("OVER"):
        p.rect(0, 0, 640, 360, 0, alpha=alpha16(220))
        ctext(p, 320, U(220) - 8, "OUT OF HEARTS", C((255, 90, 90)), font="l")
        ctext(p, 320, U(270), "Restarting Stage 2...", WHITE)
    with p.when("CLEAR"):
        ctext(p, 320, U(160) - 8, "STAGE 2 CLEAR", C((150, 255, 170)), font="l")
        ctext(p, 320, U(160) + 26, "INTERNSHIP COMPLETE!", C((150, 255, 170)), font="l")
        p.text(320 - 14 * 4, U(220) + 16, "Hearts left: ", WHITE)
        p.num(0, 0, "HEARTS", "dec", WHITE, xcont=True)
        ctext(p, 320, U(270) + 16, "CHARACTER EVOLVED -> Graduation gown", GOLD)
        ctext(p, 320, U(370), "BTNC: play again", FOOT, font="s")


def draw_toast(p):
    with p.when("TOAST_ON"):
        p.textt(320, U(44) + 5, "S2_TOAST", "TOAST", WHITE, center=True, box=True, cond="!TOAST_RECH")
        with p.when("TOAST_RECH"):
            p.rect(320 - 120, U(44), 320 + 120, U(44) + 23, 0)
            p.text(320 - 8 * 14, U(44) + 5, "Skill recharging: ", WHITE)
            p.num(0, 0, "TOAST_A", "dec", WHITE, xcont=True)
            p.text(0, 0, " s left", WHITE, xcont=True)


def draw_help(p):
    with p.when("HELP"):
        p.rect(0, 0, 640, 360, 0, alpha=alpha16(215))
        draw_box(p, 30, 50, 580, 440)
        ctext(p, SX(320), U(64), "STAGE 2: INTERNSHIP - HOW TO PLAY", WHITE)
        rows = [("Move", "BTNU BTND BTNL BTNR (hold)"), ("Interact / confirm", "BTNC (tap)"),
                ("Search / read a hint", "BTNC next to a suspicious spot"), ("Back / cancel", "hold BTNC 0.8 s"),
                ("Test input C B A", "SW2 SW1 SW0"), ("Inventory / Notebook", "SW15 / SW14"),
                ("Workshop-shirt skill", "SW13 (after 2 min)")]
        for i, (a, b) in enumerate(rows):
            p.text(SX(54), U(114 + i * 29), a, GOLD, font="s")
            p.text(SX(262), U(114 + i * 29), b, WHITE, font="s")
        p.text(SX(54), U(330), Program.wrap(
            "Find all 18 lab parts hidden around the office (read the hints on notes and screens), install them on "
            "the decoder bench, wire the 7-segment decoder on the breadboard, show it to the Boss for 3 QA tests, "
            "then leave by the exit door. A failed QA test costs 1 heart.", 62), FOOT, font="s", lh=13)
        ctext(p, SX(320), U(456), "Press BTNC to start", C((150, 255, 170)))


def build(p, T, spots):
    p.stage(2)
    with p.when("IS_S2"):
        draw_world(p, spots)
        with p.when("!CLEAR"):
            draw_closeup(p, T)
            draw_hud(p)
            draw_skill_btn(p)
            draw_notebook(p, T)
            draw_inventory(p)
            draw_hint_popup(p)
            draw_cards(p)
            draw_talk(p)
        draw_status(p)
        draw_toast(p)
        draw_help(p)
    p.stage(1)
