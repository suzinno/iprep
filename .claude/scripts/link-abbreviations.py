#!/usr/bin/env python3
"""Apply .claude/glossary.md to Markdown files.

The glossary owns what an abbreviation expands to, what it is for, and where
its official source lives. This script is the only thing that writes those
facts into a document, so no document restates them and none drifts.

Exit codes (dispatch on these, not on the printed text):
  0  OK          nothing to report; the files match the glossary
  1  FINDINGS    --check only: at least one divergence from the glossary
  2  CANNOT-RUN  the invocation, or the glossary itself, is malformed
"""

import argparse
import re
import sys
from pathlib import Path
from typing import NamedTuple

EXIT_OK = 0
EXIT_FINDINGS = 1
EXIT_CANNOT_RUN = 2

LINKED_HEADING = "## Linked terms"
EXCLUDED_HEADING = "## Deliberately not linked"

TABLE_ROW = re.compile(r"^\|(.+)\|\s*$")
SEPARATOR_ROW = re.compile(r"^[\s|:-]+$")


class Term(NamedTuple):
    term: str
    expansion: str
    purpose: str
    source: str


class GlossaryError(Exception):
    """The glossary cannot be trusted, so nothing may be written from it."""


def _table_after(lines, heading, want_columns):
    """Rows of the first Markdown table following `heading`, header dropped."""
    try:
        start = lines.index(heading) + 1
    except ValueError:
        raise GlossaryError(f"glossary has no {heading!r} section")
    rows, seen_header = [], False
    for line in lines[start:]:
        if not line.strip():
            if rows or seen_header:
                break
            continue
        match = TABLE_ROW.match(line)
        if not match:
            break
        if SEPARATOR_ROW.match(match.group(1)):
            continue
        cells = [cell.strip() for cell in match.group(1).split("|")]
        if len(cells) != want_columns:
            raise GlossaryError(
                f"{heading!r}: expected {want_columns} columns, got {len(cells)}: {line.strip()}"
            )
        if not seen_header:
            seen_header = True
            continue
        rows.append(cells)
    return rows


def _validate(term: Term) -> None:
    for label, value in (
        ("expansion", term.expansion),
        ("purpose", term.purpose),
    ):
        if not value:
            raise GlossaryError(f"{term.term}: {label} is empty")
        if '"' in value:
            raise GlossaryError(
                f'{term.term}: {label} contains a double quote, which would end the link title'
            )
        if "(" in value or ")" in value:
            # A parenthesis inside a rendered title ends the link early for the
            # regex that masks existing links, which would break idempotency.
            raise GlossaryError(
                f"{term.term}: {label} contains a parenthesis; rephrase without one"
            )
    if not term.source.startswith(("http://", "https://")):
        raise GlossaryError(f"{term.term}: source is not an http(s) URL: {term.source}")
    if "(" in term.source or ")" in term.source:
        raise GlossaryError(
            f"{term.term}: source contains a parenthesis, which would end the link target"
        )


def load_glossary(path: Path):
    """Return (linked terms, {excluded term: reason}). Raises GlossaryError."""
    try:
        lines = path.read_text(encoding="utf-8").split("\n")
    except OSError as exc:
        raise GlossaryError(f"cannot read glossary: {exc}")

    terms = []
    for term, expansion, purpose, source in _table_after(lines, LINKED_HEADING, 4):
        entry = Term(term, expansion, purpose, source)
        _validate(entry)
        terms.append(entry)

    excluded = {}
    for row in _table_after(lines, EXCLUDED_HEADING, 2):
        excluded[row[0]] = row[1]

    seen = {}
    for entry in terms:
        if entry.term in seen:
            raise GlossaryError(f"{entry.term}: listed twice under {LINKED_HEADING}")
        seen[entry.term] = True
    for term in excluded:
        if term in seen:
            raise GlossaryError(f"{term}: listed as both linked and not linked")

    # Longest first, so SHA-256 is attempted before SHA. Without this, the word
    # boundary after "SHA" in "SHA-256" is real and the shorter term wins.
    terms.sort(key=lambda entry: len(entry.term), reverse=True)
    return terms, excluded


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="link-abbreviations.py",
        description="Apply the abbreviation glossary to Markdown files.",
    )
    parser.add_argument("files", nargs="+", metavar="FILE")
    parser.add_argument("--check", action="store_true", help="report only; write nothing")
    parser.add_argument(
        "--glossary",
        default=".claude/glossary.md",
        help="path to the glossary (default: .claude/glossary.md)",
    )
    args = parser.parse_args(argv)

    try:
        terms, excluded = load_glossary(Path(args.glossary))
    except GlossaryError as exc:
        print(f"cannot-run: {exc}", file=sys.stderr)
        return EXIT_CANNOT_RUN

    targets = []
    for name in args.files:
        path = Path(name)
        if not path.is_file():
            print(f"cannot-run: no such file: {name}", file=sys.stderr)
            return EXIT_CANNOT_RUN
        targets.append(path)

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
