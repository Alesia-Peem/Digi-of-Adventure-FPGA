#!/usr/bin/env python3
"""cr_test_assets.py - tests of cr_assets.py against onlystage_3. Run: python3 -I fpga/tools/cr_test_assets.py"""
import os
import sys
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr_assets as A  # noqa: E402


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
