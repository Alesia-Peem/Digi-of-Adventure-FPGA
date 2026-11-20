#!/usr/bin/env python3
"""verify_puzzles.py - proves that every Stage 1 puzzle has exactly one correct, consistent answer
and that the door passwords follow from the puzzle results by the rules printed in the manual.
Run:  python3 fpga/tools/verify_puzzles.py      (exit code 0 = all checks passed)
"""
import itertools
import sys

ok = True


def check(cond, msg):
    global ok
    print(("  ok   " if cond else "  FAIL ") + msg)
    ok &= bool(cond)


# ---------------------------------------------------------------- Puzzle 1: base conversion
A = 0x2A - 0b10011 - 0o21
check(A == 6 and 0 <= A < 16, "P1: registered 0x2A - absent 0b10011 - sick 0o21 = 42 - 19 - 17 = %d (fits SW3..SW0 = %s)"
      % (A, format(A, "04b")))

# ---------------------------------------------------------------- Puzzle 2: K-map (Gray code order)
GRAY = [0, 1, 3, 2]
truth = 0xF888
F = lambda a, b, c, d: (a & b) | (c & d)  # noqa: E731
check(all(((truth >> (a << 3 | b << 2 | c << 1 | d)) & 1) == F(a, b, c, d)
          for a, b, c, d in itertools.product((0, 1), repeat=4)), "P2: table 0xF888 is exactly F = AB + CD")
print("       K-map as printed (rows AB, columns CD in Gray order 00 01 11 10):")
for r in GRAY:
    print("         %d%d  " % (r >> 1, r & 1) + "  ".join(str(truth >> (r << 2 | c) & 1) for c in GRAY))


def terms_table(terms):
    t = 0
    for m in range(16):
        v = [(m >> 3) & 1, (m >> 2) & 1, (m >> 1) & 1, m & 1]
        if any(all(v[i] == pol[i] for i in range(4) if used[i]) for used, pol in terms if any(used)):
            t |= 1 << m
    return t


# every product term over 4 variables: each variable absent / plain / inverted
all_terms = [(tuple(x != 0 for x in t), tuple(x == 1 for x in t)) for t in itertools.product((0, 1, 2), repeat=4)
             if any(t)]
best = None
for k in (1, 2, 3):
    for combo in itertools.combinations(all_terms, k):
        if terms_table(combo) == truth:
            lits = sum(sum(u) for u, _ in combo)
            if best is None or lits < best[0]:
                best = (lits, combo)
    if best:
        break
check(best and best[0] == 4, "P2: minimal sum of products uses 2 terms / 4 literals (the game accepts <= 4)")
sols4 = {frozenset(c) for kk in (1, 2, 3) for c in itertools.combinations(all_terms, kk)
         if terms_table(c) == truth and sum(sum(u) for u, _ in c) <= 4}
check(len(sols4) == 1, "P2: AB + CD is the ONLY answer with <= 4 literals (%d found)" % len(sols4))
B = bin(truth).count("1")
check(B == 7, "P2+P3: number of 1s of F = %d = report code B" % B)

# ---------------------------------------------------------------- Puzzle 3: NAND only
def nand_circuit(f):
    t = 0
    for m in range(16):
        v = [(m >> 3) & 1, (m >> 2) & 1, (m >> 1) & 1, m & 1]
        g = []
        for k in range(4):
            src = v + g
            g.append(1 - (src[f[2 * k]] & src[f[2 * k + 1]]))
        t |= g[f[8]] << m
    return t


ref = [0, 1, 2, 3, 4, 5, 0, 0, 2]   # G1=NAND(A,B) G2=NAND(C,D) G3=NAND(G1,G2) F=G3
check(nand_circuit(ref) == truth, "P3: NAND(NAND(A,B), NAND(C,D)) == AB + CD (De Morgan), truth-table equal")
# how many of the 4*5*6*6*7*7*... editor settings are correct (the check is by truth table, any is accepted)
n_ok = sum(1 for f in itertools.product(range(4), range(4), range(5), range(5), range(6), range(6), range(7),
                                        range(7), range(4)) if nand_circuit(f) == truth)
check(n_ok > 0, "P3: %d editor settings realise F (all accepted: comparison is by truth table)" % n_ok)

# ---------------------------------------------------------------- Puzzle 4: two's complement
ans4 = (-12) & 0xFF
check(ans4 == 0b11110100, "P4: -12 in 8-bit two's complement = %s" % format(ans4, "08b"))
check((ans4 + 12) & 0xFF == 0, "P4: 11110100 + 00001100 = 1 0000 0000 (carry dropped) -> 0")
C = bin(ans4).count("1")
check(C == 5, "P4: receipt code C = number of 1s = %d" % C)

# ---------------------------------------------------------------- Puzzle 5: projector mastermind
apps = ["Canva", "Pinterest", "Explorer", "AppStore", "X", "Facebook"]
clues = [(["Facebook", "Explorer", "Canva"], 2, 0), (["Facebook", "Canva", "X"], 1, 0),
         (["Canva", "AppStore", "Pinterest"], 2, 1), (["Pinterest", "AppStore", "Facebook"], 1, 0),
         (["AppStore", "Explorer", "Facebook"], 1, 0)]
idx = {a: i for i, a in enumerate(apps)}


def score(secret, guess):
    g = [idx[x] for x in guess]
    return len(set(secret) & set(g)), sum(a == b for a, b in zip(secret, g))


sols = [s for s in itertools.permutations(range(6), 3) if all(score(s, g) == (ca, cp) for g, ca, cp in clues)]
check(len(sols) == 1 and [apps[i] for i in sols[0]] == ["Canva", "Pinterest", "Explorer"],
      "P5: the 5 clues have ONE solution: %s -> password CPE" % [[apps[i] for i in s] for s in sols])
old = list(clues)
old[1] = (["Facebook", "Canva", "X"], 1, 1)
sols_old = [s for s in itertools.permutations(range(6), 3) if all(score(s, g) == (ca, cp) for g, ca, cp in old)]
check(sols_old != sols, "P5: (the original clue 2 'pos = 1' gave %s - fixed)" % [[apps[i] for i in s] for s in sols_old])

# ---------------------------------------------------------------- door
L1 = [int(c) for c in str(ord("CPE"[-1]))]
check(L1 == [6, 9], "Door layer 1: last letter 'E' = 0x45 = %d" % ord("E"))
S = A + B + C
row = [A, B, C, S // 10, S % 10]
code2 = [row[i] for i in (3, 1, 4, 0, 2)]
check(row == [6, 7, 5, 1, 8] and code2 == [1, 7, 8, 6, 5],
      "Door layer 2: S = %d+%d+%d = %d, row %s, order 4-2-5-1-3 -> %s" % (A, B, C, S, row, code2))
ex = [2, 4, 6, 8, 9]
check([ex[i] for i in (3, 1, 4, 0, 2)] == [8, 4, 9, 2, 6], "Manual example: 2 4 6 8 9 -> 8 4 9 2 6")

print("PUZZLES: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
