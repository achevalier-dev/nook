#!/usr/bin/env python3
"""Draw demo/transcript.json as an animated terminal and write the GIF and MP4.

The transcript is produced by demo/record.sh from the real cmd_ functions, so
nothing here invents output — this file only decides how it looks and how fast
it types.

    ./demo/record.sh && ./demo/render.py

Two things keep the GIF small enough to sit at the top of a README. The canvas
is measured from the transcript rather than fixed, so it is exactly as wide as
the longest line and as tall as the tallest command, and the screen clears
between commands rather than scrolling — a scroll moves every pixel on every
frame, which defeats the frame-to-frame differencing the format is built on.
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
TRANSCRIPT = ROOT / "demo" / "transcript.json"
OUT_GIF = ROOT / "demo" / "nook.gif"
OUT_MP4 = ROOT / "demo" / "nook.mp4"

FONT = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
FONT_SIZE = 17
PAD = 26
CHROME = 34
MIN_COLS = 52

BG = "#11121a"
PANEL = "#1a1b26"
BORDER = "#252634"
FG = "#c0caf5"
DIM = "#565f89"
GREEN = "#9ece6a"
RED = "#f7768e"
CYAN = "#7dcfff"

# One tick is one animation frame. 60ms is the coarsest step GIF timing keeps
# exactly, and it is fast enough that typing reads as typing.
TICK_MS = 60
# How long a finished command stays on screen before the next one starts.
HOLD_MS = 1100
# The beat between the command landing and its first line of output.
BEAT_MS = 260
# A longer pause on the last screen, so a loop does not snap.
END_MS = 1800

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


def load_font():
    try:
        return ImageFont.truetype(FONT, FONT_SIZE)
    except OSError:
        sys.exit(f"font not found: {FONT}")


def measure(entries):
    """The canvas is the longest line and the tallest command, not a guess."""
    cols = MIN_COLS
    rows = 1
    for entry in entries:
        lines = entry["output"].split("\n")
        cols = max(cols, len(entry["command"]) + 2, *(len(line) for line in lines))
        rows = max(rows, 1 + len(lines))
    return cols + 1, rows + 1


def main():
    font = load_font()
    entries = json.loads(TRANSCRIPT.read_text())
    cols, rows = measure(entries)

    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    cw = probe.textlength("M", font=font)
    lh = FONT_SIZE + 7
    width = int(cw * cols) + PAD * 2
    height = int(lh * rows) + PAD * 2 + CHROME

    screen: list[tuple[str, str]] = []
    frames: list[tuple[Image.Image, int]] = []

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
        for text, colour in screen:
            parts = split_label(text)
            if parts and colour is FG:
                label, rest = parts
                d.text((PAD, y), label, font=font, fill=DIM)
                d.text((PAD + cw * len(label), y), rest, font=font, fill=FG)
            else:
                d.text((PAD, y), text, font=font, fill=colour)
            y += lh
        return img

    def emit(ms: int = TICK_MS):
        """One frame, or more time on the frame already there if it is identical."""
        img = draw()
        if frames and ImageChops.difference(frames[-1][0], img).getbbox() is None:
            frames[-1] = (frames[-1][0], frames[-1][1] + ms)
            return
        frames.append((img, ms))

    for entry in entries:
        command = entry["command"]
        screen.clear()
        screen.append(("", FG))
        step = max(1, len(command) // 40)  # long commands type in bigger bites
        for i in range(0, len(command) + 1, step):
            screen[-1] = (f"❯ {command[:i]}", CYAN)
            emit()
        screen[-1] = (f"❯ {command}", CYAN)
        emit(BEAT_MS)

        for line in entry["output"].split("\n"):
            screen.append((line, colour_for(line)))
            emit()
        emit(HOLD_MS)

    frames[-1] = (frames[-1][0], frames[-1][1] + END_MS)

    write_gif(frames)
    write_mp4(frames, width, height)

    print(f"{OUT_GIF.relative_to(ROOT)}  {OUT_GIF.stat().st_size // 1024}K, "
          f"{len(frames)} frames, {sum(ms for _, ms in frames) / 1000:.1f}s, "
          f"{width}×{height}")
    print(f"{OUT_MP4.relative_to(ROOT)}  {OUT_MP4.stat().st_size // 1024}K")


def write_gif(frames):
    # Every frame is quantised against one palette taken from the busiest frame,
    # because Pillow can only store a frame as a difference from the one before
    # it when the two agree on their colours. The panel is a dozen near-identical
    # dark blues and 64 is plenty for flat terminal text.
    busiest = max(frames, key=lambda f: ImageChops.difference(
        f[0], Image.new("RGB", f[0].size, BG)).getbbox()[3])[0]
    master = busiest.quantize(colors=64, method=Image.MEDIANCUT)
    quantised = [f.quantize(palette=master, dither=Image.NONE) for f, _ in frames]

    quantised[0].save(
        OUT_GIF,
        save_all=True,
        append_images=quantised[1:],
        duration=[ms for _, ms in frames],
        loop=0,
        optimize=True,
        disposal=1,
    )


def write_mp4(frames, width, height):
    tmp = pathlib.Path(tempfile.mkdtemp())
    try:
        # ffmpeg's concat demuxer takes a duration per still, so the MP4 gets the
        # same timing as the GIF without writing one PNG per tick.
        listing = []
        for i, (frame, ms) in enumerate(frames):
            path = tmp / f"f{i:05d}.png"
            frame.save(path)
            listing.append(f"file '{path}'\nduration {ms / 1000:.3f}")
        listing.append(f"file '{tmp}/f{len(frames) - 1:05d}.png'")
        concat = tmp / "concat.txt"
        concat.write_text("\n".join(listing) + "\n")

        # yuv420p refuses an odd width, and the panel size falls out of the font
        # metrics rather than being chosen.
        run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat),
             "-vf", "fps=30,pad=ceil(iw/2)*2:ceil(ih/2)*2",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", str(OUT_MP4)])
    finally:
        shutil.rmtree(tmp)


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
