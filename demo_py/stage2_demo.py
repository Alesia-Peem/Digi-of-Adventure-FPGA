#!/usr/bin/env python3
# PC DEMO ONLY - not FPGA code. Gameplay prototype of Stage 2 (Internship), same structure as the Stage 1 demo.
# Flow: search the room for 4 logic parts -> bring them to the decoder bench -> wire the 7-segment decoder
#       (AND/OR wiring game, 3 QA rounds) -> the exit door unlocks.  No in-game computers.
# Optional images in ../assets/ :  internship.jpg (960x540 room)   player_form0..3.png   closeup_<id>.png (16:9)
#   ids: whiteboard chart cabinet toolbox drawer bench door      Missing files -> placeholders, the game still runs.
import copy, itertools, math, os, sys, time
import pygame

SCR_W, SCR_H, PANEL_H = 1152, 648, 112      # window: game area 16:9 + virtual board panel
UW, UH = 960, 540                           # internal UI surface (16:9), scaled up to the window
CU_X, CU_W = 160, 640                       # close-up panel inside the UI surface
FEET_HW, FEET_H = 14, 14                    # player collision box (feet)
SPR_W, SPR_H = 34, 70
BASE_SPEED = 260.0                          # px / second
LONG_PRESS_S = 0.8
ASSET_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")

# ---------------- decoder data (same numbers as the RTL design) ----------------
SEGS = "abcdefg"
CHAR_NAME = {1: "C", 2: "P", 3: "E", 4: "-", 5: "3", 6: "9"}          # input code CBA -> character
GOLD = {1: "adef", 2: "abefg", 3: "adefg", 4: "g", 5: "abcdg", 6: "abcdfg"}
ROUNDS = 3                                       # QA rounds, 2 random input codes each

# wiring board: 8 source rails, 2 AND gates (2 inputs), 1 OR gate (3 inputs) per segment
RAILS = ["C", "B", "A", "nC", "nB", "nA", "0", "1"]
LBL = {"C": "C", "B": "B", "A": "A", "nC": "~C", "nB": "~B", "nA": "~A", "0": "0", "1": "1",
       "g1": "AND1", "g2": "AND2"}
PINS = ["a1", "a2", "b1", "b2", "o1", "o2", "o3"]
PIN_LBL = {"a1": "AND1 in 1", "a2": "AND1 in 2", "b1": "AND2 in 1", "b2": "AND2 in 2",
           "o1": "OR in 1", "o2": "OR in 2", "o3": "OR in 3"}
CUR_CLEAR, CUR_QA = 7, 8                         # cursor entries after the 7 pins

# parts hidden in the room
PART_NAME = {"and1": "AND gate #1", "and2": "AND gate #2", "or": "OR gate", "not": "NOT chip"}
PART_SPOT = {"and1": "wall cabinet", "and2": "segment chart poster", "or": "toolbox", "not": "parts drawer"}
PART_USE = {"and1": "upper AND gate", "and2": "lower AND gate", "or": "output OR gate", "not": "~C ~B ~A rails"}
SPOTS = {"cabinet": ("and1", "DOOR"), "toolbox": ("or", "TRAY"), "drawer": ("not", "DRAWER")}


def bits(k): return (k >> 2) & 1, (k >> 1) & 1, k & 1


def sv(s, c, b, a, w):                           # value of a source (rail or AND output)
    if s == "g1": return sv(w["a1"], c, b, a, w) & sv(w["a2"], c, b, a, w) if "a1" in w and "a2" in w else 0
    if s == "g2": return sv(w["b1"], c, b, a, w) & sv(w["b2"], c, b, a, w) if "b1" in w and "b2" in w else 0
    return {"C": c, "B": b, "A": a, "nC": 1 - c, "nB": 1 - b, "nA": 1 - a, "0": 0, "1": 1}.get(s, 0)


def out(w, c, b, a):                             # one segment: OR of its connected inputs
    return int(any(p in w and sv(w[p], c, b, a, w) for p in ("o1", "o2", "o3")))


# ---------------- wiring bench layout (px inside the 640-wide close-up panel) ----------------
NODE = {k: (64, 172 + i * 32) for i, k in enumerate(RAILS)}
NODE.update({"g1": (300, 204), "g2": (300, 336)})
PIN_POS = {"a1": (200, 188), "a2": (200, 220), "b1": (200, 320), "b2": (200, 352),
           "o1": (382, 252), "o2": (382, 270), "o3": (382, 288)}
ELBOW = {"a1": 118, "a2": 130, "b1": 142, "b2": 154, "o1": 166, "o2": 178, "o3": 190}   # rail wires turn here
G_ELBOW = {"o1": 336, "o2": 348, "o3": 360}                                             # AND-output wires
TAB_RECTS = [pygame.Rect(16 + i * 46, 122, 42, 24) for i in range(7)]
BTN_CLEAR = pygame.Rect(352, 122, 96, 24)
BTN_QA = pygame.Rect(456, 122, 168, 24)
C_PANEL, C_BORDER, C_ON, C_OFF = (17, 26, 43), (45, 64, 94), (34, 197, 94), (70, 86, 111)
C_GATE, C_SEL, C_MOUSE = (32, 49, 76), (255, 230, 120), (56, 189, 248)

# ---------------- room layout (px in the 960x540 game area) ----------------
FLOOR = pygame.Rect(40, 210, 880, 290)
BLOCKERS = [pygame.Rect(80, 320, 200, 70), pygame.Rect(500, 320, 160, 70), pygame.Rect(770, 290, 150, 70)]
SPAWN = (480.0, 450.0)

CARD_ITEMS = {1: ["HINT_HARD", "BOOST", "ARMOR"], 2: ["SHARD", "SLOW", "HINT_SMART"], 3: ["FREEZE", "UNDO", "SHARD"]}
ITEM_TEXT = {
    "HINT_HARD": ("Hint", "Use it from the inventory (I)."),
    "BOOST": ("Speed Boost", "Saved for the Obby stage. No effect here."),
    "ARMOR": ("Armor", "Blocks the next failed QA penalty."),
    "SHARD": ("Armor Shard", "Collect 2 shards to forge 1 Armor."),
    "SLOW": ("Slow", "You walk slower for 10 seconds."),
    "HINT_SMART": ("Hint", "Use it from the inventory (I)."),
    "FREEZE": ("Freeze", "Stops moving obstacles for 5 s. Saved for Stage 3."),
    "UNDO": ("Undo", "Reverts your latest wiring change."),
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


# Same positions as before, so an existing room image still lines up. The three old computer spots
# (projector, laptop, PC) are now storage places that hide parts; the old terminal is the wiring bench.
OBJS = [
    Obj("whiteboard", "whiteboard", "Work-order board", 165, 250, 100, (70, 50, 190, 110)),
    Obj("chart", "chart", "Segment chart poster", 345, 250, 90, (300, 60, 90, 90)),
    Obj("door", "door", "Exit door", 490, 250, 110, (440, 30, 100, 160)),
    Obj("cabinet", "search", "Wall cabinet", 690, 250, 110, (600, 50, 180, 110)),
    Obj("bench", "bench", "Decoder bench", 180, 420, 110, (80, 320, 200, 70)),
    Obj("toolbox", "search", "Toolbox", 580, 420, 100, (520, 330, 120, 55)),
    Obj("drawer", "search", "Parts drawer", 845, 380, 100, (800, 300, 90, 60)),
]
PAGED = ("whiteboard", "chart", "bench")


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


def sw_cx(i):
    return 360 + (15 - i) * 48 + 22


def near(pos, pt, r):
    return (pos[0] - pt[0]) ** 2 + (pos[1] - pt[1]) ** 2 <= r * r


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
        self.parts = {p: False for p in PART_NAME}                  # parts found so far
        self.spots = {sid: {"slot": self.lfsr_pick(3), "open": set()} for sid in SPOTS}
        self.s_cur = 1
        self.rnd, self.codes = 0, None                              # QA rounds cleared / current test inputs
        self.w = {s: {} for s in SEGS}                              # wiring: segment -> {pin: source}
        self.wseg, self.wcur = 0, 4                                 # current segment tab / cursor (pin, CLEAR, QA)
        self.wsrc, self.wprev, self.msel = None, None, None         # source picker / saved wire / mouse selection
        self.undo_rec = None
        self.notes, self.hints_seen = [], []
        self.hh = self.hs = self.undo = self.freeze = self.armor = self.shard = 0
        self.boost, self.slow_t = False, 0.0
        self.hearts = 3
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
        ev = dict(up=0, down=0, left=0, right=0, tap=0, back=0, click=None)
        now = time.time()
        for e in events:
            if e.type == pygame.QUIT:
                pygame.quit(); sys.exit()
            if e.type == pygame.MOUSEBUTTONDOWN:
                for i, r in enumerate(self.sw_rects):
                    if r.collidepoint(e.pos):
                        self.sw[i] = not self.sw[i]
                if e.pos[1] < SCR_H:                 # click inside the game area -> close-up panel coordinates
                    ev["click"] = (e.pos[0] * UW / SCR_W - CU_X, e.pos[1] * UH / SCR_H)
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
        for p in PART_NAME:
            if not self.parts[p]:
                self.parts[p] = True
                return self.say("[DEBUG] found %s" % PART_NAME[p])
        if self.rnd < ROUNDS:
            self.rnd += 1
            self.say("[DEBUG] QA round %d marked clear" % self.rnd)
            if self.rnd < ROUNDS: self.new_round()

    # ---------------- random (LFSR) ----------------
    def lfsr_step(self):
        q = self.lfsr
        fb = ((q >> 15) ^ (q >> 14) ^ (q >> 12) ^ (q >> 3)) & 1
        q = ((q << 1) | fb) & 0xFFFF
        self.lfsr = q if q else 0xACE1

    def lfsr_pick(self, n):              # LFSR value 0..n-1 (n <= 8): take 3 bits, retry if out of range
        while True:
            self.lfsr_step()
            v = self.lfsr & 7
            if v < n:
                return v

    def card_start(self, r):
        self.deck = {"active": True, "round": r, "perm": PERMS[self.lfsr_pick(6)], "cursor": 1, "face": None}
        self.r_run[r] = True

    def card_trigger(self):              # round 1: start | round 2: all parts found | round 3: 2 QA rounds cleared
        if self.deck["active"]:
            return
        if not self.r_run[1]: self.card_start(1)
        elif self.r_done[1] and not self.r_run[2] and all(self.parts.values()): self.card_start(2)
        elif self.r_done[2] and not self.r_run[3] and self.rnd >= 2: self.card_start(3)

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

    # ---------------- decoder wiring ----------------
    def new_round(self):                 # 2 different input codes (1..6) from the LFSR, board wiped
        first = 1 + self.lfsr_pick(6)
        second = 1 + self.lfsr_pick(5)
        if second >= first: second += 1
        self.codes = [first, second]
        self.w = {s: {} for s in SEGS}
        self.wseg, self.wcur = 0, 4
        self.wsrc, self.wprev, self.msel, self.undo_rec = None, None, None, None

    def on_of(self, k):                  # segments your wiring lights for input code k
        c, b, a = bits(k)
        return "".join(s for s in SEGS if out(self.w[s], c, b, a))

    def seg_ok(self, s):                 # segment s matches the target on both test inputs
        return all(out(self.w[s], *bits(k)) == int(s in GOLD[k]) for k in self.codes)

    def code3(self): return sum(1 << i for i in range(3) if self.sw[i])

    def wiring_live(self):
        return (self.mode == "closeup" and self.cur is not None and self.cur.kind == "bench"
                and self.page == 1 and self.codes is not None)

    def rec_undo(self):
        self.undo_rec = copy.deepcopy(self.w)

    def src_opts(self, pin):             # AND inputs take rails only; OR inputs also take the AND outputs
        return [None] + RAILS + (["g1", "g2"] if pin[0] == "o" else [])

    def set_wire(self, pin, src):
        w = self.w[SEGS[self.wseg]]
        if src is None: w.pop(pin, None)
        else: w[pin] = src

    def qa_submit(self):
        good = sum(set(self.on_of(k)) == set(GOLD[k]) for k in self.codes)
        self.notes.append("QA round %d: %d/2 inputs correct" % (self.rnd + 1, good))
        if good < 2:
            self.cmsg = "QA FAILED: %d / 2 inputs correct." % good
            return self.damage()
        self.rnd += 1
        if self.rnd >= ROUNDS:
            self.cmsg = "DECODER VERIFIED. All %d QA rounds passed." % ROUNDS
            self.say("The exit door is unlocked!")
        else:
            self.new_round()
            self.cmsg = "ROUND %d CLEAR. Board wiped, next work order loaded." % self.rnd
            self.say("QA passed!")

    def damage(self):
        if self.armor > 0:
            self.armor -= 1
            return self.say("ARMOR PROTECTED!")
        self.hearts -= 1
        self.flash = 0.4
        if self.hearts <= 0:
            self.state, self.over_until = "over", time.time() + 3.0
        else:
            self.say("QA failed! -1 heart")

    def found(self, pid):
        self.parts[pid] = True
        self.notes.append("Found %s (%s)" % (PART_NAME[pid], PART_SPOT[pid]))
        left = sum(not v for v in self.parts.values())
        self.cmsg = "You found the %s! %s" % (PART_NAME[pid], ("%d part(s) still hidden." % left) if left
                                              else "That is all 4. Bring them to the decoder bench.")
        self.say("Found: %s" % PART_NAME[pid])

    # ---------------- items ----------------
    def wiring_hint(self, exact):
        for s in SEGS:
            if self.seg_ok(s):
                continue
            t = [int(s in GOLD[k]) for k in self.codes]
            ins = ["%d%d%d" % bits(k) for k in self.codes]
            if not exact:
                return "Segment %s must be %s for input %s and %s for input %s." % (
                    s, "ON" if t[0] else "OFF", ins[0], "ON" if t[1] else "OFF", ins[1])
            if t[0] == t[1]:
                fix = "wire rail 1 into an OR input" if t[0] else "leave the OR gate unwired"
            else:
                rail = next(r for r in RAILS[:6] if [sv(r, *bits(k), {}) for k in self.codes] == t)
                fix = "wire %s straight into an OR input" % LBL[rail]
            return "Segment %s: press CLEAR, then %s." % (s, fix)
        return "Every segment already matches. Run the QA test."

    def smart_hint(self):
        missing = [p for p in PART_NAME if not self.parts[p]]
        if missing: return "A part is still hidden. Search the %s." % PART_SPOT[missing[0]]
        if self.rnd >= ROUNDS: return None
        if self.codes is None: return "All parts found. Go to the decoder bench and power it on."
        return self.wiring_hint(True)

    def show_hint(self, text):
        self.hint_popup = text
        if text not in self.hints_seen:
            self.hints_seen.append(text)

    def use_item(self, name):
        if name == "HINT_HARD":
            if self.hh == 0: return self.say("You do not have this item.")
            if self.rnd >= ROUNDS: return self.say("Not useful now: the decoder is already verified.")
            if self.codes is None: return self.say("Not useful yet: power on the decoder bench first.")
            self.hh -= 1; self.show_hint(self.wiring_hint(False))
        elif name == "HINT_SMART":
            if self.hs == 0: return self.say("You do not have this item.")
            h = self.smart_hint()
            if h is None: return self.say("Not useful now: nothing left to hint.")
            self.hs -= 1; self.show_hint(h)
        elif name == "UNDO":
            if self.undo == 0: return self.say("You do not have this item.")
            if self.undo_rec is None or self.rnd >= ROUNDS: return self.say("Nothing to undo right now.")
            self.undo -= 1
            self.w, self.undo_rec, self.wsrc, self.msel = self.undo_rec, None, None, None
            self.say("Your last wiring change was undone.")
        elif name == "FREEZE":
            if self.freeze == 0: return self.say("You do not have this item.")
            self.say("No moving obstacles here. Keep it for Stage 3.")

    def inventory_input(self, ev):
        if ev["left"]: self.inv_cur = (self.inv_cur - 1) % 4
        elif ev["right"]: self.inv_cur = (self.inv_cur + 1) % 4
        elif ev["tap"]: self.use_item(USABLE[self.inv_cur])

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
                self.mode, self.cur, self.page, self.cmsg, self.s_cur = "closeup", o, 0, "", 1

    def closeup_input(self, ev):
        o = self.cur
        if ev["back"]:
            if self.wsrc is not None:                # cancel the source picker, put the old wire back
                self.set_wire(PINS[self.wcur], self.wprev)
                self.wsrc = None
            elif self.page > 0 and o.kind in PAGED:
                self.page -= 1
            else:
                self.mode = "map"
            self.cmsg, self.msel = "", None
            return
        getattr(self, "in_" + o.kind)(ev)

    def in_whiteboard(self, ev):
        if ev["tap"]: self.page = 1 - self.page

    def in_chart(self, ev):
        if not ev["tap"]: return
        if self.page == 0: self.page = 1
        elif not self.parts["and2"]: self.found("and2")

    def in_search(self, ev):
        sp = self.spots[self.cur.id]
        if ev["left"]: self.s_cur = (self.s_cur - 1) % 3
        elif ev["right"]: self.s_cur = (self.s_cur + 1) % 3
        elif ev["tap"]:
            if self.s_cur in sp["open"]:
                self.cmsg = "You already looked in there."
                return
            sp["open"].add(self.s_cur)
            if self.s_cur == sp["slot"]: self.found(SPOTS[self.cur.id][0])
            else: self.cmsg = "Nothing useful. Just dust and old datasheets."

    def in_door(self, ev):
        if not ev["tap"]: return
        if self.rnd >= ROUNDS: self.state, self.form = "clear", 2
        else: self.cmsg = "Locked. It opens when the decoder passes QA (%d / %d)." % (self.rnd, ROUNDS)

    def in_bench(self, ev):
        if self.page == 0:
            if ev["tap"]:
                missing = [PART_NAME[p] for p in PART_NAME if not self.parts[p]]
                if missing:
                    self.cmsg = "Cannot power on. Missing: " + ", ".join(missing)
                else:
                    self.page = 1
                    if self.codes is None and self.rnd < ROUNDS:
                        self.new_round()
                        self.notes.append("All parts installed. Decoder bench powered on.")
            return
        if self.rnd >= ROUNDS: return
        if ev["click"]: return self.bench_click(ev["click"])
        if self.wsrc is not None:                    # source picker: U/D changes the wire live
            pin = PINS[self.wcur]
            opts = self.src_opts(pin)
            if ev["up"] or ev["down"]:
                self.wsrc = (self.wsrc + (-1 if ev["up"] else 1)) % len(opts)
                self.set_wire(pin, opts[self.wsrc])
            elif ev["tap"]:
                self.wsrc = None
            return
        if ev["left"] or ev["right"]:
            self.wseg = (self.wseg + (1 if ev["right"] else -1)) % 7
            self.cmsg = ""
        elif ev["up"]: self.wcur = (self.wcur - 1) % 9
        elif ev["down"]: self.wcur = (self.wcur + 1) % 9
        elif ev["tap"]:
            self.msel = None
            if self.wcur == CUR_QA: self.qa_submit()
            elif self.wcur == CUR_CLEAR:
                self.rec_undo()
                self.w[SEGS[self.wseg]] = {}
            else:
                pin = PINS[self.wcur]
                self.rec_undo()
                self.wprev = self.w[SEGS[self.wseg]].get(pin)
                self.wsrc = self.src_opts(pin).index(self.wprev)
                self.cmsg = ""

    def bench_click(self, pos):          # mouse (PC demo only): click a source, then click a pin
        if self.wsrc is not None:
            self.wsrc = None
        w = self.w[SEGS[self.wseg]]
        for i, r in enumerate(TAB_RECTS):
            if r.collidepoint(pos):
                self.wseg, self.msel, self.cmsg = i, None, ""
                return
        if BTN_QA.collidepoint(pos):
            self.wcur, self.msel = CUR_QA, None
            return self.qa_submit()
        if BTN_CLEAR.collidepoint(pos):
            self.rec_undo()
            self.w[SEGS[self.wseg]] = {}
            self.wcur, self.msel = CUR_CLEAR, None
            return
        for key in RAILS + ["g1", "g2"]:
            if near(pos, NODE[key], 14):
                self.msel = None if self.msel == key else key
                self.cmsg = ""
                return
        for i, pin in enumerate(PINS):
            if near(pos, PIN_POS[pin], 12):
                self.wcur = i
                if self.msel is None:
                    if pin in w:
                        self.rec_undo()
                        w.pop(pin)
                elif pin[0] != "o" and self.msel[0] == "g":
                    self.cmsg = "AND inputs only take C, B, A, ~C, ~B, ~A, 0 or 1."
                else:
                    self.rec_undo()
                    w[pin] = self.msel
                    self.msel, self.cmsg = None, ""
                return

    # ---------------- drawing helpers ----------------
    def txt(self, s, text, x, y, font=None, color=(255, 255, 255)):
        s.blit((font or self.f_m).render(text, True, color), (x, y))

    def ctxt(self, s, text, cx, y, font=None, color=(255, 255, 255)):
        img = (font or self.f_m).render(text, True, color)
        s.blit(img, (cx - img.get_width() // 2, y))

    def rtxt(self, s, text, rx, y, font=None, color=(255, 255, 255)):
        img = (font or self.f_m).render(text, True, color)
        s.blit(img, (rx - img.get_width(), y))

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
        o = self.find_near()
        if o:
            self.ctxt(ui, "[Space] " + o.name, int(self.px), int(self.py - SPR_H - 14), self.f_s, (255, 230, 120))
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

    def draw_target(self, s, k, x, y):               # one QA target: input code, wanted shape, your shape
        ok = set(self.on_of(k)) == set(GOLD[k])
        pygame.draw.rect(s, (18, 32, 53) if ok else (27, 41, 64), (x, y, 254, 66), border_radius=6)
        pygame.draw.rect(s, C_ON if ok else C_BORDER, (x, y, 254, 66), 2, border_radius=6)
        draw_set(s, GOLD[k], x + 12, y + 9, 28, 48, (38, 54, 76))
        self.txt(s, "CBA = %d%d%d" % bits(k), x + 52, y + 12, self.f_s, (143, 161, 184))
        self.txt(s, "show  %s" % CHAR_NAME[k], x + 52, y + 34, self.f_m)
        self.txt(s, "yours", x + 140, y + 27, self.f_tiny, (143, 161, 184))
        draw_set(s, self.on_of(k), x + 172, y + 9, 28, 48, (38, 54, 76))
        self.txt(s, "OK" if ok else "--", x + 214, y + 24, self.f_m, C_ON if ok else (143, 161, 184))

    def cu_whiteboard(self, s):
        pygame.draw.rect(s, (240, 240, 235), (40, 56, 560, 376), border_radius=6)
        ink = (30, 40, 130)
        if self.page == 0:
            lines = ["WORK ORDER #402", "Build the 7-segment decoder.",
                     "1. Find 4 parts hidden in this room.", "2. Install them on the decoder bench.",
                     "3. Wire each segment a-g, pass 3 QA tests.", "",
                     "input CBA -> character", "001 = C   010 = P   011 = E", "100 = -   101 = 3   110 = 9",
                     "(000 and 111 never occur)"]
            for i, l in enumerate(lines): self.txt(s, l, 62, 70 + i * 35, self.f_mono, ink)
            return "BTNC: next page"
        self.txt(s, "QA TEST %d of %d" % (min(self.rnd + 1, ROUNDS), ROUNDS), 70, 76, self.f_mono_l, ink)
        if self.rnd >= ROUNDS:
            self.txt(s, "All QA tests passed. Go to the exit door.", 70, 140, self.f_m, (20, 120, 40))
        elif self.codes is None:
            self.blit_wrap(s, "The QA inputs appear here once the decoder bench is powered on.", 70, 140, 500, self.f_m, ink)
        else:
            for i, k in enumerate(self.codes):
                self.txt(s, "input CBA = %d%d%d  ->  show %s" % (bits(k) + (CHAR_NAME[k],)), 70, 140 + i * 130, self.f_mono, ink)
                draw_set(s, GOLD[k], 470, 126 + i * 130, 54, 92, (215, 215, 210))
        return "BTNC: previous page"

    def cu_chart(self, s):
        pygame.draw.rect(s, (245, 240, 220), (40, 56, 560, 376), border_radius=4)
        ink = (40, 40, 40)
        if self.page == 0:
            self.txt(s, "7-SEGMENT CHART", 60, 68, self.f_m, ink)
            draw_set(s, "abcdefg", 80, 120, 90, 150, (215, 210, 195))
            for sg, (lx, ly) in {"a": (125, 100), "b": (180, 150), "c": (180, 222), "d": (125, 274),
                                 "e": (62, 222), "f": (62, 150), "g": (125, 176)}.items():
                self.ctxt(s, sg, lx, ly, self.f_m, (255, 255, 255) if sg == "g" else ink)
            for i, k in enumerate(sorted(GOLD)):
                x, y = 250 + (i % 3) * 112, 106 + (i // 3) * 150
                draw_set(s, GOLD[k], x, y, 50, 86, (215, 210, 195))
                self.ctxt(s, "%d%d%d = %s" % (bits(k) + (CHAR_NAME[k],)), x + 25, y + 94, self.f_s, ink)
            return "BTNC: look closer"
        self.txt(s, "One corner of the poster is loose.", 70, 80, self.f_m, ink)
        pygame.draw.polygon(s, (215, 205, 175), [(430, 300), (560, 300), (560, 400)])
        pygame.draw.polygon(s, (190, 180, 150), [(430, 300), (560, 400), (470, 392)])
        if self.parts["and2"]:
            self.txt(s, "The AND gate that was taped here is yours now.", 70, 130, self.f_s, (20, 120, 40))
            return ""
        self.txt(s, "Something small is taped behind it...", 70, 130, self.f_s, ink)
        return "BTNC: peel the corner"

    def cu_search(self, s):
        pid, word = SPOTS[self.cur.id]
        sp = self.spots[self.cur.id]
        pygame.draw.rect(s, (58, 48, 40), (40, 56, 560, 376), border_radius=6)
        self.ctxt(s, "Three places to look. Open them one by one.", 320, 76, self.f_s, (225, 215, 200))
        for i in range(3):
            r = pygame.Rect(70 + i * 175, 120, 150, 250)
            is_open = i in sp["open"]
            pygame.draw.rect(s, (22, 18, 16) if is_open else (130, 100, 70), r, border_radius=6)
            if is_open and i == sp["slot"]:
                pygame.draw.rect(s, (25, 25, 30), (r.centerx - 30, r.centery - 18, 60, 36), border_radius=4)
                for px in range(4):
                    pygame.draw.line(s, (190, 190, 200), (r.centerx - 21 + px * 14, r.centery - 26), (r.centerx - 21 + px * 14, r.centery + 26), 3)
                pygame.draw.rect(s, (25, 25, 30), (r.centerx - 30, r.centery - 18, 60, 36), border_radius=4)
                self.ctxt(s, PART_NAME[pid], r.centerx, r.centery + 40, self.f_s, (150, 255, 170))
                self.ctxt(s, "TAKEN", r.centerx, r.centery + 62, self.f_tiny, (150, 255, 170))
            elif is_open:
                self.ctxt(s, "empty", r.centerx, r.centery - 8, self.f_s, (120, 110, 100))
            else:
                self.ctxt(s, "%s %d" % (word, i + 1), r.centerx, r.centery - 10, self.f_m, (240, 230, 215))
                pygame.draw.circle(s, (60, 45, 30), (r.centerx, r.centery + 30), 7)
            if i == self.s_cur:
                pygame.draw.rect(s, C_SEL, r.inflate(10, 10), 4, border_radius=9)
        return "L/R choose | BTNC open"

    def cu_door(self, s):
        pygame.draw.rect(s, (120, 85, 55), (240, 56, 160, 250), border_radius=6)
        done = self.rnd >= ROUNDS
        pygame.draw.circle(s, C_ON if done else (220, 60, 60), (376, 185), 9)
        self.ctxt(s, "UNLOCKED" if done else "LOCKED", 320, 320, self.f_l, C_ON if done else (255, 120, 120))
        self.ctxt(s, "Decoder QA: %d / %d" % (self.rnd, ROUNDS), 320, 362, self.f_m)
        if not done:
            self.ctxt(s, "The lock is wired to the decoder bench.", 320, 394, self.f_s, (200, 200, 210))
        return "BTNC: leave the lab" if done else "BTNC: try the handle"

    def cu_bench(self, s):
        if self.page == 0:
            pygame.draw.rect(s, (10, 20, 10), (40, 60, 560, 360), border_radius=6)
            g = (110, 255, 130)
            self.txt(s, "DECODER BENCH - PARTS SOCKETS", 56, 76, self.f_mono, g)
            for i, p in enumerate(PART_NAME):
                have = self.parts[p]
                y = 124 + i * 46
                pygame.draw.rect(s, (30, 70, 40) if have else (40, 30, 30), (56, y, 528, 38), border_radius=5)
                self.txt(s, "[OK]" if have else "[  ]", 66, y + 9, self.f_mono, g if have else (255, 120, 120))
                self.txt(s, "%-13s %s" % (PART_NAME[p], ("installed: " + PART_USE[p]) if have else "MISSING - search the room"),
                         122, y + 9, self.f_mono, g if have else (255, 170, 150))
            if self.rnd >= ROUNDS: self.txt(s, "DECODER VERIFIED.", 56, 330, self.f_mono, (255, 255, 120))
            elif all(self.parts.values()): self.txt(s, "All parts installed. Ready to power on.", 56, 330, self.f_mono, (255, 255, 120))
            else: self.txt(s, "Bring all 4 parts here to power the board.", 56, 330, self.f_mono, g)
            return "BTNC: power on / open the wiring board"
        return self.draw_wiring(s)

    def draw_wiring(self, s):
        seg = SEGS[self.wseg]
        w = self.w[seg]
        c, b, a = bits(self.code3())
        done = self.rnd >= ROUNDS
        muted = (143, 161, 184)
        # QA targets + round box
        for i, k in enumerate(self.codes):
            self.draw_target(s, k, 16 + i * 262, 50)
        pygame.draw.rect(s, C_PANEL, (540, 50, 84, 66), border_radius=6)
        self.ctxt(s, "ROUND", 582, 58, self.f_tiny, muted)
        self.ctxt(s, "%d / %d" % (min(self.rnd + 1, ROUNDS), ROUNDS), 582, 78, self.f_m)
        # segment tabs, CLEAR, RUN QA
        for i, r in enumerate(TAB_RECTS):
            pygame.draw.rect(s, (14, 165, 233) if i == self.wseg else (27, 41, 64), r, border_radius=4)
            self.ctxt(s, SEGS[i], r.centerx - 5, r.y + 3, self.f_m)
            pygame.draw.circle(s, C_ON if self.seg_ok(SEGS[i]) else (120, 60, 60), (r.right - 9, r.centery), 4)
        for r, label, idx in ((BTN_CLEAR, "CLEAR", CUR_CLEAR), (BTN_QA, "RUN QA TEST", CUR_QA)):
            hot = self.wcur == idx and not done
            pygame.draw.rect(s, C_SEL if hot else (27, 41, 64), r, border_radius=4)
            self.ctxt(s, label, r.centerx, r.y + 5, self.f_s, (20, 20, 20) if hot else (255, 255, 255))
        # board
        pygame.draw.rect(s, C_PANEL, (16, 152, 608, 270), border_radius=6)
        pygame.draw.rect(s, C_BORDER, (16, 152, 608, 270), 1, border_radius=6)
        cur_pin = PINS[self.wcur] if self.wcur < 7 else None
        picking = self.wsrc is not None
        if done: status = "Decoder verified. The exit door is unlocked."
        elif picking: status = "%s  <-  %s" % (PIN_LBL[cur_pin], LBL.get(w.get(cur_pin), "(no wire)"))
        elif self.msel: status = "Selected %s  ->  now click a pin" % LBL[self.msel]
        elif cur_pin: status = "%s  =  %s" % (PIN_LBL[cur_pin], LBL.get(w.get(cur_pin), "(no wire)"))
        else: status = "Press BTNC" if self.wcur == CUR_QA else "Press BTNC to remove every wire of segment %s" % seg
        self.txt(s, "SEGMENT %s   |   %s" % (seg, status), 100, 156, self.f_tiny, C_SEL if picking else muted)
        # wires (drawn first so they pass under the gates)
        for pin in PINS:
            if pin not in w: continue
            src = w[pin]
            (sx, sy), (tx, ty) = NODE[src], PIN_POS[pin]
            ex = G_ELBOW[pin] if src[0] == "g" else ELBOW[pin]
            col = C_SEL if (picking and pin == cur_pin) else (C_ON if sv(src, c, b, a, w) else C_OFF)
            pygame.draw.lines(s, col, False, [(sx + 9, sy), (ex, sy), (ex, ty), (tx - 7, ty)], 3)
        # source rails
        for key in RAILS:
            x, y = NODE[key]
            v = sv(key, c, b, a, w)
            self.rtxt(s, LBL[key], x - 16, y - 8, self.f_s)
            pygame.draw.circle(s, C_ON if v else (23, 34, 56), (x, y), 9)
            pygame.draw.circle(s, C_ON if v else C_BORDER, (x, y), 9, 2)
        # AND gates
        for label, (p1, p2, gk) in (("AND 1", ("a1", "a2", "g1")), ("AND 2", ("b1", "b2", "g2"))):
            gx, gy = NODE[gk]
            box = pygame.Rect(210, gy - 32, 64, 64)
            v = sv(gk, c, b, a, w)
            for p in (p1, p2): pygame.draw.line(s, C_BORDER, PIN_POS[p], (box.x, PIN_POS[p][1]), 2)
            pygame.draw.line(s, C_ON if v else C_OFF, (box.right, gy), (gx, gy), 3)
            pygame.draw.rect(s, C_GATE, box, border_top_right_radius=30, border_bottom_right_radius=30)
            pygame.draw.rect(s, C_BORDER, box, 2, border_top_right_radius=30, border_bottom_right_radius=30)
            self.ctxt(s, label, box.centerx - 4, box.centery - 7, self.f_s)
            pygame.draw.circle(s, C_ON if v else (23, 34, 56), (gx, gy), 9)
            pygame.draw.circle(s, C_ON if v else C_BORDER, (gx, gy), 9, 2)
        # OR gate + segment lamp
        res = out(w, c, b, a)
        for p in ("o1", "o2", "o3"): pygame.draw.line(s, C_BORDER, PIN_POS[p], (398, PIN_POS[p][1]), 2)
        pygame.draw.line(s, C_ON if res else C_OFF, (452, 270), (476, 270), 3)
        orp = [(392, 238), (428, 238), (456, 270), (428, 302), (392, 302), (402, 270)]
        pygame.draw.polygon(s, C_GATE, orp)
        pygame.draw.polygon(s, C_BORDER, orp, 2)
        self.ctxt(s, "OR", 426, 263, self.f_s)
        pygame.draw.circle(s, C_ON if res else (23, 34, 56), (488, 270), 12)
        pygame.draw.circle(s, C_ON if res else C_BORDER, (488, 270), 12, 2)
        self.ctxt(s, str(res), 488, 263, self.f_s, (6, 17, 26) if res else muted)
        self.ctxt(s, "seg %s" % seg, 488, 288, self.f_s)
        # pins + cursors
        for pin in PINS:
            pygame.draw.circle(s, C_ON if pin in w else C_PANEL, PIN_POS[pin], 6)
            pygame.draw.circle(s, C_ON if pin in w else muted, PIN_POS[pin], 6, 2)
        if not done:
            if cur_pin: pygame.draw.circle(s, C_SEL, PIN_POS[cur_pin], 11, 3)
            if picking and w.get(cur_pin): pygame.draw.circle(s, C_SEL, NODE[w[cur_pin]], 14, 3)
            if self.msel: pygame.draw.circle(s, C_MOUSE, NODE[self.msel], 14, 3)
        # live 7-segment output for the switch input
        k = self.code3()
        pygame.draw.rect(s, (7, 13, 23), (528, 172, 84, 132), border_radius=6)
        draw_set(s, self.on_of(k), 544, 184, 52, 92, (38, 54, 76))
        self.ctxt(s, "INPUT %d%d%d" % (c, b, a), 570, 312, self.f_s)
        self.ctxt(s, "SW2 SW1 SW0", 570, 332, self.f_tiny, muted)
        self.ctxt(s, ("should show %s" % CHAR_NAME[k]) if k in CHAR_NAME else "(never occurs)", 570, 350, self.f_tiny, muted)
        if done: return "Decoder verified. Leave through the exit door."
        if picking: return "U/D change source | BTNC confirm | hold BTNC = cancel"
        return "U/D pin | L/R segment | BTNC wire or press | SW2-SW0 test input | mouse also works"

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
        names = ["Hint (wiring)", "Hint (smart)", "Undo", "Freeze"]
        for i in range(4):
            r = pygame.Rect(110 + i * 108, 130, 100, 90)
            pygame.draw.rect(s, (255, 230, 120) if i == self.inv_cur else (70, 74, 100), r, border_radius=8)
            col = (20, 20, 20) if i == self.inv_cur else (255, 255, 255)
            self.ctxt(s, names[i], r.centerx, r.y + 14, self.f_s, col)
            self.ctxt(s, "x%d" % counts[i], r.centerx, r.y + 46, self.f_l, col)
        have = [PART_NAME[p] for p in PART_NAME if self.parts[p]]
        self.txt(s, "Parts %d / 4:  %s" % (len(have), ", ".join(have) or "none yet"), 110, 240, self.f_s, (150, 255, 170))
        self.txt(s, "Armor x%d   (shields a failed QA penalty)" % self.armor, 110, 268, self.f_s)
        self.txt(s, "Armor shards %d / 2   (2 shards = 1 armor)" % self.shard, 110, 294, self.f_s)
        self.txt(s, "Speed Boost: %s   (used in Stage 3)" % ("yes" if self.boost else "no"), 110, 320, self.f_s)
        self.txt(s, "Slow: %s" % (("%.0f s left" % self.slow_t) if self.slow_t > 0 else "off"), 110, 346, self.f_s)
        self.ctxt(s, "L/R select   BTNC use", 320, 386, self.f_s, (170, 200, 255))

    def draw_notebook(self, s):
        self.draw_box(s, pygame.Rect(60, 50, 520, 420))
        self.ctxt(s, "NOTEBOOK  (SW14 / key N to close)", 320, 62, self.f_m)
        self.txt(s, "Parts found: %d / 4     QA rounds passed: %d / %d" % (sum(self.parts.values()), self.rnd, ROUNDS),
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
        self.draw_box(s, pygame.Rect(30, 50, 580, 440))
        self.ctxt(s, "STAGE 2: INTERNSHIP - HOW TO PLAY", 320, 64, self.f_l)
        rows = [("Move", "W A S D / arrows   (BTNU BTND BTNL BTNR)"),
                ("Interact / confirm", "Space   (BTNC tap)"),
                ("Back / cancel", "hold Space 0.8 s, or Esc   (BTNC hold)"),
                ("Test input C B A", "keys 3 2 1 = SW2 SW1 SW0, or click them below"),
                ("Inventory", "I   (SW15)"),
                ("Notebook", "N   (SW14)"),
                ("This help", "H"),
                ("Debug", "F1-F4 form, F5 skip a step, F6 collision")]
        for i, (a, b) in enumerate(rows):
            self.txt(s, a, 54, 114 + i * 29, self.f_s, (255, 230, 120))
            self.txt(s, b, 220, 114 + i * 29, self.f_s)
        self.blit_wrap(s, "Search the room for 4 logic parts, bring them to the decoder bench, wire the "
                          "7-segment decoder through 3 QA rounds, then leave by the exit door. "
                          "A failed QA test costs 1 heart.", 54, 356, 532, self.f_s, (170, 200, 255), 22)
        self.ctxt(s, "Press Space to start", 320, 452, self.f_m, (150, 255, 170))

    def draw_hud(self, ui):
        for i in range(3):
            col = (230, 50, 60) if i < self.hearts else (80, 50, 50)
            pygame.draw.circle(ui, col, (24 + i * 26, 22), 10)
        if self.armor > 0:
            pygame.draw.rect(ui, (80, 180, 255), (96, 12, 18, 22), border_radius=4)
            self.txt(ui, "x%d" % self.armor, 118, 14, self.f_s, (120, 200, 255))
        if self.slow_t > 0:
            self.txt(ui, "SLOW %.0fs" % self.slow_t, 16, 40, self.f_s, (255, 150, 80))
        self.rtxt(ui, "Parts %d/4" % sum(self.parts.values()), UW - 14, 10, self.f_s, (150, 255, 170))
        self.rtxt(ui, "QA %d/%d" % (self.rnd, ROUNDS), UW - 14, 28, self.f_s, (255, 230, 120))

    def draw_toast(self, ui):
        if time.time() < self.toast[1]:
            img = self.f_m.render(self.toast[0], True, (255, 255, 255))
            r = pygame.Rect(UW // 2 - img.get_width() // 2 - 12, 44, img.get_width() + 24, 34)
            pygame.draw.rect(ui, (0, 0, 0), r, border_radius=8)
            ui.blit(img, (r.x + 12, r.y + 7))

    def seg_right(self):
        if self.state == "clear": return "PA55"
        if self.state == "over": return "dEAd"
        if self.wiring_live() and not self.deck["active"]:
            return "%d%d%d " % bits(self.code3())            # last digit is replaced by the live decoder output
        return ""

    def draw_panel(self, scr):
        y0 = SCR_H
        pygame.draw.rect(scr, (24, 26, 32), (0, y0, SCR_W, PANEL_H))
        pygame.draw.line(scr, (70, 74, 90), (0, y0), (SCR_W, y0), 2)
        leds = [False] * 16
        for i in range(3): leds[i] = self.hearts > i
        leds[3] = self.armor > 0
        for i, p in enumerate(PART_NAME): leds[4 + i] = self.parts[p]
        for i in range(ROUNDS): leds[8 + i] = self.rnd > i
        leds[11] = self.slow_t > 0
        for i in range(16):
            pygame.draw.circle(scr, (255, 70, 60) if leds[i] else (70, 40, 40), (sw_cx(i), y0 + 18), 7)
        for i in range(16):
            r = self.sw_rects[i]
            pygame.draw.rect(scr, (230, 230, 230) if self.sw[i] else (80, 80, 90), r, border_radius=5)
            self.ctxt(scr, "SW%d" % i, r.centerx, r.y + 11, self.f_tiny, (20, 20, 20) if self.sw[i] else (200, 200, 200))
        text = ("H%d" % max(0, self.hearts)) + self.seg_right().rjust(6)[-6:]
        glyphs = [SEG_MAP.get(ch, "g") for ch in text]
        if self.state == "play" and self.wiring_live() and not self.deck["active"]:
            glyphs[7] = self.on_of(self.code3())
        for i, on in enumerate(glyphs):
            draw_set(scr, on, 14 + i * 40, y0 + 26, 32, 52)
        self.txt(scr, "7-SEG: H3 = hearts | at the bench: C B A + decoder output", 14, y0 + 84, self.f_tiny, (170, 170, 190))
        self.txt(scr, "LED: 0-2 hearts  3 armor  4-7 parts  8-10 QA rounds  11 slow", 360, y0 + 78, self.f_tiny, (140, 140, 160))
        self.txt(scr, "Move WASD | BTNC = Space (hold = back) | SW0-7 = keys 1-8 or click | I inventory | N notebook | H help",
                 360, y0 + 94, self.f_tiny, (170, 170, 190))
        self.txt(scr, "Form: %s" % FORM_NAMES[self.form], 14, y0 + 98, self.f_tiny, (140, 140, 160))

    def draw(self, ui, screen):
        ui.fill((18, 20, 26))
        s = ui.subsurface(pygame.Rect(CU_X, 0, CU_W, UH))
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
