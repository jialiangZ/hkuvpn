#!/usr/bin/env python3
"""Render the tray PNGs the app embeds (assets/tray-{state}.png, 64px).

Needs: python3 with Pillow (pip install pillow).

    python3 make-tray-icons.py

Source: assets/app-icon.png, the 256px transparent crest also used as the
window icon. Each state gets the same crest plus a badge in its state
colour (the badge is what survives the 16px tray downscale). Rerun this
after replacing app-icon.png.
"""
from PIL import Image, ImageDraw

STATES = {
    "gray": (0x8A, 0x91, 0x99),   # disconnected
    "green": (0x12, 0x87, 0x3E),  # connected
    "amber": (0xC4, 0x7F, 0x17),  # connecting
    "red": (0xD9, 0x2D, 0x20),    # worker unresponsive
}

source = Image.open("assets/app-icon.png").convert("RGBA")

for name, color in STATES.items():
    icon = source.resize((64, 64), Image.LANCZOS)
    draw = ImageDraw.Draw(icon)
    x = y = int(64 * 0.775)
    r = int(64 * 0.105)
    ring = 2
    draw.ellipse([x - r - ring, y - r - ring, x + r + ring, y + r + ring],
                 fill=(255, 255, 255, 255))
    draw.ellipse([x - r, y - r, x + r, y + r], fill=color + (255,))
    icon.save(f"assets/tray-{name}.png", optimize=True)

print("wrote", ", ".join(f"tray-{n}.png" for n in STATES))
