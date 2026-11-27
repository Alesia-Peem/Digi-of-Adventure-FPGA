#!/usr/bin/env python3
"""cr_test_frame.py - the frame reference (cr_frame.py) against render.draw_frame().
Run: python3 -I fpga/tools/cr_test_frame.py"""
import os
import sys
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402
import cr_cosim as H  # noqa: E402
import cr_frame as FR  # noqa: E402


def test_row_map_is_pillows_nearest():
    """the 352 -> 360 stretch of render.py:200 is Pillow's NEAREST; FR.ROW_MAP must be exactly its row choice"""
    src = Image.fromarray(np.arange(352, dtype=np.int32).repeat(4).reshape(352, 4), "I")      # 32-bit: no wrap
    rows = np.asarray(src.resize((4, 360), Image.Resampling.NEAREST))[:, 0]
    assert list(rows) == FR.ROW_MAP, [i for i, (a, b) in enumerate(zip(rows, FR.ROW_MAP)) if a != b][:5]


def test_world_frame_matches_draw_frame():
    """every 7th step of several scenarios: the world frame drawn from fields / conds / footprint port equals the
    world frame render.py draws (effects the core cannot know are off in both, see cr_frame.py)"""
    frames = diff_frames = 0
    for name in ("skill", "interview", "lift", "careless", "retreat", "pit", "buttons"):
        run = H.Run(1)
        words = [int(l, 16) for l in open(os.path.join(H.SIM, "cr_%s_stim.mem" % name))][1:]
        for t, w in enumerate(words):
            run.word(w)
            if t % 7 or (w & H.CMD):
                continue
            want = FR.original_world(run.g)
            got = FR.world(*run.m.publish(), run.m.q_words(), assets="exact")
            n = int(np.any(np.asarray(want) != np.asarray(got), axis=2).sum())
            frames += 1
            if n:
                _, _, near = H.render_fields(run.g)
                assert near, "%s step %d: %d pixels differ and no float tie explains it" % (name, run.t, n)
                diff_frames += 1
            assert not run.first_diff, run.first_diff
    print("      %d frames compared, %d differ only where a float tie moved something by 1 px" % (frames, diff_frames))
    assert frames > 500 and diff_frames <= frames // 50


def test_rom_frames_are_close():
    """what the hardware will show (4-bit tiles, 16-colour sprites) stays close to the exact frame"""
    run = H.Run(2)
    words = [int(l, 16) for l in open(os.path.join(H.SIM, "cr_careless_stim.mem"))][1:]
    scores = []
    for t, w in enumerate(words[:600]):
        run.word(w)
        if t % 60 == 59:
            pub = run.m.publish(), run.m.q_words()
            a = np.asarray(FR.world(*pub[0], pub[1], assets="exact"), float)
            b = np.asarray(FR.world(*pub[0], pub[1], assets="rom"), float)
            mse = np.mean((a - b) ** 2)
            scores.append(99. if mse == 0 else 10 * np.log10(255 ** 2 / mse))
    print("      ROM frames vs exact: mean PSNR %.1f dB, worst %.1f dB" % (np.mean(scores), min(scores)))
    assert min(scores) >= 24


if __name__ == "__main__":
    failed = 0
    only = sys.argv[1:]
    for name, fn in list(globals().items()):
        if name.startswith("test_") and (not only or any(o in name for o in only)):
            try:
                fn()
                print("ok    %s" % name)
            except Exception:
                failed += 1
                print("FAIL  %s\n%s" % (name, traceback.format_exc()))
    print("CR_TEST_FRAME: %s" % ("FAIL (%d)" % failed if failed else "PASS"))
    sys.exit(1 if failed else 0)
