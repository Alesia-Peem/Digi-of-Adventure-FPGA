#!/usr/bin/env python3
"""cr_test_assets.py - tests of cr_assets.py against onlystage_3. Run: python3 -I fpga/tools/cr_test_assets.py"""
import os
import sys
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr_assets as A  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402
import onlystage_3.render as render  # noqa: E402

hud_sprite_names = [n for pair in A.C.SKILL_ICONS.values() for n in pair]


def test_grid_matches_level():
    for s, L in A.load_maps().items():
        solid, water = A.grid(L)
        assert len(solid) == len(water) == 250
        cells = lambda g: {(x, y) for x in range(250) for y in range(11) if g[x] >> y & 1}
        assert cells(solid) == {(int(b.x), int(b.y)) for b in L.solids}, "stage %d solid" % s
        assert cells(water) == {(int(b.x), int(b.y)) for b in L.water}, "stage %d water" % s


def test_surfaces_match_level():
    for s, L in A.load_maps().items():
        solid, _ = A.grid(L)
        for x in range(250):
            m = A.surfaces_mask(solid[x])
            got = [y + 1 for y in range(11) if m >> y & 1]
            assert got == sorted(L.surfaces(x + .5)), "stage %d column %d" % (s, x)


def test_entity_counts():
    assert [len(A.entities(s)) for s in (1, 2, 3)] == [36, 23, 44]
    assert [sum(e["leader"] >= 0 for e in A.entities(s)) for s in (1, 2, 3)] == [2, 0, 5]


def test_followers_trail_their_own_leader():
    for s in (1, 3):
        E = A.entities(s)
        for i, e in enumerate(E):
            if e["leader"] >= 0:
                lead = E[e["leader"]]
                assert e["leader"] < i and e["species"] == "squirrel" and lead["species"] == "snail"
                assert (e["lo"], e["hi"]) == (lead["lo"], lead["hi"])
        leaders = [e["leader"] for e in E if e["leader"] >= 0]
        assert len(leaders) == len(set(leaders)), "two followers share a leader"


def test_spawn_snap():
    for s, L in A.load_maps().items():
        for e in A.entities(s):
            tops = L.surfaces(e["x"])
            if e["motion"] == "pop" and tops:
                assert e["base_y"] in tops and e["y"] == e["base_y"] - 1
            elif e["motion"] in ("walk", "patrol") and tops:
                assert e["y"] in tops


def composite(level, image_of):
    """paste every cell the way draw_frame does (camera at 0), RGBA on black"""
    canvas = Image.new("RGBA", (250 * 32, 11 * 32), (0, 0, 0, 255))
    for b, role, ts, num, flags, alpha in level.cells:
        img = image_of(b, ts, num, flags, alpha)
        canvas.paste(img, (int(b.x) * 32, (10 - int(b.y)) * 32), img)
    return np.asarray(canvas)


def test_level_image_exact():
    T = A.tileset()
    for s, L in A.load_maps().items():
        def original(b, ts, num, flags, alpha):
            img = ts.image(num, flags, alpha, 0.)
            if s == 3 and ts.data["name"] in ("mai_3", "maidown_3"):
                img = render.upper_plank(img, flip=ts.data["name"] != "maidown_3")
            return img

        def rebuilt(b, ts, num, flags, alpha):
            tid, flip = T.maps[s][10 - int(b.y)][int(b.x)]
            assert tid != 0
            a = T.images[tid][:, ::-1] if flip else T.images[tid]
            return Image.fromarray(np.ascontiguousarray(a), "RGBA")

        assert np.array_equal(composite(L, original), composite(L, rebuilt)), "stage %d" % s
        filled = sum(tid != 0 for row in T.maps[s] for tid, _ in row)
        assert filled == len(L.cells)


def test_lift_tiles():
    T = A.tileset()
    for sinking in (False, True):
        for k, (cell, _, ts, num, flags, alpha) in enumerate(render.platform_art(sinking)):
            want = np.asarray(render.upper_plank(ts.image(num, flags, alpha, 0.), flip=not sinking))
            tid, flip = T.lifts[int(sinking)][k]
            got = T.images[tid][:, ::-1] if flip else T.images[tid]
            assert np.array_equal(got[:want.shape[0]], want) and not got[want.shape[0]:, :, 3].any()


def test_tile_count():
    n = len(A.tileset().images)
    assert n <= 256, "tile id is 8 bits, got %d (including the empty tile 0)" % n


def psnr(a, b, mask):
    mse = np.mean((a[mask].astype(float) - b[mask].astype(float)) ** 2)
    return 99. if mse == 0 else 10 * np.log10(255 ** 2 / mse)


def test_quantised_tiles():
    T = A.tileset()
    scores = []
    for img in T.images[1:]:
        idx, pal = A.quantise(img)
        assert idx.max() <= 15 and len(pal) == 16
        assert np.array_equal(idx == 0, img[:, :, 3] < 128), "index 0 must mean transparent, nothing else"
        opaque = idx != 0
        if opaque.any():
            scores.append(psnr(A.decode(idx, pal), img[:, :, :3], opaque))
    print("      tiles: mean PSNR %.1f dB, worst %.1f dB" % (np.mean(scores), min(scores)))
    assert np.mean(scores) >= 28


def soft_decode(idx, pal):
    table = np.array([[(c >> 8 & 15) * 17, (c >> 4 & 15) * 17, (c & 15) * 17, (c >> 12) * 17] for c in pal])
    return table[idx]


def test_sprite_translucency_kept():
    total = count = far = 0
    for key, img in A.sprite_images().items():
        idx, pal = A.quantise(img, soft=True)
        got = soft_decode(idx, pal)[:, :, 3]
        visible = img[:, :, 3] > 0
        err = np.abs(got - img[:, :, 3].astype(int))[visible]
        assert err.max() <= 80, "%s: alpha off by %d" % (key, err.max())
        assert np.all(got[~visible] == 0), "%s: empty pixels became visible" % (key,)
        total, count, far = total + err.sum(), count + err.size, far + int((err > 48).sum())
    print("      sprite alpha: mean error %.1f of 255, %d of %d pixels off by > 48" % (total / count, far, count))
    assert total / count <= 6 and far <= count * 0.005


def test_sprite_details_kept():
    """no visible pixel may change colour a lot: eyes and cheeks are only a few pixels"""
    worst = {}
    for key, img in A.sprite_images().items():
        if not key[0].startswith(("player", "reporter")):
            continue
        idx, pal = A.quantise(img, soft=True)
        visible = img[:, :, 3] >= 64
        err = np.abs(soft_decode(idx, pal)[:, :, :3] - img[:, :, :3].astype(int))[visible]
        worst[key] = int(err.max())
    bad = {k: v for k, v in worst.items() if v > 64}
    print("      player/reporter: worst channel error %d of 255" % max(worst.values()))
    assert not bad, bad


def test_sprites_cover_draw_frame():
    """record every sprite draw_frame() asks for, over every form, size, pose and skin"""
    asked = set()
    real = render.sprite, render.animal_sprite, render.collectible, hud_sprite_names

    def sprite(name, size, direction=1, opacity=255):
        asked.add((name, size[0], size[1]))
        return real[0](name, size, direction, opacity)

    def animal(name, direction):
        img = real[1](name, direction)
        asked.add((name, img.width, img.height))
        return img

    def tea(name):
        img = real[2](name)
        asked.add((name, img.width, img.height))
        return img

    render.sprite, render.animal_sprite, render.collectible = sprite, animal, tea
    try:
        maps = A.load_maps()
        g = A.Game(maps)
        for stage in (1, 2, 3):
            g.stage = stage
            g.restart()
            for e in g.enemies:
                e.active, e.exposure, e.x = True, 1., 8.
            states = [(0, False, 0), (0, True, 0), (3, False, 0), (0, True, 3), (3, True, 3)]
            for skill, gold, grow in states:
                if stage == 1 and gold or stage == 3 and not gold:
                    continue                      # gold: only after the stage-2 tea, always on in stage 3
                if stage == 2 and grow and not gold:
                    continue
                for stride, grounded in ((0, True), (.5, True), (1.4, True), (0, False)):
                    g.skill, g.gold, g.tea_growth_until = float(skill), gold, float(grow)
                    g.p.walking, g.p.stride, g.p.grounded = True, stride, grounded
                    render.draw_frame(g)
            for k in range(6):                        # skins are random in the game: force each one
                for e in g.enemies:
                    names = A.skins(stage)[e.species]
                    e.skin = names[k % len(names)]
                render.draw_frame(g)
            g.chase, g.reporter_walking = True, True
            for t in (0., .15):
                g.time = t
                g.reporter.x, g.reporter.y = 8., 5.
                render.draw_frame(g)
            if stage == 2:
                g.tea = A.Actor(8., 5.)
                render.draw_frame(g)
        for name in hud_sprite_names:
            asked.add((name, 35, 35))
    finally:
        render.sprite, render.animal_sprite, render.collectible = real[:3]
    asked = {k for k in asked if not k[0].endswith(".png") or k[0] not in A.C.BACKGROUND.values()}
    have = set(A.sprite_images())
    assert asked <= have, "missing: %s" % sorted(asked - have)
    extra = have - asked - {("clock", 32, 32)}
    assert not extra, "stored but never drawn: %s" % sorted(extra)


def test_skin_lists_match_game():
    import onlystage_3.game as G
    real = G.random.choice
    try:
        for s in (1, 2, 3):
            seen = []
            G.random.choice = lambda seq: seen.append(list(seq)) or seq[0]
            g = A.Game(A.load_maps())
            seen.clear()
            g.stage = s
            g.restart()
            assert seen == [A.skins(s)[e.species] for e in g.enemies], "stage %d" % s
    finally:
        G.random.choice = real


def read_mem(name):
    with open(os.path.join(A.MEM, name)) as f:
        return [int(line, 16) for line in f]


def test_mem_files():
    A.write_all(verbose=False)
    solid, water, tiles, tpal, mp, ent = (read_mem("cr_%s.mem" % n) for n in
                                          ("solid", "water", "tiles", "tpal", "map", "ent"))
    T = A.tileset()
    for s, L in A.load_maps().items():
        sc, wc = A.grid(L)
        assert solid[(s - 1) * 256:(s - 1) * 256 + 250] == sc
        assert water[(s - 1) * 256:(s - 1) * 256 + 250] == wc
        for row in range(11):
            for col in range(250):
                tid, flip = T.maps[s][row][col]
                assert mp[(s - 1) * 4096 + row * 256 + col] == (flip << 8 | tid)
        edge = read_mem("cr_edge.mem")
        for i, (e, bits) in enumerate(zip(A.entities(s), A.edge_bits(s))):
            got = A.unpack_entity(ent[(s - 1) * 64 + i])
            want = A.entity_fields(e, A.skins(s))
            pattern = got.pop("edge")
            assert got == want
            assert edge[pattern * 512:pattern * 512 + 512] == [bits >> k & 1 for k in range(512)], (s, i)
    for tid in (1, len(T.images) - 1):
        idx, pal = A.quantise(T.images[tid])
        assert tiles[tid * 1024:(tid + 1) * 1024] == list(idx.reshape(-1))
        assert tpal[tid * 16:tid * 16 + 16] == pal
    spr, spal, stab = (read_mem("cr_%s.mem" % n) for n in ("spr", "spal", "stab"))
    for k, (key, img) in enumerate(A.sprite_images().items()):
        w, h, off = stab[k] >> 32, stab[k] >> 24 & 255, stab[k] & 0xFFFFFF
        idx, pal = A.quantise(img, soft=True)
        assert (w, h) == (key[1], key[2]) and spr[off:off + w * h] == list(idx.reshape(-1))
        assert spal[k * 16:k * 16 + 16] == pal
    for s in (1, 2, 3):
        assert Image.open(os.path.join(A.MEM, "preview", "cr_bg%d.png" % s)).size == (704, 352)


if __name__ == "__main__":
    failed = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            try:
                fn()
                print("ok    %s" % name)
            except Exception:
                failed += 1
                print("FAIL  %s\n%s" % (name, traceback.format_exc()))
    print("CR_TEST_ASSETS: %s" % ("FAIL (%d)" % failed if failed else "PASS"))
    sys.exit(1 if failed else 0)
