#!/usr/bin/env python3
"""A closing keyword and the prose beside it are two claims about one fact.

Only one of them executes.

WHAT HAPPENED, 2026-09-06, and it happened TWICE in one hour on one issue.

  06:11:34Z  CM051 #1153 closed by a closing keyword in #1654's body
  06:09Z     the board post two minutes earlier said the PR closed 4 of its 5
  07:02:57Z  reopened with the measurement
  07:11:14Z  closed AGAIN when an unrelated PR merged, because its commit
             message QUOTED the keyword in order to explain the first mistake

Both closures were wrong and both were mine. The first is what this gate
catches: a body that says "4 of 5" in prose and "close it" in machine-readable
form. GitHub reads only the second, so the issue vanished from the register
while a measured defect was still live in it.

The second is why the gate's own message never prints the pair: an explanation
written in the language the machine parses is not an explanation, it is an
instruction. This file is safe -- GitHub parses commit messages and PR bodies,
not repository contents -- but the tests build the pair at runtime rather than
carry it as a literal, so that a future reader copying a fixture into a commit
message does not close something.

VERDICTS
  0  no conflict, or no closing reference at all
  1  a closing reference AND partial-completion prose in the same body
  2  CANNOT-RUN -- no body to read. Never a pass: a gate that could not look
     must not report the same thing as a gate that looked and found nothing.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

# GitHub's own list. `close/closes/closed`, `fix/fixes/fixed`,
# `resolve/resolves/resolved`, each optionally preceded by nothing and followed
# by an optional colon, then an issue reference in this repo or another.
_KEYWORDS = r"clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed)"
_REF = r"(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#\d+"
CLOSING_RE = re.compile(rf"\b({_KEYWORDS})\b\s*:?\s+({_REF})", re.IGNORECASE)

# Prose that says the job is NOT finished. Deliberately narrow: each of these
# asserts incompleteness about the work itself, so a false positive means
# somebody wrote a genuinely confusing body.
PARTIAL_RE = re.compile(
    r"""(?ix)
    \b(?:
        part(?:ial|ially|-way)          # "partially fixes"
      | \d+\s+of\s+(?:its\s+)?\d+       # "4 of 5", "4 of its 5"
      | stays?\s+open
      | remains?\s+open
      | still\s+(?:open|live|blind|broken)
      | does\s+not\s+(?:fully\s+)?close
      | half\s+of\s+(?:it|this|the\s+\w+)
      | the\s+(?:other|remaining)\s+half
      | not\s+the\s+(?:whole|full)\s+\w+
    )\b
    """
)


def _emit(lines: list[str]) -> None:
    for ln in lines:
        print(ln)


def check(body: str) -> tuple[int, list[str]]:
    closings = [(m.group(1), m.group(2)) for m in CLOSING_RE.finditer(body)]
    partials = sorted({m.group(0).strip() for m in PARTIAL_RE.finditer(body)})

    out = [
        "=== closing keyword vs the prose beside it ===",
        f"  body                : {len(body)} byte(s)",
        f"  closing reference(s): {len(closings)}",
        f"  partial-completion  : {len(partials)}",
        "",
    ]
    if not closings:
        out.append("  PASS  no closing reference in this body, so nothing to contradict")
        return 0, out
    if not partials:
        out.append(
            f"  PASS  {len(closings)} closing reference(s) and no partial-completion "
            "prose: the body and the keyword agree"
        )
        return 0, out

    # Report the REFERENCE and the PROSE, never the two adjacent, so this
    # output cannot itself act as a directive if pasted into a commit message.
    refs = ", ".join(sorted({ref for _kw, ref in closings}))
    out += [
        "  FAIL  this body asks to close an issue AND says the work is partial",
        f"        issue reference(s): {refs}",
        f"        but the prose says: {'; '.join(partials)}",
        "",
        "        Only the keyword executes. The prose is read by people and the",
        "        keyword is read by GitHub, so a body carrying both leaves an",
        "        issue shut on work its own author described as unfinished.",
        "",
        "        Pick one:",
        "          - the work IS complete  -> delete the partial-completion prose",
        "          - the work is NOT       -> use `Refs <ref>` and close it by hand",
        "            when the rest lands",
    ]
    return 1, out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pr-body-file", required=True)
    args = ap.parse_args()

    p = pathlib.Path(args.pr_body_file)
    try:
        body = p.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        _emit(
            [
                "=== closing keyword vs the prose beside it ===",
                f"  CANNOT-RUN  could not read {p}: {exc}",
                "  A body this gate could not read has not been checked. That is",
                "  not the same as a body with no conflict in it.",
            ]
        )
        return 2

    rc, out = check(body)
    _emit(out)
    return rc


if __name__ == "__main__":
    sys.exit(main())
