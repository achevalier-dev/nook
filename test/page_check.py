#!/usr/bin/env python3
"""Name every function the index page calls but never defines.

The page is one inline script with no build step and no module loader, so a
call to a function that does not exist is not caught by anything until somebody
presses the button: the click handler throws, the catch around it turns the
ReferenceError into a small line of text under the card, and the button reads
as doing nothing at all. That is exactly how Remove shipped broken.

A parser would be better than a regex. There is no parser here, and this finds
the one thing worth finding.
"""
import pathlib
import re
import sys

BUILTIN = set(
    """if for while switch catch return function typeof new await async of in do else
    fetch parseInt parseFloat isFinite isNaN Number String Boolean Symbol BigInt
    Math JSON Date Set Map WeakMap Array Object Promise Error RegExp
    setTimeout setInterval clearTimeout clearInterval queueMicrotask
    requestAnimationFrame cancelAnimationFrame matchMedia getComputedStyle
    encodeURIComponent decodeURIComponent encodeURI decodeURI structuredClone
    console document window navigator performance location history
    XMLSerializer DOMParser Image Blob File URL URLSearchParams ClipboardItem
    IntersectionObserver MutationObserver ResizeObserver AbortController
    addEventListener removeEventListener dispatchEvent""".split()
)

# Words that only ever appear inside strings, CSS or comments in this page.
# Listed rather than parsed around, and short enough to stay honest.
PROSE = {"not", "refused", "rotate", "url", "var", "translate", "circle", "radial"}


def undefined_calls(script: str) -> list:
    src = re.sub(r"//[^\n]*", "", script)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)

    declared = set(re.findall(r"\bfunction\s+([A-Za-z_$][\w$]*)", src))
    declared |= set(re.findall(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=", src))
    declared |= set(re.findall(r"\bcatch\s*\(([A-Za-z_$][\w$]*)\)", src))
    for params in re.findall(r"\(([^()]*)\)\s*=>", src):
        declared |= {p.strip().split("=")[0].strip() for p in params.split(",") if p.strip()}
    for params in re.findall(r"function\s*[A-Za-z_$\w]*\s*\(([^()]*)\)", src):
        declared |= {p.strip().split("=")[0].strip() for p in params.split(",") if p.strip()}

    # A call, but not a method call: `.foo(` and `?.foo(` belong to whatever is
    # on the left of the dot, which this cannot and need not resolve.
    calls = set(re.findall(r"(?<![.\w$?])([A-Za-z_$][\w$]*)\s*\(", src))
    return sorted(c for c in calls if c not in declared and c not in BUILTIN and c not in PROSE)


def main(path: str) -> int:
    page = pathlib.Path(path).read_text()
    scripts = re.findall(r"<script>(.*?)</script>", page, flags=re.S)
    if not scripts:
        print(f"page: {path} has no script — the manage controls cannot work", file=sys.stderr)
        return 1

    bad = 0
    for script in scripts:
        for name in undefined_calls(script):
            print(f"page: {path} calls {name}(), which nothing defines", file=sys.stderr)
            bad = 1
    return bad


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1 else "services/home/page.html"))
