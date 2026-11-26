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
        self.restart()

    def restart(self):
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
        pass                                       # the "?" block: Task 5

    # ---- animals (game.py update_enemy) ----
    def surfaces(self, x):
        """heights (units) of the solid tops with nothing above, in the column of x; highest first"""
        c = x // Q
        if not 0 <= c < WIDTH_M:
            return []
        m = self.solid[c] & ~(self.solid[c] >> 1)
        return [(r + 1) * Q for r in range(HEIGHT_ROWS - 1, -1, -1) if m >> r & 1]

    def update_animal(self, e):
        early = 5 if (self.stage == 2 and e.motion in (WALK, FLY)) or (self.stage == 3 and e.motion == FLY) else 0
        if self.cam + (20 + early) * Q >= e.trigger:
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
        return False                               # Phase: Task 5

    def hit(self):
        pass                                       # reporter: Task 5

    # ---- one step ----
    def step(self, axis=0, jump=False, skill=False):
        self.died = False
        self.move(axis, jump)
        if self.yf < -Q * F or (not self.grounded and self.grace <= 0 and self.touches_water()):
            self.restart()
            self.died = True
            return
        self.animals()
