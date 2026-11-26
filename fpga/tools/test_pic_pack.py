#!/usr/bin/env python3
"""test_pic_pack.py - checks for the picture packer.   python3 -I fpga/tools/test_pic_pack.py"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pic_list  # noqa: E402
import pic_pack  # noqa: E402

PHOTO = {"S1_ROOM", "S2_ROOM", "OPEN1", "OPEN2", "OPEN4", "OPEN6"}   # camera-like art, many colours


def psnr(a, b):
    mse = np.mean((a.astype(float) - b.astype(float)) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(255.0 ** 2 / mse)


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

    # 3. fits the flash above the bitstream
    end = pic_pack.PIC_BASE + len(blob)
    if end > pic_pack.FLASH_SIZE:
        print("FAIL flash overflow 0x%X" % end); fails += 1

    print("PIC_PACK: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
