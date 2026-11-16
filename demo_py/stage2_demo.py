#!/usr/bin/env python3
# PC DEMO ONLY - not FPGA code. Gameplay prototype of Stage 2 (Internship), same structure as the Stage 1 demo.
# Optional images in ../assets/ :  internship.jpg (960x540 room)   player_form0..3.png   closeup_<id>.png (16:9)
#   ids: whiteboard terminal poster laptop screen pc door      Missing files -> placeholders, the game still runs.
import copy, itertools, math, os, sys, time
import pygame

SCR_W, SCR_H, PANEL_H = 1152, 648, 112      # window: game area 16:9 + virtual board panel
UW, UH = 960, 540                           # internal UI surface (16:9), scaled up to the window
FEET_HW, FEET_H = 14, 14                    # player collision box (feet)
SPR_W, SPR_H = 34, 70
BASE_SPEED = 260.0                          # px / second
LONG_PRESS_S = 0.8
ASSET_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")

# ---------------- puzzle data (same numbers as the RTL design) ----------------
SEGS = "abcdefg"
CHAR_NAME = {1: "C", 2: "P", 3: "E", 4: "-", 5: "3", 6: "9"}          # input code CBA -> character
GOLD = {1: "adef", 2: "abefg", 3: "adefg", 4: "g", 5: "abcdg", 6: "abcdfg"}
OPT_NAMES = ["0", "1", "A", "~A", "B", "~B", "C", "~C", "~C+B+A", "B~A+CA", "C(A+B)", "A+CB", "~C+B", "C+B+~A", "AB", "C+B"]
P2_TESTS = [5, 2]                                # QA tests CBA=101 (shows 3) and CBA=010 (shows P)
ANS_A = 6                                        # P1: code of '9' = 110
ANS_B = len(GOLD[2])                             # P2: segments lit for 'P' = 5
ANS_C = 7                                        # P4: the other don't-care code = 111
P3_ANS = 12                                      # P3: segment f = ~C + B
PC_PASS = "PEC"                                  # characters on the projector: P, E, C
L1_CODE = [int(c) for c in str(ord(PC_PASS[-1]))]            # 'C' = 67 -> [6, 7]
_S = ANS_A + ANS_B + ANS_C
_PRE = [ANS_A, ANS_B, ANS_C, _S // 10, _S % 10]             # 6 5 7 1 8
CODE2 = [_PRE[i] for i in (3, 1, 4, 0, 2)]                  # order 4-2-5-1-3 -> 1 5 8 6 7


def bits(k): return (k >> 2) & 1, (k >> 1) & 1, k & 1


def opt(s, c, b, a):
    return int([0, 1, a, 1 - a, b, 1 - b, c, 1 - c, (1 - c) | b | a, (b & (1 - a)) | (c & a),
                c & (a | b), a | (c & b), (1 - c) | b, c | b | (1 - a), a & b, c | b][s])


# ---------------- room layout (px in the 960x540 game area) ----------------
FLOOR = pygame.Rect(40, 210, 880, 290)
BLOCKERS = [pygame.Rect(80, 320, 200, 70), pygame.Rect(500, 320, 160, 70), pygame.Rect(770, 290, 150, 70)]
SPAWN = (480.0, 450.0)

HINTS = {
    "P1": "Look at the work order: which input code shows the character 9? Set the switches to that code.",
    "P2": "Segment a is ON for every character except '-'. Try ~C + B + A for it, then test.",
    "P3": "Group the 1s in the map. Don't-care cells (X) may count as 1.",
    "P4": "The other don't-care is the code where every input is 1.",
    "P5": "The three characters on the projector spell the password.",
}
CARD_ITEMS = {1: ["HINT_HARD", "BOOST", "ARMOR"], 2: ["SHARD", "SLOW", "HINT_SMART"], 3: ["FREEZE", "UNDO", "SHARD"]}
ITEM_TEXT = {
    "HINT_HARD": ("Hint", "Use it from the inventory (I)."),
    "BOOST": ("Speed Boost", "Saved for the Obby stage. No effect here."),
    "ARMOR": ("Armor", "Blocks the next wrong code penalty."),
    "SHARD": ("Armor Shard", "Collect 2 shards to forge 1 Armor."),
    "SLOW": ("Slow", "You walk slower for 10 seconds."),
    "HINT_SMART": ("Hint", "Use it from the inventory (I)."),
    "FREEZE": ("Freeze", "Stops moving obstacles for 5 s. Saved for Stage 3."),
    "UNDO": ("Undo", "Reverts your latest edit in puzzle 2, 3 or 5."),
}
CAREERS = [("AIR", (60, 170, 80)), ("EARTH", (220, 190, 50)), ("WATER", (200, 60, 60))]
SYMBOLS = [["WING", "PLANE", "FART"], ["SHIP", "GEAR", "MONEY"], ["WORM", "WHITE FLAG", "PLUG"]]
PERMS = list(itertools.permutations([0, 1, 2]))
USABLE = ["HINT_HARD", "HINT_SMART", "UNDO", "FREEZE"]
FORM_COLORS = [(60, 110, 220), (90, 90, 100), (35, 35, 35), (240, 200, 60)]
FORM_NAMES = ["Student uniform", "Workshop suit", "Graduation gown", "Super Yasai"]

SEG_MAP = {"0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg", "5": "acdfg", "6": "acdefg",
           "7": "abc", "8": "abcdefg", "9": "abcdfg", "H": "bcefg", "-": "g", " ": "", "E": "adefg",
           "P": "abefg", "C": "adef", "A": "abcefg", "F": "aefg", "L": "def", "O": "abcdef",
           "U": "bcdef", "d": "bcdeg", "S": "acdfg"}


class Obj:
    def __init__(self, oid, kind, name, ax, ay, r, rect):
        self.id, self.kind, self.name = oid, kind, name
        self.ax, self.ay, self.r = ax, ay, r
        self.rect = pygame.Rect(rect)


OBJS = [
    Obj("whiteboard", "whiteboard", "Work-order board", 165, 250, 100, (70, 50, 190, 110)),
    Obj("poster", "kmap", "K-map poster", 345, 250, 90, (300, 60, 90, 90)),
    Obj("door", "door", "Exit door + keypad", 490, 250, 110, (440, 30, 100, 160)),
    Obj("screen", "screen", "Projector screen", 690, 250, 110, (600, 50, 180, 110)),
    Obj("terminal", "terminal", "Decoder board", 180, 420, 110, (80, 320, 200, 70)),
    Obj("laptop", "dcare", "Intern laptop", 580, 420, 100, (520, 330, 120, 55)),
    Obj("pc", "pc", "Supervisor PC", 845, 380, 100, (800, 300, 90, 60)),
]
PAGED = ("whiteboard", "kmap", "dcare", "terminal", "pc")


def load_img(name, size=None):
    path = os.path.join(ASSET_DIR, name)
    if not os.path.isfile(path):
        return None
    try:
        img = pygame.image.load(path).convert_alpha()
        return pygame.transform.smoothscale(img, size) if size else img
    except (pygame.error, ValueError):
        return None


def draw_set(scr, on, x, y, w, h, off=(50, 22, 22)):
    t = max(3, w // 6)
    h2 = h // 2
    segs = {"a": (x + t, y, w - 2 * t, t), "b": (x + w - t, y + t, t, h2 - t),
            "c": (x + w - t, y + h2, t, h2 - t), "d": (x + t, y + h - t, w - 2 * t, t),
            "e": (x, y + h2, t, h2 - t), "f": (x, y + t, t, h2 - t),
            "g": (x + t, y + h2 - t // 2, w - 2 * t, t)}
    for k, r in segs.items():
        pygame.draw.rect(scr, (255, 60, 40) if k in on else off, r)


def draw_digit(scr, ch, x, y, w, h):
    draw_set(scr, SEG_MAP.get(ch, "g"), x, y, w, h)


def sw_cx(i):
    return 360 + (15 - i) * 48 + 22


class Game:
    def __init__(self):
        self.f_tiny = pygame.font.Font(None, 15)
        self.f_s = pygame.font.Font(None, 20)
        self.f_m = pygame.font.Font(None, 26)
        self.f_l = pygame.font.Font(None, 38)
        mono = "dejavusansmono,consolas,menlo,couriernew"
        self.f_mono = pygame.font.SysFont(mono, 17)
        self.f_mono_l = pygame.font.SysFont(mono, 25)
        self.bg = load_img("internship.jpg", (UW, UH))
        self.sprites = [load_img("player_form%d.png" % i, (SPR_W, SPR_H)) for i in range(4)]
        self.cu_cache = {}
        self.sw = [False] * 16
        self.sw_rects = [pygame.Rect(sw_cx(i) - 20, SCR_H + 36, 40, 34) for i in range(16)]
        self.c_down, self.c_long = None, False
        self.lfsr = (int(time.time() * 1000) & 0xFFFF) or 0xACE1
        self.debug = False
        self.show_help = True
        self.form = 1
        self.reset_stage(True)

    def reset_stage(self, full=False):
        if full:
            self.form = 1
        self.px, self.py = SPAWN
        self.mode, self.cur, self.page, self.cmsg = "map", None, 0, ""
        self.state = "play"
        self.solved = [False] * 5
        self.p2, self.p2_cur = [0] * 7, 0
        self.p3_sel = 0
        self.p5, self.p5_cur = [0, 0, 0], 0
        self.undo_rec = None
        self.notes, self.hints_seen = [], []
        self.hh = self.hs = self.undo = self.freeze = self.armor = self.shard = 0
        self.boost, self.slow_t = False, 0.0
        self.hearts = 3
        self.door_layer, self.door_digits, self.door_cur = 0, [0] * 5, 0
        self.deck = {"active": False, "round": 1, "perm": (0, 1, 2), "cursor": 1, "face": None}
        self.career = None
        self.r_run = {1: False, 2: False, 3: False}
        self.r_done = {1: False, 2: False, 3: False}
        self.hint_popup, self.toast, self.inv_cur = None, ("", 0), 0
        self.flash, self.over_until = 0.0, 0.0

    def say(self, text, secs=2.5):
        self.toast = (text, time.time() + secs)

    # ---------------- input ----------------
    def poll(self, events):
        ev = dict(up=0, down=0, left=0, right=0, tap=0, back=0)
        now = time.time()
        for e in events:
            if e.type == pygame.QUIT:
                pygame.quit(); sys.exit()
            if e.type == pygame.MOUSEBUTTONDOWN:
                for i, r in enumerate(self.sw_rects):
                    if r.collidepoint(e.pos):
                        self.sw[i] = not self.sw[i]
            if e.type == pygame.KEYDOWN:
                k = e.key
                if k in (pygame.K_UP, pygame.K_w): ev["up"] = 1
                elif k in (pygame.K_DOWN, pygame.K_s): ev["down"] = 1
                elif k in (pygame.K_LEFT, pygame.K_a): ev["left"] = 1
                elif k in (pygame.K_RIGHT, pygame.K_d): ev["right"] = 1
                elif k in (pygame.K_SPACE, pygame.K_RETURN):
                    if self.c_down is None:
                        self.c_down, self.c_long = now, False
                elif k in (pygame.K_ESCAPE, pygame.K_BACKSPACE): ev["back"] = 1
                elif pygame.K_1 <= k <= pygame.K_8: self.sw[k - pygame.K_1] = not self.sw[k - pygame.K_1]
                elif k == pygame.K_i: self.sw[15] = not self.sw[15]
                elif k == pygame.K_n: self.sw[14] = not self.sw[14]
                elif k == pygame.K_h: self.show_help = not self.show_help
                elif k in (pygame.K_F1, pygame.K_F2, pygame.K_F3, pygame.K_F4): self.form = k - pygame.K_F1
                elif k == pygame.K_F5: self.cheat_solve()
                elif k == pygame.K_F6: self.debug = not self.debug
            if e.type == pygame.KEYUP and e.key in (pygame.K_SPACE, pygame.K_RETURN):
                if self.c_down is not None and not self.c_long:
                    ev["tap"] = 1
                self.c_down = None
        if self.c_down is not None and not self.c_long and now - self.c_down >= LONG_PRESS_S:
            self.c_long = True
            ev["back"] = 1
        return ev

    def cheat_solve(self):
        for i in range(5):
            if not self.solved[i]:
                self.solved[i] = True
                self.say("[DEBUG] puzzle %d marked solved" % (i + 1))
                return

    # ---------------- random cards (LFSR) ----------------
    def lfsr_step(self):
        q = self.lfsr
        fb = ((q >> 15) ^ (q >> 14) ^ (q >> 12) ^ (q >> 3)) & 1
        q = ((q << 1) | fb) & 0xFFFF
        self.lfsr = q if q else 0xACE1

    def card_start(self, r):
        while True:                      # LFSR value 0..5 -> one of the 6 permutations
            self.lfsr_step()
            v = self.lfsr & 7
            if v < 6:
                break
        self.deck = {"active": True, "round": r, "perm": PERMS[v], "cursor": 1, "face": None}
        self.r_run[r] = True

    def card_trigger(self):
        if self.deck["active"]:
            return
        n = sum(self.solved)
        if not self.r_run[1]: self.card_start(1)
        elif self.r_done[1] and not self.r_run[2] and n >= 3: self.card_start(2)
        elif self.r_done[2] and not self.r_run[3] and n == 5: self.card_start(3)

    def cards_input(self, ev):
        d = self.deck
        if d["face"] is None:
            if ev["left"]: d["cursor"] = (d["cursor"] - 1) % 3
            elif ev["right"]: d["cursor"] = (d["cursor"] + 1) % 3
            elif ev["tap"]:
                d["face"] = d["cursor"]
                idx = d["perm"][d["cursor"]]
                if d["round"] == 1: self.career = idx
                self.grant(CARD_ITEMS[d["round"]][idx])
        elif ev["tap"]:
            d["active"] = False
            self.r_done[d["round"]] = True

    def grant(self, item):
        cap = lambda v: min(3, v + 1)
        if item == "HINT_HARD": self.hh = cap(self.hh)
        elif item == "HINT_SMART": self.hs = cap(self.hs)
        elif item == "UNDO": self.undo = cap(self.undo)
        elif item == "FREEZE": self.freeze = cap(self.freeze)
        elif item == "ARMOR": self.armor = cap(self.armor)
        elif item == "BOOST": self.boost = True
        elif item == "SLOW": self.slow_t = 10.0
        elif item == "SHARD":
            self.shard += 1
            if self.shard >= 2:
                self.shard = 0
                self.armor = cap(self.armor)

    # ---------------- items ----------------
    def smart_hint(self):
        if not self.solved[4]:
            return "P5"
        for idx in (1, 2, 0, 3):         # hardest first: P2, P3, P1, P4
            if not self.solved[idx]:
                return "P%d" % (idx + 1)
        return None

    def show_hint(self, key):
        self.hint_popup = HINTS[key]
        if HINTS[key] not in self.hints_seen:
            self.hints_seen.append(HINTS[key])

    def use_item(self, name):
        if name == "HINT_HARD":
            if self.hh == 0: return self.say("You do not have this item.")
            if self.solved[1]: return self.say("Not useful now: that puzzle is already solved.")
            self.hh -= 1; self.show_hint("P2")
        elif name == "HINT_SMART":
            if self.hs == 0: return self.say("You do not have this item.")
            h = self.smart_hint()
            if h is None: return self.say("Not useful now: nothing left to hint.")
            self.hs -= 1; self.show_hint(h)
        elif name == "UNDO":
            if self.undo == 0: return self.say("You do not have this item.")
            if not self.undo_rec or self.solved[self.undo_rec[2]]: return self.say("Nothing to undo right now.")
            self.undo -= 1
            kind, snap, _ = self.undo_rec
            if kind == "p2": self.p2 = snap
            elif kind == "p3": self.p3_sel = snap
            else: self.p5 = snap
            self.undo_rec = None
            self.say("Your last edit was undone.")
        elif name == "FREEZE":
            if self.freeze == 0: return self.say("You do not have this item.")
            self.say("No moving obstacles here. Keep it for Stage 3.")

    def rec_undo(self, kind):
        src = {"p2": self.p2, "p3": self.p3_sel, "p5": self.p5}[kind]
        self.undo_rec = (kind, copy.deepcopy(src), {"p2": 1, "p3": 2, "p5": 4}[kind])

    def inventory_input(self, ev):
        if ev["left"]: self.inv_cur = (self.inv_cur - 1) % 4
        elif ev["right"]: self.inv_cur = (self.inv_cur + 1) % 4
        elif ev["tap"]: self.use_item(USABLE[self.inv_cur])

    # ---------------- door / hearts ----------------
    def door_damage(self):
        if self.armor > 0:
            self.armor -= 1
            self.say("ARMOR PROTECTED!")
            return
        self.hearts -= 1
        self.flash = 0.4
        if self.hearts <= 0:
            self.state, self.over_until = "over", time.time() + 3.0
        else:
            self.say("Wrong code! -1 heart")

    def door_confirm(self):
        n = 2 if self.door_layer == 0 else 5
        want = L1_CODE if self.door_layer == 0 else CODE2
        if self.door_digits[:n] == want:
            self.door_digits, self.door_cur = [0] * 5, 0
            if self.door_layer == 0:
                self.door_layer = 1
                self.cmsg = "LOCK 1 OPEN. Now the 5-digit lock."
            else:
                self.state, self.form = "clear", 2
        else:
            self.cmsg = "WRONG CODE"
            self.door_damage()

    def solve(self, i, msg):
        if self.solved[i]: return
        self.solved[i] = True
        self.cmsg = msg
        self.say("Notebook updated!")
        if self.undo_rec and self.undo_rec[2] == i:
            self.undo_rec = None

    # ---------------- update ----------------
    def update(self, dt, ev):
        for _ in range(7): self.lfsr_step()
        self.flash = max(0.0, self.flash - dt)
        if self.show_help:
            if ev["tap"] or ev["back"]: self.show_help = False
            return
        if self.state == "clear":
            if ev["tap"]: self.reset_stage(True)
            return
        if self.state == "over":
            if time.time() > self.over_until: self.reset_stage()
            return
        self.slow_t = max(0.0, self.slow_t - dt)
        self.card_trigger()
        if self.deck["active"]: self.cards_input(ev); return
        if self.hint_popup:
            if ev["tap"] or ev["back"]: self.hint_popup = None
            return
        if self.sw[15]: self.inventory_input(ev); return
        if self.sw[14]: return
        if self.mode == "map": self.map_update(dt, ev)
        else: self.closeup_input(ev)

    def speed(self):
        s = BASE_SPEED * (1.2 if self.form >= 1 else 1.0)
        return s * 0.5 if self.slow_t > 0 else s

    def blocked(self, x, y):
        r = pygame.Rect(int(x) - FEET_HW, int(y) - FEET_H, FEET_HW * 2, FEET_H)
        return not FLOOR.contains(r) or any(r.colliderect(b) for b in BLOCKERS)

    def find_near(self):
        bonus = 30 if self.form >= 1 else 0
        best, bs = None, 9.0
        for o in OBJS:
            score = math.hypot(self.px - o.ax, self.py - o.ay) / (o.r + bonus)
            if score <= 1.0 and score < bs:
                best, bs = o, score
        return best

    def map_update(self, dt, ev):
        k = pygame.key.get_pressed()
        dx = int(k[pygame.K_RIGHT] or k[pygame.K_d]) - int(k[pygame.K_LEFT] or k[pygame.K_a])
        dy = int(k[pygame.K_DOWN] or k[pygame.K_s]) - int(k[pygame.K_UP] or k[pygame.K_w])
        sp = self.speed() * dt
        if not self.blocked(self.px + dx * sp, self.py): self.px += dx * sp
        if not self.blocked(self.px, self.py + dy * sp): self.py += dy * sp
        if ev["tap"]:
            o = self.find_near()
            if o:
                self.mode, self.cur, self.page, self.cmsg = "closeup", o, 0, ""

    def code3(self): return sum(1 << i for i in range(3) if self.sw[i])

    def closeup_input(self, ev):
        o = self.cur
        if ev["back"]:
            if self.page > 0 and o.kind in PAGED:
                self.page -= 1
            else:
                self.mode = "map"
            self.cmsg = ""
            return
        getattr(self, "in_" + o.kind)(ev)

    def on_of(self, k):
        c, b, a = bits(k)
        return "".join(sg for i, sg in enumerate(SEGS) if opt(self.p2[i], c, b, a))

    def in_whiteboard(self, ev):
        if self.page == 0:
            if ev["tap"]: self.page = 1
        elif ev["tap"] and not self.solved[0]:
            val = self.code3()
            self.notes.append("P1 input tested: %d" % val)
            if val == ANS_A:
                self.solve(0, "ORDER ACCEPTED. A = %d" % ANS_A)
            else:
                self.cmsg = "Code recorded in notebook. (No penalty)."

    def in_terminal(self, ev):
        if self.page == 0:
            if ev["tap"]: self.page = 1
            return
        if self.solved[1]: return
        c = self.p2_cur
        if ev["left"]: self.p2_cur = (c - 1) % 7
        elif ev["right"]: self.p2_cur = (c + 1) % 7
        elif ev["up"] or ev["down"]:
            self.rec_undo("p2")
            self.p2[c] = (self.p2[c] + (1 if ev["up"] else -1)) % 16
        elif ev["tap"]:
            good = sum(set(self.on_of(k)) == set(GOLD[k]) for k in P2_TESTS)
            self.notes.append("P2 QA test: %d/%d inputs correct" % (good, len(P2_TESTS)))
            if good == len(P2_TESTS):
                self.solve(1, "DECODER VERIFIED. B = %d" % ANS_B)
            else:
                self.cmsg = "QA: %d / %d inputs correct. Logged." % (good, len(P2_TESTS))

    def in_kmap(self, ev):
        if self.page == 0:
            if ev["tap"]: self.page = 1
            return
        if self.solved[2]: return
        if ev["up"] or ev["down"]:
            self.rec_undo("p3")
            self.p3_sel = (self.p3_sel + (1 if ev["up"] else -1)) % 16
        elif ev["tap"]:
            self.notes.append("P3 answer tried: f = %s" % OPT_NAMES[self.p3_sel])
            if self.p3_sel == P3_ANS:
                self.solve(2, "MINIMAL FORM FOUND. f = %s" % OPT_NAMES[P3_ANS])
            else:
                self.cmsg = "Not the minimal form. Logged."

    def in_dcare(self, ev):
        if self.page == 0:
            if ev["tap"]: self.page = 1
        elif ev["tap"] and not self.solved[3]:
            val = self.code3()
            self.notes.append("P4 don't-care tested: %d" % val)
            if val == ANS_C:
                self.solve(3, "SPEC FIXED. C = %d" % ANS_C)
            else:
                self.cmsg = "Value logged in notebook."

    def in_screen(self, ev): pass

    def in_pc(self, ev):
        if self.solved[4]:
            if ev["down"] or ev["tap"]: self.page = min(2, self.page + 1)
            elif ev["up"]: self.page = max(0, self.page - 1)
            return
        c = self.p5_cur
        if ev["up"]: self.p5_cur = (c - 1) % 3
        elif ev["down"]: self.p5_cur = (c + 1) % 3
        elif ev["left"]: self.rec_undo("p5"); self.p5[c] = (self.p5[c] - 1) % 26
        elif ev["right"]: self.rec_undo("p5"); self.p5[c] = (self.p5[c] + 1) % 26
        elif ev["tap"]:
            entered = "".join(chr(65 + v) for v in self.p5)
            self.notes.append("P5 attempt: " + entered)
            if entered == PC_PASS:
                self.solve(4, "ACCESS GRANTED"); self.page = 0
            else:
                self.cmsg = "Incorrect passcode. Attempt logged."

    def in_door(self, ev):
        n = 2 if self.door_layer == 0 else 5
        c = self.door_cur
        if ev["left"]: self.door_cur = (c - 1) % n
        elif ev["right"]: self.door_cur = (c + 1) % n
        elif ev["up"]: self.door_digits[c] = (self.door_digits[c] + 1) % 10
        elif ev["down"]: self.door_digits[c] = (self.door_digits[c] - 1) % 10
        elif ev["tap"]: self.door_confirm()

    # ---------------- drawing helpers ----------------
    def txt(self, s, text, x, y, font=None, color=(255, 255, 255)):
        s.blit((font or self.f_m).render(text, True, color), (x, y))

    def ctxt(self, s, text, cx, y, font=None, color=(255, 255, 255)):
        img = (font or self.f_m).render(text, True, color)
        s.blit(img, (cx - img.get_width() // 2, y))

    def wrap(self, text, font, width):
        lines = []
        for para in text.split("\n"):
            cur = ""
            for word in para.split(" "):
                t = (cur + " " + word).strip()
                if font.size(t)[0] <= width or not cur: cur = t
                else: lines.append(cur); cur = word
            lines.append(cur)
        return lines

    def blit_wrap(self, s, text, x, y, width, font, color, lh=None):
        lh = lh or font.get_linesize()
        for l in self.wrap(text, font, width):
            self.txt(s, l, x, y, font, color); y += lh
        return y

    def draw_box(self, s, rect):
        pygame.draw.rect(s, (20, 22, 30), rect, border_radius=10)
        pygame.draw.rect(s, (120, 130, 170), rect, 2, border_radius=10)

    # ---------------- drawing: world ----------------
    def draw_world(self, ui):
        if self.bg:
            ui.blit(self.bg, (0, 0))
        else:
            ui.fill((70, 78, 96))
            pygame.draw.rect(ui, (150, 140, 160), FLOOR)
            for b in BLOCKERS: pygame.draw.rect(ui, (110, 80, 60), b)
            for o in OBJS:
                pygame.draw.rect(ui, (90, 120, 160), o.rect, 2)
                ui.blit(self.f_tiny.render(o.name, True, (255, 255, 255)), (o.rect.x + 2, o.rect.y + 2))
        sx, sy = int(self.px - SPR_W / 2), int(self.py - SPR_H + 4)
        img = self.sprites[self.form]
        if img:
            ui.blit(img, (sx, sy))
        else:
            pygame.draw.rect(ui, FORM_COLORS[self.form], (sx, sy + SPR_H // 3, SPR_W, SPR_H - SPR_H // 3), border_radius=6)
            pygame.draw.circle(ui, (240, 200, 160), (sx + SPR_W // 2, sy + SPR_H // 6), max(6, SPR_W // 3))
        near = self.find_near()
        if near:
            self.ctxt(ui, "[Space] " + near.name, int(self.px), int(self.py - SPR_H - 14), self.f_s, (255, 230, 120))
        if self.debug:
            pygame.draw.rect(ui, (0, 255, 255), FLOOR, 2)
            for b in BLOCKERS: pygame.draw.rect(ui, (255, 0, 0), b, 2)
            for o in OBJS:
                pygame.draw.circle(ui, (255, 255, 0), (o.ax, o.ay), 4)
                pygame.draw.circle(ui, (255, 255, 0), (o.ax, o.ay), o.r, 1)

    # ---------------- drawing: close-up ----------------
    def cu_img(self, oid):
        if oid not in self.cu_cache: self.cu_cache[oid] = load_img("closeup_%s.png" % oid, (UW, UH))
        return self.cu_cache[oid]

    def draw_closeup(self, ui, s):
        o = self.cur
        img = self.cu_img(o.id)
        if img: ui.blit(img, (0, 0))
        pygame.draw.rect(s, (70, 74, 90), (0, 0, 640, 44))
        self.txt(s, o.name.upper(), 16, 10, self.f_l)
        foot = getattr(self, "cu_" + o.kind)(s)
        if self.cmsg:
            for i, l in enumerate(self.wrap(self.cmsg, self.f_m, 610)[:2]):
                self.txt(s, l, 16, 440 + i * 24, self.f_m, (255, 225, 120))
        pygame.draw.rect(s, (40, 44, 60), (0, 494, 640, 46))
        self.txt(s, foot or "", 16, 499, self.f_s, (170, 200, 255))
        self.txt(s, "Back: hold Space (BTNC) or press Esc", 16, 520, self.f_tiny, (140, 150, 180))

    def cu_whiteboard(self, s):
        pygame.draw.rect(s, (240, 240, 235), (40, 56, 560, 376), border_radius=6)
        ink = (30, 40, 130)
        if self.page == 0:
            lines = ["WORK ORDER #402", "Show the character 9 on the board.", "",
                     "input code CBA -> character", "001 = C    010 = P    011 = E",
                     "100 = -    101 = 3    110 = 9"]
            for i, l in enumerate(lines): self.txt(s, l, 70, 78 + i * 38, self.f_mono_l, ink)
            draw_set(s, GOLD[6], 480, 90, 60, 100, (215, 215, 210))
            return "BTNC: next page"
        self.txt(s, "INPUT DIAL  (switches SW2..SW0)", 70, 76, self.f_m, ink)
        pygame.draw.rect(s, (60, 60, 70), (70, 130, 500, 200), border_radius=8)
        for k in range(3):
            i = 2 - k
            cx = 180 + k * 130
            pygame.draw.circle(s, (255, 220, 60) if self.sw[i] else (90, 90, 90), (cx, 210), 30)
            self.ctxt(s, "C B A"[k * 2], cx, 258, self.f_m)
        self.txt(s, "= %d" % self.code3(), 470, 190, self.f_l)
        if self.solved[0]: self.txt(s, "LOGGED: A = %d" % ANS_A, 70, 360, self.f_m, (20, 120, 40))
        return "ANSWER: set SW2-SW0 (keys 1-3), then BTNC"

    def cu_terminal(self, s):
        pygame.draw.rect(s, (10, 20, 10), (40, 60, 560, 360), border_radius=6)
        g, y = (110, 255, 130), (255, 255, 120)
        if self.page == 0:
            lines = ["INTERN BENCH - DECODER BOARD", "",
                     "Task: wire a 3-bit decoder (C B A)",
                     "so the 7-segment shows C P E - 3 9.", "Codes 000 and 111 never occur.",
                     "Pick a formula for each segment a-g.", "QA will test two inputs."]
            for i, l in enumerate(lines): self.txt(s, l, 56, 76 + i * 34, self.f_mono, g)
            return "BTNC: open wiring editor"
        for i, sg in enumerate(SEGS):
            hl = i == self.p2_cur
            self.txt(s, ("> " if hl else "  ") + "seg %s: %s" % (sg, OPT_NAMES[self.p2[i]]),
                     64 + (i // 4) * 280, 74 + (i % 4) * 32, self.f_mono, y if hl else g)
        for j, k in enumerate(P2_TESTS):
            x = 70 + j * 280
            c, b, a = bits(k)
            self.txt(s, "CBA=%d%d%d  want %s" % (c, b, a, CHAR_NAME[k]), x, 220, self.f_s, g)
            draw_set(s, GOLD[k], x, 250, 36, 64)
            draw_set(s, self.on_of(k), x + 90, 250, 36, 64)
            self.txt(s, "target", x - 2, 322, self.f_tiny, g)
            self.txt(s, "yours", x + 92, 322, self.f_tiny, g)
        return "L/R segment | U/D formula | BTNC test"

    def cu_kmap(self, s):
        pygame.draw.rect(s, (245, 240, 220), (40, 56, 560, 366), border_radius=4)
        ink = (40, 40, 40)
        self.txt(s, "SEGMENT f  (1 = ON, X = never happens)", 70, 70, self.f_m, ink)
        self.txt(s, "C \\ BA", 70, 120, self.f_s, ink)
        cols, vals = ["00", "01", "11", "10"], [["X", "1", "1", "1"], ["0", "0", "X", "1"]]
        for c in range(4): self.txt(s, cols[c], 150 + c * 70 + 20, 120, self.f_s, ink)
        for r in range(2):
            self.txt(s, str(r), 100, 160 + r * 60 + 18, self.f_s, ink)
            for c in range(4):
                rc = pygame.Rect(150 + c * 70, 150 + r * 60, 70, 60)
                pygame.draw.rect(s, ink, rc, 1)
                self.ctxt(s, vals[r][c], rc.centerx, rc.y + 18, self.f_m, ink)
        if self.page == 0:
            self.txt(s, "f = ?", 70, 300, self.f_l, ink)
            return "BTNC: next page"
        self.txt(s, "f = %s" % OPT_NAMES[self.p3_sel], 70, 300, self.f_l, (30, 80, 160))
        if self.solved[2]: self.txt(s, "LOGGED: f = %s" % OPT_NAMES[P3_ANS], 70, 350, self.f_m, (20, 120, 40))
        return "U/D choose formula | BTNC test"

    def cu_dcare(self, s):
        pygame.draw.rect(s, (10, 10, 25), (40, 60, 560, 360), border_radius=6)
        g = (130, 200, 255)
        if self.page == 0:
            lines = ["QA LAPTOP - SPEC NOTE", "",
                     "Two input codes never occur", "(don't-care). One of them is 000.",
                     "Find the OTHER one.", "", "READY FOR INPUT..."]
            for i, l in enumerate(lines): self.txt(s, l, 56, 76 + i * 34, self.f_mono, g)
            return "BTNC: open input console"
        self.txt(s, "enter code with switches SW2..SW0:", 70, 90, self.f_m, g)
        self.txt(s, "".join("1" if self.sw[i] else "0" for i in (2, 1, 0)), 70, 140, self.f_mono_l, (255, 255, 120))
        self.txt(s, "decimal %d" % self.code3(), 70, 190, self.f_m, g)
        return "ANSWER: set SW2-SW0 (keys 1-3), then BTNC"

    def cu_screen(self, s):
        pygame.draw.rect(s, (15, 20, 30), (40, 60, 560, 360), border_radius=6)
        self.ctxt(s, "PROJECTOR: LOGIN HINT", 320, 76, self.f_s, (130, 200, 255))
        for i, ch in enumerate(PC_PASS):
            draw_digit(s, ch, 100 + i * 160, 150, 90, 150)
        self.ctxt(s, "Three characters on the board.", 320, 340, self.f_s, (180, 220, 180))
        return ""

    def cu_door(self, s):
        pygame.draw.rect(s, (120, 85, 55), (240, 56, 160, 230), border_radius=6)
        n = 2 if self.door_layer == 0 else 5
        self.ctxt(s, "LOCK %d of 2  (%d digits)" % (self.door_layer + 1, n), 320, 298, self.f_m)
        x0 = 320 - n * 70 // 2
        for i in range(n):
            r = pygame.Rect(x0 + i * 70 + 5, 332, 60, 64)
            pygame.draw.rect(s, (255, 230, 120) if i == self.door_cur else (200, 200, 200), r, border_radius=6)
            self.ctxt(s, str(self.door_digits[i]), r.centerx, r.y + 14, self.f_l, (20, 20, 20))
        return "U/D digit | L/R box | BTNC confirm"

    def cu_pc(self, s):
        pygame.draw.rect(s, (15, 25, 50), (40, 60, 560, 360), border_radius=6)
        c = (160, 200, 255)
        if not self.solved[4]:
            self.txt(s, "SUPERVISOR TERMINAL LOGIN", 70, 75, self.f_mono, c)
            self.txt(s, "Enter 3-letter passcode (A-Z):", 70, 115, self.f_s, c)
            for i in range(3):
                r = pygame.Rect(180 + i * 90, 150, 70, 70)
                pygame.draw.rect(s, (255, 230, 120) if i == self.p5_cur else (60, 75, 110), r, border_radius=8)
                self.ctxt(s, chr(65 + self.p5[i]), r.centerx, r.y + 18, self.f_l, (255, 255, 255))
            self.txt(s, "Read the characters on the projector screen", 70, 250, self.f_tiny, (180, 220, 180))
            return "U/D box | L/R letter (A-Z) | BTNC enter"
        if self.page == 0:
            self.txt(s, "Welcome, supervisor.", 70, 90, self.f_mono_l, c)
            self.txt(s, "[ door_manual.txt ]", 70, 150, self.f_mono_l, (255, 230, 120))
            return "U/D or BTNC: open file"
        if self.page == 1:
            lines = ["DOOR - LAYER 1  (2 digits)", "1. Take the LAST letter of your login password.",
                     "2. Find it in the table (values are HEX).", "3. Key in its DECIMAL value.", "",
                     "A 41  B 42  C 43  D 44  E 45  F 46  G 47", "H 48  I 49  J 4A  K 4B  L 4C  M 4D  N 4E",
                     "O 4F  P 50  Q 51  R 52  S 53  T 54  U 55", "V 56  W 57  X 58  Y 59  Z 5A"]
        else:
            lines = ["DOOR - LAYER 2  (5 digits)", "A = work-order board result",
                     "B = decoder board result", "C = QA laptop result",
                     "Step 1: S = A + B + C.  Row: A B C S", "        (S has two digits -> 5 digits)",
                     "Step 2: new digit 1 = old position 4,", "        then old 2, 5, 1, 3.",
                     "Example: row 2 4 6 8 9 -> 8 4 9 2 6"]
        for i, l in enumerate(lines): self.txt(s, l, 56, 74 + i * 33, self.f_mono, c)
        return "U/D page"

    # ---------------- drawing: overlays ----------------
    def draw_cards(self, ui, s):
        d = self.deck
        ov = pygame.Surface((UW, UH), pygame.SRCALPHA); ov.fill((0, 0, 0, 205)); ui.blit(ov, (0, 0))
        self.ctxt(s, "PICK A CARD  (ROUND %d)" % d["round"], 320, 30, self.f_l)
        for pos in range(3):
            r = pygame.Rect(80 + pos * 180, 80, 140, 200)
            idx = d["perm"][pos]
            item = CARD_ITEMS[d["round"]][idx]
            if d["round"] == 1:
                if d["face"] == pos:
                    pygame.draw.rect(s, CAREERS[idx][1], r, border_radius=10)
                    self.ctxt(s, CAREERS[idx][0], r.centerx, r.y + 60, self.f_m)
                    self.ctxt(s, ITEM_TEXT[item][0], r.centerx, r.y + 120, self.f_s)
                else:
                    pygame.draw.rect(s, (80, 85, 100), r, border_radius=10)
                    self.ctxt(s, "?", r.centerx, r.y + 90, self.f_l, (200, 200, 200))
            else:
                pygame.draw.rect(s, CAREERS[self.career][1], r, border_radius=10)
                self.ctxt(s, SYMBOLS[self.career][pos], r.centerx, r.y + 60, self.f_m)
                if d["face"] == pos:
                    self.ctxt(s, ITEM_TEXT[item][0], r.centerx, r.y + 120, self.f_s)
            if d["face"] is None and pos == d["cursor"]:
                pygame.draw.rect(s, (255, 255, 255), r.inflate(10, 10), 4, border_radius=12)
        if d["face"] is not None:
            name, desc = ITEM_TEXT[CARD_ITEMS[d["round"]][d["perm"][d["face"]]]]
            pygame.draw.rect(s, (30, 35, 45), (60, 310, 520, 90), border_radius=8)
            self.ctxt(s, "Obtained: " + name, 320, 322, self.f_m, (255, 230, 120))
            self.ctxt(s, desc, 320, 356, self.f_s, (240, 240, 240))
            self.ctxt(s, "BTNC: continue", 320, 420, self.f_m, (170, 200, 255))
        else:
            self.ctxt(s, "L/R choose   BTNC pick", 320, 360, self.f_m, (170, 200, 255))

    def draw_inventory(self, s):
        self.draw_box(s, pygame.Rect(90, 80, 460, 340))
        self.ctxt(s, "INVENTORY  (SW15 / key I to close)", 320, 94, self.f_m)
        counts = [self.hh, self.hs, self.undo, self.freeze]
        names = ["Hint (hard)", "Hint (smart)", "Undo", "Freeze"]
        for i in range(4):
            r = pygame.Rect(110 + i * 108, 140, 100, 90)
            pygame.draw.rect(s, (255, 230, 120) if i == self.inv_cur else (70, 74, 100), r, border_radius=8)
            col = (20, 20, 20) if i == self.inv_cur else (255, 255, 255)
            self.ctxt(s, names[i], r.centerx, r.y + 14, self.f_s, col)
            self.ctxt(s, "x%d" % counts[i], r.centerx, r.y + 46, self.f_l, col)
        self.txt(s, "Armor x%d   (shields wrong code penalty)" % self.armor, 110, 260, self.f_s)
        self.txt(s, "Armor shards %d / 2   (2 shards = 1 armor)" % self.shard, 110, 286, self.f_s)
        self.txt(s, "Speed Boost: %s   (used in Stage 3)" % ("yes" if self.boost else "no"), 110, 312, self.f_s)
        self.txt(s, "Slow: %s" % (("%.0f s left" % self.slow_t) if self.slow_t > 0 else "off"), 110, 338, self.f_s)
        self.ctxt(s, "L/R select   BTNC use", 320, 380, self.f_s, (170, 200, 255))

    def draw_notebook(self, s):
        self.draw_box(s, pygame.Rect(60, 50, 520, 420))
        self.ctxt(s, "NOTEBOOK  (SW14 / key N to close)", 320, 62, self.f_m)
        self.txt(s, "Answers Logged: A = %s   B = %s   C = %s" % (
            ANS_A if self.solved[0] else "?", ANS_B if self.solved[1] else "?", ANS_C if self.solved[3] else "?"),
            80, 100, self.f_s, (255, 230, 120))
        if self.career is not None:
            self.txt(s, "Career card: %s" % CAREERS[self.career][0], 80, 120, self.f_s, CAREERS[self.career][1])
        y = 148
        self.txt(s, "Logged Actions & Clues:", 80, y, self.f_s, (170, 200, 255)); y += 22
        for n in self.notes[-9:]: y = self.blit_wrap(s, "- " + n, 80, y, 480, self.f_s, (230, 230, 230))
        y += 8
        self.txt(s, "Hints Used:", 80, y, self.f_s, (170, 200, 255)); y += 22
        for h in self.hints_seen[-3:]:
            y = self.blit_wrap(s, "- " + h, 80, y, 480, self.f_s, (230, 230, 230))

    def draw_help(self, ui, s):
        ov = pygame.Surface((UW, UH), pygame.SRCALPHA); ov.fill((0, 0, 0, 215)); ui.blit(ov, (0, 0))
        self.draw_box(s, pygame.Rect(30, 60, 580, 420))
        self.ctxt(s, "STAGE 2: INTERNSHIP - HOW TO PLAY", 320, 74, self.f_l)
        rows = [("Move", "W A S D / arrows   (BTNU BTND BTNL BTNR)"),
                ("Interact / confirm", "Space   (BTNC tap)"),
                ("Back", "hold Space 0.8 s, or Esc   (BTNC hold)"),
                ("Switches", "keys 1-8 = SW0-SW7, or click them below"),
                ("Inventory", "I   (SW15)"),
                ("Notebook", "N   (SW14)"),
                ("This help", "H"),
                ("Debug", "F1-F4 form, F5 solve next, F6 collision")]
        for i, (a, b) in enumerate(rows):
            self.txt(s, a, 54, 128 + i * 30, self.f_s, (255, 230, 120))
            self.txt(s, b, 220, 128 + i * 30, self.f_s)
        self.blit_wrap(s, "Solve the 5 puzzles, collect cards, then open the exit door.", 54, 380, 530, self.f_m, (170, 200, 255))
        self.ctxt(s, "Press Space to start", 320, 442, self.f_m, (150, 255, 170))

    def draw_hud(self, ui):
        for i in range(3):
            col = (230, 50, 60) if i < self.hearts else (80, 50, 50)
            pygame.draw.circle(ui, col, (24 + i * 26, 22), 10)
        if self.armor > 0:
            pygame.draw.rect(ui, (80, 180, 255), (96, 12, 18, 22), border_radius=4)
            self.txt(ui, "x%d" % self.armor, 118, 14, self.f_s, (120, 200, 255))
        if self.slow_t > 0:
            self.txt(ui, "SLOW %.0fs" % self.slow_t, 180, 14, self.f_m, (255, 150, 80))

    def draw_toast(self, ui):
        if time.time() < self.toast[1]:
            img = self.f_m.render(self.toast[0], True, (255, 255, 255))
            r = pygame.Rect(UW // 2 - img.get_width() // 2 - 12, 44, img.get_width() + 24, 34)
            pygame.draw.rect(ui, (0, 0, 0), r, border_radius=8)
            ui.blit(img, (r.x + 12, r.y + 7))

    def seg_right(self):
        if self.state == "clear": return "PA55"
        if self.state == "over": return "dEAd"
        if self.mode == "closeup" and self.cur and not self.deck["active"]:
            k = self.cur.kind
            if k in ("whiteboard", "dcare") and self.page == 1: return str(self.code3())
            if k == "terminal" and self.page == 1: return str(self.p2[self.p2_cur])
            if k == "kmap" and self.page == 1: return str(self.p3_sel)
            if k == "door": return "".join(str(d) for d in self.door_digits[:2 if self.door_layer == 0 else 5])
            if k == "pc" and not self.solved[4]: return "".join(str(v) for v in self.p5)
        return ""

    def draw_panel(self, scr):
        y0 = SCR_H
        pygame.draw.rect(scr, (24, 26, 32), (0, y0, SCR_W, PANEL_H))
        pygame.draw.line(scr, (70, 74, 90), (0, y0), (SCR_W, y0), 2)
        leds = [False] * 16
        for i in range(3): leds[i] = self.hearts > i
        leds[3] = self.armor > 0
        for i in range(5): leds[4 + i] = self.solved[i]
        leds[11] = self.slow_t > 0
        for i in range(16):
            pygame.draw.circle(scr, (255, 70, 60) if leds[i] else (70, 40, 40), (sw_cx(i), y0 + 18), 7)
        for i in range(16):
            r = self.sw_rects[i]
            pygame.draw.rect(scr, (230, 230, 230) if self.sw[i] else (80, 80, 90), r, border_radius=5)
            self.ctxt(scr, "SW%d" % i, r.centerx, r.y + 11, self.f_tiny, (20, 20, 20) if self.sw[i] else (200, 200, 200))
        text = ("H%d" % max(0, self.hearts)) + self.seg_right().rjust(6)[-6:]
        for i, ch in enumerate(text):
            draw_digit(scr, ch, 14 + i * 40, y0 + 26, 32, 52)
        self.txt(scr, "7-SEG: H3 = 3 hearts | right = live value", 14, y0 + 84, self.f_tiny, (170, 170, 190))
        self.txt(scr, "LED: 0-2 hearts  3 armor  4-8 puzzles  11 slow", 360, y0 + 78, self.f_tiny, (140, 140, 160))
        self.txt(scr, "Move WASD | BTNC = Space (hold = back) | SW0-7 = keys 1-8 or click | I inventory | N notebook | H help",
                 360, y0 + 94, self.f_tiny, (170, 170, 190))
        self.txt(scr, "Form: %s" % FORM_NAMES[self.form], 14, y0 + 98, self.f_tiny, (140, 140, 160))

    def draw(self, ui, screen):
        ui.fill((18, 20, 26))
        s = ui.subsurface(pygame.Rect(160, 0, 640, UH))
        if self.mode == "closeup" and self.cur: self.draw_closeup(ui, s)
        else: self.draw_world(ui)
        self.draw_hud(ui)
        if self.sw[14]: self.draw_notebook(s)
        if self.sw[15]: self.draw_inventory(s)
        if self.hint_popup:
            self.draw_box(s, pygame.Rect(80, 170, 480, 180))
            self.ctxt(s, "HINT", 320, 182, self.f_m, (255, 230, 120))
            self.blit_wrap(s, self.hint_popup, 100, 220, 440, self.f_m, (255, 255, 255))
            self.ctxt(s, "BTNC: close", 320, 322, self.f_s, (170, 200, 255))
        if self.deck["active"]: self.draw_cards(ui, s)
        if self.flash > 0:
            fl = pygame.Surface((UW, UH)); fl.fill((255, 0, 0)); fl.set_alpha(int(180 * self.flash / 0.4)); ui.blit(fl, (0, 0))
        if self.state == "over":
            ov = pygame.Surface((UW, UH)); ov.set_alpha(220); ui.blit(ov, (0, 0))
            self.ctxt(ui, "OUT OF HEARTS", UW // 2, 220, self.f_l, (255, 90, 90))
            self.ctxt(ui, "Restarting Stage 2...", UW // 2, 270, self.f_m)
        if self.state == "clear":
            ui.fill((15, 40, 25))
            self.ctxt(ui, "STAGE 2 CLEAR - INTERNSHIP COMPLETE!", UW // 2, 160, self.f_l, (150, 255, 170))
            self.ctxt(ui, "Hearts left: %d" % self.hearts, UW // 2, 220, self.f_m)
            self.ctxt(ui, "CHARACTER EVOLVED -> %s" % FORM_NAMES[2], UW // 2, 270, self.f_m, (255, 230, 120))
            self.ctxt(ui, "BTNC: play again", UW // 2, 370, self.f_s, (170, 200, 255))
        self.draw_toast(ui)
        if self.show_help: self.draw_help(ui, s)
        screen.blit(pygame.transform.smoothscale(ui, (SCR_W, SCR_H)), (0, 0))
        self.draw_panel(screen)


def main():
    pygame.display.init()
    pygame.font.init()
    pygame.display.set_caption("CPE Escape - Stage 2 Internship (PC demo)")
    size = (SCR_W, SCR_H + PANEL_H)
    try:
        screen = pygame.display.set_mode(size, pygame.SCALED | pygame.RESIZABLE)
    except pygame.error:
        screen = pygame.display.set_mode(size)
    ui = pygame.Surface((UW, UH))
    clock = pygame.time.Clock()
    game = Game()
    while True:
        dt = min(clock.tick(60) / 1000.0, 0.05)
        ev = game.poll(pygame.event.get())
        game.update(dt, ev)
        game.draw(ui, screen)
        pygame.display.flip()


if __name__ == "__main__":
    main()
