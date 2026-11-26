#!/usr/bin/env python3
"""cr_model.py - integer model of onlystage_3/game.py, the reference cr_core.v must match bit for bit.
One step = 1/120 s. No file or pygame code here.

Numbers: lengths in units, 1 m = Q = 600*4096, so every horizontal speed is a whole number per step.
The player's state (xf, yf, vxf, vyf, gf) carries VF = 8 more fraction bits: with whole-unit values one double
jump could drift 2 mm (gravity) or reach a wall a step late (sideways speed). Speeds are per step, gravity per step per step. Timers are step counts.
"""
from collections import deque
from math import isqrt


DT = 1 / 120        # the game's float step (settings.TICK)
EPS = 1e-7          # game.EPS

Q = 600 * 4096
VF = 8
F = 1 << VF
WIDTH_M, HEIGHT_ROWS = 250, 11
LEVEL_W = WIDTH_M * Q
HALF_W = 774144                          # PLAYER_WIDTH / 2 = 0.315 m
PH = 3686400                             # PLAYER_HEIGHT = 1.5 m
NEAR = Q // 10                           # move(): blocks within 0.1 m of the body
# Vertical tolerance. Jumps are designed to come back to exactly the takeoff height on an exact step; the float
# game is then within 1e-12 m and its EPS absorbs that. Integer rounding is about 44 units (18 um) at worst
# seen, so the tolerance here is 128 units (52 um), not the game's 0.25 units.
TIE_F = 128 * F
TIE_X = F                                # sideways: one unit covers the double-jump speed rounding (< 0.6 unit)
RUN = 102400                             # 5 m/s per step
G_F = round(8 * 2.5 / .7 ** 2 * Q / 14400 * F)        # normal gravity
JUMP_VY_F = round(8 * 2.5 / .7 ** 2 * .35 * Q / 120 * F)
DOUBLE_H = 9 * Q // 2                    # 4.5 m
DOUBLE_RANGE = 11 * Q // 2               # 5.5 m
DOUBLE_STEPS = 144                       # 1.2 s
DOUBLE_LAST = 134                        # a second jump is allowed while elapsed <= this
MIN_RISE = Q // 50                       # 0.02 m
SPAWNS = {1: (6, 3), 2: (5, 3), 3: (6, 3)}
HALF_F, NEAR_F = HALF_W * F, NEAR * F
SEED = 0xACE1

# animals
SPECIES = ("snail", "squirrel", "ant", "goose")
PATROL, WALK, FLY, POP = range(4)
ENEMY = 40960                            # 2 m/s per step
ANIMAL_H = 2106514                       # 1.5 / 1.75 m, rounded
HALF_GOOSE, HALF_OTHER = 1105920, 811008  # half of 0.9 m and 0.66 m
WALK_G = 5120                            # 30 m/s^2 per step per step
SINK_WATER = 57344                       # 2.8 m/s
ANT_CYCLE, ANT_HIDDEN, ANT_RAMP = 720, 240, 120      # steps: hidden 2 s, rise 1, above 2, fall 1
FOLLOW = 60                              # a follower is 0.5 s behind its leader


def timer_steps(seconds, limit):
    """How many times does the float game subtract DT from a timer before the timer is <= limit?

    The game keeps timers as floats:  t = seconds, then every step  t -= DT.  The hardware keeps a whole
    number of steps instead, so it needs the exact step on which the float game's condition flips -
    including the rounding residue (0.15 s is NOT 18 steps in the game).

    limit is 0 for a timer the game tests with `t > 0` (or `t <= 0`), and EPS for one tested with `t < EPS`.
    Returns an int. Example: timer_steps(0.15, 0) == 19.
    """
    t, n = seconds, 0
    while t > limit:        # replay the game's own float countdown, rounding residue included
        t -= DT
        n += 1
    return n


# ---------------- flow, reporter, skills, objects ----------------
PLAY, PAUSE, CLEAR, WIN = range(4)
(MSG_NONE, MSG_NEW, MSG_TIMEUP, MSG_SPLASH, MSG_FELL, MSG_STAGE2, MSG_STAGE3, MSG_NEED_CHASE, MSG_PICK_TEA,
 MSG_TEA, MSG_REPORTER, MSG_NEAR1, MSG_NEAR2, MSG_NEAR3, MSG_NEED_TEA) = range(15)
T_LIMIT = timer_steps(120, 0)
T_NOTICE = timer_steps(2.0, 0)
T_FLASH = timer_steps(.45, 0)
T_PROTECT = timer_steps(.65, 0)
T_PROTECT_AFTER = timer_steps(1.0, 0)
T_SKILL = timer_steps(5, EPS)
T_INTERVIEW = timer_steps(5, EPS)
T_FOLLOW = timer_steps(.6, EPS)
T_RETREAT = timer_steps(2.0, EPS)
T_CLEAR = timer_steps(2.0, EPS)
T_GROW = 360                             # tea: sprite 8 % bigger for 3 s
QUESTIONS = 15
ROUTE_OLD = 34                           # reporter delay 0.28 s: newest entry at least 34 steps old
TRAIL = 512
GAP = 2826240                            # 1.15 m
GAP_STILL = 8 * Q // 5                   # 1.6 m
NEAR_PLAYER = 17 * Q // 20               # 0.85 m
RETREAT_STEP = 61440                     # 3 m/s
FEET = Q // 50                           # 0.02 m
TOL_Y, TOL_X = 128, 2                    # tolerances for comparisons in whole units
LIFT_LOW, LIFT_HIGH = 3 * Q, 5 * Q
LIFT_SPEED, SINK_SPEED = 16384, 12288    # 0.8 and 0.6 m/s
PUZZLE_X, PUZZLE_Y = 240 * Q, 5 * Q
TEA_VX, TEA_VY, TEA_G = 53248, 6 * Q // 120, 4096
TEA_STOP = PUZZLE_X + 19 * Q // 10
TEA_HALF, TEA_H = 5 * Q // 8, 17 * Q // 10
# door: x, y, width, height
DOORS = {1: (245 * Q, 2 * Q, 5 * Q, 23 * Q // 10), 2: (607518720, 2 * Q, 3 * Q // 2, 23 * Q // 10),
         3: (246 * Q, 2 * Q, 4 * Q, 23 * Q // 10)}


class Lfsr16:
    """fpga/rtl/common/lfsr16.v. A draw advances it 16 times so consecutive draws share no bits."""

    def __init__(self, seed=SEED):
        self.q = seed or SEED

    def step(self):
        q = self.q
        fb = (q >> 15 ^ q >> 14 ^ q >> 12 ^ q >> 3) & 1
        self.q = ((q << 1 | fb) & 0xFFFF) or SEED

    def choice(self, n):
        for _ in range(16):
            self.step()
        return self.q * n >> 16

    def pair(self, n):
        """two different indices below n (random.sample of 2)"""
        i = self.choice(n)
        j = self.choice(n - 1)
        return i, j + (j >= i)


class Animal:
    def __init__(self, e, skin):
        u = lambda v: round(v * Q)
        self.species = SPECIES.index(e["species"])
        self.motion = ("patrol", "walk", "fly", "pop").index(e["motion"])
        self.x, self.y, self.base_y = u(e["x"]), u(e["y"]), u(e["base_y"])
        self.lo, self.hi, self.trigger = u(e["lo"]), u(e["hi"]), u(e["trigger"])
        self.leader, self.active, self.alive = e["leader"], e["active"], True
        self.skin, self.direction, self.vy = skin, -1, 0
        self.age = 0                     # steps, saturates; only a follower needs "at least 61"
        self.phase = 0                   # ant: steps into its 6 s cycle
        self.exposure = 0 if self.motion == POP else ANT_RAMP
        self.waterline = None
        self.path = deque()              # follower: the leader's last 61 (x, y, direction)
        self.edges, self.marks = e["edges"], 0     # cr_assets.edge_bits()


COYOTE = timer_steps(.15, 0)
BUFFER = timer_steps(.15, 0)


class Model:
    def __init__(self, tables, seed=SEED):
        """tables[stage] = (solid column words, water column words, entities with "nskins")"""
        self.tables = tables
        self.rng = Lfsr16(seed)
        self.stage = 1
        self.no_animals = False
        self.died = False
        self.exit_req = False
        self.restart()

    def restart(self, message=MSG_NONE):
        self.solid, self.water = self.tables[self.stage][0], self.tables[self.stage][1]
        sx, sy = SPAWNS[self.stage]
        self.xf, self.yf, self.vyf = sx * Q * F, sy * Q * F, 0
        self.facing, self.grounded, self.walking = 1, False, False
        self.jumps, self.elapsed, self.takeoff = 0, 0, 0
        self.gf, self.vxf = G_F, RUN * F
        self.grace, self.buffer = 0, 0
        self.stride, self.cam = 0, 0
        self.extra = []                  # boxes outside the grid: (x, yf, width, heightf) - puzzle, lifts
        ents = [Animal(e, self.rng.choice(e["nskins"])) for e in self.tables[self.stage][2]]
        self.ents = [] if self.no_animals else ents
        self.contacts = set()
        # flow
        self.mode, self.exit_req = PLAY, False
        self.time_left, self.clear_left = T_LIMIT, 0
        self.used, self.near, self.chase = False, False, False
        self.skill = self.interview = self.protection = self.retreat = self.follow = 0
        self.flash = self.grow = 0
        self.questions = ()
        self.gold, self.opened, self.tea = self.stage == 3, False, None      # tea = [x, y, vy]
        # [column, top, sinking, direction]
        self.lifts = [[163, 4 * Q, False, 1], [208, 5 * Q, True, 1]] if self.stage == 3 else []
        if self.stage == 2:
            self.extra.append((PUZZLE_X * F, PUZZLE_Y * F, Q * F, Q * F))
        if self.no_animals:
            self.lifts = []              # physics-only tests: no animals and no lifts
        self.extra += [self.lift_box(lift) for lift in self.lifts]
        # reporter: x in units, y and vy with VF fraction bits
        self.rx, self.ry, self.rvy, self.rdir = sx * Q, sy * Q * F, 0, 1
        self.rvisible, self.rwalking = True, False
        self.route = deque([(0, sx * Q, sy * Q, 1, False, False)])   # (step, x, y, dir, walking, grounded)
        self.trail = deque(maxlen=TRAIL)
        self.now = 0                                                  # steps since the restart
        self.notify(message)

    def notify(self, message):
        self.message, self.notice = message, T_NOTICE if message else 0

    def new_game(self):
        self.stage = 1
        self.restart(MSG_NEW)

    def pause_toggle(self):
        if self.mode in (PLAY, PAUSE):
            self.mode = PAUSE if self.mode == PLAY else PLAY

    def confirm(self):
        if self.mode == WIN:
            self.exit_req = True

    @property
    def seconds(self):
        return (self.time_left + 119) // 120

    @property
    def skill_digit(self):
        return min(5, (self.skill + 119) // 120) if self.mode in (PLAY, PAUSE) else 0

    @property
    def question_index(self):
        return int(self.interview <= T_INTERVIEW // 2)

    @property
    def progress(self):
        if self.mode in (CLEAR, WIN):
            return 100
        spawn = SPAWNS[self.stage][0] * Q
        return min(max(100 * (self.px - spawn) // (DOORS[self.stage][0] - spawn), 0), 99)

    def teleport(self, x, y, grounded):
        self.xf, self.yf, self.vyf, self.grounded = x * F, y * F, 0, grounded
        self.cam = min(max(x - 7 * Q, 0), LEVEL_W - 20 * Q)

    @property
    def px(self):
        """player x in whole units, for everything outside the physics"""
        return self.xf >> VF

    def x_units(self):
        return self.xf / F

    def y_units(self):
        return self.yf / F

    # ---- boxes: (xf, yf, widthf, heightf) ----
    def boxes(self, lo, hi):
        """every block overlapping lo < x < hi, in the game's list order: map rows top to bottom,
        left to right, then the extra boxes"""
        cell = Q * F
        first, last = max(lo // cell, 0), min((hi - 1) // cell, WIDTH_M - 1)
        for r in range(HEIGHT_ROWS - 1, -1, -1):
            for c in range(first, last + 1):
                if self.solid[c] >> r & 1:
                    yield (c * cell, r * cell, cell, cell)
        for box in self.extra:
            if box[0] < hi and box[0] + box[2] > lo:
                yield box

    def under(self, box):
        """is the player horizontally over / under this box"""
        return self.xf + HALF_F > box[0] + TIE_X and self.xf - HALF_F < box[0] + box[2] - TIE_X

    def touches(self, box):
        """player body against a box (Box.touches with its tolerance)"""
        by, bh = box[1], box[3]
        return self.under(box) and self.yf < by + bh - TIE_F and self.yf + PH * F > by + TIE_F

    def touches_water(self):
        cell = Q * F
        first = max((self.xf - HALF_F) // cell, 0)
        last = min((self.xf + HALF_F - 1) // cell, WIDTH_M - 1)
        return any(self.water[c] >> r & 1 and self.touches((c * cell, r * cell, cell, cell))
                   for c in range(first, last + 1) for r in range(HEIGHT_ROWS))

    # ---- game.py try_jump() / move() ----
    def try_jump(self):
        if self.grounded or (self.jumps == 0 and self.grace > 0):
            self.grounded, self.grace, self.buffer = False, 0, 0
            self.jumps, self.takeoff, self.elapsed = 1, self.yf, 0
            self.gf, self.vyf, self.vxf = G_F, JUMP_VY_F, RUN * F
        elif self.jumps == 1 and self.elapsed <= DOUBLE_LAST:
            if self.vyf < 0:                      # about to land: keep the press for the ground jump
                b = max(self.buffer - 1, 0)       # the float buffer is (count - 1)/120 s
                reach = -self.vyf * b + self.gf * b * b // 2
                for box in self.boxes(self.xf - HALF_F, self.xf + HALF_F):
                    if self.under(box) and -TIE_F <= self.yf - (box[1] + box[3]) <= reach:
                        return
            n = DOUBLE_STEPS - self.elapsed
            rise = max(MIN_RISE, (self.takeoff + DOUBLE_H * F - self.yf) >> VF)
            s = isqrt(rise << 16) + isqrt(DOUBLE_H << 16)
            self.gf = ((2 * s * s << VF) >> 16) // (n * n)
            self.vyf = isqrt(2 * self.gf * (rise << VF))
            self.vxf = min(max(((DOUBLE_RANGE - RUN * self.elapsed) << VF) // n, 0), RUN * F)
            self.jumps, self.buffer = 2, 0

    def move(self, axis, jump):
        if jump:
            self.buffer = BUFFER
        if self.buffer > 0:
            self.try_jump()
        old_xf, old_yf = self.xf, self.yf
        if axis:
            self.facing = axis
        self.xf = min(max(self.xf + axis * self.vxf, HALF_F), LEVEL_W * F - HALF_F)
        near = list(self.boxes(self.xf - HALF_F - NEAR_F, self.xf + HALF_F + NEAR_F))
        for box in near:                           # X pass
            if axis and self.touches(box):
                bx, bw = box[0], box[2]
                self.xf = min(self.xf, bx - HALF_F) if axis > 0 else max(self.xf, bx + bw + HALF_F)
        dy = self.vyf - (self.gf >> 1)             # Y pass: exact for constant gravity
        self.vyf -= self.gf
        self.yf += dy
        self.grounded = False
        for box in near:
            if not self.under(box):
                continue
            by, bh = box[1], box[3]
            if dy <= 0 and old_yf >= by + bh - TIE_F and self.yf <= by + bh + TIE_F:
                self.yf, self.vyf, self.grounded = by + bh, 0, True
            if dy > 0 and old_yf + PH * F <= by + TIE_F and self.yf + PH * F >= by - TIE_F:
                self.yf, self.vyf = by - PH * F, 0
                self.head_bump(box)
        if self.grounded:
            self.grace, self.jumps, self.vxf, self.gf = COYOTE, 0, RUN * F, G_F
            if self.buffer > 0:
                self.try_jump()
        else:
            self.elapsed = min(self.elapsed + 1, 255)      # only ever compared with DOUBLE_LAST
            self.grace = max(self.grace - 1, 0)
        self.buffer = max(self.buffer - 1, 0)
        self.walking = abs(self.xf - old_xf) > TIE_X
        self.stride += abs(self.xf - old_xf)
        self.cam = min(max(self.px - 7 * Q, 0), LEVEL_W - 20 * Q)

    def head_bump(self, box):
        if self.stage == 2 and not self.opened and box == (PUZZLE_X * F, PUZZLE_Y * F, Q * F, Q * F):
            self.opened, self.tea = True, [PUZZLE_X + Q // 2, PUZZLE_Y + Q, TEA_VY]
            self.notify(MSG_PICK_TEA)

    # ---- animals (game.py update_enemy) ----
    def surfaces(self, x):
        """heights (units) of the solid tops with nothing above, in the column of x; highest first"""
        c = x // Q
        if not 0 <= c < WIDTH_M:
            return []
        m = self.solid[c] & ~(self.solid[c] >> 1)
        return [(r + 1) * Q for r in range(HEIGHT_ROWS - 1, -1, -1) if m >> r & 1]

    def wakes(self, e, reach):
        return reach >= e.trigger      # a method so the harness can settle exact float ties (cr_cosim.Run)

    def update_animal(self, e):
        early = 5 if (self.stage == 2 and e.motion in (WALK, FLY)) or (self.stage == 3 and e.motion == FLY) else 0
        if not e.active and self.wakes(e, self.cam + (20 + early) * Q):
            e.active = True
        if not e.active:
            return
        e.age = min(e.age + 1, 127)
        if e.leader >= 0:
            leader = self.ents[e.leader]
            e.path.append((leader.x, leader.y, leader.direction))
            while len(e.path) > FOLLOW + 1:
                e.path.popleft()
            if len(e.path) == FOLLOW + 1:
                e.x, e.y, e.direction = e.path[0]
                return
        if e.motion == POP:
            e.phase = (e.phase + 1) % ANT_CYCLE
            t = e.phase - ANT_HIDDEN
            e.exposure = min(max(min(t, 4 * ANT_RAMP - t), 0), ANT_RAMP)     # up 1 s, stay 2 s, down 1 s
            e.y = e.base_y - Q + e.exposure * (Q // ANT_RAMP)
            return
        if e.waterline is not None:
            e.y -= SINK_WATER
            e.alive = e.y + ANIMAL_H > e.waterline
            return
        old_x = e.x
        e.x += e.direction * ENEMY
        nudge = 0
        if e.x % (Q // 2) == 0:                         # exactly on a mark: take the float game's side of it
            if e.edges >> e.marks & 1:
                nudge = -1 if e.x % Q == 0 else e.direction
            e.marks = min(e.marks + 1, 511)
        seen = e.x + nudge                              # what the comparisons below see
        if e.motion == PATROL:
            if seen < e.lo:
                e.x, e.direction = 2 * e.lo - e.x, 1
                seen = e.x
            elif seen > e.hi:
                e.x, e.direction = 2 * e.hi - e.x, -1
                seen = e.x
            reachable = [h for h in self.surfaces(seen) if abs(h - e.y) <= Q]
            if reachable:
                e.y = min(reachable, key=lambda h: abs(h - e.y))
            else:
                e.x, e.direction = old_x, -e.direction
        if e.motion == WALK:
            if e.vy == 0:
                steps = [h for h in self.surfaces(seen) if 0 < h - e.y <= Q]
                if steps:
                    e.y = min(steps)
            self.fall(e, seen)
            c = seen // Q
            if 0 <= c < WIDTH_M:
                for r in range(HEIGHT_ROWS - 1, -1, -1):
                    if self.water[c] >> r & 1 and r * Q <= e.y < (r + 1) * Q:
                        e.waterline = (r + 1) * Q
                        break
        if seen < -3 * Q or e.y < -2 * Q:
            e.alive = False

    def fall(self, e, x):
        """fall_item() onto the level's solids (walking animals)"""
        old = e.y
        e.vy -= WALK_G
        e.y += e.vy
        c = x // Q
        if 0 <= c < WIDTH_M:
            for r in range(HEIGHT_ROWS - 1, -1, -1):
                top = (r + 1) * Q
                if self.solid[c] >> r & 1 and old >= top and e.y <= top:
                    e.y, e.vy = top, 0
                    return

    def animals(self):
        contacts = set()
        for i, e in enumerate(self.ents):
            if not e.alive:
                continue
            self.update_animal(e)
            if not e.alive or not e.active or not e.exposure or e.waterline is not None:
                continue
            half = (HALF_GOOSE if e.species == 3 else HALF_OTHER) * F
            bottom = (e.base_y if e.motion == POP else e.y) * F
            height = (ANIMAL_H * e.exposure // ANT_RAMP) * F
            x = e.x * F
            if (self.xf - HALF_F < x + half - TIE_X and self.xf + HALF_F > x - half + TIE_X
                    and self.yf < bottom + height - TIE_F and self.yf + PH * F > bottom + TIE_F
                    and not self.untouchable()):
                contacts.add(i)
                if i not in self.contacts:
                    self.hit()
        self.contacts = contacts

    def untouchable(self):
        return self.stage == 3 and self.skill > 0  # Phase

    # ---------------- boxes in whole units (reporter, tea, door) ----------------
    def blocks_units(self, lo, hi):
        """(x, y, width, height) of every block that could matter between lo and hi, in list order"""
        for bx, by, bw, bh in self.boxes((lo - Q) * F, (hi + Q) * F):
            yield bx >> VF, by >> VF, bw >> VF, bh >> VF

    @staticmethod
    def overlap(x, y, w, h, box):
        bx, by, bw, bh = box
        return x < bx + bw - TOL_X and x + w > bx + TOL_X and y < by + bh - TOL_Y and y + h > by + TOL_Y

    def blocked(self, x, y, w, h):
        return any(self.overlap(x, y, w, h, b) for b in self.blocks_units(x, x + w))

    # ---------------- reporter (game.py:412-526) ----------------
    def place_reporter(self, tx, ty, behind=False):
        choices = []
        for bx, by, bw, bh in self.blocks_units(tx - 11 * Q, tx + 11 * Q):
            if bx > tx + 10 * Q or bx + bw < tx - 10 * Q:
                continue
            x = min(max(tx, bx + HALF_W), bx + bw - HALF_W)
            if behind and (self.px - x) * self.facing < GAP - TOL_X:
                continue
            y = by + bh
            score = 5 * abs(x - tx) + 8 * abs(y - ty)            # 5 x the game's score, exact
            if abs(x - self.px) < NEAR_PLAYER:
                score += 10 * Q
            choices.append((score, x, y))
        for _, x, y in sorted(choices):
            if not self.blocked(x - HALF_W, y, 2 * HALF_W, PH):
                self.rx, self.ry, self.rvy = x, y * F, 0
                self.rdir = 1 if self.px >= x else -1
                return True
        return False

    def record_route(self, moved):
        self.route.append((self.now, self.px, self.yf >> VF, self.facing, moved and self.grounded, self.grounded))
        while len(self.route) > 1 and self.route[1][0] <= self.now - ROUTE_OLD:
            self.route.popleft()

    def follow_reporter(self):
        _, x, y, _, walking, grounded = self.route[0]
        still = len(self.route) > 1 and abs(self.px - self.route[-2][1]) <= TOL_X
        direction = self.facing
        if still and GAP - TOL_X <= (self.px - self.rx) * direction <= GAP_STILL:
            x = self.rx
        if (self.px - x) * direction < GAP:
            x = self.px - direction * GAP
        self.rvisible = True
        feet = (x - HALF_W, y - FEET, 2 * HALF_W, FEET)
        unsupported = grounded and not self.blocked(*feet)
        if unsupported or self.blocked(x - HALF_W, y, 2 * HALF_W, PH):
            self.rvisible = self.place_reporter(x, y, behind=True)
        else:
            self.rx, self.ry = x, y * F
        self.rdir = direction
        self.rwalking = walking and not still

    def remember_reporter(self):
        now = (self.rx, self.ry >> VF, self.rdir)
        if self.trail:
            x, y, facing = self.trail[-1]
            if (facing != self.rdir or (self.rx - x) * self.rdir < -TOL_X or abs(self.rx - x) > Q // 5
                    or abs(now[1] - y) > 7 * Q // 20):
                self.trail.clear()
            elif abs(self.rx - x) <= TOL_X:
                self.trail[-1] = now
                return
        self.trail.append(now)

    def retreat_reporter(self):
        old_x = self.rx
        target = min(max(self.rx - self.rdir * RETREAT_STEP, HALF_W), LEVEL_W - HALF_W)
        trail = self.trail
        while len(trail) > 1 and (trail[-2][0] - target) * self.rdir >= 0:
            trail.pop()
        if len(trail) > 1:
            x0, y0, _ = trail[-2]
            x1, y1, _ = trail[-1]
            height = y0 + (y1 - y0) * (target - x0) // (x1 - x0)
            if not self.blocked(target - HALF_W, height, 2 * HALF_W, PH):
                self.rx, self.ry, self.rvy = target, height * F, 0
                self.rwalking = abs(self.rx - old_x) > TOL_X
                return
            trail.clear()
        # not enough recorded ground: keep backing up under gravity, stop at walls
        self.rx = target
        y = self.ry >> VF
        for bx, by, bw, bh in self.blocks_units(self.rx - 2 * Q, self.rx + 2 * Q):
            if self.overlap(self.rx - HALF_W, y, 2 * HALF_W, PH, (bx, by, bw, bh)):
                self.rx = max(self.rx, bx + bw + HALF_W) if self.rdir > 0 else min(self.rx, bx - HALF_W)
        previous = self.ry
        self.rvy -= G_F
        self.ry += self.rvy
        tops = [(by + bh) * F for bx, by, bw, bh in self.blocks_units(self.rx - Q, self.rx + Q)
                if self.rx + HALF_W > bx + TOL_X and self.rx - HALF_W < bx + bw - TOL_X
                and self.ry <= (by + bh) * F <= previous + TIE_F]
        if tops:
            self.ry, self.rvy = max(tops), 0
        self.rwalking = abs(self.rx - old_x) > TOL_X

    def hit(self):
        if self.protection or self.interview or self.retreat or self.follow:
            return
        self.protection = T_PROTECT
        if self.chase:
            self.rvisible = self.place_reporter(self.px + self.facing * (13 * Q // 10), self.yf >> VF)
            self.questions = self.rng.pair(QUESTIONS)
            self.chase, self.interview = False, T_INTERVIEW
            self.notify(MSG_NONE)
        else:
            self.chase, self.retreat = True, 0
            self.trail.clear()
            self.follow_reporter()
            self.notify(MSG_REPORTER)

    def cast(self):
        if self.used:
            return
        if self.stage == 3:                                # Phase
            self.used, self.skill, self.flash = True, T_SKILL, T_FLASH
            return
        if not self.chase:
            self.notify(MSG_NEED_CHASE)
            return
        self.chase = False                                 # Cloak
        self.follow = T_FOLLOW
        self.used, self.skill = True, T_SKILL

    # ---------------- lifts, tea ----------------
    @staticmethod
    def lift_box(lift):
        column, top = lift[0], lift[1]
        return ((column - 1) * Q * F, (top - Q) * F, 2 * Q * F, Q * F)

    def advance_lifts(self):
        first = len(self.extra) - len(self.lifts)
        for i, lift in enumerate(self.lifts):
            column, top, sinking, direction = lift
            riding = self.grounded and abs(self.yf - top * F) <= TIE_F and self.under(self.lift_box(lift))
            if sinking:
                direction = -1 if riding else 1
            elif top >= LIFT_HIGH or top <= LIFT_LOW:
                direction = -1 if top >= LIFT_HIGH else 1
            speed = SINK_SPEED if sinking else LIFT_SPEED
            new = min(max(top + direction * speed, LIFT_LOW), LIFT_HIGH)
            lift[1], lift[3] = new, direction
            if riding:
                self.yf += (new - top) * F
            self.extra[first + i] = self.lift_box(lift)

    def move_tea(self):
        x, y, vy = self.tea
        x = min(TEA_STOP, x + TEA_VX)
        old = y
        vy -= TEA_G
        y += vy
        for bx, by, bw, bh in self.blocks_units(x - Q, x + Q):
            if bx <= x < bx + bw and old >= by + bh - TOL_Y and y <= by + bh:
                y, vy = by + bh, 0
        self.tea = [x, y, vy]
        if self.touches(((x - TEA_HALF) * F, y * F, 2 * TEA_HALF * F, TEA_H * F)):
            self.gold, self.tea = True, None
            self.grow = T_GROW
            self.notify(MSG_TEA)

    # ---- one step (game.py:528-630) ----
    def step(self, axis=0, jump=False, skill=False):
        self.died = False
        if self.mode == CLEAR:
            self.clear_left -= 1
            if self.clear_left <= 0:
                self.stage += 1
                self.restart(MSG_STAGE2 if self.stage == 2 else MSG_STAGE3)
            return
        if self.mode != PLAY:
            return
        self.now += 1
        self.grow = max(self.grow - 1, 0)
        self.time_left -= 1
        if self.time_left <= 0:
            self.restart(MSG_TIMEUP)
            self.died = True
            return
        self.notice = max(self.notice - 1, 0)
        self.flash = max(self.flash - 1, 0)
        if self.stage == 3 and self.skill == 1:            # Phase ends: flash
            self.flash, self.skill = T_FLASH, 0
        self.skill = max(self.skill - 1, 0)
        self.protection = max(self.protection - 1, 0)
        if self.interview:
            self.interview -= 1
            if not self.interview:
                self.protection = T_PROTECT_AFTER
            return
        if skill:
            self.cast()
        last_x = self.xf
        self.advance_lifts()
        self.move(axis, jump)
        if self.yf < -Q * F or (not self.grounded and self.grace <= 0 and self.touches_water()):
            self.restart(MSG_FELL if self.stage == 3 else MSG_SPLASH)
            self.died = True
            return
        if self.tea:
            self.move_tea()
        self.record_route(abs(self.xf - last_x) > TIE_X)
        if self.chase or self.follow:
            self.follow_reporter()
            self.remember_reporter()
            if self.follow:
                self.follow -= 1
                if not self.follow:
                    self.retreat = T_RETREAT
        elif self.retreat:
            self.retreat_reporter()
            self.retreat -= 1
            if not self.retreat:
                self.rvisible = False
        self.animals()
        if self.progress >= 92 and not self.near:
            self.near = True
            self.notify(MSG_NEAR1 + self.stage - 1)
        dx, dy, dw, dh = DOORS[self.stage]
        if dx <= self.px <= dx + dw and self.touches((dx * F, dy * F, dw * F, dh * F)):
            if self.stage < 3 and (self.stage == 1 or self.gold):
                self.mode, self.clear_left = CLEAR, T_CLEAR
                self.notify(MSG_NONE)
            elif self.gold:
                self.mode = WIN
                self.notify(MSG_NONE)
            else:
                self.notify(MSG_NEED_TEA)
