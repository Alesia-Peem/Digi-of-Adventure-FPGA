#!/usr/bin/env python3
"""ui_compile.py - assembler + bit-exact software model of the UI engine.

  python3 fpga/tools/ui_compile.py            -> writes fpga/mem/ui_prog.mem, ui_str.mem, ui_ptr.mem,
                                                 fpga/rtl/ui/ui_map.vh and preview PNGs of every screen
The model (Composer.run + render) follows ui_composer.v / line_renderer.v exactly (same integer
alpha maths, same clipping), so tb_frame.v can compare a frame dumped from the RTL simulation with
the model pixel for pixel.
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ui_spec  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, ".."))
MEM = os.path.join(ROOT, "mem")

OPS = dict(END=0, RECT=1, CLRBG=2, CIRC=3, TEXT=4, NUM=5, TEXTT=6, SPR=7, OFS=8, SKIP=9, ZOOM=10, S3=11)
S3_WATER, S3_TERRAIN, S3_TIMG, S3_HILLS = 0, 1, 2, 3
FMT = dict(dec=0, bin=1, letter=2, sdec8=3, bits16=4, term=5, eqn=6, let3=7)


def col12(rgb):
    """Pygame (r,g,b) 0..255 -> 12-bit 4:4:4 (rounded)."""
    r, g, b = (min(15, (int(v) + 8) // 17) for v in rgb)
    return (r << 8) | (g << 4) | b


def alpha16(a255):
    return max(0, min(16, round(a255 * 16 / 255)))


def s11(v):
    assert -1024 <= v < 1024, v
    return v & 0x7FF


def s10(v):
    assert -512 <= v < 512, v
    return v & 0x3FF


# ====================================================================== program builder
class Program:
    def __init__(self):
        self.fmap = ui_spec.FIELD   # field namespace of the stage being written (ui_spec.FIELD / FIELD2)
        self.cmap = ui_spec.COND    # condition namespace (ui_spec.COND / COND2)
        self.ins = []          # (op, cond, neg, fields dict)
        self.strings = {}      # text -> address (filled at link time)
        self.tables = {}       # name -> base index in the pointer ROM

    # ---- condition helper: "NAME", "!NAME" or None
    def _cond(self, c):
        if c is None:
            return 0, 0
        neg = c.startswith("!")
        name = c[1:] if neg else c
        return self.cmap[name], int(neg)

    def stage(self, n):
        """switch the field / condition namespace (1 or 2)"""
        self.fmap = {1: ui_spec.FIELD, 2: ui_spec.FIELD2, 3: ui_spec.FIELD3}[n]
        self.cmap = {1: ui_spec.COND, 2: ui_spec.COND2, 3: ui_spec.COND3}[n]

    def _emit(self, op, cond=None, **kw):
        ci, neg = self._cond(cond)
        self.ins.append([op, ci, neg, kw])

    # ---- primitives (game-area pixel coordinates, 640 x 360)
    def rect(self, x0, y0, x1, y1, col, alpha=16, cond=None, afield=None, f1=None):
        """f1 = (field x1, field y1): far corner taken from two fields (absolute game px)"""
        if f1:
            self._emit("RECT", cond, x0=x0, y0=y0, x1=0, y1=0, col=col, alpha=alpha, afield=0, frect=1,
                       fx1=self.fmap[f1[0]], fy1=self.fmap[f1[1]])
        else:
            self._emit("RECT", cond, x0=x0, y0=y0, x1=x1, y1=y1, col=col, alpha=alpha,
                       afield=self.fmap[afield] if afield else 0)

    def s3(self, sub, x=0, y=0, tid=0, field=None, col=0, cond=None):
        """Stage 3 renderer primitive (water / terrain / Thai text bitmap tid (+ field value) / hills)"""
        self._emit("S3", cond, x0=x, y0=y, sub=sub, tid=tid, fid=self.fmap[field] if field else 0, col=col)

    def frame(self, x0, y0, x1, y1, col, w=1, cond=None):
        """outline of width w (pygame.draw.rect(..., width))"""
        self.rect(x0, y0, x1, y0 + w, col, cond=cond)
        self.rect(x0, y1 - w, x1, y1, col, cond=cond)
        self.rect(x0, y0 + w, x0 + w, y1 - w, col, cond=cond)
        self.rect(x1 - w, y0 + w, x1, y1 - w, col, cond=cond)

    def clrbg(self, x0, y0, x1, y1, cond=None, f1=None):
        """f1 = (field x1, field y1): far corner taken from two fields (absolute game px)"""
        if f1:
            self._emit("CLRBG", cond, x0=x0, y0=y0, x1=0, y1=0, col=0, alpha=16, afield=0, frect=1,
                       fx1=self.fmap[f1[0]], fy1=self.fmap[f1[1]])
        else:
            self._emit("CLRBG", cond, x0=x0, y0=y0, x1=x1, y1=y1, col=0, alpha=16, afield=0)

    def circ(self, cx, cy, r, col, ri=0, alpha=16, cond=None):
        assert 0 <= r < 32 and 0 <= ri < 32
        self._emit("CIRC", cond, x0=cx, y0=cy, r=r, ri=ri, col=col, alpha=alpha)

    def text(self, x, y, s, col, font="m", center=False, xcont=False, ycont=False, lh=None, cond=None):
        if font == "l":
            w = 16
        elif font == "s":
            w = 6
        else:
            w = 8
        if center:
            first = s.split("\n")[0]
            x = x - (len(first) * w) // 2
        if lh is None:
            lh = 32 if font == "l" else (13 if font == "s" else 17)
        assert font == "l" or 8 <= lh <= 23, lh
        self.strings.setdefault(s, None)
        self._emit("TEXT", cond, x0=x, y0=y, s=s, col=col, sc2=int(font == "l"), small=int(font == "s"),
                   xc=int(xcont), yc=int(ycont), lh=lh)

    def num(self, x, y, field, fmt, col, width=0, font="m", center=False, xcont=False, ycont=False, cond=None):
        self._emit("NUM", cond, x0=x, y0=y, fid=self.fmap[field], fmt=FMT[fmt], width=width, col=col,
                   sc2=int(font == "l"), small=int(font == "s"), cen=int(center), xc=int(xcont), yc=int(ycont))

    def textt(self, x, y, table, field, col, font="m", center=False, xcont=False, ycont=False, lh=None,
              wrap=None, box=False, cond=None):
        """string = TABLES[table][field]; wrap = max chars per line (pre-wrapped at link time)"""
        if lh is None:
            lh = 32 if font == "l" else (13 if font == "s" else 17)
        key = (table, wrap)
        self.tables.setdefault(key, None)
        self._emit("TEXTT", cond, x0=x, y0=y, key=key, fid=self.fmap[field], col=col, sc2=int(font == "l"),
                   small=int(font == "s"), cen=int(center), xc=int(xcont), yc=int(ycont), lh=lh, box=int(box))

    def spr(self, x, y, img, col=0, field=None, scale=1, flip=False, step=0, cond=None):
        """step != 0: fractional size, step = 256 * 32 / size_in_pixels (source px per screen px x 256)"""
        self._emit("SPR", cond, x0=x, y0=y, img=img, fid=self.fmap[field] if field else 0,
                   scm1=scale - 1, flip=int(flip), step=step, col=0)

    def zoom(self, zf=None, zo=None, zinv=None, cond=None):
        """world zoom on (fields) / off (no arguments)"""
        if zinv:
            self._emit("ZOOM", cond, fa=self.fmap[zinv], fb=0, sub=1, x0=0, y0=0, col=0)
        else:
            self._emit("ZOOM", cond, fa=self.fmap[zf] if zf else 0, fb=self.fmap[zo] if zo else 0,
                       sub=0, x0=0, y0=0, col=0)

    def wires(self, cond=None):
        """all breadboard wires (Stage 2), drawn by the renderer from the wiring table"""
        self._emit("RECT", cond, x0=0, y0=0, x1=0, y1=0, col=0, alpha=0, afield=0, wires=1)

    def ofs(self, fx=None, sx=1, fy=None, sy=1, x0=0, y0=0, cond=None):
        self._emit("OFS", cond, fx=self.fmap[fx] if fx else 0, fy=self.fmap[fy] if fy else 0,
                   sx=sx, sy=sy, x0=x0, y0=y0, col=0)

    class _Block:
        def __init__(self, prog, cond):
            self.p, self.cond = prog, cond

        def __enter__(self):
            # "skip the block when the condition is FALSE" = SKIP with the negated condition
            c = self.cond[1:] if self.cond.startswith("!") else "!" + self.cond
            self.p._emit("SKIP", c, n=0, x0=0, y0=0, col=0)
            self.idx = len(self.p.ins) - 1
            return self

        def __exit__(self, *a):
            self.p.ins[self.idx][3]["n"] = len(self.p.ins) - self.idx - 1

    def when(self, cond):
        return Program._Block(self, cond)

    def end(self):
        self._emit("END", None, x0=0, y0=0, col=0)

    # ---------------------------------------------------------------- linking
    @staticmethod
    def wrap(text, n):
        out = []
        for para in text.split("\n"):
            cur = ""
            for w in para.split(" "):
                t = (cur + " " + w).strip()
                if len(t) <= n or not cur:
                    cur = t
                else:
                    out.append(cur)
                    cur = w
            out.append(cur)
        return "\n".join(out)

    def link(self):
        # string ROM: 0 = "", 1 = "(empty)", 9 = "(nothing)" (fixed, used by the term formatter)
        rom = [0, *b"(empty)", 0, *b"(nothing)", 0]
        addr = {"": 0, "(empty)": 1, "(nothing)": 9}

        def put(s):
            if s not in addr:
                addr[s] = len(rom)
                rom.extend(s.encode("ascii"))
                rom.append(0)
            return addr[s]

        for s in self.strings:
            put(s)
        ptr = []
        for key in self.tables:
            table, wrap = key
            self.tables[key] = len(ptr)
            for _, txt in ui_spec.TABLES[table]:
                ptr.append(put(self.wrap(txt, wrap) if wrap else txt))
        assert len(rom) <= 32768, "string ROM full (%d)" % len(rom)
        assert len(ptr) <= 512, "pointer ROM full"
        assert len(self.ins) <= 2048, "program ROM full (%d)" % len(self.ins)
        words = []
        for op, ci, neg, k in self.ins:
            A = B = 0
            if op in ("RECT", "CLRBG"):
                A = (s11(k["x1"]) << 10) | s10(k["y1"])
                if k.get("frect"):
                    A = (k["fx1"] << 14) | (k["fy1"] << 7)
                B = (k["alpha"] << 23) | (k["afield"] << 16) | (k.get("wires", 0) << 15) | (k.get("frect", 0) << 14)
            elif op == "CIRC":
                A = (k["r"] << 16) | (k["ri"] << 11)
                B = k["alpha"] << 23
            elif op == "TEXT":
                A = (k["sc2"] << 20) | (k["xc"] << 19) | (k["yc"] << 18) | (addr[k["s"]] << 3)
                B = ((0 if k["sc2"] else k["lh"] - 8) << 24) | (k["small"] << 23)
            elif op == "NUM":
                A = (k["sc2"] << 20) | (k["xc"] << 19) | (k["yc"] << 18) | (k["fid"] << 11) | (k["fmt"] << 7) | \
                    (k["width"] << 3) | (k["small"] << 2) | (k["cen"] << 1)
            elif op == "TEXTT":
                A = (k["sc2"] << 20) | (k["xc"] << 19) | (k["yc"] << 18) | (self.tables[k["key"]] << 9) | \
                    (k["fid"] << 2) | (k["small"] << 1) | k["cen"]
                B = (k["lh"] << 22) | (k["box"] << 21)
            elif op == "SPR":
                A = (k["img"] << 15) | (k["fid"] << 8) | (k["scm1"] << 6) | (k["flip"] << 5) | (k["step"] >> 4)
                k["col"] = (k["step"] & 15) << 8          # step[3:0] lives in ins[39:36] (sprites have no colour)
            elif op == "ZOOM":
                A = (k["fa"] << 14) | (k["fb"] << 7) | (k["sub"] << 6)
            elif op == "OFS":
                A = (k["fx"] << 14) | (k["fy"] << 7)
                B = (k["sx"] << 20) | (k["sy"] << 12)
            elif op == "SKIP":
                A = k["n"] << 11
            elif op == "S3":
                A = (k["sub"] << 19) | (k["tid"] << 13) | (k["fid"] << 6)
            w = (OPS[op] << 91) | (ci << 83) | (neg << 82) | (s11(k.get("x0", 0)) << 71) | \
                (s10(k.get("y0", 0)) << 61) | (A << 40) | (k.get("col", 0) << 28) | B
            words.append(w)
        self.words, self.rom, self.ptr = words, rom, ptr
        return words

    def write(self, mem_dir):
        with open(os.path.join(mem_dir, "ui_prog.mem"), "w") as f:
            for w in self.words + [0] * (2048 - len(self.words)):
                f.write("%024X\n" % w)
        with open(os.path.join(mem_dir, "ui_str.mem"), "w") as f:
            for c in self.rom + [0] * (32768 - len(self.rom)):
                f.write("%02X\n" % c)
        with open(os.path.join(mem_dir, "ui_ptr.mem"), "w") as f:
            for p in self.ptr + [0] * (512 - len(self.ptr)):
                f.write("%04X\n" % p)


# ====================================================================== composer model
def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class Composer:
    """Executes ui_prog exactly like ui_composer.v and returns (display list, text RAM)."""

    def __init__(self, prog):
        self.p = prog

    def run(self, fields, conds):
        F = lambda k: fields.get(k, 0) & 0xFFFFFF  # noqa: E731
        dl, tx = [], []
        offx = offy = lastx = lasty = nexty = 0
        zon, zf, zox, zoy, zinv = 0, 0, 0, 0, 65536
        pc = 0

        def zt(p, o):                       # world zoom transform (ui_composer.v zt())
            if not zon:
                return p
            m = (p - (o & 0x7FF)) * zf
            return sx(m >> 8, 12)
        words = self.p.words
        rom, ptr = self.p.rom, self.p.ptr

        def flush(x, y, start, n, col, sc2, sml, cen, lh):
            nonlocal lastx, lasty, nexty
            wid = n * (16 if sc2 else 6 if sml else 8)
            xe = x - (wid >> 1) if cen else x
            xe = sx(xe, 12)
            if n:
                dl.append(("TEXT", sx(xe, 11), sx(y, 10), col, sc2, start, n, sml))
            lastx, lasty, nexty = sx(xe + wid, 12), y, sx(y + lh, 12)

        while True:
            w = words[pc]
            op = w >> 91
            ci = (w >> 83) & 0xFF
            neg = (w >> 82) & 1
            x0 = sx(w >> 71, 11)
            y0 = sx(w >> 61, 10)
            A = (w >> 40) & ((1 << 21) - 1)
            col = (w >> 28) & 0xFFF
            B = w & ((1 << 28) - 1)
            ok = (1 if ci == 0 else int(bool(conds.get(ci, 0)))) ^ neg
            pc += 1
            if op == 0:
                break
            if op == 9:
                if ok:
                    pc += (A >> 11) & 0x3FF
                continue
            if not ok:
                continue
            ax0, ay0 = zt(sx(x0 + offx, 12), zox), zt(sx(y0 + offy, 12), zoy)
            if op in (1, 2) and (B >> 15) & 1:
                dl.append(("WIRES",))
            elif op in (1, 2):
                if (B >> 14) & 1:
                    ax1 = zt(sx(F((A >> 14) & 127), 12), zox)
                    ay1 = zt(sx(F((A >> 7) & 127), 12), zoy)
                else:
                    ax1 = zt(sx(sx(A >> 10, 11) + offx, 12), zox)
                    ay1 = zt(sx(sx(A, 10) + offy, 12), zoy)
                af = (B >> 16) & 0x7F
                alpha = (F(af) & 31) if (af and not (B >> 14) & 1) else (B >> 23) & 31
                dl.append(("RECT" if op == 1 else "CLRBG", sx(ax0, 11), sx(ay0, 10), sx(ax1, 11), sx(ay1, 10),
                           col, alpha))
            elif op == 3:
                r = (A >> 16) & 31
                if zon:
                    r = min(31, (r * zf) >> 8)
                dl.append(("CIRC", sx(ax0, 11), sx(ay0, 10), r, 0 if zon else (A >> 11) & 31, col, (B >> 23) & 31))
            elif op == 7:
                img = (((A >> 15) & 63) + (F((A >> 8) & 127) & 63)) & 63
                step = ((A & 31) << 4) | (col >> 8)
                if zon and step:
                    step = max(1, ((step * zinv) >> 16) & 511)
                dl.append(("SPR", sx(ax0, 11), sx(ay0, 10), img, (A >> 6) & 3, (A >> 5) & 1, step))
            elif op == 10:
                if (A >> 6) & 1:
                    zinv = F((A >> 14) & 127) & 0x1FFFF
                else:
                    v, o = F((A >> 14) & 127), F((A >> 7) & 127)
                    zon, zf, zox, zoy = int((v & 511) != 0), v & 511, o & 0xFFF, (o >> 12) & 0xFFF
            elif op == 11:
                fid = (A >> 6) & 127
                tid = (((A >> 13) & 63) + ((F(fid) & 63) if fid else 0)) & 63
                dl.append(("S3", (A >> 19) & 3, sx(ax0, 11), sx(ay0, 10), tid, col))
            elif op == 8:
                fx, fy = (A >> 14) & 127, (A >> 7) & 127
                offx = sx(sx(F(fx), 12) * ((B >> 20) & 255) + x0, 12)
                offy = sx(sx(F(fy), 12) * ((B >> 12) & 255) + y0, 12)
            elif op in (4, 5, 6):
                sc2, xc, yc = (A >> 20) & 1, (A >> 19) & 1, (A >> 18) & 1
                tx_x = lastx if xc else ax0
                tx_y = lasty if xc else (sx(nexty + y0, 12) if yc else ay0)
                start = len(tx)
                if op in (4, 6):
                    if op == 4:
                        s_addr, sml, cen = (A >> 3) & 0x7FFF, (B >> 23) & 1, 0
                        lh = 32 if sc2 else ((B >> 24) & 15) + 8
                    else:
                        s_addr = ptr[((A >> 9) & 0x1FF) + (F((A >> 2) & 127) & 0x1FF)]
                        lh, sml, cen = (B >> 22) & 63, (A >> 1) & 1, A & 1
                        if (B >> 21) & 1:               # box: reserved display-list slot
                            box_i = len(dl)
                            dl.append(None)
                    x0l = tx_x
                    n = 0
                    if not (op == 6 and (B >> 21) & 1):
                        box_i = None
                    while True:
                        c = rom[s_addr]
                        if c == 0:
                            flush(tx_x, tx_y, start, n, col, sc2, sml, cen, lh)
                            if box_i is not None:
                                wid = n * (16 if sc2 else 6 if sml else 8)
                                xe = sx(sx(tx_x - (wid >> 1), 12) if cen else tx_x, 12)
                                dl[box_i] = ("RECT", sx(xe - 8, 11), sx(tx_y - 5, 10), sx(xe + wid + 8, 11),
                                             sx(tx_y + 18, 10), 0, 16)
                            break
                        if c == 10:
                            flush(tx_x, tx_y, start, n, col, sc2, sml, cen, lh)
                            tx_y, tx_x, start, n = sx(tx_y + lh, 12), x0l, len(tx), 0
                        else:
                            tx.append(c & 127)
                            n += 1
                        s_addr += 1
                else:
                    fid, fmt, width = (A >> 11) & 127, (A >> 7) & 15, (A >> 3) & 15
                    sml, cen = (A >> 2) & 1, (A >> 1) & 1
                    lh = 32 if sc2 else (12 if sml else 16)
                    v = F(fid)
                    s = self.fmt(v, fmt, width)
                    tx.extend(ord(c) for c in s)
                    flush(tx_x, tx_y, start, len(s), col, sc2, sml, cen, lh)
        dl = [e for e in dl if e is not None]
        dl.append(("END",))
        assert len(dl) <= 256, "display list overflow (%d)" % len(dl)
        return dl, tx

    @staticmethod
    def term(b):
        s = ""
        for i in range(4):
            if b >> (7 - i) & 1:
                s += "ABCD"[i] + ("" if b >> (3 - i) & 1 else "'")
        return s

    def fmt(self, v, fmt, width):
        if fmt == 0:
            return str(v % 1000000).rjust(width, "0") if width else str(v % 1000000)
        if fmt == 1:
            return "".join("1" if v >> (k - 1) & 1 else "0" for k in range(width, 0, -1))
        if fmt == 2:
            return chr(65 + (v & 127))
        if fmt == 3:
            b = v & 255
            return ("-" + str(256 - b)) if b & 128 else str(b)
        if fmt == 4:
            return " ".join("".join(str(v >> (g * 4 + i) & 1) for i in range(4)) for g in range(4))
        if fmt == 5:
            t = self.term(v & 255)
            return t if t else {1: "(empty)", 2: "(nothing)"}.get(width, "")
        if fmt == 6:
            return " + ".join(t for t in (self.term(v & 255), self.term(v >> 8 & 255), self.term(v >> 16 & 255)) if t)
        if fmt == 7:
            return "".join(chr(65 + (v >> s & 31)) for s in (0, 8, 16))
        return ""


# ====================================================================== renderer model
class Assets:
    def __init__(self, mem=MEM):
        rd = lambda n: [int(l, 16) for l in open(os.path.join(mem, n))]  # noqa: E731
        self.font = rd("font8x16.mem")
        self.circ = rd("circ.mem")
        self.spr = rd("spr.mem")
        self.spal = rd("spr_pal.mem")
        # Stage 1 / Stage 2 rooms (bg_mode 1 / 2) are streamed from the QSPI flash (pic_stream.v): the colours
        # are the decoded 4:4:4 previews written by pic_pack.py. arr = 12-bit colour per pixel, pal = identity.
        def room(name):
            a = np.asarray(Image.open(os.path.join(mem, "preview", "pic_%s.png" % name)).convert("RGB"),
                           dtype=np.int32)
            assert a.shape == (358, 640, 3) and not np.any(a % 17), "pic_%s.png is not 640x358 4:4:4" % name
            a = a // 17
            return (a[:, :, 0] << 8) | (a[:, :, 1] << 4) | a[:, :, 2], list(range(4096))
        self.bg = {1: room("S1_ROOM"), 2: room("S2_ROOM")}
        try:                                       # Stage 2 breadboard + wires (stage2_assets.py)
            tiles, bmap, bpal = rd("s2_btile.mem"), rd("s2_bmap.mem"), rd("s2_bpal.mem")
            img = np.zeros((360, 640), dtype=np.int32)
            for ty in range(45):
                for tx in range(80):
                    t = bmap[ty * 80 + tx]
                    for y in range(8):
                        w = tiles[t * 8 + y]
                        for x in range(8):
                            img[ty * 8 + y, tx * 8 + x] = (w >> (6 * (7 - x))) & 63
            self.board = (img, bpal)
            self.wire = rd("s2_wire.mem")
        except FileNotFoundError:
            self.board, self.wire = None, None
        try:
            self.s3_solid = rd("s3_solid.mem")
            self.s3_tidx = rd("s3_tidx.mem")
            self.s3_txt = rd("s3_txt.mem")
            self.sin = [v - 256 if v > 127 else v for v in rd("sin256.mem")]
        except FileNotFoundError:
            self.s3_solid = None


SRC_COL = {1: 0xE55, 2: 0x68F}


def src_col(s):
    if s in SRC_COL:
        return SRC_COL[s]
    return 0xFC4 if s <= 5 else 0xB8F if s <= 8 else 0x5CF if s <= 12 else 0x7E7 if s <= 20 else 0xE94


def s3_ter_on(k, lx, by):
    return lx >= 0 or (k == 5 and (lx - 3) ** 2 + (by - 8) ** 2 <= 64)


def s3_ter_col(k, lx, w, ty, by, h):
    """draw_terrain() colours at 32 px per metre (line_renderer.v ter_col)"""
    incell = lx < (w & ~31) and by < (h & ~31)
    edge = (lx & 31) in (0, 31) or (by & 31) in (0, 31)
    if k == 1:
        return 0x4A4 if ty < 10 else 0x853
    if k == 2:
        return 0x666 if incell and edge else 0x899
    if k == 3:
        return 0x654 if incell and edge else 0x889 if incell and not ((lx >> 5) ^ (by >> 5)) & 1 else 0x975
    if k == 4:
        return 0x753 if ty < 4 else 0x863 if (lx & 15) == 0 and lx < (w & ~15) else 0xB85
    return 0x631 if ty < 3 else 0xC96 if (lx - 3) ** 2 + (by - 8) ** 2 <= 64 else 0x742


def render(dl, tx, assets, bg_mode, bg_color=0x112, bg_color2=0, cam=(0, 0), zoom=(0, 0, 65536),
           wires=None, s3=(0, 0, 0)):
    """Returns a 640x480 RGB image (4-bit channels expanded) exactly like line_renderer.v.
    wires = (wire_src list of 54, src_val bit mask, highlight sink or None)
    s3 = (camera px, water phase, hills phase) for the Stage 3 primitives"""
    K = np.full((360, 640), 16, dtype=np.int32)
    R = np.zeros((360, 640, 3), dtype=np.int32)

    def blend(y, x, c, a, clr=False):
        if not (0 <= x < 640):
            return
        if clr:
            K[y, x] = 16
            R[y, x] = 0
            return
        cc = ((c >> 8) & 15, (c >> 4) & 15, c & 15)
        if a == 16:
            K[y, x] = 0
            R[y, x] = cc
            return
        ik = 16 - a
        K[y, x] = ((K[y, x] * ik + 8) >> 4) & 31
        for i in range(3):
            R[y, x, i] = ((R[y, x, i] * ik + cc[i] * a + 8) >> 4) & 15

    for e in dl:
        t = e[0]
        if t == "END":
            break
        for y in range(360):
            if t in ("RECT", "CLRBG"):
                _, x0, y0, x1, y1, c, a = e
                if y0 <= y < y1 and x1 > x0:
                    for x in range(max(x0, 0), min(x1, 640)):
                        blend(y, x, c, a, t == "CLRBG")
            elif t == "CIRC":
                _, cx, cy, r, ri, c, a = e
                dy = abs(y - cy)
                if dy <= r:
                    hw = assets.circ[r * 32 + dy]
                    ex = None
                    if ri and dy <= ri:
                        h2 = assets.circ[ri * 32 + dy]
                        ex = (cx - h2, cx + h2)
                    for x in range(cx - hw, cx + hw + 1):
                        if ex and ex[0] <= x <= ex[1]:
                            continue
                        blend(y, x, c, a)
            elif t == "TEXT":
                _, x0, y0, c, sc2, start, n, sml = e
                d = y - y0
                h = 32 if sc2 else 12 if sml else 16
                if 0 <= d < h:
                    row = d >> 1 if sc2 else d
                    w = 16 if sc2 else 6 if sml else 8
                    px = 0
                    for i in range(n):
                        g = assets.font[(sml << 11) | (tx[start + i] << 4) | (row & 15)]
                        for b in range(w):
                            bit = b >> 1 if sc2 else b
                            if g >> (7 - bit) & 1:
                                blend(y, x0 + px, c, 16)
                            px += 1
            elif t == "WIRES":
                ws, sv, hl = wires
                for i in range(54):
                    sidx = ws[i]
                    if not sidx:
                        continue
                    w = assets.wire[i * 28 + sidx]
                    x1, y1, x2, y2, ym = w >> 37, (w >> 28) & 511, (w >> 18) & 1023, (w >> 9) & 511, w & 511
                    c = 0xFF7 if hl == i else (src_col(sidx) if (sv >> sidx) & 1 else
                                               (((src_col(sidx) >> 9) & 7) << 8) | (((src_col(sidx) >> 5) & 7) << 4) |
                                               ((src_col(sidx) >> 1) & 7))
                    spans = []
                    if min(y1, ym) <= y <= max(y1, ym):
                        spans.append((x1 - 1, x1 + 1, c))
                    if y == ym or y + 1 == ym:
                        spans.append((min(x1, x2) - 1, max(x1, x2) + 1, c))
                    if min(ym, y2) <= y <= max(ym, y2):
                        spans.append((x2 - 1, x2 + 1, c))
                    if y + 2 >= y1 and y <= y1 + 2:
                        spans.append((x1 - 2, x1 + 3, c))
                    if y + 2 >= y2 and y <= y2 + 2:
                        spans.append((x2 - 2, x2 + 3, c))
                        spans.append((x2 - 1, x2 + 2, 0xFA4))
                    for a, b, cc in spans:
                        for x in range(a, b):
                            blend(y, x, cc, 16)
            elif t == "S3":
                _, sub, x0, y0, tid, c = e
                s3cam, wph, hph = s3
                if sub == 0 and y >= 294:
                    for x in range(640):
                        sv = assets.sin[(((x * 2086) >> 10) + wph) & 255]
                        if y >= 299 or y >= 296 + ((sv * 2 + 64) >> 7):
                            blend(y, x, 0x28D, 14)
                elif sub == 3 and y >= 165:
                    for x in range(640):
                        sv = assets.sin[((x * 139 + hph) >> 8) & 255]
                        if y >= 200 - ((sv * 35 + 64) >> 7):
                            blend(y, x, 0x9D9, 16)
                elif sub == 1:
                    for wd in assets.s3_solid:
                        k = wd >> 46
                        if k == 0:
                            break
                        t0, t1 = (wd >> 33) & 8191, (wd >> 20) & 8191
                        y0s, y1s = sx(wd >> 10, 10), sx(wd, 10)
                        if k == 6 or y < y0s or y >= y1s or t1 <= s3cam or t0 >= s3cam + 640:
                            continue
                        ext = 5 if k == 5 else 0
                        lx = s3cam - t0 if t0 - ext < s3cam else -ext
                        while t0 + lx < t1 and t0 + lx - s3cam < 640:
                            if s3_ter_on(k, lx, y1s - 1 - y):
                                blend(y, t0 + lx - s3cam,
                                      s3_ter_col(k, lx, t1 - t0, y - y0s, y1s - 1 - y, y1s - y0s), 16)
                            lx += 1
                elif sub == 2:
                    ent = assets.s3_tidx[tid]
                    off, w, h = ent >> 16, (ent >> 6) & 1023, ent & 63
                    if y0 <= y < y0 + h:
                        base = off + (y - y0) * ((w + 7) >> 3)
                        for px in range(w):
                            if assets.s3_txt[(base + (px >> 3)) & 0x3FFF] >> (7 - (px & 7)) & 1:
                                blend(y, x0 + px, c, 16)
            elif t == "SPR" and e[6]:              # fractional size
                _, x0, y0, img, scm1, flip, step = e
                d = y - y0
                if d >= 0 and (d * step) >> 8 < 32:
                    row = ((d * step) >> 8) & 31
                    acc, px = 0, 0
                    while (acc >> 8) < 32:
                        sxp = acc >> 8
                        xx = 31 - sxp if flip else sxp
                        i = assets.spr[img * 1024 + row * 32 + xx]
                        if i:
                            blend(y, x0 + px, assets.spal[i], 16)
                        px += 1
                        acc += step
            elif t == "SPR":
                _, x0, y0, img, scm1, flip, _step = e
                S = scm1 + 1
                d = y - y0
                if 0 <= d < 32 * S:
                    row = d // S
                    px = 0
                    for sxp in range(32):
                        xx = 31 - sxp if flip else sxp
                        i = assets.spr[img * 1024 + row * 32 + xx]
                        for _ in range(S):
                            if i:
                                blend(y, x0 + px, assets.spal[i], 16)
                            px += 1
    img = np.zeros((480, 640, 3), dtype=np.int32)
    for y in range(360):
        if bg_mode == 1:
            arr, pal = assets.bg[1]
            sy = (cam[1] + y) >> 1
            row = [pal[arr[sy, (cam[0] + x) >> 1]] for x in range(640)]
        elif bg_mode == 2:
            arr, pal = assets.bg[2]
            zy = zoom[1] + ((y * zoom[2]) >> 16)
            row = [pal[arr[min(zy, 357), min(zoom[0] + ((x * zoom[2]) >> 16), 639)]] for x in range(640)]
        elif bg_mode == 4:
            arr, pal = assets.board
            row = [pal[arr[y, x]] for x in range(640)]
        elif bg_mode == 3:
            t = (y * 45) >> 4
            row = [sky12(t, ((y & 1) << 1) | (x & 1)) for x in range(640)]
        else:
            row = [bg_color] * 640
        for x in range(640):
            b = row[x]
            k = K[y, x]
            for i, sh in enumerate((8, 4, 0)):
                v = (((b >> sh) & 15) * k + 8 >> 4) + R[y, x, i]
                img[60 + y, x, i] = min(15, v)
    return (img * 17).astype("uint8")


SKY0, SKY1 = 0x58B4EE, 0xD3F0FC


def sky12(t, dp):
    """Stage 3 sky (line_renderer.v sky4): 8-bit gradient, 2x2 ordered dither to 4 bit"""
    out = 0
    for sh in (16, 8, 0):
        a, b = (SKY0 >> sh) & 255, (SKY1 >> sh) & 255
        c8 = a + (((b - a) * t) >> 10)
        o = ((c8 * 241) >> 8) + (2, 10, 14, 6)[dp]
        out = (out << 4) | min(15, o >> 4)
    return out


def lerp(a, b, t):
    out = 0
    for sh in (8, 4, 0):
        ca, cb = (a >> sh) & 15, (b >> sh) & 15
        out |= ((ca + (((cb - ca) * t) >> 10)) & 15) << sh
    return out


# ====================================================================== main
def build():
    import ui_screens
    prog = ui_screens.build_program()
    prog.link()
    prog.write(MEM)
    ui_spec.write_vh(os.path.join(ROOT, "rtl", "ui", "ui_map.vh"))
    print("ui_prog: %d instructions, strings %d bytes, pointers %d" % (len(prog.words), len(prog.rom), len(prog.ptr)))
    return prog


if __name__ == "__main__":
    prog = build()
    if "--preview" in sys.argv:
        import ui_screens
        assets = Assets()
        out = os.path.join(MEM, "preview")
        os.makedirs(out, exist_ok=True)
        for name, (f, c, bg) in ui_screens.preview_states().items():
            dl, tx = Composer(prog).run(f, c)
            Image.fromarray(render(dl, tx, assets, *bg)).save(os.path.join(out, "ui_%s.png" % name))
            print("  preview %-14s %3d primitives" % (name, len(dl)))
