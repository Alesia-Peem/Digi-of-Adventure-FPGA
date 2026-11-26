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


# ---------------- flow: reporter, skills, lifts, tea, doors ----------------
def done(run, *must_have):
    assert not run.first_diff, run.first_diff
    missing = [k for k in must_have if k not in run.seen]
    assert not missing, "the scenario never showed: %s" % missing
    print("      %5d steps, worst %.3f mm, %d ties" % (run.t, run.worst, len(run.ties)))


def meet_snail():
    """stand on the first snail's ground and wait for it to walk into us"""
    snail = H.tables()[1][2][0]
    r = H.Run(1).put(snail["x"] - 4, snail["y"])
    return r.until(lambda g: g.chase, 2000)


def test_chase_then_interview():
    r = meet_snail().hold(100, 1).hold(100, -1)
    r.until(lambda g: g.interview > 0, 3000)
    done(r.hold(900), "chase", "interview", "message 10")


def test_cloak_refused_without_chase():
    r = H.Run(1).hold(200)
    r.step(skill=True)
    done(r.hold(10), "message 7")
    assert not r.m.used


def test_cloak_follow_then_retreat():
    for walk in (0, 1, -1):
        r = meet_snail().hold(60, walk)
        r.step(skill=True)
        done(r.hold(700), "follow", "retreat", "used")


def test_phase_ignores_hits():
    r = H.Run(3).put(14.5, surface(3, 14))
    r.hold(100)
    r.step(skill=True)
    done(r.hold(900), "used")


def test_lift_ride_both_kinds():
    for column, top in ((163, 4.0), (208, 5.0)):
        r = H.Run(3).put(column, top).hold(700)
        assert abs(r.g.p.y - r.g.lifts[0 if column == 163 else 1].top) < .01, "fell off the lift"
        done(r.hold(60, 1).hold(200))


def test_tea_gold_growth():
    h = ground_under(2, 240)
    r = H.Run(2).put(240.5, h)
    r.step(jump=True)
    r.hold(120)
    r.step(jump=True)
    r.hold(40, 1).hold(300, 1).hold(500)
    done(r, "opened", "gold", "message 8", "message 9")


def test_door_stage2_needs_tea():
    r = H.Run(2).put(247.5, surface(2, 247)).hold(60)
    done(r, "message 14", "mode %d stage 2" % M.PLAY)
    r.g.gold = r.m.gold = True
    done(r.hold(400), "mode %d stage 2" % M.CLEAR, "mode %d stage 3" % M.PLAY, "message 6")


def test_clear_to_next_level():
    r = H.Run(1).put(236.5, 2).hold(5)
    r.put(246.5, 2).hold(400)
    done(r, "mode %d stage 1" % M.CLEAR, "mode %d stage 2" % M.PLAY, "message 5", "near", "message 11")


def test_win_stage3():
    r = H.Run(3).put(230.5, surface(3, 230)).hold(5)
    r.put(247.5, surface(3, 247)).hold(100)
    done(r, "mode %d stage 3" % M.WIN, "message 13")
    r.m.confirm()
    assert r.m.exit_req


def test_timeout_at_14400():
    r = H.Run(1)
    for t in range(14405):
        r.step()
        if r.g.message.startswith("Time up"):
            break
    assert r.t == 14400, "timed out after %d steps" % r.t
    done(r, "message 2", "interview")


def test_restart_clears_everything():
    for cause in ("chase", "interview", "tea", "lift"):
        if cause == "lift":
            r = H.Run(3).put(208, 5.0).hold(150)
        elif cause == "tea":
            r = H.Run(2).put(240.5, ground_under(2, 240))
            r.step(jump=True)
            r.hold(60)
        else:
            r = meet_snail()
            if cause == "interview":
                r.hold(100, 1).until(lambda g: g.interview > 0, 3000, -1).hold(50)
        r.put(100.5, -2, False).hold(400)             # off the bottom: restart, then play on
        done(r)


def test_pause_in_each_mode():
    r = meet_snail().hold(100, 1).until(lambda g: g.interview > 0, 3000, -1).hold(10)
    r.step(menu=True)
    r.hold(50, 1, jump=True)
    r.step(menu=True)
    done(r.hold(700), "interview")
    r = H.Run(1).put(246.5, 2)
    r.until(lambda g: g.mode == "clear", 100)
    r.step(menu=True)                                 # ignored while clearing
    done(r.hold(300), "mode %d stage 2" % M.PLAY)
    r = H.Run(3).put(247.5, surface(3, 247)).hold(100)
    r.step(menu=True)                                 # ignored on the win screen
    done(r.hold(10), "mode %d stage 3" % M.WIN)


def test_random_full_game():
    seen, steps, worst, ties = set(), 0, 0., {}
    for stage in (1, 2, 3):
        for seed in range(8):
            rng = random.Random(1000 * stage + seed)
            r = H.Run(stage, seed=seed + 1)
            axis = 1
            for t in range(5000):
                if rng.random() < .02:
                    axis = rng.choice((1, 1, 1, 0, -1))
                if t % 600 == 599:                    # jump ahead to see the whole level
                    col = rng.randrange(8, 244)
                    if r.g.mode == "play" and not r.g.interview and surface(stage, col):
                        r.put(col + .5, surface(stage, col))
                r.step(axis, rng.random() < .025, rng.random() < .004, rng.random() < .001)
                if r.first_diff:
                    break
                if r.g.mode == "pause" and rng.random() < .05:
                    r.step(menu=True)
            assert not r.first_diff, "stage %d seed %d: %s" % (stage, seed, r.first_diff)
            seen |= r.seen
            for _, name in r.ties:
                key = name.split(" of animal")[0]
                ties[key] = ties.get(key, 0) + 1
            steps, worst = steps + r.t, max(worst, r.worst)
    print("      %d steps, worst %.3f mm; ties %s; seen: %s" %
          (steps, worst, ties, sorted(k for k in seen if not k.startswith(("mode", "message")))))


# ---------------- scenarios (also the RTL stimulus) ----------------
def test_routes_clear_every_level():
    for stage in (1, 2, 3):
        r = H.play("plan%d" % stage)
        cleared = "mode %d stage %d" % (M.WIN if stage == 3 else M.CLEAR, stage)
        done(r, cleared)
        end = (stage, M.WIN) if stage == 3 else (stage + 1, M.PLAY)     # levels 1, 2 go on into the next one
        assert (r.g.stage, H.MODES[r.g.mode]) == end == (r.m.stage, r.m.mode), \
            "plan%d ends in stage %d mode %s at x=%.1f" % (stage, r.g.stage, r.g.mode, r.g.p.x)
        assert (stage == 3) == r.m.exit_req


def test_scenarios_match_the_game():
    must = {"careless": {"chase"}, "skill": {"used", "retreat"}, "interview": {"interview"}, "pit": {"message 3"},
            "lift": {"message 4"}, "timeout": {"message 2"}, "restart": {"message 3", "chase"},
            "buttons": {"used", "mode 1 stage 3"}}
    assert set(H.SCEN) == set(must) | {"plan1", "plan2", "plan3"}
    for name, wanted in sorted(must.items()):
        r = H.play(name)
        done(r, *wanted)


def test_stimulus_words_replay_the_same_run():
    r = H.play("tea") if "tea" in H.SCEN else H.play("plan2")
    again = H.Run(1)
    for w in r.words:
        again.word(w)
    assert again.first_diff is None and again.trace == r.trace and len(r.trace) > 1000
    assert all(len(row) == len(M.Model.HEADER) for row in r.trace)


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
    print("CR_TEST_MODEL: %s" % ("FAIL (%d)" % failed if failed else "PASS"))
    sys.exit(1 if failed else 0)
