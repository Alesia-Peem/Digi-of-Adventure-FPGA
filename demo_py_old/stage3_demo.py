"""
เกมวิ่งข้ามน้ำ - หนีนักข่าว (เวอร์ชันไพทอน / pygame)

ติดตั้ง:  pip install pygame
รัน:      python river_run.py

ควบคุม:  ← → (หรือ A D) เดิน | Space / ↑ / W กระโดด (กด 2 ครั้ง = สูงขึ้น)
         E / Shift ใช้สกิล | Enter / Space / คลิก เริ่มเกม
หมายเหตุ: ไม่มีการเหยียบสัตว์ — สัตว์ไม่หายเมื่อกระโดดทับ และนับเป็นการชน
"""
import math
import sys
import pygame

# ===== ตั้งค่า (แก้ตรงนี้ได้) =====
TIME_LIMIT = 120            # เวลาจำกัด (วินาที)
LEN, SPEED, ESPD, CAMW, CAMOFF, TALK = 250, 5, 2, 20, 6, 5
# ===================================
W, H = 1280, 720
S = W / CAMW
DT = 1 / 120


def clamp(v, a, b):
    return max(a, min(b, v))


def hit(a, b):
    e = 1e-4
    return (a['x'] < b['x'] + b['w'] - e and a['x'] + a['w'] > b['x'] + e and
            a['y'] < b['y'] + b['h'] - e and a['y'] + a['h'] > b['y'] + e)


# ---------- ด่าน: พิกัดเป็นเมตร ----------
solids = []


def R(x0, x1, y0, y1, k):
    solids.append({'x': x0, 'y': y0, 'w': x1 - x0, 'h': y1 - y0, 'k': k, 'top': y1})


def G(a, b, h):
    R(a - 1, b, 0, h, 'g')


def B(a, b, y, k, t=1):
    R(a - 1, b, y, y + t, k)


G(1, 20, 4); B(9, 11, 6, 'd'); B(21, 30, 2, 'b'); G(31, 49, 3); B(41, 45, 7, 's')
for a, b, s, l in [(53, 54, 3, 4), (59, 60, .5, 1.5), (63, 64, 3, 4), (69, 70, 1.5, 2.5),
                   (74, 75, 4.5, 5.5), (80, 81, .5, 1.5), (86, 87, 1.5, 2.5)]:
    B(a, b, s, 's'); B(a, b, l, 'l', .5)
G(92, 121, 3); B(105, 108, 6, 'd'); R(126, 129, 0, 6, 's'); B(129, 137, 6, 'b'); R(136, 139, 0, 6, 's')
G(145, 165, 2); B(148, 155, 6, 'd'); B(163, 165, 3, 's'); B(168, 169, 6, 's'); B(172, 174, 6, 's'); B(177, 178, 6, 's')
B(181, 183, 3, 's'); G(181, 200, 2); B(194, 194, 6, 'd')
R(199.5, 202.5, 1.5, 2, 'l'); G(204, 209, 2); R(208.5, 211.5, 1.5, 2, 'l'); G(213, 217, 2)
R(216.5, 219.5, 1.5, 2, 'l'); R(218.5, 221.5, 2.5, 3, 'l'); G(223, 226, 4); R(225.5, 228.5, 5.5, 6, 'l'); G(235, 250, 2)
R(250, 251, 0, 30, 'w')   # กำแพงท้ายด่าน (มองไม่เห็น)

# ---------- สัตว์: t1,t2 เดิน/เดินไปมา, t3 โผล่หัว, t4 บิน ----------
DEF = []


def Z(**o):
    d = {'trig': -99, 'm': 'w'}
    d.update(o)
    DEF.append(d)


Z(t=1, x=13, y=3)
for x in (24, 27, 30):
    Z(t=2, x=x, y=3, trig=24, m='p', a=20, b=37)
Z(t=1, x=42, y=8, trig=41, m='p', a=40, b=45)
for i, (cx, y, y2) in enumerate([(63, 4, 6), (74, 6.5, 8.5), (86, 3.5, 5.5), (210.5, 1, 3), (227.5, 5, 7)]):
    Z(t=3, x=cx - .5, y=y, y2=y2, ph=i * 1.3)
Z(t=1, x=106, y=3, trig=106, m='p', a=101, b=111); Z(t=2, x=109, y=3, trig=106, m='p', a=101, b=111)
Z(t=1, x=132, y=7, trig=129, m='p', a=128, b=137); Z(t=2, x=151, y=7, trig=148, m='p', a=147, b=155)
Z(t=1, x=148, y=3, trig=142); Z(t=1, x=154, y=3, trig=140); Z(t=1, x=158, y=3, trig=152); Z(t=2, x=241, y=3, trig=235)
for x, y in [(190, 5), (194, 2.5), (202, 4), (213, 5), (223, 6)]:
    Z(t=4, x=x, y=y, trig=x - 6)


def surf(x, y):
    b = None
    for s in solids:
        if s['k'] != 'w' and s['x'] <= x <= s['x'] + s['w'] and s['top'] <= y + 1.01 and (b is None or s['top'] > b):
            b = s['top']
    return b


# ---------- ภาพ / ฟอนต์ ----------
pygame.init()
screen = pygame.display.set_mode((W, H), pygame.SCALED | pygame.RESIZABLE)
pygame.display.set_caption('เกมวิ่งข้ามน้ำ – หนีนักข่าว')
clock = pygame.time.Clock()


def make_font(size, bold=False):
    for n in ('leelawadeeui', 'leelawadee', 'tahoma', 'notosansthai', 'notosansthaiui', 'sarabun',
              'thsarabunnew', 'angsananew', 'garuda', 'loma', 'norasi', 'umpush', 'arialunicodems'):
        p = pygame.font.match_font(n)
        if p:
            f = pygame.font.Font(p, size)
            f.set_bold(bold)
            return f
    return pygame.font.Font(None, size)   # ถ้าไม่มีฟอนต์ไทย ตัวอักษรไทยอาจไม่แสดง


F26, F28, F30, F56 = make_font(26, True), make_font(28), make_font(30, True), make_font(56, True)

sky = pygame.Surface((W, H))
for yy in range(H):
    t = yy / H
    c0, c1 = (0x58, 0xb4, 0xee), (0xd3, 0xf0, 0xfc)
    pygame.draw.line(sky, [int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)], (0, yy), (W, yy))
water_layer = pygame.Surface((W, H), pygame.SRCALPHA)

TC = {'g': '#8a5a33', 's': '#8d939c', 'd': '#9b7b56', 'b': '#b98a4f', 'l': '#7b4b25'}
cam_x = 0.0


def X(x): return (x - cam_x) * S
def Y(y): return H - y * S


def C(col):
    # pygame ไม่รองรับสีย่อ เช่น '#fff' -> แปลงเป็น '#ffffff'
    if isinstance(col, str) and len(col) == 4 and col[0] == '#':
        return '#' + ''.join(ch * 2 for ch in col[1:])
    return col


def rect(x, y, w, h, col):
    pygame.draw.rect(screen, C(col), (X(x), Y(y + h), max(1, w * S), max(1, h * S)))


def circ(x, y, r, col):
    pygame.draw.circle(screen, C(col), (X(x), Y(y)), max(1, r * S))


def arect(x, y, w, h, rgba):
    s = pygame.Surface((int(w), int(h)), pygame.SRCALPHA)
    s.fill(rgba)
    screen.blit(s, (x, y))


def txt(s, font, col, x, y, align='left'):
    img = font.render(s, True, col)
    r = img.get_rect()
    r.centery = y
    if align == 'left': r.left = x
    elif align == 'right': r.right = x
    else: r.centerx = x
    screen.blit(img, r)


# ---------- ตัวละคร / สัตว์ ----------
def eyes(x, y, f):
    circ(x - .14, y, .1, '#fff'); circ(x + .14, y, .1, '#fff')
    circ(x - .14 + f * .03, y, .05, '#111'); circ(x + .14 + f * .03, y, .05, '#111')


def character(x, y, f, run, body, cap, mic):
    cx = x + .45
    sw = math.sin(run * 14) * .16
    rect(cx - .32 + sw, y, .26, .55, '#2a3f6e'); rect(cx + .06 - sw, y, .26, .55, '#2a3f6e')
    rect(cx - .4, y + .5, .8, .6, body); circ(cx, y + 1.2, .3, '#f2c9a0')
    rect(cx - .33, y + 1.36, .66, .2, cap); rect(cx if f > 0 else cx - .5, y + 1.32, .5, .09, cap)
    circ(cx + f * .12, y + 1.2, .05, '#111')
    if mic:
        rect(cx + f * .5 - .04, y + .65, .08, .45, '#444'); circ(cx + f * .5, y + 1.13, .1, '#222')
        rect(cx - .25, y + .7, .5, .14, '#fff')


def draw_animal(a, gt):
    if a['dead']:
        return
    x, y, f = a['x'] + .5, a['cy'], a['dir']
    if a['t'] == 1:
        circ(x, y + .45, .5, '#a8643a'); rect(x - .4, y, .8, .2, '#5b3820'); eyes(x, y + .55, f)
    elif a['t'] == 2:
        circ(x, y + .45, .5, '#7a55c8')
        for i in range(-2, 3):
            rect(x + i * .18 - .05, y + .85, .1, .2, '#4a2f8c')
        eyes(x, y + .5, f); rect(x - .3, y + .2, .6, .06, '#2b1a55')
    elif a['t'] == 4:
        w = math.sin(gt * 14) * .25
        circ(x, y + .35, .5, '#e0483a'); rect(x - .1, y + .35 + w, .5, .12, '#a82a20')
        circ(x - .35, y + .4, .15, '#f5b82a'); circ(x - .15, y + .5, .09, '#fff'); circ(x - .17, y + .5, .045, '#111')


def draw_plant(a):
    if a['t'] != 3:
        return
    x, y = a['x'] + .5, a['cy']
    rect(x - .15, y - 3, .3, 3.3, '#2c8a3c'); circ(x, y + .5, .55, '#2fa64a')
    o = .2 if a['r'] > .6 else .05
    rect(x - .45, y + .35, .9, o + .1, '#7a1020')
    for i in range(-2, 3):
        rect(x + i * .18 - .04, y + .38, .08, .12, '#fff')
    circ(x, y + .75, .08, '#111')


def draw_terrain(s):
    if s['k'] == 'w' or s['x'] + s['w'] < cam_x or s['x'] > cam_x + CAMW:
        return
    k = s['k']
    rect(s['x'], s['y'], s['w'], s['h'], TC[k])
    if k == 'g':
        rect(s['x'], s['top'] - .3, s['w'], .3, '#4cb040')
    elif k in ('s', 'd'):
        line = (0x62, 0x66, 0x6d) if k == 's' else (0x6c, 0x56, 0x3c)
        for i in range(int(s['w'])):
            for j in range(int(s['h'])):
                if k == 'd' and (i + j) % 2 == 0:
                    rect(s['x'] + i, s['y'] + j, 1, 1, '#8a8f98')
                pygame.draw.rect(screen, line, (X(s['x'] + i), Y(s['y'] + j + 1), S, S), 2)
    elif k == 'b':
        for i in range(int(s['w'] * 2)):
            pygame.draw.line(screen, (0x81, 0x60, 0x37), (X(s['x'] + i * .5), Y(s['top'])),
                             (X(s['x'] + i * .5), Y(s['top']) + S * s['h']), 2)
        rect(s['x'], s['top'] - .12, s['w'], .12, '#7a5430')
    elif k == 'l':
        circ(s['x'] + .1, s['y'] + .25, .25, '#c99a62'); rect(s['x'], s['top'] - .1, s['w'], .1, '#5e3818')


# ---------- เกม ----------
class Game:
    def __init__(self):
        self.st = 'menu'
        self.dd = 0.0
        self.msg_t, self.msg_u = '', 0.0
        self.reset()
        self.st = 'menu'

    def reset(self):
        global cam_x
        self.p = {'x': 2, 'y': 4, 'w': .9, 'h': 1.5, 'vy': 0, 'g': 40.8, 'jumps': 0, 'ly': 4, 'coy': 0, 'f': 1, 'run': 0}
        self.A = []
        for d in DEF:
            a = {'on': d['trig'] < -90, 'dir': -1, 'dead': False, 'ph': 0, 'ya': d['y'], 'cy': d['y'], 'r': 0}
            a.update(d)
            if a['t'] < 3:
                s = surf(a['x'] + .5, a['ya'])
                if s is not None:
                    a['cy'] = s
            self.A.append(a)
        self.gt, self.hits, self.hc, self.used = 0.0, 0, 0.0, False
        self.rep, self.talk = None, 0.0
        self.st, self.msg_u = 'play', 0.0
        cam_x = 0.0

    def flash(self, t):
        self.msg_t, self.msg_u = t, 1.8

    def do_jump(self):
        p = self.p
        if self.st != 'play' or self.talk > 0:
            return
        if p['coy'] > 0 and p['jumps'] == 0:      # กดครั้งเดียว: สูง 2.5 m
            p['vy'], p['g'], p['jumps'], p['ly'], p['coy'] = 14.29, 40.8, 1, p['y'], 0
        elif p['jumps'] < 2:                      # กดครั้งที่ 2: สูง 4.5 m
            if p['jumps'] == 0:
                p['ly'] = p['y']
            p['g'] = 25
            p['vy'] = math.sqrt(2 * 25 * max(.5, p['ly'] + 4.5 - p['y']))
            p['jumps'] = 2

    def skill(self):
        if self.st != 'play' or self.talk > 0:
            return
        if not self.used and self.hits == 1:
            self.used, self.hits = True, 0
            self.rep['st'] = 'out'
            self.flash('สกิล! นักข่าวหลุดจากเฟรม')

    def on_hit(self):
        self.hits += 1
        self.hc = 1.5
        if self.hits == 1:
            self.rep = {'x': cam_x - 2, 'y': self.p['y'], 'st': 'in'}
            self.flash('ชนสัตว์! นักข่าวตามมาแล้ว')
        else:
            self.talk = TALK
            self.hc = 99

    def upd_rep(self, dt):
        r, p = self.rep, self.p
        if not r:
            return
        if r['st'] == 'out':
            r['x'] -= 14 * dt
            if r['x'] < cam_x - 3:
                self.rep = None
            return
        off = 1.4 if self.talk > 0 else 2.4
        r['x'] += (p['x'] - off - r['x']) * min(1, 5 * dt)
        s = surf(r['x'] + .45, p['y'] + .6)
        ty = p['y'] if s is None else s
        r['y'] += (ty - r['y']) * min(1, 12 * dt)

    def step_p(self, dt, keys):
        p = self.p
        d = (1 if keys['r'] else 0) - (1 if keys['l'] else 0)
        if d:
            p['f'] = d
        p['run'] += abs(d) * dt
        p['x'] += d * SPEED * dt
        if p['x'] < cam_x:
            p['x'] = cam_x
        if d:
            for s in solids:
                if hit(p, s):
                    p['x'] = s['x'] - p['w'] if d > 0 else s['x'] + s['w']
        p['vy'] -= p['g'] * dt
        p['y'] += p['vy'] * dt
        gr = False
        for s in solids:
            if hit(p, s):
                if p['vy'] <= 0:
                    p['y'] = s['top']; gr = True
                else:
                    p['y'] = s['y'] - p['h']
                p['vy'] = 0
        if gr:
            p['jumps'], p['g'], p['coy'] = 0, 40.8, .1
        else:
            p['coy'] -= dt

    def upd_a(self, a, dt):
        if a['dead']:
            return
        if not a['on']:
            if cam_x + CAMW >= a['trig']:
                a['on'] = True
            else:
                return
        if a['t'] == 3:
            a['ph'] += dt
            u = a['ph'] % 5
            a['r'] = (u / .8 * 2 if u < .8 else 2 if u < 2.8 else 2 - (u - 2.8) / .8 * 2 if u < 3.6 else 0)
            a['cy'] = a['ya'] + a['r']
            return
        if a['t'] == 4:
            a['x'] -= ESPD * dt
            if a['x'] < cam_x - 3:
                a['dead'] = True
            return
        if a.get('fall'):                       # ตกน้ำ
            a['vy'] -= 20 * dt
            if a['cy'] < 2 and a['vy'] < -2.5:
                a['vy'] = -2.5                  # อยู่ในน้ำแล้วจมช้าลง
            a['cy'] += a['vy'] * dt
            a['x'] += a['dir'] * ESPD * dt * .5
            if a['cy'] < -1.5 or a['x'] < cam_x - 3:
                a['dead'] = True
            return
        a['x'] += a['dir'] * ESPD * dt
        if a['m'] == 'p':
            if a['x'] < a['a']:
                a['x'] = a['a']; a['dir'] = 1
            if a['x'] + 1 > a['b']:
                a['x'] = a['b'] - 1; a['dir'] = -1
        elif a['x'] < cam_x - 3:
            a['dead'] = True
            return
        s = surf(a['x'] + .5, a['ya'])
        if s is None:
            a['fall'], a['vy'] = True, 0.0      # หมดพื้น -> ตกลงน้ำ (ไม่หายไปเฉยๆ)
        else:
            a['cy'] = s

    def step(self, dt, keys):
        global cam_x
        p = self.p
        self.gt += dt
        if self.gt >= TIME_LIMIT:
            self.st = 'lose'
            return
        cam_x = clamp(p['x'] - CAMOFF, 0, LEN - CAMW)
        if self.msg_u > 0:
            self.msg_u -= dt
        if self.talk > 0:
            self.upd_rep(dt)
            self.talk -= dt
            if self.talk <= 0:
                self.talk, self.hits, self.hc = 0, 0, 1.5
                if self.rep:
                    self.rep['st'] = 'out'
            return
        self.step_p(dt, keys)
        self.hc -= dt
        for a in self.A:
            self.upd_a(a, dt)
        for a in self.A:
            if a['dead'] or not a['on'] or a.get('fall'):
                continue
            if a['t'] == 3:
                if a['r'] < .6:
                    continue
                b = {'x': a['x'] + .15, 'y': a['cy'], 'w': .7, 'h': 1}
            else:
                b = {'x': a['x'] + .1, 'y': a['cy'] + .05, 'w': .8, 'h': .7 if a['t'] == 4 else .9}
            if not hit(p, b):
                continue
            # ไม่มีการเหยียบ: สัตว์ไม่หาย ชนจากด้านไหนก็นับว่าโดน
            if self.hc <= 0:
                self.on_hit()
                break
        self.upd_rep(dt)
        if p['y'] < 1:
            self.st, self.dd = 'dead', 1.1
            return
        if p['x'] + p['w'] >= 249:
            self.st = 'win'

    # ---------- วาด ----------
    def hud(self):
        gt = self.gt
        rem = max(0, TIME_LIMIT - gt)
        m, s = int(rem // 60), int(rem % 60)
        arect(14, 12, 230, 44, (10, 30, 50, 166)); arect(W - 340, 12, 326, 44, (10, 30, 50, 166))
        arect(W / 2 - 200, 12, 400, 16, (10, 30, 50, 166))
        col = '#ff6b5a' if rem < 15 and int(gt * 3) % 2 else '#ffffff'
        txt('เวลา %d:%02d' % (m, s), F26, col, 26, 35)
        pygame.draw.rect(screen, '#ffd24a', (W / 2 - 200, 12, 400 * clamp(self.p['x'] / LEN, 0, 1), 16))
        rdy = not self.used and self.hits == 1
        col = '#aaaabb' if self.used else ('#ffd24a' if rdy and int(gt * 4) % 2 else '#ffffff')
        label = 'ใช้แล้ว' if self.used else ('พร้อมใช้!' if self.hits == 1 else 'ใช้เมื่อโดนนักข่าวตาม')
        txt('สกิล [E]: ' + label, F26, col, W - 26, 35, 'right')
        if self.msg_u > 0:
            arect(W / 2 - 260, 76, 520, 44, (10, 30, 50, 178))
            txt(self.msg_t, F26, '#ffffff', W / 2, 99, 'center')

    def panel(self, lines, sub):
        arect(0, 0, W, H, (8, 24, 40, 199))
        txt(lines[0], F56, '#ffffff', W / 2, 200, 'center')
        for i, l in enumerate(lines[1:]):
            txt(l, F28, '#ffffff', W / 2, 280 + i * 44, 'center')
        txt(sub, F28, '#ffd24a', W / 2, 600, 'center')

    def draw(self):
        gt = self.gt
        screen.blit(sky, (0, 0))
        pts = [(0, H)] + [(x, H - 5 * S - math.sin((x + cam_x * S * .3) / 150) * 70) for x in range(0, W + 1, 16)] + [(W, H)]
        pygame.draw.polygon(screen, '#9ad69a', pts)
        for i in range(6):
            cx = ((i * 7.3 - cam_x * .2) % 30 + 30) % 30 - 4
            cy = 8.6 + (i % 3) * .8
            for o in (-.5, 0, .6):
                circ(cx + o + cam_x, cy + (0 if o else .2), .55, (244, 250, 255))
        for a in self.A:
            draw_plant(a)
        for a in self.A:
            if a.get('fall'):
                draw_animal(a, gt)              # วาดก่อนผิวน้ำ ให้ดูเหมือนจมลงไป
        water_layer.fill((0, 0, 0, 0))
        wp = [(0, H), (0, Y(2))] + [(x, Y(2) + math.sin((x + cam_x * S) / 40 + gt * 2.5) * 4) for x in range(0, W + 1, 16)] + [(W, H)]
        pygame.draw.polygon(water_layer, (38, 128, 214, 224), wp)
        screen.blit(water_layer, (0, 0))
        for s in solids:
            draw_terrain(s)
        rect(248, 2, .12, 4, '#eeeeee'); rect(248.12, 4.8, 1.2, 1.1, '#e5453a')
        for a in self.A:
            if a['t'] != 3 and not a.get('fall'):
                draw_animal(a, gt)
        r, p = self.rep, self.p
        if r:
            character(r['x'], r['y'], -1 if r['st'] == 'out' else 1, gt, '#e8832a', '#222222', True)
        if self.st != 'dead':
            character(p['x'], p['y'], p['f'], p['run'], '#2f7de1', '#d83a3a', False)
        self.hud()
        if self.talk > 0:
            arect(120, 480, W - 240, 190, (8, 24, 40, 217))
            txt('นักข่าว', F30, '#ffd24a', 150, 515)
            txt('ขอสัมภาษณ์หน่อยค่ะ! ทำไมถึงวิ่งชนสัตว์คะ?' if self.talk > 2.5
                else 'ช่วยเล่าให้ฟังหน่อยนะคะ รู้สึกอย่างไรบ้าง...', F28, '#ffffff', 150, 570)
            txt('คุยต่ออีก %d วินาที' % math.ceil(self.talk), F28, '#ffd24a', 150, 630)
        if self.st == 'dead':
            arect(0, 0, W, H, (20, 70, 140, 140))
            txt('ตกน้ำ! เริ่มใหม่', F56, '#ffffff', W / 2, H / 2, 'center')
        if self.st == 'menu':
            self.panel(['เกมวิ่งข้ามน้ำ',
                        'เดินหน้า/ถอยหลัง: ← → (A D)   กระโดด: Space หรือ ↑',
                        'กด 2 ครั้งกลางอากาศ = กระโดดสูงและไกลขึ้น',
                        'ชนสัตว์ 1 ครั้ง = นักข่าวตาม  ·  ชน 2 ครั้ง = หยุดคุย 5 วินาที',
                        'กด E ใช้สกิลได้ 1 ครั้งต่อเกม ให้นักข่าวหลุดเฟรม  ·  ตกน้ำ = เริ่มใหม่',
                        'เหยียบสัตว์ไม่ได้ — สัตว์ไม่หาย  ·  เวลาจำกัด %d วินาที' % TIME_LIMIT],
                       'กด Enter / Space หรือคลิกเพื่อเริ่ม')
        if self.st == 'win':
            self.panel(['ถึงเส้นชัย!', 'ใช้เวลา %.1f วินาที' % self.gt], 'กด Enter หรือคลิกเพื่อเล่นอีกครั้ง')
        if self.st == 'lose':
            self.panel(['หมดเวลา!', 'ไปได้ %d จาก %d เมตร' % (int(self.p['x']), LEN)], 'กด Enter หรือคลิกเพื่อลองใหม่')


def main():
    g = Game()
    acc = 0.0
    while True:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                pygame.quit(); sys.exit()
            if e.type == pygame.MOUSEBUTTONDOWN and g.st in ('menu', 'win', 'lose'):
                g.reset()
            if e.type == pygame.KEYDOWN:
                k = e.key
                if k == pygame.K_ESCAPE:
                    pygame.quit(); sys.exit()
                if k in (pygame.K_RETURN, pygame.K_SPACE) and g.st not in ('play', 'dead'):
                    g.reset()
                    continue
                if k in (pygame.K_SPACE, pygame.K_UP, pygame.K_w):
                    g.do_jump()
                if k in (pygame.K_e, pygame.K_LSHIFT, pygame.K_RSHIFT):
                    g.skill()
        pk = pygame.key.get_pressed()
        keys = {'l': pk[pygame.K_LEFT] or pk[pygame.K_a], 'r': pk[pygame.K_RIGHT] or pk[pygame.K_d]}
        dt = min(.05, clock.tick(60) / 1000)
        if g.st == 'play':
            acc += dt
            while acc >= DT and g.st == 'play':
                acc -= DT
                g.step(DT, keys)
        elif g.st == 'dead':
            g.dd -= dt
            if g.dd <= 0:
                g.reset()
        g.draw()
        pygame.display.flip()


if __name__ == '__main__':
    main()