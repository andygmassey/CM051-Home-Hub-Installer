#!/usr/bin/env python3
"""Behavioural check for v1018-D031, driven by tests/test_enrich_budget.sh.

Lifts the budget helpers out of the SHIPPED vendored processor and
exercises them, so the gate tests what ships rather than a copy.

Extraction is bounded by the block's own closing sentinel and PROVES it
did not overshoot before executing anything -- the lesson from v1018-D032,
where a greedy `.*$` swallowed the rest of the module and only failed on
CI's interpreter.

Emits one `PASS: ` / `FAIL: ` line per assertion, and exactly one `FAIL: `
for an unexpected exception. Never a raw traceback.
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

    m = re.search(
        r"^_ENRICH_BUDGET_DEFAULT_SECS = .*?^# -{10,}$", src, re.S | re.M
    )
    if not m:
        fail("budget block not found between its sentinels in the shipped source")
    snippet = m.group(0)

    for required in ("def _budget_timeout", "def _enrich_budget_secs",
                     "class EnrichmentBudgetExceeded"):
        if required not in snippet:
            fail(f"extraction did not include {required!r}")
    for leaked in ("def _step_enrich", "def _run_step", "def process_"):
        if leaked in snippet:
            fail(f"extraction overshot the budget block and pulled in {leaked!r}")
    print("PASS: extraction is bounded to the budget block and did not overshoot")

    import time as _time
    ns: dict = {"os": os, "time": _time}
    exec(snippet, ns)  # noqa: S102 -- our own shipped source, verified above
    budget_secs = ns["_enrich_budget_secs"]
    budget_timeout = ns["_budget_timeout"]
    Exceeded = ns["EnrichmentBudgetExceeded"]
    ceiling = ns["_ENRICH_CALL_CEILING_SECS"]
    default = ns["_ENRICH_BUDGET_DEFAULT_SECS"]

    checks = []

    # --- the allowance itself -------------------------------------------
    for label, raw, want in [
        ("unset uses the default allowance", None, float(default)),
        ("explicit value is honoured", "60", 60.0),
        ("zero means unbounded", "0", None),
        ("garbage falls back, never raises", "banana", float(default)),
    ]:
        os.environ.pop("OSTLER_ENRICH_BUDGET_SECS", None)
        if raw is not None:
            os.environ["OSTLER_ENRICH_BUDGET_SECS"] = raw
        try:
            checks.append((label, budget_secs() == want))
        except Exception as exc:  # noqa: BLE001
            checks.append((f"{label} (raised {type(exc).__name__})", False))

    # --- the per-call timeout derived from it ---------------------------
    # Unarmed: full ceiling, so a caller outside the step is unaffected.
    ns["_enrich_deadline"] = None
    checks.append(("unarmed budget yields the full per-call ceiling",
                   budget_timeout() == ceiling))

    # Plenty of allowance left: still clamped to the per-call ceiling.
    ns["_enrich_deadline"] = _time.monotonic() + 10_000
    checks.append(("ample allowance is still clamped to the call ceiling",
                   budget_timeout() == ceiling))

    # Less remaining than the ceiling: the CALL shrinks to fit the budget.
    # This is the property that makes the total bound hold however the
    # transcript happens to chunk.
    ns["_enrich_deadline"] = _time.monotonic() + 5
    got = budget_timeout()
    checks.append(("a nearly-spent allowance shrinks the next call",
                   0 < got <= 5.5 and got < ceiling))

    # Exhausted: refuse rather than start a call that cannot finish.
    ns["_enrich_deadline"] = _time.monotonic() - 1
    try:
        budget_timeout()
        checks.append(("an exhausted allowance refuses the next call", False))
    except Exception as exc:  # noqa: BLE001
        checks.append(("an exhausted allowance refuses the next call",
                       isinstance(exc, Exceeded)))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_enrich_budget.py <path-to-processor.py>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
