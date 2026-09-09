#!/usr/bin/env python3
"""Render the actual PTY menu with fixture data; optional Pillow dependency."""
from pathlib import Path
import re
from PIL import Image, ImageDraw, ImageFont
from terminal import run_case

ROWS, COLS = 24, 80
stream = run_case(jobs=3).split("\x1b[?1049l")[0]
screen = [[(" ", "#e5e7eb") for _ in range(COLS)] for _ in range(ROWS)]
row = col = 0
color = "#e5e7eb"
for match in re.finditer(r"\x1b\[([0-9;?]*)([A-Za-z])|([^\x1b])", stream):
    if match.group(3) is not None:
        char = match.group(3)
        if char == "\r":
            col = 0
        elif char == "\n":
            row = min(row + 1, ROWS - 1)
        elif char >= " ":
            if 0 <= row < ROWS and 0 <= col < COLS:
                screen[row][col] = (char, color)
            col += 1
        continue
    values, command = match.group(1), match.group(2)
    if command == "H":
        coords = [int(item or 1) for item in values.split(";")]
        row, col = coords[0] - 1, (coords[1] if len(coords) > 1 else 1) - 1
    elif command == "J" and values == "2":
        screen = [[(" ", "#e5e7eb") for _ in range(COLS)] for _ in range(ROWS)]
    elif command == "K" and values == "2" and row < ROWS:
        screen[row] = [(" ", color) for _ in range(COLS)]
    elif command == "m":
        color = {"1;36": "#52d8eb", "1;32": "#55dc92", "1;33": "#f5c96a"}.get(values, "#e5e7eb")

font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 16)
cell_width, cell_height = 10, 23
image = Image.new("RGB", (COLS * cell_width + 40, ROWS * cell_height + 65), "#171b20")
draw = ImageDraw.Draw(image)
draw.text((20, 10), "WGWM · тестовые данные · 80 × 24", font=font, fill="#94a3b8")
for y, line in enumerate(screen):
    for x, (char, foreground) in enumerate(line):
        draw.text((20 + x * cell_width, 45 + y * cell_height), char, font=font, fill=foreground)
destination = Path(__file__).resolve().parent.parent / "docs" / "terminal-preview.png"
destination.parent.mkdir(exist_ok=True)
image.save(destination)
print(destination)
