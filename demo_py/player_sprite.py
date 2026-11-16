"""player_sprite.py - shared player sprite + walk animation (use in every stage).

Rules:
  * Pressing right/left/down/up -> character faces right/left/front/back.
  * Walking always starts with the LEFT leg, then stand, RIGHT leg, stand, ...
  * Stopping -> stand pose. Left/right wins when two directions are held.
  * Missing pose -> falls back to 'stand'. Missing form -> falls back to form 0.
  * Old single-image files player_form0..3.png still work as a last fallback.
"""
import os
import pygame

FILE_PATTERN = "player_form{form}_{dir}_{pose}.png"    # change here if your names differ
LEGACY_PATTERN = "player_form{form}.png"
STEP_TIME = 0.14                                       # seconds per walk frame
WALK_CYCLE = ("stepl", "stand", "stepr", "stand")      # left leg first, always


class PlayerSprite:
    def __init__(self, asset_dir, height):
        self.asset_dir = asset_dir
        self.height = height          # drawn height in pixels (width keeps the aspect ratio)
        self.cache = {}
        self.reset()

    def reset(self):
        self.dir = "front"
        self.t = 0.0
        self.moving = False

    def stop(self):
        self.moving = False
        self.t = 0.0

    def update(self, dt, dx, dy, moved):
        """dx, dy = input direction (-1/0/1). moved = True if the player really moved this frame."""
        if dx:
            self.dir = "right" if dx > 0 else "left"
        elif dy:
            self.dir = "front" if dy > 0 else "back"
        if moved:
            if self.moving:
                self.t += dt
            else:
                self.moving, self.t = True, 0.0     # first frame of a walk = left leg
        else:
            self.stop()

    @property
    def pose(self):
        if not self.moving:
            return "stand"
        return WALK_CYCLE[int(self.t / STEP_TIME) % len(WALK_CYCLE)]

    def _read(self, name):
        if name in self.cache:
            return self.cache[name]
        img = None
        path = os.path.join(self.asset_dir, name)
        if os.path.isfile(path):
            try:
                raw = pygame.image.load(path).convert_alpha()
                w = max(1, round(raw.get_width() * self.height / raw.get_height()))
                img = pygame.transform.smoothscale(raw, (w, self.height))
            except (pygame.error, ValueError):
                img = None
        self.cache[name] = img
        return img

    def image(self, form):
        """Current frame for this form, or None (the stage then draws a placeholder)."""
        for f in (form, 0):
            img = (self._read(FILE_PATTERN.format(form=f, dir=self.dir, pose=self.pose))
                   or self._read(FILE_PATTERN.format(form=f, dir=self.dir, pose="stand"))
                   or self._read(LEGACY_PATTERN.format(form=f)))
            if img:
                return img
        return None