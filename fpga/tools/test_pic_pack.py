#!/usr/bin/env python3
"""test_pic_pack.py - checks for the picture packer.   python3 -I fpga/tools/test_pic_pack.py"""
import os
import sys

import importlib.util
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pic_list  # noqa: E402
import pic_pack  # noqa: E402

PHOTO = {"S1_ROOM", "S2_ROOM", "OPEN1", "OPEN2", "OPEN4", "OPEN6"}   # camera-like art, many colours


def psnr(a, b):
    mse = np.mean((a.astype(float) - b.astype(float)) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(255.0 ** 2 / mse)


def load_game_module(fname):
    """Import a Pygame demo module (no import side effects: only constants/defs) headlessly."""
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
    path = os.path.join(pic_pack.ROOT, "demo_py", fname)
    spec = importlib.util.spec_from_file_location("game_" + fname[:-3], path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def check_loaders():
    """Independent of pic_pack.pygame_canvas: rebuild pictures with the real game loaders, 960x540, pixel exact."""
    import pygame
    from PIL import Image
    fails = 0
    pic_pack.pygame_canvas("title", False, (0, 0, 0))      # initialises the dummy display
    opn = load_game_module("open.py")
    c23 = load_game_module("cutscene_2_3.py")
    cases = []
    for name, stem, kind, smooth, w, h in pic_list.PICS:
        if kind == "fit_black":
            raw = pygame.image.load(pic_pack.find_asset(stem)).convert()
            surf = opn.fit(raw, smooth=smooth)
            fill = (0, 0, 0)
        elif name.startswith("CUT23_"):
            surf = c23.load_slide(stem)
            fill = (12, 14, 20)
        else:
            continue
        real = np.asarray(Image.frombytes("RGB", surf.get_size(), pygame.image.tobytes(surf, "RGB")))
        mine = np.asarray(pic_pack.pygame_canvas(stem, smooth, fill))
        ok = real.shape == mine.shape and np.array_equal(real, mine)
        # letterbox bars (where the picture has any) must be the fill colour in the real loader's output
        bar = 0
        while bar < real.shape[0] and (real[bar] == np.array(fill)).all():
            bar += 1
        if bar:
            ok = ok and (real[:bar] == fill).all() and (real[-bar:] == fill).all()
        print("  loader %-8s canvas==pygame_canvas %s  letterbox %d px" % (name, "ok" if ok else "FAIL", bar))
        if not ok:
            fails += 1
        cases.append(name)
    if "TITLE" not in cases or "OPEN1" not in cases or "CUT23_1" not in cases:
        print("FAIL loader cases missing"); fails += 1
    return fails


def main():
    fails = 0
    blob, entries = pic_pack.build()
    dec = pic_pack.unpack(blob)

    # 1. round trip: what the hardware decodes == what the packer intended, header matches the list
    if len(dec) != len(pic_list.PICS):
        print("FAIL count %d != %d" % (len(dec), len(pic_list.PICS))); fails += 1
    for (name, off, w, h, idx, pal), (dw, dh, rgb) in zip(entries, dec):
        lut = np.array([pic_pack.rgb12_to_888(c) for c in pal], np.uint8)
        if (dw, dh) != (w, h) or not np.array_equal(lut[idx], rgb):
            print("FAIL roundtrip", name); fails += 1
        if off % 256:
            print("FAIL alignment", name); fails += 1

    # 2. quality vs the source as the DAC could best show it (12-bit truncation)
    for (name, stem, kind, smooth, w, h), (_, _, rgb) in zip(pic_list.PICS, dec):
        src = np.asarray(pic_pack.source_image(name, stem, kind, smooth, w, h))
        ref = (src >> 4) * 17
        p = psnr(ref, rgb)
        need = 30.0 if name in PHOTO else 36.0
        status = "ok" if p >= need else "FAIL"
        if p < need:
            fails += 1
        print("  %-8s %dx%d  PSNR %5.1f dB (need %.0f) %s" % (name, w, h, p, need, status))
        dm = np.abs(ref.reshape(-1, 3).mean(0) - rgb.reshape(-1, 3).mean(0))   # floor bias would be ~ -8 per ch
        if dm.max() >= 2.0:
            print("FAIL brightness drift %s %s (>= 2/255)" % (name, dm.round(2))); fails += 1

    # 2b. synthetic: > 256 distinct 12-bit colours force median-cut boxes whose averages are not multiples of 17
    rng = np.random.default_rng(1)
    syn = Image.fromarray((rng.integers(0, 16, (120, 160, 3)) * 17).astype("uint8"))
    idx, pal = pic_pack.quantize_picture(syn)
    lut = np.array([pic_pack.rgb12_to_888(c) for c in pal], np.uint8)
    drift = np.abs(np.asarray(syn).reshape(-1, 3).mean(0) - lut[idx].reshape(-1, 3).mean(0)).max()
    print("  synthetic palette mean drift %.2f/255 %s" % (drift, "ok" if drift < 2.0 else "FAIL"))
    if drift >= 2.0:
        fails += 1

    # 2c. independent check of the Pygame canvas against the real game loaders
    fails += check_loaders()

    # 3. fits the flash above the bitstream
    end = pic_pack.PIC_BASE + len(blob)
    if end > pic_pack.FLASH_SIZE:
        print("FAIL flash overflow 0x%X" % end); fails += 1

    print("PIC_PACK: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
