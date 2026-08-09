#!/usr/bin/env python3
"""Behavioural check for v1018-D032, driven by tests/test_stderr_tail.sh.

Lifts `_stderr_excerpt` out of the SHIPPED pipeline source and exercises
it, so the gate tests what ships rather than a copy that can drift.

Lives in its own file rather than inline in the shell script: the first
cut embedded it as a heredoc, which made the extraction regex and the
shell quoting interact badly and hid a real bug (see below).

Emits one `PASS: ` or `FAIL: ` line per assertion, and exactly one
`FAIL: ` line for an unexpected exception -- never a raw traceback. A
multi-line failure used to be counted as one bogus failure per line,
which inflated the count and buried the reason.

Exit 0 if every assertion holds, 1 otherwise.
"""

from __future__ import annotations

import os
import re
import sys


def fail(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


def main(path: str) -> int:
    src = open(path, encoding="utf-8").read()

    # Bounded by the helper's own closing sentinel.
    #
    # The first cut used `.*$` under re.S. That is greedy to end-of-file,
    # so it silently swallowed the rest of the module and exec'd function
    # definitions annotated `Optional[Path]`. It passed on Python 3.14,
    # where deferred annotation evaluation is the default and those
    # annotations are never evaluated, and failed on CI's older Python,
    # which evaluates them and raises NameError.
    #
    # The lesson is not "escape the regex better" -- it is that an
    # extraction must prove what it extracted before running it.
    m = re.search(
        r"^_STDERR_EXCERPT_DEFAULT_CHARS = .*?^# -{10,}$", src, re.S | re.M
    )
    if not m:
        fail("helper block not found between its sentinels in the shipped source")
    snippet = m.group(0)

    if "def _stderr_excerpt" not in snippet:
        fail("extraction did not include _stderr_excerpt")
    for leaked in ("def _dispatch_to_cm048", "def process_", "def _resolve_"):
        if leaked in snippet:
            fail(f"extraction overshot the helper and pulled in {leaked!r}")
    print("PASS: extraction is bounded to the helper and did not overshoot")

    ns: dict = {"os": os}
    exec(snippet, ns)  # noqa: S102 -- executing our own shipped source, verified above
    excerpt = ns["_stderr_excerpt"]

    os.environ["OSTLER_DISPATCH_STDERR_CHARS"] = "40"
    long = "START-OF-RUN " + ("x" * 300) + " LAST-THING-BEFORE-IT-WEDGED"
    got = excerpt(long)

    checks = [
        ("keeps the tail", got.endswith("LAST-THING-BEFORE-IT-WEDGED")),
        ("drops the head", "START-OF-RUN" not in got),
        ("marks the clip", "earlier chars dropped" in got),
        ("reports how much was dropped", re.search(r"<\.\.\.\d+ earlier", got) is not None),
        ("short text passes through", excerpt("brief error") == "brief error"),
        ("None is explicit", excerpt(None) == "<no stderr captured>"),
        ("empty is explicit", excerpt("   ") == "<stderr empty>"),
    ]

    os.environ["OSTLER_DISPATCH_STDERR_CHARS"] = "banana"
    checks.append(
        ("malformed env falls back rather than raising", isinstance(excerpt(long), str))
    )
    os.environ["OSTLER_DISPATCH_STDERR_CHARS"] = "0"
    checks.append(("zero means no clipping", excerpt(long) == long.strip()))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_stderr_excerpt.py <path-to-pipeline.py>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
