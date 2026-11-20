#!/usr/bin/env python3
"""asset_convert.py - turn the Pygame assets into Vivado/Icarus memory files.

Run from the repo root:   python3 fpga/tools/asset_convert.py
Inputs : assets/*.png, assets/*.jpg  (the same files the Pygame demos load)
Outputs: fpga/mem/*.mem   (one hex value per line, read with $readmemh)
         fpga/mem/preview/*.png  (what the FPGA will show, for a visual check)

Memory map (all images are palette-indexed; index 0 of the sprite palette = transparent)
  bg_s1.mem      640 x 358, 6-bit index  : Stage 1 room (finalexam.jpg). 1 stored px = 2x2 screen px,
                 i.e. 1 stored px = 3.125 world px of stage1_demo.py (IMG_W=2000 -> 640).
  bg_s1_pal.mem  64 x 12-bit RGB (4:4:4, what the Nexys A7 VGA DAC can show)
  bg_s2.mem      640 x 358, 6-bit index  : Stage 2 office (bg.jpg), shown 1:1 in the 640x360 game area
  bg_s2_pal.mem  64 x 12-bit
  spr.mem        64 images x 32 x 32, 7-bit index, address = img*1024 + y*32 + x
                   img  0..47 : player, img = form*12 + dir*3 + pose
                                dir  0 front 1 back 2 left 3 right   pose 0 stand 1 stepl 2 stepr
                   img 48..50 : card round 1 back   (air, earth, water)
                   img 51..53 : card round 1 front  (air, earth, water)
                   img 54..62 : card rounds 2+      (career*3 + slot)
                   img 63     : unused (transparent)
  spr_pal.mem    128 x 12-bit (entry 0 unused = transparent)
  font8x16.mem   128 glyphs x 16 rows, 8 bits per row (bit 7 = leftmost pixel)
  circ.mem       circle half-widths: addr = r*32 + dy (r,dy 0..31) -> floor(sqrt(r*r - dy*dy)) (6 bit)

Sprite fallback rules (same as the Pygame demos):
  missing left  -> mirrored right of the same form (stage2_demo.py rule)
  missing dir   -> form 1 of that dir, then form 0 (stage2 / player_sprite.py rules)
  missing pose  -> stand pose of the same form/dir (player_sprite.py rule)
  form 3 ("Super Yasai", secret form) has no art in assets/: it is GENERATED here from the
  graduation-gown frames by recolouring the brown hair to gold (FORM_COLORS[3] = (240,200,60)).
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ASSETS = os.path.join(ROOT, "assets")
OUT = os.path.join(ROOT, "fpga", "mem")
PREV = os.path.join(OUT, "preview")

BG_W, BG_H = 640, 358
DIRS = ["front", "back", "left", "right"]
POSES = ["stand", "stepl", "stepr"]
CAREERS = ["air", "earth", "water"]
FONT_CANDIDATES = [("/System/Library/Fonts/Menlo.ttc", 1), ("/System/Library/Fonts/Monaco.ttf", 0),
                   ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 0)]
HAIR_TO_GOLD = {(82, 66, 58): (225, 170, 30), (82, 66, 59): (225, 170, 30),
                (97, 78, 69): (255, 214, 80), (96, 78, 69): (255, 214, 80)}


def rgb12(c):
    return ((int(c[0]) >> 4) << 8) | ((int(c[1]) >> 4) << 4) | (int(c[2]) >> 4)


def expand12(v):
    r, g, b = (v >> 8) & 15, (v >> 4) & 15, v & 15
    return (r * 17, g * 17, b * 17)


def write_mem(name, values, digits):
    path = os.path.join(OUT, name)
    with open(path, "w") as f:
        for v in values:
            f.write("%0*X\n" % (digits, v))
    print("  %-16s %7d words" % (name, len(values)))


# ---------------------------------------------------------------- backgrounds
def convert_bg(src, tag):
    img = Image.open(os.path.join(ASSETS, src)).convert("RGB").resize((BG_W, BG_H), Image.LANCZOS)
    # quantise in 12-bit space so the palette is exactly what the DAC shows
    a = (np.asarray(img) >> 4) * 17
    q = Image.fromarray(a.astype("uint8")).quantize(colors=64, method=Image.Quantize.MEDIANCUT,
                                                     dither=Image.Dither.NONE)
    pal = q.getpalette()[:64 * 3]
    pal += [0] * (64 * 3 - len(pal))
    idx = np.asarray(q).astype(int).flatten()
    pal12 = [rgb12(pal[i * 3:i * 3 + 3]) for i in range(64)]
    write_mem("bg_%s.mem" % tag, idx.tolist(), 2)
    write_mem("bg_%s_pal.mem" % tag, pal12, 3)
    prev = np.array([expand12(pal12[i]) for i in idx], dtype="uint8").reshape(BG_H, BG_W, 3)
    Image.fromarray(prev).save(os.path.join(PREV, "bg_%s.png" % tag))


# ---------------------------------------------------------------- sprites + cards
def load32(name):
    p = os.path.join(ASSETS, name)
    if not os.path.isfile(p):
        return None
    im = Image.open(p).convert("RGBA")
    return im.resize((32, 32), Image.NEAREST) if im.size != (32, 32) else im


def player_frame(form, d, pose):
    def raw(f, dd, pp):
        return load32("player_form%d_%s_%s.png" % (f, dd, pp))

    def one(f):
        img = raw(f, d, pose) or raw(f, d, "stand")
        if img is None and d == "left":
            img = raw(f, "right", pose) or raw(f, "right", "stand")
            img = ImageOps.mirror(img) if img else None
        return img

    if form == 3 and not os.path.isfile(os.path.join(ASSETS, "player_form3_front_stand.png")):
        base, _ = player_frame(2, d, pose)
        a = np.asarray(base).copy()
        for src, dst in HAIR_TO_GOLD.items():
            m = (a[:, :, 0] == src[0]) & (a[:, :, 1] == src[1]) & (a[:, :, 2] == src[2]) & (a[:, :, 3] >= 128)
            a[m, :3] = dst
        return Image.fromarray(a), "generated (gold-hair gown)"
    for f, why in ((form, ""), (1, "fallback form1"), (0, "fallback form0")):
        img = one(f)
        if img is not None:
            return img, why
    raise SystemExit("no player sprite at all in %s" % ASSETS)


def convert_sprites():
    imgs, notes = [], []
    for form in range(4):
        for d in DIRS:
            for p in POSES:
                img, why = player_frame(form, d, p)
                imgs.append(img)
                if why:
                    notes.append("form%d %s %s: %s" % (form, d, p, why))
    for c in CAREERS:
        imgs.append(load32("%s_back.png" % c))
    for c in CAREERS:
        imgs.append(load32("%s_r1.png" % c))
    for c in CAREERS:
        for k in (1, 2, 3):
            im = load32("%s_card%d.png" % (c, k)) or (load32("eartg_card%d.png" % k) if c == "earth" else None)
            imgs.append(im)
    imgs.append(None)
    assert len(imgs) == 64
    missing = [i for i, im in enumerate(imgs[:63]) if im is None]
    if missing:
        raise SystemExit("missing sprite/card images: %s" % missing)
    colors = {}
    for im in imgs[:63]:
        a = np.asarray(im)
        for px in a[a[:, :, 3] >= 128]:
            colors.setdefault(rgb12(px[:3]), len(colors) + 1)
    if len(colors) > 127:
        raise SystemExit("sprites use %d colours (>127): reduce or widen the index" % len(colors))
    pal = [0] * 128
    for c12, i in colors.items():
        pal[i] = c12
    words = []
    for im in imgs:
        if im is None:
            words += [0] * 1024
            continue
        a = np.asarray(im)
        for y in range(32):
            for x in range(32):
                px = a[y, x]
                words.append(colors[rgb12(px[:3])] if px[3] >= 128 else 0)
    write_mem("spr.mem", words, 2)
    write_mem("spr_pal.mem", pal, 3)
    sheet = Image.new("RGBA", (16 * 32, 4 * 32), (40, 40, 60, 255))
    for i in range(64):
        tile = np.zeros((32, 32, 4), dtype="uint8")
        for y in range(32):
            for x in range(32):
                w = words[i * 1024 + y * 32 + x]
                if w:
                    tile[y, x] = expand12(pal[w]) + (255,)
        sheet.alpha_composite(Image.fromarray(tile), ((i % 16) * 32, (i // 16) * 32))
    sheet.resize((sheet.width * 3, sheet.height * 3), Image.NEAREST).save(os.path.join(PREV, "sprites.png"))
    print("  sprite palette: %d colours" % len(colors))
    for n in notes:
        print("    note:", n)


# ---------------------------------------------------------------- fonts
def render_font(path, idx, size, cw, ch, base, thr):
    font = ImageFont.truetype(path, size, index=idx)
    asc, _ = font.getmetrics()
    words = []
    for code in range(128):
        cell = Image.new("L", (cw, ch), 0)
        if 32 <= code < 127:
            d = ImageDraw.Draw(cell)
            d.text(((cw - font.getlength(chr(code))) / 2, base - asc), chr(code), font=font, fill=255)
        a = np.asarray(cell) > thr
        for y in range(16):
            words.append(0xFF if code == 127 and y < ch else
                         (sum((1 << (7 - x)) for x in range(cw) if a[y, x]) if y < ch else 0))
    return words


def convert_font():
    """font8x16.mem = 2 fonts x 128 chars x 16 rows (8 bits, bit 7 = leftmost pixel)
         0..2047    : 8x16 (Menlo Bold 13)     - Pygame f_m / f_l / mono_l sizes
         2048..4095 : 6x12 (Menlo Regular 10)  - Pygame f_s / f_tiny / mono sizes (rows 12..15 empty)
       char 127 = solid block."""
    for path, _ in FONT_CANDIDATES:
        if os.path.isfile(path):
            break
    else:
        raise SystemExit("no TTF font found: edit FONT_CANDIDATES")
    big = render_font(path, 1 if path.endswith(".ttc") else 0, 13, 8, 16, 13, 110)
    small = render_font(path, 0, 10, 6, 12, 10, 100)
    print("  font source: %s" % path)
    write_mem("font8x16.mem", big + small, 2)


def convert_circle():
    words = []
    for r in range(32):
        for dy in range(32):
            words.append(int(np.floor(np.sqrt(r * r - dy * dy))) if dy <= r else 0)
    write_mem("circ.mem", words, 2)


if __name__ == "__main__":
    os.makedirs(PREV, exist_ok=True)
    print("assets:", ASSETS)
    convert_bg("finalexam.jpg", "s1")
    convert_bg("bg.jpg", "s2")
    convert_sprites()
    convert_font()
    convert_circle()
    print("done ->", OUT)
    sys.exit(0)
