#!/usr/bin/env python3
"""dedupe_merge must not weld two Contacts cards onto one Person.

WHY THIS EXISTS. MEASURED on the v1.0.71 walk box, 2026-09-05, on a graph
built entirely inside the walk window:

    icloud_contact_uid identifiers        1673   (anti-vacuity control)
    Person nodes with 2+ distinct uids      54
    Contacts cards swallowed               117
    mergedInto tombstones in the graph       1   (control: the predicate CAN
                                                  see tombstones)
    of the 54, how many carry a tombstone     0

That last pair is the discriminator. `identity_resolver.merge_persons` and
`batch_resolver._merge_oxigraph` ALWAYS write a `mergedInto` tombstone and both
already veto on canonical keys (#1418, #1543). `dedupe_merge` writes no
tombstone. Not one of the 54 survivors carries one, so every one of them was
welded by this module -- which had no RULE 2 check of any kind.

WHY EVERY EARLIER AUDIT MISSED IT: this file never mentions
`icloud_contact_uid`. It groups on email and phone VALUES, so a search starting
from the canonical key, or from the guarded function, cannot see the writer
that corrupts it. The v1.0.71 cut manifest records the symptom in as many
words: "every audit that started from the guarded function came back clean."

THE TEST STUBS THE STORE. The defect is a decision, not a query, so the SPARQL
layer is replaced with an in-memory fixture and every merge is recorded. No
Oxigraph, no network, no box.

Exit 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
MODULE_REL = "vendor/ostler_fda/dedupe_merge.py"
# The tree that shipped the defect. Pinned to a sha, never a branch: a control
# that reads origin/main inverts the moment this fix merges.
CONTROL_SHA = "bdbd5bb5"

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def cannot_run(msg: str) -> None:
    print(f"CANNOT-RUN: {msg}", file=sys.stderr)
    raise SystemExit(2)


def _ensure_httpx_importable() -> None:
    """`dedupe_merge` imports httpx at module scope, so loading it needs the
    name to resolve even though this test never makes a request -- the whole
    SPARQL layer is replaced before `run()` is called.

    Installing httpx in CI just to satisfy an import would give a hermetic
    test a network dependency and a slower job, so if the real package is
    absent a minimal stand-in is registered instead. If the real one IS
    present it is left alone, so local runs exercise the genuine import.

    The stand-in deliberately raises if anything actually calls it: a test
    that silently made a request through a dummy client would be worse than
    one that could not import at all.
    """
    try:
        import httpx  # noqa: F401
        return
    except ModuleNotFoundError:
        pass
    import types

    stub = types.ModuleType("httpx")

    def _refuse(*_a, **_k):
        raise AssertionError(
            "the httpx stand-in was CALLED. This test stubs _sparql_query and "
            "_sparql_update, so nothing should reach the transport. A real "
            "request here means the stubs did not take effect."
        )

    stub.HTTPTransport = _refuse  # type: ignore[attr-defined]
    stub.Client = _refuse         # type: ignore[attr-defined]
    sys.modules["httpx"] = stub


def load(path: pathlib.Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        cannot_run(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def drive(mod, people, raise_on_key_query=False):
    """people: {person_uri: {"email": [...], "phone": [...], "uid": [...]}}
    Returns (merges_performed, stats)."""
    merges = []

    def fake_query(sparql: str):
        # The canonical-key read is the only query naming the uid type.
        if mod.CANONICAL_KEY_TYPE in sparql:
            if raise_on_key_query:
                raise RuntimeError("store unreachable")
            out = []
            for p, d in people.items():
                for v in d.get("uid", []):
                    out.append({"p": {"value": p}, "v": {"value": v}})
            return out
        for typ in mod.EXACT_KEY_TYPES:
            if f'"{typ}"' in sparql:
                out = []
                for p, d in people.items():
                    for v in d.get(typ, []):
                        out.append({"p": {"value": p}, "v": {"value": v}})
                return out
        return []

    def fake_update(sparql: str):
        merges.append(sparql)

    mod._sparql_query = fake_query      # type: ignore[attr-defined]
    mod._sparql_update = fake_update    # type: ignore[attr-defined]
    stats = mod.run(dry_run=False)
    # _merge_pair issues two updates per merge
    return len(merges) // 2, stats


def main() -> int:
    _ensure_httpx_importable()
    subject_path = REPO / MODULE_REL
    if not subject_path.is_file():
        cannot_run(f"no module at {subject_path}")
    subject = load(subject_path, "dedupe_merge_subject")

    # Synthetic throughout. Fictional names, example.com addresses, and the
    # RFC-reserved UK drama phone range: nothing here belongs to a real person.
    TWO_CARDS = {
        "urn:p:alpha": {"phone": ["+447700900001"], "uid": ["CARD-AAA"]},
        "urn:p:bravo": {"phone": ["+447700900001"], "uid": ["CARD-BBB"]},
    }
    ONE_CARD = {
        "urn:p:alpha": {"phone": ["+447700900002"], "uid": ["CARD-AAA"]},
        "urn:p:imsg": {"phone": ["+447700900002"]},
    }
    SAME_CARD = {
        "urn:p:alpha": {"email": ["testcase.alpha@example.com"], "uid": ["CARD-AAA"]},
        "urn:p:dup": {"email": ["testcase.alpha@example.com"], "uid": ["CARD-AAA"]},
    }
    # Union-find bridge: alpha and charlie share NOTHING directly. bravo
    # touches alpha's phone and charlie's email, so all three land in one
    # component. alpha and charlie are different Contacts cards.
    TRANSITIVE = {
        "urn:p:alpha": {"phone": ["+447700900003"], "uid": ["CARD-AAA"]},
        "urn:p:bravo": {"phone": ["+447700900003"], "email": ["bridge@example.com"]},
        "urn:p:charlie": {"email": ["bridge@example.com"], "uid": ["CARD-CCC"]},
    }
    # 🔴 THE CARD-LESS CANONICAL. TNM's fixture, and it exists because the
    # TRANSITIVE arm above NAMES accumulation in its own message and CANNOT
    # DETECT ITS REMOVAL. Measured: delete `held |= dupe_keys` from the module
    # and TRANSITIVE still reports PASS, with the word "accumulates" in it.
    #
    # The reason is the fixture, not the arm. In TRANSITIVE, `alpha` sorts
    # first AND already holds CARD-AAA, so `held` is non-empty before any merge
    # and the refusal comes from alpha's own key. Accumulation never has to do
    # anything, so removing it changes nothing that arm can see.
    #
    # Here the bridge sorts FIRST and starts with NO key, so the only thing
    # that can stop the second card being welded on is a `held` set that grew
    # during the component's own merges. That is the property, isolated.
    ACCUM = {
        "urn:p:aaa_bridge": {"phone": ["+447700900007"], "email": ["bridge2@example.com"]},
        "urn:p:mike": {"phone": ["+447700900007"], "uid": ["CARD-MMM"]},
        "urn:p:zulu": {"email": ["bridge2@example.com"], "uid": ["CARD-ZZZ"]},
    }

    print("== subject: this tree ==")

    n, stats = drive(subject, TWO_CARDS)
    if n == 0 and stats.get("refused_rule2") == 1:
        ok("two DIFFERENT Contacts cards sharing a phone are NOT merged (RULE 2 veto fires)")
    else:
        bad(f"two different cards produced {n} merge(s), refused={stats.get('refused_rule2')}. This is the measured defect.")

    n, stats = drive(subject, ONE_CARD)
    if n == 1 and stats.get("refused_rule2") == 0:
        ok("CONTROL: RULE 1 still works -- a card and a card-less iMessage node DO merge")
    else:
        bad(f"RULE 1 regressed: expected 1 merge, got {n} (refused={stats.get('refused_rule2')}). The veto has blinded the sweep.")

    n, stats = drive(subject, SAME_CARD)
    if n == 1 and stats.get("refused_rule2") == 0:
        ok("CONTROL: two nodes carrying the SAME card still merge -- the veto keys on DIFFERENCE, not presence")
    else:
        bad(f"same-card nodes gave {n} merge(s), refused={stats.get('refused_rule2')}; the veto is testing presence rather than difference")

    n, stats = drive(subject, TRANSITIVE)
    if n == 1 and stats.get("refused_rule2") == 1:
        ok("TRANSITIVE: the bridge node merges, the second Contacts card is refused (veto accumulates across the component)")
    else:
        bad(f"transitive component gave {n} merge(s), refused={stats.get('refused_rule2')}; expected 1 and 1. Union-find still welds two cards.")

    n, stats = drive(subject, ACCUM)
    if n == 1 and stats.get("refused_rule2") == 1:
        ok("ACCUMULATION: a CARD-LESS canonical takes the first card and REFUSES the second, which is the only arm that fails when `held |= dupe_keys` is deleted")
    else:
        bad(f"card-less canonical gave {n} merge(s), refused={stats.get('refused_rule2')}; expected 1 and 1. "
            f"With the accumulation removed this is 2 and 0: BOTH cards welded onto a node that had none.")

    n, stats = drive(subject, TWO_CARDS, raise_on_key_query=True)
    if n == 0 and stats.get("refused_unreadable") is True:
        ok("FAIL CLOSED: an unreadable key set refuses every merge rather than merging blind")
    else:
        bad(f"an unreadable key set still performed {n} merge(s); it must refuse everything")

    # -- NEGATIVE CONTROL, pinned to the tree that shipped the defect --------
    print(f"== negative control: {CONTROL_SHA} (the tree with no RULE 2 veto) ==")
    try:
        blob = subprocess.run(
            ["git", "-C", str(REPO), "show", f"{CONTROL_SHA}:{MODULE_REL}"],
            capture_output=True, check=True,
        ).stdout
    except subprocess.CalledProcessError:
        cannot_run(
            f"control blob {CONTROL_SHA}:{MODULE_REL} is unreadable. A shallow "
            "clone cannot see it, and scanning nothing must not read as a "
            "passing control."
        )
    with tempfile.TemporaryDirectory() as td:
        cpath = pathlib.Path(td) / "control_dedupe_merge.py"
        cpath.write_bytes(blob)
        control = load(cpath, "dedupe_merge_control")
        if not hasattr(control, "EXACT_KEY_TYPES"):
            cannot_run("the control blob is not the module this test drives")
        # The control has no CANONICAL_KEY_TYPE at all; give the driver the
        # name so its query-routing still works against the old module.
        if not hasattr(control, "CANONICAL_KEY_TYPE"):
            control.CANONICAL_KEY_TYPE = "icloud_contact_uid"  # type: ignore[attr-defined]
        n, stats = drive(control, TWO_CARDS)
        if n == 1:
            ok(f"control {CONTROL_SHA}: two different Contacts cards ARE welded together -- the defect reproduces")
        else:
            bad(f"control {CONTROL_SHA}: produced {n} merge(s); this harness is not measuring the defect")
        n, _ = drive(control, ONE_CARD)
        if n == 1:
            ok("CONTROL ON THE CONTROL: the pre-fix tree merged the legitimate RULE 1 pair too, so the DIFFERENCE in canonical keys is the discriminator")
        else:
            bad(f"the pre-fix tree gave {n} merge(s) on the legitimate pair; the discriminator is not what this test claims")

    print()
    print(f"== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
