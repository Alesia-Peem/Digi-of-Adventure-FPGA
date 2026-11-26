#!/usr/bin/env python3
"""pic_pack.py - pack every large picture (pic_list.PICS) into one flash image for the QSPI streamer.

    python3 -I fpga/tools/pic_pack.py            -> fpga/mem/pictures.bin   (programmed at flash PIC_BASE)
                                                    fpga/mem/pictures.hex   (same bytes, for the Icarus flash model)
                                                    fpga/rtl/video/pic_map.vh
                                                    fpga/mem/preview/pic_<NAME>.png (exactly what the FPGA shows)

FLASH IMAGE FORMAT (all little-endian, offsets relative to PIC_BASE)
    0x000  "CPEP"  magic           (pic_stream.v checks it -> `missing` when the flash was not programmed)
    0x004  u16 count, u16 version = 1
    0x008  count x { u32 off, u16 w, u16 h }          8 bytes per picture
    off    256 x u16 palette, 0x0RGB (4:4:4 = what the Nexys A7 VGA DAC shows)
    off+512  h rows x w bytes of palette index (row y starts at off + 512 + y*w)
Pictures start on 256-byte boundaries so a row fetch never needs more than one READ command.
"""
import os
import struct
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FPGA = os.path.dirname(HERE)
ROOT = os.path.dirname(FPGA)
ASSETS = os.path.join(ROOT, "assets")
MEM = os.path.join(FPGA, "mem")
PREV = os.path.join(MEM, "preview")
sys.path.insert(0, HERE)
import pic_list  # noqa: E402

PIC_BASE = 0x400000          # flash byte address; the xc7a100t bitstream (~3.8 MB) ends below it
FLASH_SIZE = 16 * 1024 * 1024
MAGIC = b"CPEP"
VERSION = 1
MAX_W = 768                  # pic_stream line budget: a row of w bytes takes ~4w + 90 clk < 3200 clk


def find_asset(stem):
    for ext in (".png", ".jpg", ".jpeg", ".webp"):       # same search order as the Pygame loaders
        p = os.path.join(ASSETS, stem + ext)
        if os.path.isfile(p):
            return p
    raise FileNotFoundError("asset %s.* not found in %s" % (stem, ASSETS))


def pygame_canvas(stem, smooth, fill):
    """Rebuild the 960x540 surface the Pygame loader makes (fit() / load_cutscene_image / load_slide)."""
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
    import pygame
    if not pygame.display.get_init():            # .convert() needs a display, as in the game
        pygame.display.init()
        pygame.display.set_mode((1, 1))
    raw = pygame.image.load(find_asset(stem)).convert()      # the loaders all call .convert()
    iw, ih = raw.get_size()
    k = min(pic_list.PY_W / iw, pic_list.PY_H / ih)
    size = (max(1, round(iw * k)), max(1, round(ih * k)))
    out = (pygame.transform.smoothscale if smooth else pygame.transform.scale)(raw, size)
    s = pygame.Surface((pic_list.PY_W, pic_list.PY_H))
    s.fill(fill)
    s.blit(out, ((pic_list.PY_W - size[0]) // 2, (pic_list.PY_H - size[1]) // 2))
    return Image.frombytes("RGB", s.get_size(), pygame.image.tobytes(s, "RGB"))


def source_image(name, stem, kind, smooth, w, h):
    if kind == "room":
        return Image.open(find_asset(stem)).convert("RGB").resize((w, h), Image.LANCZOS)
    fill = (0, 0, 0) if kind == "fit_black" else pic_list.DARK
    return pygame_canvas(stem, smooth, fill).resize((w, h), Image.LANCZOS)


def quantize_picture(img):
    """RGB image -> (index array h x w uint8, list of 256 palette entries 0x0RGB).

    Colours must be chosen in 12-bit space (r,g,b >> 4) because that is all the DAC can show.
    """
    # No dither: matches asset_convert.convert_bg and keeps pixel-art pictures (title) crisp.
    a = (np.asarray(img.convert("RGB")) >> 4) * 17
    q = Image.fromarray(a.astype("uint8")).quantize(colors=256, method=Image.Quantize.MEDIANCUT,
                                                     dither=Image.Dither.NONE)
    flat = q.getpalette()[:256 * 3]
    flat += [0] * (256 * 3 - len(flat))
    # Pillow's median-cut palette entries are box averages (not multiples of 17): round, never floor.
    def lvl(v):
        return min(15, (v + 8) // 17)
    pal = [(lvl(flat[i * 3]) << 8) | (lvl(flat[i * 3 + 1]) << 4) | lvl(flat[i * 3 + 2])
           for i in range(256)]
    return np.asarray(q).astype(np.uint8), pal


def rgb12_to_888(c):
    return ((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17


def build():
    """Return (bin_bytes, entries) where entries = [(name, off, w, h, idx, pal)]."""
    n = len(pic_list.PICS)
    head = bytearray(MAGIC + struct.pack("<HH", n, VERSION))
    body = bytearray()
    entries = []
    data_start = (8 + 8 * n + 255) & ~255
    for (name, stem, kind, smooth, w, h) in pic_list.PICS:
        # pic_stream.v fetches one row per VGA line: 4 clk/byte + ~90 clk overhead must fit in 3200 clk
        assert w <= MAX_W, "%s: width %d > %d bytes = one row fetch per VGA line (3200 clk)" % (name, w, MAX_W)
        idx, pal = quantize_picture(source_image(name, stem, kind, smooth, w, h))
        assert idx.shape == (h, w) and idx.dtype == np.uint8, name
        assert len(pal) == 256 and all(0 <= c <= 0xFFF for c in pal), name
        off = data_start + len(body)
        head += struct.pack("<IHH", off, w, h)
        body += struct.pack("<256H", *pal) + idx.tobytes()
        body += b"\xff" * ((-len(body)) % 256)
        entries.append((name, off, w, h, idx, pal))
    blob = bytes(head) + b"\xff" * (data_start - len(head)) + bytes(body)
    assert PIC_BASE + len(blob) <= FLASH_SIZE, "pictures do not fit in the 16 MiB flash"
    return blob, entries


def unpack(blob):
    """Inverse of build(): what the hardware will read. Returns [(w, h, rgb uint8 array)]."""
    assert blob[:4] == MAGIC
    n, ver = struct.unpack_from("<HH", blob, 4)
    assert ver == VERSION
    out = []
    for i in range(n):
        off, w, h = struct.unpack_from("<IHH", blob, 8 + 8 * i)
        pal = struct.unpack_from("<256H", blob, off)
        idx = np.frombuffer(blob, np.uint8, w * h, off + 512).reshape(h, w)
        lut = np.array([rgb12_to_888(c) for c in pal], np.uint8)
        out.append((w, h, lut[idx]))
    return out


def main():
    os.makedirs(PREV, exist_ok=True)
    blob, entries = build()
    with open(os.path.join(MEM, "pictures.bin"), "wb") as f:
        f.write(blob)
    with open(os.path.join(MEM, "pictures.hex"), "w") as f:   # one byte per line for $readmemh
        f.write("\n".join("%02X" % b for b in blob) + "\n")
    for (name, *_), (w, h, rgb) in zip(entries, unpack(blob)):
        Image.fromarray(rgb).save(os.path.join(PREV, "pic_%s.png" % name))
    L = ["// pic_map.vh - GENERATED by fpga/tools/pic_pack.py from pic_list.py. Do not edit.",
         "localparam [23:0] PIC_BASE = 24'h%06X;" % PIC_BASE,
         "localparam integer PIC_COUNT = %d;" % len(entries)]
    for i, (name, off, w, h, *_ ) in enumerate(entries):
        L.append("localparam [4:0] PIC_%-8s = 5'd%-2d;   // %dx%d at +0x%06X" % (name, i, w, h, off))
    with open(os.path.join(FPGA, "rtl", "video", "pic_map.vh"), "w") as f:
        f.write("\n".join(L) + "\n")
    print("pictures: %d, %.2f MB at flash 0x%06X..0x%06X" % (
        len(entries), len(blob) / 1e6, PIC_BASE, PIC_BASE + len(blob)))


if __name__ == "__main__":
    main()
