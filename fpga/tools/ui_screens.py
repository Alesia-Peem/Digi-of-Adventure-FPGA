"""ui_screens.py - every Stage 1 screen of stage1_demo.py, written for the UI engine.

Coordinates are given in the SAME numbers as the Pygame source (960 x 540 UI surface; close-up
panels in the 640-wide subsurface `s` at x = 160) and converted here by x 2/3 to the 640 x 360
FPGA game area, so each line below can be checked against the matching Pygame draw call.

Fonts: Pygame f_m / f_l / mono_l -> 8x16 ("m"),  f_s / f_tiny / mono -> 6x12 ("s"),
       big titles of full-screen overlays (f_l) -> 16x32 ("l").
"""
from ui_compile import Program, col12, alpha16
import ui_spec


def U(v):                      # UI surface -> game area
    return int(round(v * 2 / 3))


def SX(x):                     # close-up subsurface x -> game area
    return int(round((160 + x) * 2 / 3))


C = col12
WHITE = C((255, 255, 255))
GOLD = C((255, 230, 120))
FOOT = C((170, 200, 255))
CMSG = C((255, 225, 120))


def ctext(p, cx, y, s, col, font="m", cond=None):
    p.text(cx, y, s, col, font=font, center=True, cond=cond)


# ---------------------------------------------------------------------------------------- world + HUD
def draw_world(p):
    with p.when("MAP"):
        # player sprite anchored bottom-centre on the feet (PSX, PSY), 32x32 art drawn 2x
        p.ofs(fx="PSX", fy="PSY", x0=-32, y0=-64)
        p.spr(0, 0, 0, field="PFRAME", scale=2)
        p.ofs()
        # lights off: dark blue overlay, alpha 150 (world + player only)
        p.rect(0, 0, 640, 360, C((0, 0, 25 * 255 // 150)), alpha=alpha16(150), cond="!LIGHTS")
        with p.when("DEBUG"):     # F6 / demo hub "Collision debug": blockers + feet box + anchors
            XS, YS = 400, 300       # constant shift so room coordinates fit the signed 11/10-bit fields
            p.ofs(fx="CAMXN", fy="CAMYN", x0=XS, y0=YS)
            for (bx, by, bw, bh) in [(620, 300, 200, 70), (815, 250, 140, 120), (450, 440, 125, 120),
                                     (100, 880, 200, 125), (660, 420, 650, 120), (520, 615, 850, 150),
                                     (380, 860, 1080, 170), (1490, 525, 225, 250)]:
                k = 0.64
                p.frame(int(bx * k) - XS, int(by * k) - YS, int((bx + bw) * k) - XS, int((by + bh) * k) - YS,
                        C((255, 0, 0)), 1)
            for (ax, ay) in [(300, 580), (700, 400), (1370, 920), (570, 690), (1560, 400), (1540, 620),
                             (1150, 310), (1340, 300)]:
                p.circ(int(ax * 0.64) - XS, int(ay * 0.64) - YS, 3, C((255, 255, 0)))
            p.ofs(fx="PSX", fy="PSY")
            p.frame(-12, -17, 12, -3, C((0, 255, 0)), 1)
            p.ofs()


def draw_hud(p):
    for i in range(3):
        p.circ(U(24 + i * 26), U(22), 7, C((230, 50, 60)), cond="HEART%d" % (i + 1))
        p.circ(U(24 + i * 26), U(22), 7, C((80, 50, 50)), cond="!HEART%d" % (i + 1))
    with p.when("ARMOR_ON"):
        p.rect(U(96), U(12), U(96 + 18), U(12 + 22), C((80, 180, 255)))
        p.text(U(118), U(14), "x", C((120, 200, 255)), font="s")
        p.num(0, 0, "ARMOR", "dec", C((120, 200, 255)), font="s", xcont=True)
    with p.when("SLOW_ON"):
        p.text(U(180), U(14), "SLOW ", C((255, 150, 80)))
        p.num(0, 0, "SLOW_S", "dec", C((255, 150, 80)), xcont=True)
        p.text(0, 0, "s", C((255, 150, 80)), xcont=True)
    with p.when("FREEZE_ON"):
        p.text(U(290), U(14), "FREEZE ", C((140, 220, 255)))
        p.num(0, 0, "FREEZE_S", "dec", C((140, 220, 255)), xcont=True)
        p.text(0, 0, "s", C((140, 220, 255)), xcont=True)


# ---------------------------------------------------------------------------------------- close-ups
def closeup_frame_top(p):
    p.rect(SX(0), 0, SX(640), U(44), C((70, 74, 90)))
    p.textt(SX(16), U(10), "OBJ", "OBJ", WHITE)


def closeup_frame_bottom(p, foot):
    """cmsg lines, footer bar, footer text (foot = list of (cond, text))"""
    with p.when("CMSG_ON"):
        p.textt(SX(16), U(440), "CMSG", "CMSG", CMSG)
        with p.when("CMSG_TN"):
            p.num(0, 0, "CMSG_P", "dec", CMSG, xcont=True)
            p.textt(0, 0, "CMSG_SUFFIX", "CMSG", CMSG, xcont=True)
    p.rect(SX(0), U(494), SX(640), 360, C((40, 44, 60)))
    for cond, t in foot:
        p.text(SX(16), U(497), t, FOOT, font="s", cond=cond)
    p.text(SX(16), U(518), "Back: hold BTNC (0.8 s)", C((140, 150, 180)), font="s")


def cu_whiteboard(p):
    ink = C((30, 40, 130))
    p.rect(SX(40), U(56), SX(600), U(432), C((240, 240, 235)))
    with p.when("PAGE0"):
        for i, l in enumerate(["ROOM 402 - FINAL EXAM", "attendance sheet", "", "registered ........ 0x2A",
                               "absent ............ 0b10011", "sick leave ........ 0o21", "",
                               "sitting the exam = ?"]):
            if l:
                p.text(SX(70), U(78 + i * 38), l, ink)
    with p.when("PAGE1"):
        for i, l in enumerate(["margin notes:", "weights   128 64 32 16 8 4 2 1",
                               "hex  A=10 B=11 C=12 D=13 E=14 F=15", "octal: digits are 8s and 1s"]):
            p.text(SX(70), U(70 + i * 26), l, ink, font="s")
        p.rect(SX(70), U(190), SX(570), U(414), C((60, 60, 70)))
        p.text(SX(90), U(202), "HEAD-COUNT DIAL  (switches SW3..SW0)", WHITE, font="s")
        for k in range(4):
            i = 3 - k
            cx = SX(150 + k * 90)
            p.circ(cx, U(280), 17, C((255, 220, 60)), cond="SW%d" % i)
            p.circ(cx, U(280), 17, C((90, 90, 90)), cond="!SW%d" % i)
            ctext(p, cx, U(316), str(8 >> k), WHITE)
        p.text(SX(470), U(262), "= ", WHITE, font="l")
        p.num(0, 0, "P1VAL", "dec", WHITE, font="l", xcont=True)
        with p.when("DONE1"):
            p.text(SX(90), U(366), "LOGGED: A = ", GOLD)
            p.num(0, 0, "ANS_A", "dec", GOLD, xcont=True)


def draw_kmap(p, x, y, cell, ink):
    """draw_kmap() of the demo; x, y, cell in subsurface units"""
    gray = [0, 1, 3, 2]
    truth = 0xF888
    p.text(SX(x), U(y + 4), "AB\\CD", ink, font="s")
    for c in range(4):
        p.text(SX(x + cell * (c + 1) + cell // 3), U(y + 4), "%d%d" % (gray[c] >> 1, gray[c] & 1), ink, font="s")
    for r in range(4):
        p.text(SX(x + 6), U(y + cell * (r + 1) + cell // 3), "%d%d" % (gray[r] >> 1, gray[r] & 1), ink, font="s")
    # grid: the 1-px outlines of 16 adjacent cells = 5 + 5 lines
    x0, y0 = SX(x + cell), U(y + cell)
    x1, y1 = SX(x + cell * 5), U(y + cell * 5)
    for k in range(5):
        xx = SX(x + cell * (k + 1))
        yy = U(y + cell * (k + 1))
        p.rect(min(xx, x1 - 1), y0, min(xx, x1 - 1) + 1, y1, ink)
        p.rect(x0, min(yy, y1 - 1), x1, min(yy, y1 - 1) + 1, ink)
    for r in range(4):
        for c in range(4):
            m = (gray[r] << 2) | gray[c]
            cx = SX(x + cell * (c + 1) + cell // 2)
            ctext(p, cx, U(y + cell * (r + 1) + cell // 3) - 1, str((truth >> m) & 1), ink)


def cu_paper(p):
    ink = C((40, 40, 40))
    p.rect(SX(40), U(56), SX(600), U(422), C((245, 240, 220)))
    with p.when("PAGE0"):
        p.text(SX(70), U(68), "SENSOR FAIL LOG   (1 = failed)", ink)
        p.text(SX(70), U(94), "rows: A B      columns: C D", ink, font="s")
        draw_kmap(p, 70, 122, 52, ink)
        p.text(SX(400), U(230), "F =", ink, font="l")
        # coffee stain over the answer: ellipse 150 x 110, (110,70,30) alpha 170
        p.circ(SX(450 + 75), U(190 + 55), 31, C((110, 70, 30)), alpha=alpha16(170))
    with p.when("PAGE1"):
        draw_kmap(p, 56, 70, 44, ink)
        for i in range(3):
            y = 90 + i * 46
            p.rect(SX(310), U(y - 6), SX(580), U(y + 32), GOLD, cond="P2C%d" % i)
            p.text(SX(324), U(y), "T%d:  " % (i + 1), ink)
            p.num(0, 0, "P2_T%d" % (i + 1), "term", ink, width=1, xcont=True)
        p.text(SX(310), U(250), "switches say:  ", C((30, 80, 160)))
        p.num(0, 0, "P2_SW", "term", C((30, 80, 160)), width=2, xcont=True)
        p.text(SX(310), U(290), "SW7-4: which letters (A B C D)", ink, font="s")
        p.text(SX(310), U(312), "SW3-0: 1 = plain, 0 = inverted", ink, font="s")
        with p.when("DONE2"):
            p.text(SX(70), U(380), "LOGGED: F = ", C((30, 80, 160)))
            p.num(0, 0, "P2_EQN", "eqn", C((30, 80, 160)), xcont=True)


def cu_nand(p):
    g = C((110, 255, 130))
    hl = C((255, 255, 120))
    p.rect(SX(40), U(60), SX(600), U(420), C((10, 20, 10)))
    with p.when("PAGE0"):
        for i, l in enumerate(["SYSTEM TERMINAL - LAB 01", "", "Status: Spec match required",
                               "Task: Build F from puzzle 2 as a", "      minimal combinational circuit",
                               "Constraint: 74HC00 quad NAND gates only."]):
            if l:
                p.text(SX(56), U(76 + i * 34), l, g, font="s")
    with p.when("PAGE1"):
        for k in range(4):
            y = 74 + k * 44
            for j in range(2):
                f = 2 * k + j
                x = SX(64 + j * 260)
                for on, colr in (("P3F%d" % f, hl), ("!P3F%d" % f, g)):
                    p.text(x, U(y), ("> " if on[0] != "!" else "  ") + "G%d in%d: " % (k + 1, j + 1), colr,
                           font="s", cond=on)
                    p.textt(0, 0, "SRC", "P3_%d" % f, colr, font="s", xcont=True, cond=on)
        for on, colr in (("P3F8", hl), ("!P3F8", g)):
            p.text(SX(64), U(256), ("> " if on[0] != "!" else "  ") + "F = output of: G", colr, font="s", cond=on)
            p.num(0, 0, "P3_OUTN", "dec", colr, font="s", xcont=True, cond=on)
        p.text(SX(64), U(320), "your F:   ", g, font="s")
        p.num(0, 0, "P3_TAB", "bits16", g, font="s", xcont=True)


def cu_twos(p):
    g = C((130, 200, 255))
    p.rect(SX(40), U(60), SX(600), U(420), C((10, 10, 25)))
    with p.when("PAGE0"):
        for i, l in enumerate(["SYSTEM KERNEL CONSOLE", "", "Target register: penalty_reg",
                               "Current decimal value: 12", "Operation: Invert sign using two's complement", "",
                               "READY FOR PATCH INPUT..."]):
            if l:
                p.text(SX(56), U(76 + i * 34), l, g, font="s")
    with p.when("PAGE1"):
        p.text(SX(70), U(90), "penalty_reg patch value:", g)
        p.num(SX(70), U(130), "P4VAL", "bin", C((255, 255, 120)), width=8, font="l")
        p.text(SX(70), U(180), "unsigned ", g)
        p.num(0, 0, "P4VAL", "dec", g, xcont=True)
        p.text(0, 0, "    signed ", g, xcont=True)
        p.num(0, 0, "P4VAL", "sdec8", g, xcont=True)


def cu_screen(p):
    with p.when("LIGHTS"):
        p.rect(SX(40), U(60), SX(600), U(420), C((235, 235, 230)))
        ctext(p, SX(320), U(230), "No Signal", C((150, 150, 145)), font="s")
    with p.when("!LIGHTS"):
        p.rect(SX(40), U(60), SX(600), U(420), C((15, 20, 30)))
        ctext(p, SX(320), U(62), "PROJECTOR SLIDE: APP LOGO MASTERMIND", C((130, 200, 255)), font="s")
        p.rect(SX(50), U(88), SX(530), U(118), C((40, 50, 70)))
        p.text(SX(60), U(96), "App Sequence (3 Logos)", GOLD, font="s")
        p.text(SX(325), U(96), "Correct Apps", GOLD, font="s")
        p.text(SX(445), U(96), "Correct Pos", GOLD, font="s")
        # clue 2 fixed (Correct Pos 1 -> 0): now C-P-E is the ONLY solution (checked in tb + docs)
        rows = [("Facebook, Explorer, Canva", "2", "0"), ("Facebook, Canva, X", "1", "0"),
                ("Canva, AppStore, Pinterest", "2", "1"), ("Pinterest, AppStore, Facebook", "1", "0"),
                ("AppStore, Explorer, Facebook", "1", "0")]
        for idx, (seq, ca, cp) in enumerate(rows):
            y = 122 + idx * 35
            p.rect(SX(50), U(y), SX(530), U(y + 33), C((25, 32, 45)) if idx % 2 == 0 else C((20, 26, 38)))
            p.text(SX(60), U(y + 9), seq, C((240, 240, 240)), font="s")
            ctext(p, SX(365), U(y + 9), ca, C((150, 255, 150)), font="s")
            ctext(p, SX(485), U(y + 9), cp, C((255, 220, 100)), font="s")
        ctext(p, SX(320), U(316), "Deduce the secret 3-app code from clues.", C((180, 220, 180)), font="s")


def cu_lightsw(p):
    p.rect(SX(260), U(110), SX(380), U(310), C((200, 200, 200)))
    p.rect(SX(290), U(130), SX(350), U(200), C((90, 200, 90)), cond="LIGHTS")
    p.rect(SX(290), U(220), SX(350), U(290), C((200, 80, 80)), cond="!LIGHTS")
    ctext(p, SX(320), U(340), "LIGHTS ON", WHITE, cond="LIGHTS")
    ctext(p, SX(320), U(340), "LIGHTS OFF", WHITE, cond="!LIGHTS")


def cu_door(p):
    p.rect(SX(240), U(56), SX(400), U(286), C((120, 85, 55)))
    ctext(p, SX(320), U(298), "LOCK 1 of 2  (2 digits)", WHITE, cond="!DOOR_L2")
    ctext(p, SX(320), U(298), "LOCK 2 of 2  (5 digits)", WHITE, cond="DOOR_L2")
    for n, cond in ((2, "!DOOR_L2"), (5, "DOOR_L2")):
        with p.when(cond):
            x0 = 320 - n * 70 // 2
            for i in range(n):
                rx = x0 + i * 70 + 5
                p.rect(SX(rx), U(332), SX(rx + 60), U(396), GOLD, cond="DOOR_C%d" % i)
                p.rect(SX(rx), U(332), SX(rx + 60), U(396), C((200, 200, 200)), cond="!DOOR_C%d" % i)
                p.num(SX(rx + 30) - 8, U(332 + 14), "DOOR_D%d" % i, "dec", C((20, 20, 20)), font="l")


def cu_pc(p):
    c = C((160, 200, 255))
    p.rect(SX(40), U(60), SX(600), U(420), C((15, 25, 50)))
    with p.when("!DONE5"):
        p.text(SX(70), U(75), "PROFESSOR TERMINAL LOGIN", c)
        p.text(SX(70), U(115), "Enter 3-letter passcode (A-Z):", c, font="s")
        for i in range(3):
            rx = 180 + i * 90
            p.rect(SX(rx), U(150), SX(rx + 70), U(220), GOLD, cond="P5C%d" % i)
            p.rect(SX(rx), U(150), SX(rx + 70), U(220), C((60, 75, 110)), cond="!P5C%d" % i)
            p.num(SX(rx + 35), U(150 + 18) - 2, "P5_L%d" % i, "letter", WHITE, font="l", center=True)
        p.text(SX(70), U(250), "Match projector table clues to unlock terminal", C((180, 220, 180)), font="s")
    with p.when("DONE5"):
        with p.when("PAGE0"):
            p.text(SX(70), U(90), "Welcome, prof.", c)
            p.text(SX(70), U(150), "[ door_manual.txt ]", GOLD)
        pages = {
            "PAGE1": ["DOOR - LAYER 1  (2 digits)", "1. Take the LAST letter of your login password.",
                      "2. Find it in the table (values are HEX).", "3. Key in its DECIMAL value.", "",
                      "A 41  B 42  C 43  D 44  E 45  F 46  G 47", "H 48  I 49  J 4A  K 4B  L 4C  M 4D  N 4E",
                      "O 4F  P 50  Q 51  R 52  S 53  T 54  U 55", "V 56  W 57  X 58  Y 59  Z 5A"],
            "PAGE2": ["DOOR - LAYER 2  (5 digits)", "A = whiteboard dial result",
                      "B = report code from cabinet + laptop 1", "C = receipt code from laptop 2",
                      "Step 1: S = A + B + C.  Row: A B C S", "        (S has two digits -> 5 digits)",
                      "Step 2: new digit 1 = old position 4,", "        then old 2, 5, 1, 3.",
                      "Example: row 2 4 6 8 9 -> 8 4 9 2 6"],
        }
        for cond, lines in pages.items():
            with p.when(cond):
                for i, l in enumerate(lines):
                    if l:
                        p.text(SX(56), U(74 + i * 33), l, c, font="s")


def draw_closeup(p):
    with p.when("CLOSEUP"):
        closeup_frame_top(p)
        feet = []
        for kind, fn, foot in [
            ("CU_WB", cu_whiteboard, [("PAGE0", "BTNC: next page"), ("PAGE1", "ANSWER: set SW3-SW0, then BTNC")]),
            ("CU_PAPER", cu_paper, [("PAGE0", "BTNC: next page"),
                                    ("PAGE1", "L/R slot | BTNC store | BTND clear | BTNU confirm answer")]),
            ("CU_NAND", cu_nand, [("PAGE0", "BTNC: open circuit editor"),
                                  ("PAGE1", "L/R field | U/D change source | BTNC save circuit")]),
            ("CU_TWOS", cu_twos, [("PAGE0", "BTNC: open patch console"), ("PAGE1", "ANSWER: set SW7-SW0, then BTNC")]),
            ("CU_SCREEN", cu_screen, [("!LIGHTS", "Turn off room lights to view clearly")]),
            ("CU_LIGHTSW", cu_lightsw, [(None, "BTNC: flip the switch")]),
            ("CU_DOOR", cu_door, [(None, "U/D digit | L/R box | BTNC confirm")]),
            ("CU_PC", cu_pc, [("!DONE5", "U/D box | L/R letter (A-Z) | BTNC enter"),
                              ("DONE5", "U/D or BTNC: open file / change page")]),
        ]:
            with p.when(kind):
                fn(p)
                closeup_frame_bottom(p, foot)


# ---------------------------------------------------------------------------------------- overlays
def draw_box(p, x, y, w, h):
    p.rect(SX(x), U(y), SX(x + w), U(y + h), C((20, 22, 30)))
    p.frame(SX(x), U(y), SX(x + w), U(y + h), C((120, 130, 170)), 1)


def draw_notebook(p):
    with p.when("NOTEBOOK"):
        draw_box(p, 60, 50, 520, 420)
        ctext(p, SX(320), U(62), "NOTEBOOK  (SW14 to close)", WHITE)
        y = U(100)
        p.text(SX(80), y, "Answers Logged: A = ", GOLD, font="s")
        p.num(0, 0, "ANS_A", "dec", GOLD, font="s", xcont=True, cond="ANSA_V")
        p.text(0, 0, "?", GOLD, font="s", xcont=True, cond="!ANSA_V")
        p.text(0, 0, "   B = ", GOLD, font="s", xcont=True)
        p.num(0, 0, "ANS_B", "dec", GOLD, font="s", xcont=True, cond="ANSB_V")
        p.text(0, 0, "?", GOLD, font="s", xcont=True, cond="!ANSB_V")
        p.text(0, 0, "   C = ", GOLD, font="s", xcont=True)
        p.num(0, 0, "ANS_C", "dec", GOLD, font="s", xcont=True, cond="ANSC_V")
        p.text(0, 0, "?", GOLD, font="s", xcont=True, cond="!ANSC_V")
        p.text(SX(80), U(140), "Logged Actions & Clues:", FOOT, font="s")
        for k in range(8):                      # notes[-8:], one line each (13 px)
            y = U(140) + 15 + k * 13
            with p.when("NOTE_V%d" % k):
                p.textt(SX(80), y, "NOTE", "NOTE_T%d" % k, C((230, 230, 230)), font="s")
                p.num(0, 0, "NOTE_V%d" % k, "dec", C((230, 230, 230)), font="s", xcont=True, cond="NOTE_D%d" % k)
                p.num(0, 0, "NOTE_V%d" % k, "eqn", C((230, 230, 230)), font="s", xcont=True, cond="NOTE_E%d" % k)
                p.num(0, 0, "NOTE_V%d" % k, "let3", C((230, 230, 230)), font="s", xcont=True, cond="NOTE_L%d" % k)
        hy = U(140) + 15 + 8 * 13 + 6
        p.text(SX(80), hy, "Hints Used:", FOOT, font="s")
        p.ofs()
        # the last 3 hints, each wrapped at 52 chars (480 px of the demo), flowing downwards
        p.text(SX(80), hy, "", WHITE, font="s")           # sets the "next line" position
        for k in range(3):
            with p.when("HINT_V%d" % k):
                p.text(SX(80), 2, "- ", C((230, 230, 230)), font="s", ycont=True, lh=13)
                p.textt(0, 0, "HINT", "HINT%d" % k, C((230, 230, 230)), font="s", xcont=True, lh=13, wrap=50)


def draw_cards(p):
    with p.when("DECK"):
        p.rect(0, 0, 640, 360, 0, alpha=alpha16(205))
        ctext(p, SX(320), U(30), "PICK A CARD", WHITE, font="l")
        for pos in range(3):
            rx, ry = 65 + pos * 180, 95                  # slot 170 x 170 (stage1 card_assets size)
            cx, cy = SX(rx + 85), U(ry + 85)
            # 32x32 art drawn 3x = 96 px, centred in the 113 px slot
            p.spr(cx - 48, cy - 48, 0, field="CIMG%d" % pos, scale=3)
            # revealed card of round 2/3: name on a dark strip (alpha 180) at the bottom of the slot
            # (the Pygame slot is filled by the art; here the frame and the name strip follow the 96 px art)
            with p.when("CF%d" % pos):
                with p.when("!CARD_R1"):
                    p.rect(cx - 48, cy + 48 - 24, cx + 48, cy + 48 - 5, 0, alpha=alpha16(180))
                    p.textt(cx, cy + 48 - 22, "ITEM", "CNAME", GOLD, font="s", center=True)
            p.frame(cx - 52, cy - 52, cx + 52, cy + 52, WHITE, 3, cond="CARD_C%d" % pos)
        with p.when("CARD_FACEUP"):
            p.rect(SX(60), U(300), SX(580), U(410), C((30, 35, 45)))
            p.textt(SX(320), U(308), "OBTAINED", "CNAME", GOLD, center=True)
            p.textt(SX(320), U(340), "DESC", "CDESC", C((240, 240, 240)), font="s", center=True, lh=13, wrap=54)
            ctext(p, SX(320), U(424), "BTNC: continue", FOOT)
        ctext(p, SX(320), U(360), "L/R choose   BTNC pick", FOOT, cond="!CARD_FACEUP")


def draw_status(p):
    # flash: red overlay, alpha = 180 * flash / 0.4
    p.rect(0, 0, 640, 360, C((255, 0, 0)), afield="FLASH_A", cond="FLASH_ON")
    with p.when("OVER"):
        p.rect(0, 0, 640, 360, 0, alpha=alpha16(220))
        ctext(p, 320, U(220) - 8, "OUT OF HEARTS", C((255, 90, 90)), font="l")
        ctext(p, 320, U(270), "Restarting Stage 1...", WHITE)
    with p.when("CLEAR"):
        ctext(p, 320, U(160) - 8, "STAGE 1 CLEAR - YOU PASSED THE EXAM!", C((150, 255, 170)), font="l")
        p.text(320 - 14 * 8 // 2, U(220), "Hearts left: ", WHITE)
        p.num(0, 0, "HEARTS", "dec", WHITE, xcont=True)
        ctext(p, 320, U(270), "CHARACTER EVOLVED -> Lab coat", GOLD)
        ctext(p, 320, U(370), "BTNC: play again", FOOT, font="s", cond="STANDALONE")
        ctext(p, 320, U(370), "BTNC: continue to the next stage", FOOT, font="s", cond="!STANDALONE")


def draw_toast(p):
    with p.when("TOAST_ON"):
        # black box sized to the text: centred text, box drawn from the widest message (24 chars)
        p.rect(320 - 110, U(14), 320 + 110, U(14 + 34), 0)
        p.textt(320, U(14) + 3, "TOAST", "TOAST", WHITE, center=True)


def draw_help(p):
    with p.when("HELP"):
        p.rect(0, 0, 640, 360, 0, alpha=alpha16(215))
        draw_box(p, 30, 60, 580, 420)
        ctext(p, SX(320), U(74), "HOW TO PLAY", WHITE, font="l")
        rows = [("Move", "BTNU BTND BTNL BTNR (hold)"), ("Interact / confirm", "BTNC (tap)"),
                ("Back", "hold BTNC 0.8 s"), ("Switches", "SW0-SW7 = puzzle inputs"),
                ("Notebook", "SW14"), ("Hearts / puzzles", "LED0-2 / LED4-8, 7-seg 'H3'"),
                ("Demo tools", "SW12 on: demo menu (see docs)")]
        for i, (a, b) in enumerate(rows):
            p.text(SX(54), U(128 + i * 30), a, GOLD, font="s")
            p.text(SX(232), U(128 + i * 30), b, WHITE, font="s")
        p.text(SX(54), U(360), Program.wrap("Walk up to anything and press BTNC. If nothing happens, it is "
                                            "just scenery.", 44), FOOT, lh=17)
        ctext(p, SX(320), U(442), "Press BTNC to start", C((150, 255, 170)))


def build_program():
    p = Program()
    with p.when("IS_S1"):                         # ---- Stage 1 (Final Exam)
        draw_world(p)
        with p.when("!CLEAR"):
            draw_closeup(p)
            draw_hud(p)
            draw_notebook(p)
            draw_cards(p)
        draw_status(p)
        draw_toast(p)
        draw_help(p)
    import ui_screens_s2                          # ---- Stage 2 (Internship)
    T = ui_spec._T
    ui_screens_s2.build(p, T, [tuple(xy) for xy in T["spot_xy"]])
    import ui_screens_s3                          # ---- Stage 3 (Graduation obby)
    ui_screens_s3.build(p)
    p.end()
    return p


# ---------------------------------------------------------------------------------------- previews
def preview_states():
    """A few hand-made game states to look at the screens without hardware (ui_compile --preview)."""
    F, Cn = ui_spec.FIELD, ui_spec.COND

    def st(fields=None, conds=(), bg=(1, 0x112, 0, (420, 0))):
        f = {F[k]: v for k, v in (fields or {}).items()}
        c = {Cn[k]: 1 for k in conds}
        c[Cn["IS_S1"]] = 1
        return f, c, bg

    base = dict(HEARTS=3, PSX=280, PSY=280, PFRAME=0)
    hearts = ["HEART1", "HEART2", "HEART3", "LIGHTS", "PLAY", "STAGE1"]
    cu = (0, 0x112, 0, (0, 0))
    return {
        "help": st(base, hearts + ["MAP", "HELP"]),
        "map": st(dict(base, ARMOR=1, SLOW_S=8), hearts + ["MAP", "ARMOR_ON", "SLOW_ON"]),
        "map_dark": st(base, ["HEART1", "HEART2", "MAP", "PLAY"]),
        "wb_p0": st(dict(base, OBJ=0), hearts + ["CLOSEUP", "CU_WB", "PAGE0"], cu),
        "wb_p1": st(dict(base, OBJ=0, P1VAL=6, ANS_A=6, PAGE=1, CMSG=1),
                    hearts + ["CLOSEUP", "CU_WB", "PAGE1", "SW1", "SW2", "DONE1", "CMSG_ON"], cu),
        "paper_p0": st(dict(base, OBJ=1), hearts + ["CLOSEUP", "CU_PAPER", "PAGE0"], cu),
        "paper_p1": st(dict(base, OBJ=1, P2_T1=0xCC, P2_T2=0x33, P2_SW=0x90, P2_EQN=0x33CC, CMSG=2, CMSG_P=2),
                       hearts + ["CLOSEUP", "CU_PAPER", "PAGE1", "P2C1", "DONE2", "CMSG_ON", "CMSG_TN"], cu),
        "nand_p1": st(dict(base, OBJ=2, P3_1=1, P3_2=2, P3_3=3, P3_4=4, P3_5=5, P3_8=2, P3_OUTN=3, P3_TAB=0xF888),
                      hearts + ["CLOSEUP", "CU_NAND", "PAGE1", "P3F2"], cu),
        "twos_p1": st(dict(base, OBJ=3, P4VAL=0xF4), hearts + ["CLOSEUP", "CU_TWOS", "PAGE1"], cu),
        "screen": st(dict(base, OBJ=4), ["HEART1", "HEART2", "HEART3", "CLOSEUP", "CU_SCREEN", "PLAY"], cu),
        "pc_login": st(dict(base, OBJ=5, P5_L0=2, P5_L1=15, P5_L2=4, P5_CUR=1),
                       hearts + ["CLOSEUP", "CU_PC", "P5C1"], cu),
        "pc_manual2": st(dict(base, OBJ=5, PAGE=2), hearts + ["CLOSEUP", "CU_PC", "DONE5", "PAGE2"], cu),
        "door": st(dict(base, OBJ=7, DOOR_D0=1, DOOR_D1=7, DOOR_D2=8, DOOR_CUR=2, CMSG=9),
                   hearts + ["CLOSEUP", "CU_DOOR", "DOOR_L2", "DOOR_C2", "CMSG_ON"], cu),
        "cards_r1": st(dict(base, CIMG0=48, CIMG1=49, CIMG2=50), hearts + ["MAP", "DECK", "CARD_R1", "CARD_C1"]),
        "cards_r2": st(dict(base, CIMG0=54, CIMG1=55, CIMG2=56, CNAME=4, CDESC=14),
                       hearts + ["MAP", "DECK", "CARD_FACEUP", "CF2"]),
        "notebook": st(dict(base, ANS_A=6, ANS_B=7, NOTE_T0=1, NOTE_V0=6, NOTE_T1=2, NOTE_V1=0x33CC, NOTE_T2=5,
                            NOTE_V2=0x040F02, HINT1=3, HINT2=5),
                       hearts + ["MAP", "NOTEBOOK", "ANSA_V", "ANSB_V", "NOTE_V0", "NOTE_V1", "NOTE_V2",
                                 "NOTE_D0", "NOTE_E1", "NOTE_L2", "HINT_V1", "HINT_V2"]),
        "over": st(dict(base, HEARTS=0), ["MAP", "OVER", "LIGHTS"]),
        "clear": st(dict(base, CLEAR_FORM=1), ["CLEAR", "HEART1", "HEART2"], (0, 0x021, 0, (0, 0))),
    }
