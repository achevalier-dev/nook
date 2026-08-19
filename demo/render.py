#!/usr/bin/env python3
"""Draw demo/transcript.json as an animated terminal and hand the frames to ffmpeg.

The transcript is produced by demo/record.sh from the real cmd_ functions, so
nothing here invents output — this file only decides how it looks and how fast
it types.

    ./demo/record.sh && ./demo/render.py
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
TRANSCRIPT = ROOT / "demo" / "transcript.json"
OUT_GIF = ROOT / "demo" / "nook.gif"
OUT_MP4 = ROOT / "demo" / "nook.mp4"

FONT = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
FONT_SIZE = 17
COLS, ROWS = 84, 28
PAD = 26
CHROME = 34
FPS = 16

BG = "#11121a"
PANEL = "#1a1b26"
BORDER = "#252634"
FG = "#c0caf5"
DIM = "#565f89"
BLUE = "#7aa2f7"
GREEN = "#9ece6a"
RED = "#f7768e"
CYAN = "#7dcfff"

# How long a finished command stays on screen before the next one starts.
HOLD_FRAMES = 14
# Frames per typed character. Long commands get compressed rather than dragging.
TYPE_FRAMES = 1

GOOD_PREFIXES = ("adopted", "mounted", "attached", "ejected", "formatted", "unmounted")


def split_label(line: str):
    """`disk       /dev/nbd0` renders as a dim label and a bright value."""
    if line.startswith(" ") or "  " not in line.strip():
        return None
    head, _, tail = line.partition("  ")
    if not head or not head.replace("-", "").isalpha() or len(head) > 12:
        return None
    return head, line[len(head):]


def colour_for(line: str) -> str:
    stripped = line.strip()
    if stripped.startswith("nook:"):
        return RED
    # A two-column row is a label, whatever its first word happens to be:
    # "attached    100.87.4.31" is a field, "attached at /run/…" is an outcome.
    if split_label(line):
        return FG
    if stripped.split(" ")[0] in GOOD_PREFIXES:
        return GREEN
    if line.startswith("  ") or stripped.endswith(":"):
        return DIM
    return FG


class Screen:
    """A rolling window of rendered lines, one entry per terminal row."""

    def __init__(self):
        self.lines: list[tuple[str, str]] = []

    def add(self, text: str, colour: str = FG):
        for chunk in (text or "").split("\n"):
            self.lines.append((chunk, colour))
        del self.lines[: max(0, len(self.lines) - ROWS)]

    def replace_last(self, text: str, colour: str = FG):
        self.lines[-1] = (text, colour)


def load_font():
    try:
        return ImageFont.truetype(FONT, FONT_SIZE)
    except OSError:
        sys.exit(f"font not found: {FONT}")


def main():
    font = load_font()
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    cw = probe.textlength("M", font=font)
    lh = FONT_SIZE + 7
    width = int(cw * COLS) + PAD * 2
    height = int(lh * ROWS) + PAD * 2 + CHROME

    entries = json.loads(TRANSCRIPT.read_text())
    screen = Screen()
    frames: list[Image.Image] = []

    def draw() -> Image.Image:
        img = Image.new("RGB", (width, height), BG)
        d = ImageDraw.Draw(img)
        d.rounded_rectangle(
            (8, 8, width - 8, height - 8), radius=10, fill=PANEL, outline=BORDER, width=1
        )
        for i, colour in enumerate(("#f7768e", "#e0af68", "#9ece6a")):
            d.ellipse((26 + i * 20, 20, 36 + i * 20, 30), fill=colour)
        d.text((width / 2, 25), "nook", font=font, fill=DIM, anchor="mm")

        y = PAD + CHROME
        for text, colour in screen.lines:
            parts = split_label(text)
            if parts and colour is FG:
                label, rest = parts
                d.text((PAD, y), label, font=font, fill=DIM)
                d.text((PAD + cw * len(label), y), rest, font=font, fill=FG)
            else:
                d.text((PAD, y), text, font=font, fill=colour)
            y += lh
        return img

    def hold(n: int):
        frames.extend([draw()] * n)

    for entry in entries:
        command = entry["command"]
        screen.add("", FG)  # the line the prompt types into
        step = max(1, len(command) // 40)  # long commands type in bigger bites
        for i in range(0, len(command) + 1, step):
            screen.replace_last(f"❯ {command[:i]}", CYAN)
            frames.extend([draw()] * TYPE_FRAMES)
        screen.replace_last(f"❯ {command}", CYAN)
        hold(4)

        for line in entry["output"].split("\n"):
            screen.add(line, colour_for(line))
            frames.append(draw())
        screen.add("")
        hold(HOLD_FRAMES)

    hold(FPS)  # a beat on the last screen before it loops

    tmp = pathlib.Path(tempfile.mkdtemp())
    try:
        for i, frame in enumerate(frames):
            frame.save(tmp / f"f{i:05d}.png")
        pattern = str(tmp / "f%05d.png")
        palette = tmp / "palette.png"

        # A generated palette rather than ffmpeg's default: the panel is a dozen
        # near-identical dark blues and the stock palette bands them badly. 64
        # colours is plenty for flat terminal text and roughly halves the file.
        run(["ffmpeg", "-y", "-framerate", str(FPS), "-i", pattern,
             "-vf", "palettegen=max_colors=64:stats_mode=diff", str(palette)])
        run(["ffmpeg", "-y", "-framerate", str(FPS), "-i", pattern, "-i", str(palette),
             "-lavfi", "paletteuse=dither=bayer:bayer_scale=3", str(OUT_GIF)])
        # yuv420p refuses an odd width, and the panel width falls out of the
        # font metrics rather than being chosen.
        run(["ffmpeg", "-y", "-framerate", str(FPS), "-i", pattern,
             "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", str(OUT_MP4)])
    finally:
        shutil.rmtree(tmp)

    print(f"{OUT_GIF.relative_to(ROOT)}  {OUT_GIF.stat().st_size // 1024}K, "
          f"{len(frames)} frames at {FPS}fps")
    print(f"{OUT_MP4.relative_to(ROOT)}  {OUT_MP4.stat().st_size // 1024}K")


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
