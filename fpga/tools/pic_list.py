"""pic_list.py - every large picture that the FPGA streams from the QSPI flash (not from BRAM).

One entry = (name, source file stem, how Pygame builds it).  The order is the picture id used by the RTL
(`rtl/video/pic_map.vh` is generated from this list - never reorder without re-running pic_pack.py).

Kinds
  room      : stage background, resized straight to w x h (same as the old asset_convert.convert_bg)
  fit_black : open.py fit()            960x540 canvas, black letterbox      (smooth = smoothscale / scale)
  fit_dark  : cutscene_*.py loaders    960x540 canvas, (12,14,20) letterbox (smooth = smoothscale / scale)
Every fit_* picture is built at Pygame's 960x540 and then reduced to the FPGA game area 640x360 (2/3),
the same scale factor the rest of the port uses.
"""

GAME_W, GAME_H = 640, 360          # FPGA game area (Pygame 960x540 x 2/3)
PY_W, PY_H = 960, 540              # Pygame UI canvas (UW, UH in open.py / cutscene_*.py)

#        name           stem             kind         smooth  w    h
PICS = [
    ("S1_ROOM",       "finalexam",      "room",      True,  640, 358),   # stage1 room, 2x upscaled by the renderer
    ("S2_ROOM",       "bg",             "room",      True,  640, 358),   # stage2 office, 1:1 or zoomed
    ("TITLE",         "title",          "fit_black", False, 640, 360),   # open.py:105 fit(..., smooth=False)
    ("OPEN1",         "1",              "fit_black", True,  640, 360),   # open.py:112
    ("OPEN2",         "2",              "fit_black", True,  640, 360),
    ("OPEN3",         "3",              "fit_black", True,  640, 360),
    ("OPEN4",         "4",              "fit_black", True,  640, 360),
    ("OPEN5",         "5",              "fit_black", True,  640, 360),
    ("OPEN6",         "6",              "fit_black", True,  640, 360),
    ("CUT12",         "cutscene1_2",    "fit_dark",  True,  640, 360),   # cutscene_1_2.py:51 smoothscale
    ("CUT23_1",       "cut23_1",        "fit_dark",  False, 640, 360),   # cutscene_2_3.py:48 scale
    ("CUT23_2",       "cut23_2",        "fit_dark",  False, 640, 360),
    ("CUT23_3",       "cut23_3",        "fit_dark",  False, 640, 360),
] + [("END%d" % n, "ending%d" % n, "fit_dark", True, 640, 360) for n in range(1, 10)]  # cutscene_ending.py:90

DARK = (12, 14, 20)
