#!/usr/bin/env python3
"""card_assets.py - Shared card image loader & renderer for CPE Escape (Rounds 1 to 5).

Draws every card at the EXACT original pixel size of the image file (no resizing),
centered on the card slot rect, and returns the drawn rect so borders/overlays fit tightly.

Expected image files in assets/ (supports .png, .jpg, .jpeg, .webp):
  Round 1 (back / face-down):
    air_back, earth_back, water_back
  Round 1 (front / revealed):
    air_r1, earth_r1, water_r1
  Rounds 2-5 (by chosen career & card slot 1..3):
    air_card1,   air_card2,   air_card3
    earth_card1 (or eartg_card1), earth_card2, earth_card3
    water_card1, water_card2, water_card3
"""
import os
import pygame

CAREER_KEYS = ("air", "earth", "water")   # 0: AIR, 1: EARTH, 2: WATER
EXTS = (".png", ".jpg", ".jpeg", ".webp")

# Support both "eartg_card1" (exact filename) and "earth_card1" (fallback)
R1_BACK_NAMES = {
    0: ("air_back",),
    1: ("earth_back",),
    2: ("water_back",),
}

R1_FRONT_NAMES = {
    0: ("air_r1",),
    1: ("earth_r1",),
    2: ("water_r1",),
}

R2_TO_5_NAMES = {
    0: (("air_card1",), ("air_card2",), ("air_card3",)),
    1: (("eartg_card1", "earth_card1"), ("earth_card2",), ("earth_card3",)),
    2: (("water_card1",), ("water_card2",), ("water_card3",)),
}


class CardAssets:
    def __init__(self, asset_dir=None, card_size=None):
        """card_size=None keeps the exact original image size (no scaling)."""
        here = os.path.dirname(os.path.abspath(__file__))
        self.search_dirs = []
        if asset_dir:
            self.search_dirs.append(asset_dir)
        self.search_dirs.extend([
            os.path.join(os.path.dirname(here), "assets"),
            os.path.join(here, "assets"),
            os.path.join(os.getcwd(), "assets"),
            here,
            os.getcwd(),
        ])
        self.card_size = card_size
        self.cache = {}

    def _find_file(self, stem):
        for d in self.search_dirs:
            if not d or not os.path.isdir(d):
                continue
            for ext in EXTS:
                path = os.path.join(d, stem + ext)
                if os.path.isfile(path):
                    return path
        return None

    def _load(self, candidates, size=None):
        target_size = size if size is not None else self.card_size
        key = (candidates, target_size)
        if key in self.cache:
            return self.cache[key]

        img = None
        for stem in candidates:
            path = self._find_file(stem)
            if path:
                try:
                    raw = pygame.image.load(path).convert_alpha()
                    img = pygame.transform.smoothscale(raw, target_size) if target_size else raw
                    break
                except (pygame.error, ValueError):
                    img = None
        self.cache[key] = img
        return img

    def get_r1_back(self, slot_career_idx, size=None):
        """Round 1 face-down card image for career index 0(air)/1(earth)/2(water)."""
        names = R1_BACK_NAMES.get(slot_career_idx, ())
        return self._load(names, size)

    def get_r1_front(self, slot_career_idx, size=None):
        """Round 1 revealed card image for career index 0(air)/1(earth)/2(water)."""
        names = R1_FRONT_NAMES.get(slot_career_idx, ())
        return self._load(names, size)

    def get_round_card(self, career_idx, pos, size=None):
        """Rounds 2-5 card image for chosen career (0..2) and slot position (0..2)."""
        if career_idx not in R2_TO_5_NAMES or not (0 <= pos <= 2):
            return None
        return self._load(R2_TO_5_NAMES[career_idx][pos], size)

    def get_image(self, round_num, career_idx, pos, revealed, slot_idx=None, size=None):
        """Return the card Surface at its original size (unless size is given), or None."""
        if round_num == 1:
            idx = slot_idx if slot_idx is not None else pos
            return self.get_r1_front(idx, size) if revealed else self.get_r1_back(idx, size)
        return self.get_round_card(career_idx, pos, size)

    def draw_card(self, surface, slot_rect, round_num, career_idx, pos, revealed,
                  slot_idx=None, fallback_color=(80, 85, 100)):
        """Draw the card at its EXACT original size centered on slot_rect.

        Returns:
            (drew_img: bool, drawn_rect: pygame.Rect)
        """
        img = self.get_image(round_num, career_idx, pos, revealed, slot_idx=slot_idx)
        if img is not None:
            drawn_rect = img.get_rect(center=slot_rect.center)
            surface.blit(img, drawn_rect.topleft)
            return True, drawn_rect
        pygame.draw.rect(surface, fallback_color, slot_rect, border_radius=10)
        return False, slot_rect
