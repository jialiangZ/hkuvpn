#!/usr/bin/env python3
"""Generate HKU VPN icon assets from the SVG sources in assets/.

Needs: python3 with cairosvg + Pillow (pip install cairosvg pillow).
Run from windows/app:  python3 make-icons.py

Small sizes (<= 40px) are rendered from the *-small.svg variants, which
drop the fine detail that only turns into noise at taskbar sizes.

Outputs:
  app.ico                           multi-size window/exe icon
  tray-{gray,green,amber,red}.ico   multi-size tray icons (state colours)
  ui/assets/badge.tga               96px badge used by the RmlUi header
"""
import struct
from pathlib import Path

import cairosvg
from PIL import Image

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"

APP_SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
TRAY_SIZES = [16, 20, 24, 32, 40, 48, 64]
SMALL_CUTOFF = 48

STATES = {
    "gray": "#8A9199",    # disconnected
    "green": "#12873E",   # connected
    "amber": "#C47F17",   # connecting
    "red": "#D92D20",     # worker unresponsive
}


def render_png(svg_path: Path, size: int, out: Path, **subs: str) -> None:
    svg = svg_path.read_text(encoding="utf-8")
    for key, value in subs.items():
        svg = svg.replace(key, value)
    cairosvg.svg2png(bytestring=svg.encode("utf-8"), write_to=str(out),
                     output_width=size, output_height=size)


def write_ico(entries, out: Path) -> None:
    """entries: [(size, png_bytes)] -> Windows ICO with embedded PNGs."""
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    directory = b""
    payload = b""
    for size, data in entries:
        dim = 0 if size >= 256 else size
        directory += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        payload += data
        offset += len(data)
    out.write_bytes(header + directory + payload)


def build_icon(name: str, sizes, out: Path, tmp: Path, **subs: str) -> None:
    entries = []
    for size in sizes:
        stem = name if size >= SMALL_CUTOFF else f"{name}-small"
        png = tmp / f"{out.stem}-{size}.png"
        render_png(ASSETS / f"{stem}.svg", size, png, **subs)
        entries.append((size, png.read_bytes()))
    write_ico(entries, out)


def build_badge(svg: Path, size: int, out: Path, tmp: Path) -> None:
    png = tmp / f"{out.stem}.png"
    render_png(svg, size, png)
    Image.open(png).convert("RGBA").save(out)


def main() -> None:
    tmp = HERE / ".icon-tmp"
    tmp.mkdir(exist_ok=True)

    build_icon("app-icon", APP_SIZES, HERE / "app.ico", tmp)
    build_badge(ASSETS / "app-icon.svg", 96, HERE / "ui" / "assets" / "badge.tga", tmp)

    for name, colour in STATES.items():
        build_icon("tray-icon", TRAY_SIZES, HERE / f"tray-{name}.ico", tmp,
                   STATE_COLOR=colour)

    for f in tmp.iterdir():
        f.unlink()
    tmp.rmdir()
    print("icons written: app.ico, tray-*.ico, ui/assets/badge.tga")


if __name__ == "__main__":
    main()
