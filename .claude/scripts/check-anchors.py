#!/usr/bin/env python3
"""Report same-file anchor links that no heading produces.

A table of contents is written by hand or by a model, but GitHub derives each
anchor from the heading text by rules that are easy to misapply by eye: letters
in any script are kept, punctuation is dropped without collapsing the hyphens
it leaves, underscores are kept, a link in a heading contributes only its text,
and a repeated heading gets a numbered suffix.

Only ATX headings (`#` to `######`) are read; setext headings are not used in
this repository. Links to other files are not checked.

Exit codes (dispatch on these, not on the printed text):
  0  OK          every same-file link resolves
  1  FINDINGS    at least one link names an anchor no heading produces
  2  CANNOT-RUN  the invocation is malformed or a file cannot be read
"""

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote

EXIT_OK = 0
EXIT_FINDINGS = 1
EXIT_CANNOT_RUN = 2

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
INLINE_CODE = re.compile(r"`[^`]*`")
SAME_FILE_LINK = re.compile(r"\]\(#([^)\s]+)\)")
MD_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
NOT_IN_ANCHOR = re.compile(r"[^\w\- ]")


def unfenced_lines(text):
    """Yield (line number, line) outside fenced code blocks."""
    in_fence, marker = False, None
    for number, line in enumerate(text.split("\n"), start=1):
        fence = FENCE.match(line)
        if fence:
            if not in_fence:
                in_fence, marker = True, fence.group(1)
            elif fence.group(1) == marker:
                in_fence, marker = False, None
            continue
        if not in_fence:
            yield number, line


def slug(heading: str) -> str:
    """The anchor GitHub renders for one heading, before de-duplication."""
    text = MD_LINK.sub(r"\1", heading)
    return NOT_IN_ANCHOR.sub("", text.lower()).replace(" ", "-")


def anchors(text: str) -> set:
    seen, result = {}, set()
    for _, line in unfenced_lines(text):
        match = HEADING.match(line)
        if not match:
            continue
        base = slug(match.group(1))
        candidate, count = base, seen.get(base, 0)
        while candidate in result:
            count += 1
            candidate = f"{base}-{count}"
        seen[base] = count
        result.add(candidate)
    return result


def findings(text: str) -> list:
    known = anchors(text)
    reported = []
    for number, line in unfenced_lines(text):
        for match in SAME_FILE_LINK.finditer(INLINE_CODE.sub("", line)):
            target = unquote(match.group(1))
            if target not in known:
                reported.append(f"{number}: no heading for #{target}")
    return reported


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="check-anchors.py",
        description="Report same-file anchor links that no heading produces.",
    )
    parser.add_argument("files", nargs="+", metavar="FILE")
    args = parser.parse_args(argv)

    texts = []
    for name in args.files:
        path = Path(name)
        if not path.is_file():
            print(f"cannot-run: no such file: {name}", file=sys.stderr)
            return EXIT_CANNOT_RUN
        texts.append((path, path.read_text(encoding="utf-8")))

    found = False
    for path, text in texts:
        for finding in findings(text):
            print(f"{path}:{finding}")
            found = True
    return EXIT_FINDINGS if found else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
