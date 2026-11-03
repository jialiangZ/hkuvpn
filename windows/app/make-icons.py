#!/usr/bin/env python3
"""Generate the HKU VPN tray icons from the SVG sources in assets/.

The application itself has no icon: only the notification-area icon is
generated, with its colour encoding the connection state.

Needs: python3 with cairosvg (pip install cairosvg).
Run from windows/app:  python3 make-icons.py

Small sizes (<= 40px) come from tray-icon-small.svg, which drops detail
that only turns into noise at taskbar sizes.

Outputs:
  tray-{gray,green,amber,red}.ico   multi-size tray icons
"""
import struct
from pathlib import Path

import cairosvg

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"

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


def main() -> None:
    tmp = HERE / ".icon-tmp"
    tmp.mkdir(exist_ok=True)

    for name, colour in STATES.items():
        build_icon("tray-icon", TRAY_SIZES, HERE / f"tray-{name}.ico", tmp,
                   STATE_COLOR=colour)

    for f in tmp.iterdir():
        f.unlink()
    tmp.rmdir()
    print("icons written: tray-*.ico")


if __name__ == "__main__":
    main()
