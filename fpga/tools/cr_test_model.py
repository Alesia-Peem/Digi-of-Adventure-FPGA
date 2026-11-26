#!/usr/bin/env python3
"""cr_test_model.py - tests of cr_model.py. Run: python3 -I fpga/tools/cr_test_model.py"""
import os
import sys
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import random  # noqa: E402
import cr_model as M  # noqa: E402
import cr_cosim as H  # noqa: E402

IDLE, RIGHT, LEFT = (0, False, False), (1, False, False), (-1, False, False)


def check(seconds, limit, want):
    got = M.timer_steps(seconds, limit)
    assert got == want, "timer_steps(%r, %r) = %r, the game takes %d steps" % (seconds, limit, got, want)


def test_timers_that_leave_a_residue():
    check(.15, 0, 19)           # coyote time and jump buffer: one step more than 0.15 * 120
    check(2.0, 0, 241)          # the on-screen notice


def test_timers_tested_with_eps():
    check(5, M.EPS, 600)        # skill and interview
    check(2.0, M.EPS, 240)      # retreat and level clear
    check(.6, M.EPS, 72)        # cloak follow


def test_other_game_timers():
    check(.45, 0, 54)           # phase flash
    check(.65, 0, 78)           # protection after a hit
    check(1.0, 0, 121)          # protection after an interview
    check(120, 0, 14400)        # the level time limit


# ---------------- terrain features, found in the maps instead of typed in ----------------
def surface(stage, col):
    """height of the top surface standing in this column, or None"""
    solid = H.tables()[stage][0]
    return None if not solid[col] else solid[col].bit_length()


def find(stage, want):
    for col in range(8, 240):
        if want(stage, col):
            return col
    raise AssertionError("no such feature in stage %d" % stage)


def flat(n):
    def want(stage, col):
        h = surface(stage, col)
        solid, water = H.tables()[stage][:2]
        return h is not None and h <= 3 and all(solid[c] == solid[col] and not water[c] for c in range(col, col + n))
    return want


def ledge(stage, col):              # flat ground, then nothing at all
    solid = H.tables()[stage][0]
    return all(surface(stage, c) == surface(stage, col) for c in range(col - 3, col + 1)) \
        and surface(stage, col) is not None and not solid[col + 1] and not solid[col + 2]


def step_up(stage, col):            # a wall one or two tiles high on the right
    a, b = surface(stage, col), surface(stage, col + 1)
    return a is not None and b is not None and b - a in (1, 2) and surface(stage, col - 2) == a


def overhang(stage, col):           # a block with at least 1.5 m of air under it, within first-jump reach
    solid = H.tables()[stage][0]
    ground = next((y + 1 for y in range(4) if solid[col] >> y & 1 and not solid[col] >> (y + 1) & 1), None)
    return ground is not None and any(solid[col] >> y & 1 and not solid[col] >> (y - 1) & 1
                                      for y in (ground + 2, ground + 3))


def ground_under(stage, col):
    solid = H.tables()[stage][0]
    return next(y + 1 for y in range(4) if solid[col] >> y & 1 and not solid[col] >> (y + 1) & 1)


def press(n, *at, axis=1):
    return [(axis, t in at, False) for t in range(n)]


def agree(results, label):
    bad = ["%s: %s" % (k, r.first_diff) for k, r in results if r.first_diff]
    assert not bad, "%d of %d differ, first: %s" % (len(bad), len(results), bad[:3])
    print("      %-30s %4d runs, worst %.3f mm, %d deaths" %
          (label, len(results), max(r.worst_mm for _, r in results), sum(r.deaths for _, r in results)))


def standing(stage, col, height, dx=.5):
    return lambda g, m: H.teleport(g, m, col + dx, height)


# ---------------- sweeps ----------------
def test_double_jump_at_every_step():
    col = find(1, flat(12))
    at = standing(1, col, surface(1, col))
    agree([((k, axis), H.compare(press(220, 5, 5 + k, axis=axis), 1, at))
           for k in range(1, 141) for axis in (0, 1)], "double jump, press 1..140")


def test_coyote_time():
    col = find(3, ledge)
    at = standing(3, col, surface(3, col), dx=.2)
    g, m = H.original(3, True), H.model(3)
    at(g, m)
    left = next(t for t in range(200) if (g.step(1 / 120, 1), not g.p.grounded)[1])
    agree([(k, H.compare(press(left + 160, left + 1 + k), 3, at)) for k in range(23)], "coyote time, 0..22 steps")


def test_jump_buffer():
    col = find(1, flat(12))
    at = standing(1, col, surface(1, col))
    g = H.original(1, True)
    at(g, H.model(1))
    for t in range(300):
        g.step(1 / 120, 0, t == 5)
        if t > 5 and g.p.grounded:
            break
    land = t
    agree([((k, 'single'), H.compare(press(land + 120, 5, land - k, axis=0), 1, at)) for k in range(23)]
          + [((k, 'after double'), H.compare(press(land + 200, 5, 40, land + 40 - k, axis=0), 1, at))
             for k in range(45)], "buffer / early press")


def test_wall_push():
    col = find(1, step_up)
    for_right = standing(1, col - 2, surface(1, col - 2))
    for_left = standing(1, col + 1, surface(1, col + 1))
    agree([("right", H.compare([RIGHT] * 240, 1, for_right)), ("left", H.compare([LEFT] * 240, 1, for_left)),
           ("jump into it", H.compare(press(240, 20, 40), 1, for_right))], "wall push")


def test_head_bump():
    col = find(1, overhang)
    at = standing(1, col, ground_under(1, col))
    agree([(k, H.compare(press(200, 5, 5 + k, axis=0), 1, at)) for k in (1, 10, 30, 60)], "head bump")


def test_fast_fall_onto_stacked_tiles():
    out = []
    for stage in (1, 2, 3):
        for col in range(10, 240, 7):
            out.append(((stage, col), H.compare([IDLE] * 400, stage,
                                                lambda g, m, c=col: H.teleport(g, m, c + .5, 30, False))))
    agree(out, "fall from 30 m")


def test_late_double_jump_far_below_takeoff():
    col = find(3, ledge)
    at = lambda g, m: H.teleport(g, m, col + 2.5, 10)           # in the air over a pit, counted as standing
    agree([((k, a), H.compare(press(300, 0, k, axis=a), 3, at)) for k in range(100, 137) for a in (0, 1)],
          "late double jump over a pit")


def test_random_play():
    out = []
    for stage in (1, 2, 3):
        for seed in range(6):
            rng = random.Random(seed * 10 + stage)
            script, axis = [], 1
            for _ in range(6000):
                if rng.random() < .02:
                    axis = rng.choice((1, 1, 1, 0, -1))
                script.append((axis, rng.random() < .025, False))
            out.append(((stage, seed), H.compare(script, stage)))
    agree(out, "random play, 6000 steps each")


def test_lfsr_is_the_verilog_one():
    r = M.Lfsr16(0xACE1)
    r.step()
    assert r.q == 0x59C3                          # lfsr16.v: fb = q15 ^ q14 ^ q12 ^ q3
    assert M.Lfsr16(0).q == 0xACE1
    pairs = [M.Lfsr16(seed).pair(15) for seed in range(1, 2000)]
    assert all(i != j and 0 <= i < 15 and 0 <= j < 15 for i, j in pairs)
    assert len(set(pairs)) > 150, "question pairs hardly vary: %d of 210" % len(set(pairs))


def test_animals_follow_the_game():
    for stage in (1, 2, 3):
        for steps in (14000, 6000):
            r, st = H.compare_animals(stage, steps, seed=stage + steps)
            assert not r.first_diff, "stage %d: %s" % (stage, r.first_diff)
            print("      stage %d, %5d steps: worst %.3f mm, %d animals woke, %d hits, %d dead" %
                  (stage, steps, r.worst_mm, len(st["woke"]), st["contacts"], st["dead"]))
            assert len(st["woke"]) == len(H.tables()[stage][2]) and st["contacts"] > 0


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
    print("CR_TEST_MODEL: %s" % ("FAIL (%d)" % failed if failed else "PASS"))
    sys.exit(1 if failed else 0)
