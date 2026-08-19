#!/usr/bin/env python3
"""Draw demo/skill-transcript.json as a Claude Code session.

The transcript comes from demo/record-skill.sh, which runs a real session with
the skill installed, so nothing here invents an answer — this file only decides
how it looks and how fast it arrives.

    ./demo/record-skill.sh && ./demo/render-skill.py

The answer is longer than a screen, so it pages rather than scrolls: a scroll
moves every pixel on every frame, which is the one thing GIF differencing
cannot help with. Nothing is dropped — the page turns.
"""

import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
TRANSCRIPT = ROOT / "demo" / "skill-transcript.json"
OUT_GIF = ROOT / "demo" / "skill.gif"
OUT_MP4 = ROOT / "demo" / "skill.mp4"

FONT = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
FONT_SIZE = 17
COLS, ROWS = 76, 15
PAD = 26
CHROME = 34

BG = "#11121a"
PANEL = "#1a1b26"
BORDER = "#252634"
FG = "#c0caf5"
DIM = "#565f89"
GREEN = "#9ece6a"
CYAN = "#7dcfff"
MAUVE = "#bb9af7"

TICK_MS = 60
TOOL_MS = 320
LINE_MS = 90
PAGE_MS = 1500
END_MS = 2200


def flow(text: str):
    """Markdown as a terminal renders it: no emphasis marks, code kept apart."""
    out, fenced = [], False
    for raw in text.split("\n"):
        if raw.strip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            out.append(("  " + raw.rstrip(), GREEN))
            continue
        line = re.sub(r"\*\*(.+?)\*\*", r"\1", raw)
        line = line.replace("`", "").rstrip()
        if not line:
            out.append(("", FG))
            continue
        indent = "  " if line.startswith(("-", "*")) else ""
        for i, part in enumerate(textwrap.wrap(line, COLS - 2) or [""]):
            out.append((("" if i == 0 else indent) + part, FG))
    while out and out[-1][0] == "":
        out.pop()
    return out


def load_font():
    try:
        return ImageFont.truetype(FONT, FONT_SIZE)
    except OSError:
        sys.exit(f"font not found: {FONT}")


def main():
    font = load_font()
    entries = json.loads(TRANSCRIPT.read_text())

    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    cw = probe.textlength("M", font=font)
    lh = FONT_SIZE + 7
    width = int(cw * COLS) + PAD * 2
    height = int(lh * ROWS) + PAD * 2 + CHROME

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
        d.text((width / 2, 25), "claude — the nook skill", font=font, fill=DIM, anchor="mm")
        y = PAD + CHROME
        for text, colour in screen:
            d.text((PAD, y), text, font=font, fill=colour)
            y += lh
        return img

    def emit(ms: int = TICK_MS):
        img = draw()
        if frames and ImageChops.difference(frames[-1][0], img).getbbox() is None:
            frames[-1] = (frames[-1][0], frames[-1][1] + ms)
            return
        frames.append((img, ms))

    def add(line: str, colour: str, ms: int):
        """One line, turning the page rather than scrolling when the screen fills."""
        if len(screen) >= ROWS:
            emit(PAGE_MS)
            screen.clear()
        screen.append((line, colour))
        emit(ms)

    for entry in entries:
        if entry.get("role") == "user":
            wrapped = textwrap.wrap(entry["text"], COLS - 2)
            screen.append(("", CYAN))
            for i, part in enumerate(wrapped):
                head = "> " if i == 0 else "  "
                for j in range(0, len(part) + 1, 4):
                    screen[-1] = (head + part[:j], CYAN)
                    emit()
                screen[-1] = (head + part, CYAN)
                if i < len(wrapped) - 1:
                    screen.append(("", CYAN))
            add("", FG, TOOL_MS)

        elif entry.get("tool"):
            arg = " ".join(entry["arg"].split())
            if len(arg) > COLS - 12:
                arg = arg[: COLS - 15] + "…"
            add(f"⏺ {entry['tool']}({arg})", MAUVE if entry["tool"] == "Skill" else DIM,
                TOOL_MS)

        else:
            add("", FG, LINE_MS)
            for line, colour in flow(entry["text"]):
                add(line, colour, LINE_MS)

    frames[-1] = (frames[-1][0], frames[-1][1] + END_MS)

    write_gif(frames)
    write_mp4(frames)

    print(f"{OUT_GIF.relative_to(ROOT)}  {OUT_GIF.stat().st_size // 1024}K, "
          f"{len(frames)} frames, {sum(ms for _, ms in frames) / 1000:.1f}s, "
          f"{width}×{height}")
    print(f"{OUT_MP4.relative_to(ROOT)}  {OUT_MP4.stat().st_size // 1024}K")


def write_gif(frames):
    # One palette for every frame, because Pillow can only store a frame as a
    # difference from the one before it when the two agree on their colours.
    master = frames[-1][0].quantize(colors=64, method=Image.MEDIANCUT)
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


def write_mp4(frames):
    tmp = pathlib.Path(tempfile.mkdtemp())
    try:
        listing = []
        for i, (frame, ms) in enumerate(frames):
            path = tmp / f"f{i:05d}.png"
            frame.save(path)
            listing.append(f"file '{path}'\nduration {ms / 1000:.3f}")
        listing.append(f"file '{tmp}/f{len(frames) - 1:05d}.png'")
        concat = tmp / "concat.txt"
        concat.write_text("\n".join(listing) + "\n")
        run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat),
             "-vf", "fps=30,pad=ceil(iw/2)*2:ceil(ih/2)*2",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", str(OUT_MP4)])
    finally:
        shutil.rmtree(tmp)


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
