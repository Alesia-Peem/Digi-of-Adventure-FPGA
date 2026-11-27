#!/usr/bin/env python3
"""cr_frame.py - the Stage 3 world frame drawn ONLY from what cr_core publishes (cr_fields.py fields / conds and
the footprint port) plus the asset files: the reference for the renderer side of the integration.

world(fields, conds, q_words, assets) -> 640 x 352 RGB image = render.draw_frame()'s world frame (before its
NEAREST resize to 360 rows and before the HUD), in draw_frame's painter's order:
  backdrop (shifted by PAR) -> tiles at x = 32 col - CAM_PX, y = 32 row (+ water bob lines) -> lifts ->
  footprints -> "?" box -> tea -> animal slots -> reporter (+ "?" label) -> cloak ghosts -> player.
assets="exact": the game's own images (cr_test_frame.py: pixel-exact against draw_frame);
assets="rom":   what the hardware stores (cr_tiles / cr_tpal 4-bit tiles, cr_spr / cr_spal 16-colour ARGB sprites).
Not drawn here, because they need float positions or sin() of the time that the core does not publish (the
renderer approximates them from NOW / the fields): snow, night stars, wind, tea sparkles, the 9 player particles,
the flash ring. The goose bob and the water bob lines ARE drawn: they only need NOW.
final(world) applies the 352 -> 360 row stretch (ROW_MAP = Pillow's NEAREST choice).
"""
import os
import sys
from math import sin

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import numpy as np                       # noqa: E402
from PIL import Image, ImageDraw         # noqa: E402
import cr_assets as A                    # noqa: E402
import onlystage_3.render as render      # noqa: E402
import onlystage_3.winter_art as winter_art  # noqa: E402
import onlystage_3.settings as C         # noqa: E402

DT = 1 / 120
TIME = [0.0]                             # game.time after n steps: the float sum, exactly as game.py builds it
for _ in range(14400 + 300):
    TIME.append(TIME[-1] + DT)
# render.py:200 stretches 352 rows to 360 with Pillow's NEAREST: these 8 source rows are shown twice. (Exact maths,
# floor((r + .5) * 352 / 360), differs from Pillow at output rows 67, 112, 157, 337, so the rule is the list;
# cr_test_frame.py checks it against Pillow.)
DOUBLED = (22, 65, 109, 153, 198, 242, 286, 329)
ROW_MAP = sorted(list(range(352)) + list(DOUBLED))
INK, CREAM = render.INK, render.CREAM


# ---------------- images ----------------
_rom = {}


def _rom_tiles():
    if "tiles" not in _rom:
        out = []
        for img in A.tileset().images:
            idx, pal = A.quantise(img)
            rgb = A.decode(idx, pal)
            out.append(np.dstack([rgb, np.where(idx == 0, 0, 255).astype(np.uint8)]))
        _rom["tiles"] = out
    return _rom["tiles"]


def _rom_sprite(key):
    if key not in _rom:
        idx, pal = A.quantise(A.sprite_images()[key], soft=True)
        alpha = np.array([(c >> 12) * 17 for c in pal], np.uint8)[idx]
        _rom[key] = Image.fromarray(np.dstack([A.decode(idx, pal), alpha]), "RGBA")
    return _rom[key]


def _sprite_key(sprite_id):
    return list(A.sprite_images())[sprite_id]


def sprite(sprite_id, flip, opacity, assets):
    """a published sprite id as draw_frame pastes it (render.sprite / animal_sprite semantics)"""
    name, w, h = _sprite_key(sprite_id)
    if assets == "exact":
        if h == 27:                                            # animals: render.animal_sprite
            return render.animal_sprite(name, -1 if flip else 1)
        return render.sprite(name, (w, h), -1 if flip else 1, opacity)
    img = _rom_sprite((name, w, h))
    if flip:
        img = img.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    if opacity != 255:
        img = img.copy()
        img.putalpha(img.getchannel("A").point(lambda a: a * opacity // 255))
    return img


def tile(tid, flip, assets):
    a = (A.tileset().images if assets == "exact" else _rom_tiles())[tid]
    img = Image.fromarray(np.ascontiguousarray(a[:, ::-1] if flip else a), "RGBA")
    return img


# ---------------- the frame ----------------
def world(F, Cd, q_words, assets="exact"):
    get = lambda k: F.get(k, 0)
    on = lambda k: bool(Cd.get(k))
    stage, cam_px, now = get("STAGE"), get("CAM_PX"), get("NOW")
    t = TIME[now]
    frame = Image.new("RGB", (640, 352), INK)
    d = ImageDraw.Draw(frame)

    def put(img, left, top):
        frame.paste(img, (left, top), img)

    bg = render.sprite(C.BACKGROUND[stage], (704, 352))
    put(bg, -get("PAR"), 0)
    T, solid_water = A.tileset(), A.grid(A.load_maps()[stage])[1]
    for row in range(11):                                       # tiles, then each water tile's two bob lines
        for col in range(250):
            x = 32 * col - cam_px
            tid, flip = T.maps[stage][row][col]
            if not tid or not -32 < x < 640:
                continue
            py = 32 * row
            put(tile(tid, flip, assets), x, py)
            if solid_water[col] >> (10 - row) & 1:
                bob = round(1.5 * sin(t * 4 + col))
                d.line((x, py + bob + 2, x + 14, py + bob + 2), fill="#c3f2df", width=2)
                d.line((x + 15, py - bob + 3, x + 31, py - bob + 3), fill="#85ddd3", width=2)
    for k in (0, 1):                                            # lifts: two plank tiles each
        if on("L%d_ON" % k):
            for j, (tid, flip) in enumerate(T.lifts[k]):
                put(tile(tid, flip, assets), get("L%d_X" % k) + 32 * j, get("L%d_Y" % k))
    if q_words:                                                 # footprints (winter_art.tracks)
        layer = Image.new("RGBA", frame.size)
        dl = ImageDraw.Draw(layer)
        for w in q_words:
            sx = (w >> 26 & 0x3FFF) - (1 << 14 if w >> 39 & 1 else 0)
            sy = (w >> 15 & 0x7FF) - (1 << 11 if w >> 25 & 1 else 0)
            agen, kind = w >> 6 & 0x1FF, w >> 3 & 7
            direction, side = (-1 if w >> 2 & 1 else 1), (-1 if w >> 1 & 1 else 1)
            x, y = sx, sy + 1 + (side > 0)
            if not -7 < x < 647:
                continue
            age = t - TIME[now - agen]
            opacity = round(170 * max(0, 1 - age / 2))
            ink = (48, 81, 99, opacity)
            if kind == 4:
                dl.line((x - 2, y, x + 1, y), fill=ink, width=2)
                dl.point((x - 3 * direction, y + 1), fill=ink)
            elif kind == 1:
                dl.line((x - 1, y + 1, x + 1, y + 1), fill=ink, width=2)
                for dx in (-2, 0, 2):
                    dl.point((x + dx + direction, y - 1), fill=ink)
            else:
                dl.line((x - 3, y, x + 2, y), fill=(128, 193, 188, opacity), width=1)
            if age < .24:
                dy = round(sin(age / .24 * 3.14) * 4)
                dl.point((x - direction * int(age * 15), y - 2 - dy), fill=(247, 255, 255, round(210 * (1 - age / .24))))
        frame.paste(layer, (0, 0), layer)
    if on("PUZ_ON"):                                            # the "?" box at metre 240, top 6 m
        box = render.sprite(C.BLOCK, (32, 32)) if assets == "exact" else _rom_sprite((C.BLOCK, 32, 32))
        put(box, get("PUZ_X") - 16, get("PUZ_Y") - 32)
        if on("OPENED"):
            xq = 32 * 240 - cam_px
            d.rectangle((xq + 2, 162, xq + 32 - 3, 189), fill="#947058")
            d.line((xq + 10, 176, xq + 22, 176), fill=CREAM, width=2)
    if on("TEA_ON"):
        img = render.collectible(C.TEA) if assets == "exact" else _rom_sprite((C.TEA,) + render.collectible(C.TEA).size)
        put(img, get("TEA_X") - img.width // 2, get("TEA_Y") - img.height)
    for k in range(16):                                         # animal slots
        if not on("A%d_V" % k):
            continue
        img = sprite(get("A%d_ID" % k), on("A%d_F" % k), 255, assets)
        rows, x, y = get("A%d_ROWS" % k), get("A%d_X" % k), get("A%d_Y" % k)
        if on("A%d_POP" % k):
            put(img.crop((0, 0, img.width, rows)), x - img.width // 2, y - rows)
            continue
        if on("A%d_FLY" % k):                                   # the goose's bob (render.py:133), from NOW only
            y = round(352 - ((352 - y) / 32 + .06 * sin(t * 9)) * 32)
        top = y - img.height
        if rows < img.height:
            img = img.crop((0, 0, img.width, rows))
        put(img, x - img.width // 2, top)
    if on("R_ON"):                                              # the reporter, clipped at walls, "?" while following
        img = sprite(get("R_ID"), on("R_FLIP"), 255, assets)
        left, low, high = get("R_X") - 16, get("R_CL"), get("R_CH")
        if low < high:
            put(img.crop((low, 0, high, img.height)), left + low, get("R_Y") - img.height)
        if on("R_LABEL"):
            cx, cy = get("R_X"), get("R_LY")
            width = d.textlength("?", font=render.font(10))
            d.rectangle((cx - width / 2 - 4, cy - 14, cx + width / 2 + 4, cy + 1), fill=INK)
            d.text((cx, cy - 7), "?", font=render.font(10), fill=CREAM, anchor="mm")
    pid, flip = get("P_ID"), on("P_FLIP")
    _, w, h = _sprite_key(pid)
    if on("P_CLOAK"):                                           # three ghosts, then the see-through player
        for i in (3, 2, 1):
            put(sprite(pid, flip, 50 // i, assets), get("G%d_X" % i) - w // 2, get("P_Y") - h)
    put(sprite(pid, flip, 180 if on("P_CLOAK") else 255, assets), get("P_X") - w // 2, get("P_Y") - h)
    return frame


def final(world_frame):
    """render.py:200 - the 352 rows stretched to 360 (the HUD is drawn afterwards, in 360-row space)"""
    a = np.asarray(world_frame)
    return Image.fromarray(a[ROW_MAP], "RGB")


# ---------------- the original, with the effects the core does not publish switched off ----------------
class _NoEffects:
    """ImageDraw stand-in for draw_frame: drops the 9 particles and the flash ring, keeps everything else"""

    def __init__(self, real):
        self.real = real

    def rectangle(self, xy, fill=None, **kw):
        if fill in ("#adf4eb", render.GOLD) and xy[2] - xy[0] == 1 and xy[3] - xy[1] == 2:
            return None
        return self.real.rectangle(xy, fill=fill, **kw)

    def line(self, xy, fill=None, **kw):
        if fill == "#ffefa8":
            return None
        return self.real.line(xy, fill=fill, **kw)

    def __getattr__(self, name):
        return getattr(self.real, name)


def original_world(g):
    """render.draw_frame(g)'s world frame (640 x 352, before the resize and the HUD), effects off"""
    caught = []
    real_resize, real_draw = Image.Image.resize, render.ImageDraw.Draw
    saved = {n: getattr(winter_art, n) for n in ("snowfall", "night_stars", "wind", "sparkles")}

    def resize(img, size, *a, **kw):
        if size == (640, 360) and img.size == (640, 352) and not caught:
            caught.append(img.copy())
        return real_resize(img, size, *a, **kw)

    class Draw:
        @staticmethod
        def Draw(img, *a, **kw):
            return _NoEffects(real_draw(img, *a, **kw))

    try:
        Image.Image.resize = resize
        render.ImageDraw = Draw
        for n in saved:
            setattr(winter_art, n, lambda *a, **k: None)
        render.draw_frame(g)
    finally:
        Image.Image.resize = real_resize
        render.ImageDraw = ImageDraw
        for n, f in saved.items():
            setattr(winter_art, n, f)
    return caught[0].convert("RGB")


def write_previews():
    """mem/preview/cr_frame_<level>.png: the exact frame above the ROM frame, 360 rows each, mid-level"""
    import cr_cosim as H
    for stage, col in ((1, 64), (2, 131), (3, 160)):
        run = H.Run(stage)
        h = H.tables()[stage][0][col].bit_length() or 3
        run.put(col + .5, h)
        for t in range(240):
            run.step(1 if t < 120 else 0)
        pub = run.m.publish(), run.m.q_words()
        both = Image.new("RGB", (640, 720))
        both.paste(final(world(*pub[0], pub[1], "exact")), (0, 0))
        both.paste(final(world(*pub[0], pub[1], "rom")), (0, 360))
        both.save(os.path.join(A.MEM, "preview", "cr_frame_%d.png" % stage))


if __name__ == "__main__":
    write_previews()
    print("wrote mem/preview/cr_frame_1..3.png (exact above, ROM below)")
