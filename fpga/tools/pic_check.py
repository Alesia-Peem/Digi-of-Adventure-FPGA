#!/usr/bin/env python3
"""pic_check.py - exact pixel check of the pic_stream testbench output against the packer previews.

    python3 -I fpga/tools/pic_check.py TITLE S2_ROOM TITLE_RELOAD=TITLE

NAME or PPMNAME=PREVIEWNAME (compare sim/frames/pic_PPMNAME.ppm with mem/preview/pic_PREVIEWNAME.png).

For every NAME: reads fpga/sim/frames/pic_<NAME>.ppm (written by tb_pic_stream: P3, maxval 15,
"# rows r0 r1 ..." comment = which picture rows were streamed, in file order) and compares each row
with the same row of fpga/mem/preview/pic_<NAME>.png (made by pic_pack.py = exactly what the FPGA
must show; 4-bit channels x 17). Prints "PIC_CHECK: PASS ..." or the first differences; exit 1 on FAIL.
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FPGA = os.path.dirname(HERE)


def read_ppm(path):
    rows, tokens = None, []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                if line.startswith("# rows"):
                    rows = [int(t) for t in line.split()[2:]]
                continue
            tokens += line.split()
    assert tokens[0] == "P3", path
    w, h, mx = int(tokens[1]), int(tokens[2]), int(tokens[3])
    # unknown RTL values ('x' / 'z') become -1 -> never equal to the preview
    vals = np.array([int(t) if t.isdigit() else -1 for t in tokens[4:4 + w * h * 3]], np.int64)
    assert mx == 15 and len(vals) == w * h * 3, "%s: truncated (%d values)" % (path, len(vals))
    assert rows is not None and len(rows) == h, "%s: '# rows' comment missing" % path
    return rows, vals.reshape(h, w, 3) * 17


def check(arg):
    name, _, prev = arg.partition("=")
    ppm = os.path.join(FPGA, "sim", "frames", "pic_%s.ppm" % name)
    png = os.path.join(FPGA, "mem", "preview", "pic_%s.png" % (prev or name))
    if not os.path.isfile(ppm):
        print("PIC_CHECK: FAIL %s (no %s)" % (name, ppm))
        return False
    rows, got = read_ppm(ppm)
    ref = np.asarray(Image.open(png).convert("RGB"))
    if got.shape[1] != ref.shape[1]:
        print("PIC_CHECK: FAIL %s width %d, preview %d" % (name, got.shape[1], ref.shape[1]))
        return False
    exp = ref[rows].astype(np.int64)
    diff = np.any(got != exp, axis=2)
    nbad = int(diff.sum())
    if nbad:
        ys, xs = np.nonzero(diff)
        for y, x in list(zip(ys, xs))[:5]:
            print("  %s row %d x %d: got %s expected %s" % (name, rows[y], x, got[y, x], exp[y, x]))
        print("PIC_CHECK: FAIL %s %d of %d pixels differ" % (name, nbad, diff.size))
        return False
    print("PIC_CHECK: PASS %s (%d rows x %d px identical to the preview)" % (name, len(rows), got.shape[1]))
    return True


def main(names):
    ok = all([check(n) for n in names])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main(sys.argv[1:] or ["TITLE", "S2_ROOM", "TITLE_RELOAD=TITLE"])
