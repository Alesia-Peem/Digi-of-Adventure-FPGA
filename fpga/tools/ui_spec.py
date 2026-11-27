"""ui_spec.py - the contract between game logic (Verilog) and UI screens (ui_screens.py).

FIELDS: 24-bit numbers the stage drives (field 0 is always 0).
CONDS : booleans the stage drives (cond 0 is always 1).
ui_compile.py turns these lists into fpga/rtl/ui/ui_map.vh (localparam F_xxx / C_xxx), so the
Verilog and the screen scripts can never disagree on an index.
"""

FIELDS = (
    # HUD / player
    ["HEARTS", "ARMOR", "SLOW_S", "FREEZE_S", "PSX", "PSY", "PFRAME", "CAMXN", "CAMYN", "FLASH_A"]
    # puzzle inputs / answers (stage 1)
    + ["P1VAL", "P4VAL", "ANS_A", "ANS_B", "ANS_C"]
    + ["P2_T1", "P2_T2", "P2_T3", "P2_SW", "P2_EQN", "P2_CUR"]
    + ["P3_%d" % i for i in range(9)] + ["P3_OUTN", "P3_CUR", "P3_TAB"]
    + ["P5_L0", "P5_L1", "P5_L2", "P5_CUR"]
    + ["DOOR_D%d" % i for i in range(5)] + ["DOOR_CUR", "DOOR_LNUM", "DOOR_N"]
    # messages
    + ["CMSG", "CMSG_P", "TOAST", "OBJ", "PAGE"]
    # cards
    + ["CARD_CUR", "CARD_ROUND", "CIMG0", "CIMG1", "CIMG2", "CNAME", "CDESC", "CAREER", "CSYM0", "CSYM1", "CSYM2"]
    # notebook
    + ["HINT0", "HINT1", "HINT2"]
    + ["NOTE_T%d" % i for i in range(8)] + ["NOTE_V%d" % i for i in range(8)]
    + ["FORM", "CLEAR_FORM"]
)

CONDS = (
    ["HELP", "PLAY", "OVER", "CLEAR", "MAP", "CLOSEUP", "DECK", "NOTEBOOK", "LIGHTS", "DEBUG", "STANDALONE"]
    + ["CU_WB", "CU_PAPER", "CU_NAND", "CU_TWOS", "CU_SCREEN", "CU_PC", "CU_LIGHTSW", "CU_DOOR"]
    + ["PAGE0", "PAGE1", "PAGE2"]
    + ["HEART1", "HEART2", "HEART3", "ARMOR_ON", "SLOW_ON", "FREEZE_ON", "FLASH_ON", "TOAST_ON"]
    + ["DONE1", "DONE2", "DONE3", "DONE4", "DONE5", "ANSA_V", "ANSB_V", "ANSC_V"]
    + ["SW%d" % i for i in range(8)]
    + ["P3F%d" % i for i in range(9)]
    + ["DOOR_L2", "CMSG_ON", "CMSG_TN"]
    + ["CARD_FACEUP", "CARD_R1", "CAREER_V", "CF0", "CF1", "CF2"]
    + ["NOTE_V%d" % i for i in range(8)] + ["NOTE_D%d" % i for i in range(8)]
    + ["NOTE_E%d" % i for i in range(8)] + ["NOTE_L%d" % i for i in range(8)]
    + ["HINT_V0", "HINT_V1", "HINT_V2"]
    + ["STAGE1", "NEAR_OBJ"]
    + ["P2C%d" % i for i in range(3)] + ["P5C%d" % i for i in range(3)]
    + ["DOOR_C%d" % i for i in range(5)] + ["CARD_C%d" % i for i in range(3)]
    + ["CMSG_LONG"]                    # close-up message drawn small and wrapped to 2 lines (commit messages)
)

# ---------------------------------------------------------------- text tables (index = id the RTL drives)
# Strings are copied from stage1_demo.py. Keyboard wording ("Space", "Esc") is replaced by the board
# controls the Pygame demo itself names in brackets (BTNC, SW..), since the FPGA has no keyboard.
HINT_TEXT = {
    "P1": "10",
    "P2": "Circle the 1s in the biggest groups you can. Two groups are enough.",
    "P3": "De Morgan",
    "P4": "00001100",
    "P5": "It takes greater faith to dance in the dark than to rest in light.",
}
TABLES = {
    "TOAST": [("NONE", ""), ("INC", "Incorrect - try again"), ("LON", "Lights ON"), ("LOFF", "Lights OFF"),
              ("ARMOR", "ARMOR PROTECTED!"), ("WRONG", "Wrong code! -1 heart"), ("ARMORP", "Armor +1"),
              ("DBG1", "[DEBUG] puzzle 1 answered"), ("DBG2", "[DEBUG] puzzle 2 answered"),
              ("DBG3", "[DEBUG] puzzle 3 answered"), ("DBG4", "[DEBUG] puzzle 4 answered"),
              ("DBG5", "[DEBUG] puzzle 5 answered")]
             # commit() of a correct answer: "Puzzle %d correct - saved to Notebook" (TOAST_OK1 + i)
             + [("OK%d" % n, "Puzzle %d correct - saved to Notebook" % n) for n in range(1, 6)],
    # CMSG with a %d parameter is split: prefix here, number, then "." (cond CMSG_TN)
    # commit(): "CORRECT! " + correct_msg / "INCORRECT! " + wrong_msg, verbatim from the puzzle handlers.
    # Ids 2, 3, 9, 10 keep their old numbers (STORED / CLEARED / LOCK1 / WRONG are unchanged).
    "CMSG": [("NONE", ""),
             ("P1OK", "CORRECT! The base-conversion answer is correct. Puzzle 1 is complete."),
             ("STORED", "Stored in T"), ("CLEARED", "T"),
             ("NOTERM", "INCORRECT! No terms have been stored yet. Please create your K-map expression first."),
             ("P3OK", "CORRECT! The NAND circuit produces the correct truth table. Puzzle 3 is complete."),
             ("P4OK", "CORRECT! The two's-complement value is correct. Puzzle 4 is complete."),
             ("P5OK", "CORRECT! ACCESS GRANTED. The login passcode is correct. Puzzle 5 is complete."),
             ("P5BAD", "INCORRECT! ACCESS DENIED. The passcode is incorrect. Check the letters and try again."),
             ("LOCK1", "LOCK 1 OPEN. Now the 5-digit lock."), ("WRONG", "WRONG CODE"),
             ("P1BAD", "INCORRECT! The base-conversion answer is incorrect. Check your calculation and try again."),
             ("P2OK", "CORRECT! Your K-map expression is correct. You can use this to solve the next puzzle."),
             ("P2BAD", "INCORRECT! Your K-map expression is not correct. Check your variables and terms, "
                       "then try again."),
             ("P3BAD", "INCORRECT! The NAND circuit output does not match the required truth table. Check the "
                       "connections and try again."),
             ("P4BAD", "INCORRECT! The binary value is incorrect. Check the two's-complement conversion and try "
                       "again.")],
    "CMSG_SUFFIX": [("NONE", ""), ("P1OK", ""), ("STORED", "."), ("CLEARED", " cleared.")],
    "ITEM": [("NONE", ""), ("HINT_HARD", "Hint"), ("BOOST", "Speed Boost"), ("ARMOR", "Armor"),
             ("SHARD", "Armor Shard"), ("SLOW", "Slow"), ("HINT_SMART", "Hint"), ("FREEZE", "Freeze"),
             ("UNDO", "Undo")],
    "DESC": [("NONE", ""), ("H1", HINT_TEXT["P1"]), ("H2", HINT_TEXT["P2"]), ("H3", HINT_TEXT["P3"]),
             ("H4", HINT_TEXT["P4"]), ("H5", HINT_TEXT["P5"]), ("NOHINT", "No hint this time. Keep going!"),
             ("U1", "Your latest answer (Puzzle 1) was undone."), ("U2", "Your latest answer (Puzzle 2) was undone."),
             ("U3", "Your latest answer (Puzzle 3) was undone."), ("U4", "Your latest answer (Puzzle 4) was undone."),
             ("U5", "Your latest answer (Puzzle 5) was undone."), ("NOUNDO", "Nothing to undo right now."),
             ("FORGED", "2 shards forged 1 Armor!"), ("SHARD1", "Armor Shard 1 / 2 (saved for later)."),
             ("BOOST", "Saved for later stages."), ("ARMOR", "Blocks the next wrong code penalty."),
             ("SLOW", "You walk slower for 10 seconds."), ("FREEZE", "Moving obstacles stop for 5 seconds.")],
    "HINT": [("NONE", ""), ("P1", HINT_TEXT["P1"]), ("P2", HINT_TEXT["P2"]), ("P3", HINT_TEXT["P3"]),
             ("P4", HINT_TEXT["P4"]), ("P5", HINT_TEXT["P5"])],
    "OBJ": [("WB", "WHITEBOARD"), ("PAPER", "PAPER ON THE CABINET"), ("NAND", "LAPTOP"), ("TWOS", "LAPTOP"),
            ("SCREEN", "PROJECTOR SCREEN"), ("PC", "TEACHER COMPUTER"), ("LIGHTSW", "LIGHT SWITCH"),
            ("DOOR", "EXIT DOOR")],
    # notes of a correct commit, "- " + note (draw_notebook). Only correct answers are stored, so every note is a
    # fixed text: A is always 6, the passcode always CPE, and a correct K-map is AB + CD in one of two orders.
    "NOTE": [("NONE", ""), ("P1", "- P1 correct answer: A = 6"), ("P2", "- P2 correct answer: F = AB + CD"),
             ("P3", "- P3 correct circuit: NAND-only output matches the K-map."),
             ("P4", "- P4 correct answer: 11110100 (unsigned 244 / signed -12)."),
             ("P5", "- P5 correct login passcode: CPE"), ("P2B", "- P2 correct answer: F = CD + AB")],
    "SRC": [("A", "A"), ("B", "B"), ("C", "C"), ("D", "D"), ("G1", "G1"), ("G2", "G2"), ("G3", "G3")],
    "CAREER": [("AIR", "AIR"), ("EARTH", "EARTH"), ("WATER", "WATER")],
    "SYMBOL": [("WING", "WING"), ("PLANE", "PLANE"), ("FART", "FART"), ("SHIP", "SHIP"), ("GEAR", "GEAR"),
               ("MONEY", "MONEY"), ("WORM", "WORM"), ("FLAG", "WHITE FLAG"), ("PLUG", "PLUG")],
    "FORM": [("F0", "Student uniform"), ("F1", "Lab coat"), ("F2", "Graduation gown"), ("F3", "Super Yasai")],
}
TABLES["OBTAINED"] = [(k, ("Obtained: " + v) if v else "") for k, v in TABLES["ITEM"]]

# ================================================================ STAGE 2 (own field / condition namespace)
import json as _json
import os as _os
_T = _json.load(open(_os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "s2_text.json")))

FIELDS2 = (
    ["HEARTS", "ARMOR", "SLOW_S", "PSX", "PSY", "PFRAME", "FLASH_A", "TOAST", "TOAST_A", "CMSG", "CMSG_A",
     "OBJ", "PAGE", "CARD_ROUND", "CIMG0", "CIMG1", "CIMG2", "CNAME", "CDESC", "FORM"]
    + ["NOTE%d" % i for i in range(8)]
    + ["HN%d_%s" % (i, k) for i in range(2) for k in ("T", "A", "B", "C")]     # last 2 hints (notebook)
    + ["HP_T", "HP_A", "HP_B", "HP_C"]                                          # hint popup
    + ["PCOUNT%d" % i for i in range(9)] + ["PTOTAL", "QA_RND", "QA_K0", "QA_K1"]
    + ["QA_P%d" % i for i in range(6)]
    + ["NPC_X", "NPC_Y", "TLINE", "TL_A", "TL_B", "TL_C"]
    + ["SKILL_S", "SKILL_M", "SKILL_SS", "INV_HH", "INV_HS", "INV_UN", "INV_FR", "SHARDS"]
    + ["ZF", "ZO", "ZINV", "GLOW_R", "LEG_X0", "LEG_Y0", "LEG_X1", "LEG_Y1", "PROMPT"]
    + ["WCUR", "WCUR_X", "WCUR_Y", "WSRC", "WCNT", "CODE3", "CODE_C", "PD_N", "MISSN"]
)
CONDS2 = (
    ["HELP", "PLAY", "OVER", "CLEAR", "MAP", "CLOSEUP", "DECK", "NOTEBOOK", "INV", "HINTP", "TALK", "TALK_ASKLAST",
     "CU_WB", "CU_DOOR", "CU_BENCH", "BOARD", "PAGE0", "PAGE1", "PAGE2"]
    + ["HEART1", "HEART2", "HEART3", "ARMOR_ON", "SLOW_ON", "FLASH_ON", "TOAST_ON", "TOAST_RECH", "CMSG_ON",
       "CMSG_LOCK", "CMSG_MISS", "CARD_FACEUP", "CARD_R1", "CF0", "CF1", "CF2", "CARD_C0", "CARD_C1", "CARD_C2",
       "CAREER_V", "BOOST"]
    + ["NOTE_V%d" % i for i in range(8)]
    + ["HN%d_%s" % (i, k) for i in range(2) for k in ("V", "SEG", "WIRE", "TXT")]
    + ["HP_SEG", "HP_WIRE", "HP_TXT"]
    + ["NPC_ON", "NPC_BEHIND", "NPC_SIT", "SKILLBTN", "SKILL_ON", "SKILL_USED", "SKILL_READY", "BLINK", "ZOOM",
       "GLOW", "LEGS", "PROMPT_ON", "DONE", "CODES", "TL_STATIC", "TL_VIN", "TL_VOK", "TL_PASSMID", "TL_ASK2"]
    + ["FOUND%d" % i for i in range(18)] + ["PARTOK%d" % i for i in range(9)] + ["QAPASS%d" % i for i in range(3)]
    + ["WCLEAR", "WPICK", "WCURSOR", "DSW0", "DSW1", "DSW2", "DIPOK", "COMOK", "CODEVALID"]
    + ["SEG%d" % i for i in range(7)] + ["T0S%d" % i for i in range(7)] + ["T1S%d" % i for i in range(7)]
    + ["PWR%d" % i for i in range(4)] + ["MISS%d" % i for i in range(9)] + ["MSEP%d" % i for i in range(9)]
    + ["INVC%d" % i for i in range(4)] + ["ALL18"]
)
_Q = _T["part_qty"]
TABLES.update({
    "S2_NOTE": [("N%d" % i, v) for i, v in enumerate(_T["note"])],
    "S2_CLUE": [("C%d" % i, v) for i, v in enumerate(_T["spot_clue"])],
    "S2_HTITLE": [("H%d" % i, v) for i, v in enumerate(_T["hint_title"])],
    "S2_HTEXT": [("H%d" % i, v) for i, v in enumerate(_T["hint_text"])],
    "S2_SINK": [("K%d" % i, v) for i, v in enumerate(_T["sink_name"])],
    "S2_SRC": [("S%d" % i, v) for i, v in enumerate(_T["src_name"])],
    "S2_CHAR": [("C%d" % i, v) for i, v in enumerate(_T["char_name"])],
    "S2_PSHORT": [("P%d" % i, v) for i, v in enumerate(_T["part_short"])],
    "S2_PLABEL": [("P%d" % i, "%-26s" % v) for i, v in enumerate(_T["part_label"])],
    "S2_ITEM": [("NONE", ""), ("HINT_HARD", "Hint"), ("BOOST", "Speed Boost"), ("ARMOR", "Armor"),
                ("SHARD", "Armor Shard"), ("SLOW", "Slow"), ("HINT_SMART", "Hint"), ("FREEZE", "Freeze"),
                ("UNDO", "Undo")],
    "S2_DESC": [("NONE", ""), ("HINT_HARD", "Use it from the inventory (SW15)."),
                ("BOOST", "Saved for the Obby stage. No effect here."), ("ARMOR", "Blocks the next failed QA penalty."),
                ("SHARD", "Collect 2 shards to forge 1 Armor."), ("SLOW", "You walk slower for 10 seconds."),
                ("HINT_SMART", "Use it from the inventory (SW15)."),
                ("FREEZE", "Stops moving obstacles for 5 s. Saved for Stage 3."),
                ("UNDO", "Reverts your latest wiring change.")],
    # toast: one table entry per message ("Found" messages pre-built per part type and count)
    "S2_TOAST": [("NONE", ""), ("ALLFOUND", "All 18 parts found! Go to the decoder bench."),
                 ("ARMOR", "ARMOR PROTECTED!"), ("QAFAIL", "QA failed! -1 heart"),
                 ("DOOR", "The exit door is unlocked!"), ("NOITEM", "You do not have this item."),
                 ("NU_VER", "Not useful now: the decoder is already verified."),
                 ("NU_BENCH", "Not useful yet: power on the decoder bench first."),
                 ("NU_NOTHING", "Not useful now: nothing left to hint."), ("NOUNDO", "Nothing to undo right now."),
                 ("UNDONE", "Your last wiring change was undone."),
                 ("FREEZE", "No moving obstacles here. Keep it for Stage 3."), ("SK_ON", "The skill is already on!"),
                 ("SK_USED", "You already used the skill again."), ("SK_RECH", "Skill recharging: "),
                 ("SK_MAP", "Use the skill while walking around the office."),
                 ("SK_GO", "WORKSHOP SHIRT: hidden parts revealed for 10 s!")]
                + [("F%d_%d" % (pi, n), "Found: %s  (%d/%d)" % (lbl, n, _Q[pi]))
                   for pi, lbl in enumerate(_T["part_label"]) for n in range(1, _Q[pi] + 1)],
    "S2_TALK": [("I%d" % i, v) for i, v in enumerate(_T["intro"])]
               + [("NB1", "Come back when the decoder is built."),
                  ("NB2", "Find all 18 parts, install them on the decoder bench, then wire the breadboard."),
                  ("VERIF", "Everything is verified. Leave through the exit door!"),
                  ("ASK1", "Is your circuit finished?"), ("V0", "Let me test your circuit..."),
                  ("PASSF", "All 3 tests passed! The decoder is verified. You may leave through the exit door."),
                  ("FAILA", "Not right. Go back to the bench and fix it. Your armor takes the hit this time."),
                  ("FAIL", "Not right. Go back to the bench and fix it. That costs you a heart.")],
    "S2_PROMPT": [("WB", "[BTNC] Work-order board"), ("DOOR", "[BTNC] Exit door"), ("BENCH", "[BTNC] Decoder bench"),
                  ("NPC", "[BTNC] Talk to the Boss")],
    "S2_OBJ": [("WB", "WORK-ORDER BOARD"), ("DOOR", "EXIT DOOR"), ("BENCH", "DECODER BENCH")],
    "S2_SEGN": [("S%d" % i, c) for i, c in enumerate("abcdefg")],
    "S2_ONOFF": [("OFF", "OFF"), ("ON", "ON")],
    "S2_CMSG": [("NONE", ""), ("LOCK", "Locked. It opens when the decoder passes QA ("),
                ("MISS", "Cannot power on. Missing: ")],
})
# hint popup: text 0..8 hint notes, 9..26 clues, 27 parts done, 28 every segment matches; title 0..8, 9 = HINT
TABLES["S2_PTEXT"] = ([("H%d" % i, v) for i, v in enumerate(_T["hint_text"])] +
                      [("C%d" % i, v) for i, v in enumerate(_T["spot_clue"])] +
                      [("PARTSDONE", "All parts found. Go to the decoder bench and power it on."),
                       ("EVERY", "Every segment already matches. Show it to the Boss.")])
TABLES["S2_PTITLE"] = [("H%d" % i, v) for i, v in enumerate(_T["hint_title"])] + [("HINT", "HINT")]
TABLES["S2_PTITLEU"] = [(k, v.upper()) for k, v in TABLES["S2_PTITLE"]]
TABLES["S2_ONOFF0"] = [("V%d" % i, "ON" if i & 1 else "OFF") for i in range(4)]        # bit 0 of {t1, t0}
TABLES["S2_ONOFF1"] = [("V%d" % i, "ON" if i & 2 else "OFF") for i in range(4)]        # bit 1
TABLES["S2_BIN3HI"] = [("V%d" % i, format(i >> 3, "03b")) for i in range(64)]         # bits 5..3 as text
TABLES["S2_QAN"] = [("R%d" % i, "%d / 3" % min(i + 1, 3)) for i in range(4)]
for _pi, (_sh, _q) in enumerate(zip(_T["part_short"], _T["part_qty"])):          # "<part> x<missing>"
    TABLES["S2_MISS%d" % _pi] = [("F%d" % f, "%s x%d" % (_sh, _q - f) if f < _q else "") for f in range(8)]
TOAST2 = {k: i for i, (k, _) in enumerate(TABLES["S2_TOAST"])}
TID = {t: {k: i for i, (k, _) in enumerate(rows)} for t, rows in TABLES.items()}
TALK2 = {k: i for i, (k, _) in enumerate(TABLES["S2_TALK"])}

# ================================================================ STAGE 3 (graduation obby, stage3_demo.py)
# screen positions are game-area pixels (32 px per metre); slots = visible animals picked by s3_core each tick
N_AS, N_FS, N_PS = 6, 2, 3          # animal slots (walkers / jumpers / flyers), falling slots, plant slots
FIELDS3 = (
    ["CAMPX", "PCX", "PL1", "PL2", "PY", "RCX", "RL1", "RL2", "RY", "FLAGX"]
    + ["CL%d" % i for i in range(6)]
    + ["A%d_%s" % (i, k) for i in range(N_AS) for k in ("X", "Y", "YW")]
    + ["F%d_%s" % (i, k) for i in range(N_FS) for k in ("X", "Y")]
    + ["P%d_%s" % (i, k) for i in range(N_PS) for k in ("X", "Y")]
    + ["TM", "TS1", "TS2", "PBX1", "PBY1", "TALKD", "W1", "W2", "W3", "WT", "L1", "L2", "L3", "SKX"]
)
CONDS3 = (
    ["MENU", "PLAY", "DEAD", "WIN", "LOSE", "PLAYER", "PF", "REP", "RF", "FLAG", "TBLINK", "SK_USED", "SK_READY",
     "SK_BLINK", "MSG", "MSG_SKILL", "TALK", "TALK1", "WD1", "WD2", "WD3", "LD1", "LD2", "LD3"]
    + ["A%d_%s" % (i, k) for i in range(N_AS) for k in ("V", "T1", "T2", "T4", "F")]
    + ["F%d_%s" % (i, k) for i in range(N_FS) for k in ("V", "T2", "F")]
    + ["P%d_%s" % (i, k) for i in range(N_PS) for k in ("V", "OPEN")]
)
assert len(FIELDS3) < 128, len(FIELDS3)
assert len(CONDS3) < 252, len(CONDS3)

assert len(FIELDS) < 128, len(FIELDS)
assert len(CONDS) < 252, len(CONDS)
assert len(FIELDS2) < 128, len(FIELDS2)
assert len(CONDS2) < 252, len(CONDS2)
# conditions 252..254 are driven by the stage manager, not by a stage: which stage is running
RESERVED = {"IS_S3": 252, "IS_S2": 253, "IS_S1": 254}
FIELD = {n: i + 1 for i, n in enumerate(FIELDS)}
COND = dict({n: i + 1 for i, n in enumerate(CONDS)}, **RESERVED)
FIELD2 = {n: i + 1 for i, n in enumerate(FIELDS2)}
COND2 = dict({n: i + 1 for i, n in enumerate(CONDS2)}, **RESERVED)
FIELD3 = {n: i + 1 for i, n in enumerate(FIELDS3)}
COND3 = dict({n: i + 1 for i, n in enumerate(CONDS3)}, **RESERVED)


def write_vh(path):
    with open(path, "w") as f:
        f.write("// ui_map.vh - GENERATED by fpga/tools/ui_compile.py from ui_spec.py. Do not edit.\n")
        f.write("// Field k occupies fields[24*k +: 24]; condition k is conds[k].\n")
        for n, i in FIELD.items():
            f.write("localparam integer F_%s = %d;\n" % (n, i))
        for n, i in COND.items():
            f.write("localparam integer C_%s = %d;\n" % (n, i))
        for n, i in FIELD2.items():
            f.write("localparam integer F2_%s = %d;\n" % (n, i))
        for n, i in COND2.items():
            if n not in RESERVED:
                f.write("localparam integer C2_%s = %d;\n" % (n, i))
        for n, i in FIELD3.items():
            f.write("localparam integer F3_%s = %d;\n" % (n, i))
        for n, i in COND3.items():
            if n not in RESERVED:
                f.write("localparam integer C3_%s = %d;\n" % (n, i))
        f.write("function [7:0] s2_toast_found(input [3:0] part, input [2:0] n);   // 'Found: <part> (n/q)'\n")
        f.write("    case (part)\n")
        for pi in range(9):
            f.write("        4'd%d: s2_toast_found = 8'd%d + n - 8'd1;\n" % (pi, TOAST2["F%d_1" % pi]))
        f.write("        default: s2_toast_found = 8'd0;\n    endcase\nendfunction\n")
        for t, ids in TID.items():
            for k, i in ids.items():
                f.write("localparam [7:0] %s_%s = 8'd%d;\n" % (t, k, i))
