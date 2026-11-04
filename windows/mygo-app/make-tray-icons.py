#!/usr/bin/env python3
"""Render the tray PNGs the app embeds (assets/tray-{state}.png, 64px).

Needs: python3 with cairosvg (pip install cairosvg).

    python3 make-tray-icons.py

Sources: assets/tray-icon.svg, which carries a STATE_COLOR placeholder
that this script substitutes. The app embeds the four rendered PNGs;
MyGo scales them for the taskbar.
"""
import cairosvg
from pathlib import Path

STATES = {
    "gray": "#8A9199",   # disconnected
    "green": "#12873E",  # connected
    "amber": "#C47F17",  # connecting
    "red": "#D92D20",    # worker unresponsive
}

for name, color in STATES.items():
    svg = Path(f"assets/tray-icon.svg").read_text().replace("STATE_COLOR", color)
    cairosvg.svg2png(bytestring=svg.encode(),
                     write_to=f"assets/tray-{name}.png",
                     output_width=64, output_height=64)
print("wrote", ", ".join(f"tray-{n}.png" for n in STATES))
