#!/usr/bin/env python3
"""v1018-D014b behavioural check, driven by tests/test_section_contract.sh.

WHAT THE DEFECT IS, because the ledger's stated mechanism is wrong.

The ledger says raw prompt scaffolding was written to the wiki instead of
the model's output -- "a wire-order bug passed the prompt through to
storage". Measured on the founder box: zero scaffolding markers in the
4,918 People pages or anywhere else in the built wiki, and a wire-order
bug would fire on EVERY document deterministically rather than on 22% of
them.

What is actually happening is that a section goes MISSING.
`## Summary` is declared with three sub-sections -- `### Participants`,
`### Thread`, `### Narrative` -- and 29 of 129 conversation summaries
carry the first two and no third. The metadata renders, the prose does
not, and a Summary consisting only of its own metadata is what reads as
raw scaffolding.

It tracks CHUNKING, not sparse input, which is the opposite of D014a:

    1 msg    83 ok /  2 missing     2% fail
    2 msg    10 ok / 10 missing    50% fail
    3 msg     1 ok / 10 missing    91% fail
    4+ msgs   6 ok /  7 missing    54% fail

Mechanism, confirmed in the shipped source and the shipped prompts:
a chunked document is merged by `_merge_chunk_outputs`, which loads
`02b_merge_chunks` -- a template that declares no `###` headings at all
and never mentions Narrative. Nothing asked the model to keep it. And
`EXPECTED_HEADINGS_BY_PROMPT` validates `##` only, so nothing noticed.

The check was one level coarser than the defect. That is the same shape
as five other gates this cut.

Lifts the helpers out of the SHIPPED vendored source so this tests what
ships, not a copy.

Emits one `PASS: ` / `FAIL: ` line per assertion. Never a raw traceback.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys


def fail(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


def load_shipped(repo: pathlib.Path):
    src = repo / "vendor/cm048_pipeline/src/enrichment_validation.py"
    if not src.exists():
        fail(f"shipped module missing at {src}")
    spec = importlib.util.spec_from_file_location("_ev_shipped", src)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Register BEFORE exec: the module defines an @dataclass, and
    # dataclasses resolves the owning module out of sys.modules while
    # building it. Without this the load dies with a bare
    # "AttributeError: 'NoneType' object has no attribute '__dict__'".
    sys.modules["_ev_shipped"] = mod
    spec.loader.exec_module(mod)
    return mod


# The exact shape of the 29 broken documents: Summary present, its two
# metadata sub-sections present, the prose sub-section absent.
BROKEN = """## Summary

### Participants

- A person (user)
- Another person (other)

### Thread

- Subject: A subject line
- Span: 2026-08-08 to 2026-08-08
- Messages: 3

## Key topics

_Nothing to report._
"""

WHOLE = BROKEN.replace(
    "## Key topics",
    "### Narrative\n\nThe thread opens with a question and resolves it.\n\n## Key topics",
)


def main(repo_str: str) -> int:
    repo = pathlib.Path(repo_str)
    ev = load_shipped(repo)

    for name in ("expected_subheadings_for", "validate_subheadings",
                 "build_section_contract"):
        if not hasattr(ev, name):
            fail(f"{name} is gone from the shipped module (v1018-D014b)")

    checks: list[tuple[str, bool]] = []

    # --- the declared contract ------------------------------------------
    checks.append((
        "email_thread declares its three sub-sections",
        ev.expected_subheadings_for("02_enrich_email_thread")
        == ["Participants", "Thread", "Narrative"],
    ))
    checks.append((
        "work_one-on-one declares its three sub-sections",
        ev.expected_subheadings_for("02_enrich_work_one-on-one")
        == ["Participants", "Location", "Narrative"],
    ))
    # This is the asymmetry that matters. `expected_headings_for` falls
    # back to work_one-on-one for unknown names; sub-headings must NOT,
    # or a family conversation gets asserted against sections it never
    # declares and the gate manufactures failures.
    checks.append((
        "a flat variant declares none, with NO fallback",
        ev.expected_subheadings_for("02_enrich_family") == [],
    ))
    checks.append((
        "an unknown prompt name declares none, with NO fallback",
        ev.expected_subheadings_for("02_enrich_does_not_exist") == [],
    ))

    # --- THE REGRESSION, with its RED demonstrated first -----------------
    # If this stops being true the fixture has stopped reproducing D014b.
    checks.append((
        "fixture still reproduces the defect (no ### Narrative in it)",
        "### Narrative" not in BROKEN and "### Thread" in BROKEN,
    ))

    expected = ev.expected_subheadings_for("02_enrich_email_thread")
    broken = ev.validate_subheadings(BROKEN, expected)
    whole = ev.validate_subheadings(WHOLE, expected)

    checks.append(("the 29-document shape is caught", not broken.ok))
    checks.append((
        "and it names the section that is missing",
        broken.missing == ["Narrative"],
    ))
    checks.append(("a complete document passes", whole.ok))
    checks.append(("a complete document reports nothing missing", whole.missing == []))

    # --- false positives, which are worse than false negatives here -----
    # A wrong RED here retries a 900s model call against the D031 budget.
    checks.append((
        "a flat variant is never asserted against sub-sections",
        ev.validate_subheadings(BROKEN, []).ok,
    ))
    fenced = "## Summary\n\n```\n### Narrative\n```\n"
    checks.append((
        "a heading inside a code fence does not satisfy the contract",
        not ev.validate_subheadings(fenced, ["Narrative"]).ok,
    ))
    checks.append((
        "over-nesting does not satisfy the contract",
        not ev.validate_subheadings("#### Narrative\n", ["Narrative"]).ok,
    ))
    checks.append((
        "matching is case-insensitive",
        ev.validate_subheadings("### narrative\n", ["Narrative"]).ok,
    ))
    # A cleaned transcript legitimately carries one ### per speaker turn,
    # so extras must never be reported or every real document is noisy.
    noisy = WHOLE + "\n### Someone - 2026-08-08 (sent)\n\nHello.\n"
    checks.append((
        "speaker-turn sub-headings are not reported as extras",
        ev.validate_subheadings(noisy, expected).ok
        and ev.validate_subheadings(noisy, expected).extras == [],
    ))

    # --- the contract text the merge pass now receives -------------------
    contract = ev.build_section_contract("02_enrich_email_thread")
    checks.append((
        "the contract names every ## section",
        all(f"## {h}" in contract
            for h in ev.expected_headings_for("02_enrich_email_thread")),
    ))
    checks.append((
        "the contract names every ### sub-section",
        all(f"### {h}" in contract for h in expected),
    ))
    flat = ev.build_section_contract("02_enrich_family")
    checks.append((
        "a flat variant's contract mentions no sub-sections",
        "###" not in flat,
    ))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_section_contract.py <repo-root>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
