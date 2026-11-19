#!/usr/bin/env python3
import os
os.environ["SDL_VIDEODRIVER"] = "dummy"
import pygame

ASSET_DIR = "assets"
DIRS  = ["front", "back", "left", "right"]   # 0..3 ตรงกับ spr_dir ใน Verilog
POSES = ["stand", "stepl", "stepr"]          # 0..2 ตรงกับ spr_pose ใน Verilog
SPR_W, SPR_H = 24, 48
TRANSPARENT_HEX = "F0F"

def convert_bg(src_path, dst_path, w, h):
    img = pygame.image.load(src_path)
    img = pygame.transform.smoothscale(img, (w, h))
    with open(dst_path, "w") as f:
        for y in range(h):
            for x in range(w):
                r, g, b, *_ = img.get_at((x, y))
                f.write(f"{r>>4:X}{g>>4:X}{b>>4:X}\n")
    print(f"Generated {dst_path} ({w}x{h})")

def load_sprite_frame(form, d, p):
    # Fallback ลำดับเดียวกับ player_sprite.py
    candidates = []
    for f in (form, 0):
        candidates.append(f"player_form{f}_{d}_{p}.png")
        candidates.append(f"player_form{f}_{d}_stand.png")
        candidates.append(f"player_form{f}.png")
    for name in candidates:
        path = os.path.join(ASSET_DIR, name)
        if os.path.isfile(path):
            raw = pygame.image.load(path)
            return pygame.transform.smoothscale(raw, (SPR_W, SPR_H))
    return None

def convert_sprites(dst_path):
    total_frames = 0
    with open(dst_path, "w") as f:
        for form in range(4):
            for d in DIRS:
                for p in POSES:
                    img = load_sprite_frame(form, d, p)
                    total_frames += 1
                    for y in range(SPR_H):
                        for x in range(SPR_W):
                            if img is None:
                                f.write(TRANSPARENT_HEX + "\n")
                            else:
                                r, g, b, a = img.get_at((x, y))
                                if a < 128:
                                    f.write(TRANSPARENT_HEX + "\n")
                                else:
                                    h_col = f"{r>>4:X}{g>>4:X}{b>>4:X}"
                                    # กันสีจริงชนกับสีโปร่งใส F0F
                                    if h_col == TRANSPARENT_HEX:
                                        h_col = "F0E"
                                    f.write(h_col + "\n")
    print(f"Generated {dst_path} ({total_frames} frames, {SPR_W}x{SPR_H})")

if __name__ == "__main__":
    pygame.init()
    convert_bg("assets/finalexam.jpg", "assets/finalexam.mem", 250, 140)
    convert_sprites("assets/player_sprites.mem")