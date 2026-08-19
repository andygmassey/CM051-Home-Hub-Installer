#!/usr/bin/env python3
"""v1018-D014c behavioural check, driven by tests/test_placeholder_strip.sh.

WHAT THE DEFECT IS, because it is not what the ledger says and I got it
wrong twice before getting here.

The enrichment prompts are INSTRUCTIONS. All ten `load_prompt` call sites
in processor.py do `template + "\n\n---\n\n" + prompt_body`, so the real
values arrive BELOW a separator and the `{token}` forms inside a template
are ILLUSTRATIVE -- they show the model the shape of output to produce.
`prompts.render()` exists and has ZERO callers; nothing substitutes them
and nothing is meant to.

The defect is that the model sometimes copies an illustrative token into
its answer instead of substituting the value it can see below the rule,
so a customer's wiki page carries a literal `{user_email}`. That is why
it is INTERMITTENT. A substitution-plumbing bug would fire every time.

WHY STRIP AND NOT RETRY. A retry costs a model call, and v1018-D031
established those run to 900s and that the step's total budget is the
scarce resource. Stripping is deterministic and free.

Lifts the helper out of the SHIPPED vendored source so this tests what
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
    # Register BEFORE exec. The module defines an @dataclass, and
    # dataclasses resolves the owning module out of sys.modules while
    # building it -- without this the load dies with a bare
    # "AttributeError: 'NoneType' object has no attribute '__dict__'"
    # that says nothing about the real cause.
    sys.modules["_ev_shipped"] = mod
    spec.loader.exec_module(mod)
    return mod


def main(repo_str: str) -> int:
    repo = pathlib.Path(repo_str)
    ev = load_shipped(repo)
    if not hasattr(ev, "strip_placeholder_tokens"):
        fail("strip_placeholder_tokens is gone from the shipped module (v1018-D014c)")
    strip = ev.strip_placeholder_tokens

    checks: list[tuple[str, bool]] = []

    # --- THE REGRESSION, with its own RED demonstrated first -----------
    leaked = (
        "## Summary\n\nAndy wrote to the supplier from {user_email} about "
        "the {conversation_id} thread.\n"
    )
    # If this stops being true the fixture has stopped reproducing D014c
    # and every assertion below is measuring nothing.
    checks.append(
        ("fixture still reproduces the defect (raw text carries the token)",
         "{user_email}" in leaked),
    )

    cleaned, dropped = strip(leaked)
    checks.append(("the literal token is removed", "{user_email}" not in cleaned))
    checks.append(("every token is removed", "{conversation_id}" not in cleaned))
    checks.append(("both tokens are reported", dropped == ["{conversation_id}", "{user_email}"]))
    checks.append(("real prose survives", "Andy wrote to the supplier" in cleaned))
    checks.append(("the heading survives", cleaned.startswith("## Summary")))
    checks.append(("no double space is left behind", "  " not in cleaned))

    # --- FALSE POSITIVES matter more than false negatives --------------
    # A missed token is a cosmetic defect. A false positive silently edits
    # the customer's own content, which is worse, so the predicate is
    # deliberately narrow: lowercase-initial only.
    for label, text in [
        ("JSON in a code sample is untouched", '```\n{"name": "Ada"}\n```'),
        ("a brace with a capital is untouched", "She said {Alice} was late."),
        ("a numeric brace is untouched", "row {1} of the table"),
        ("an empty brace is untouched", "the set {} is empty"),
        ("prose with no braces is byte-identical", "Nothing to do here."),
    ]:
        out, drops = strip(text)
        checks.append((label, out == text and drops == []))

    # --- Idempotence: running it twice must not chew the text ----------
    once, _ = strip(leaked)
    twice, second_drops = strip(once)
    checks.append(("stripping is idempotent", once == twice and second_drops == []))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_placeholder_strip.py <repo-root>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
