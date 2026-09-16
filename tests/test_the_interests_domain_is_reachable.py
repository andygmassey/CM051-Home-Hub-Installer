#!/usr/bin/env python3
"""The Interests domain must be reachable from a source a real box actually has.

THE DEFECT, measured on a walk box (CM051 #1872 characterised it; this gate
stops it coming back). A customer holding 830 preference points and 1629 people
saw an EMPTY Interests page. The compiler was not broken: it applied a
membership floor, ``min_confidence = 0.28``, to a number that for the two
categories feeding the Interests domain could never reach it.

    interest           x facebook   -> 0.2484   floor 0.28   DELETED
    interest           x <unnamed>  -> 0.1720   floor 0.28   DELETED
    inferred_interest  x facebook   -> 0.2259   floor 0.28   DELETED

and no amount of corroboration closed the gap, because ``evidence_factor``
returned 0.70 for the single-observation case and at most 1.0 ever, so the
displayed confidence could never EXCEED the row's own reliability. A saturating
corroboration term that cannot change an outcome is dead code, and a domain
whose only feeder categories cannot clear the floor is dead by construction.

WHAT THIS ASSERTS, all four with printed denominators:

  1. REACHABILITY. Every domain that is not the declared noise bucket must be
     reachable from every source in ``DECLARED_SOURCES`` at ONE fresh
     observation. Both the domain set and the declared-source set are read from
     the module, never hard-coded here, so adding a category or a source moves
     the denominator rather than silently escaping the gate.
  2. CORROBORATION LIFTS. A below-floor row repeated enough times must clear
     the floor. This is CM051 #1872's own measurement (1, 3, 10, 20, 50), which
     returned zero at every N before the fix.
  3. THE NOISE LEVER STILL WORKS. The known-noise sources and the two weakest
     categories must still be screened at one observation, or "reachable" has
     been bought by turning the screen off.
  4. THE CODE AND ITS DOCUMENTATION AGREE. The retired sentence claiming
     low-trust categories "still appear in the profile" must not be in the
     module, because they do not: they are deleted and counted.

RUN:  env -u PYTHONPATH python3 tests/test_the_interests_domain_is_reachable.py
EXIT: 0 pass · 1 fail · 2 CANNOT-RUN (a third state, and not a pass)

No network, no subprocess, no HTTP: nothing here can be killed by a proxy.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The test inserts its own path. A test that only passes because the caller
# exported PYTHONPATH reports CANNOT-RUN in CI, which is neither pass nor fail.
sys.path.insert(0, os.path.join(REPO, "vendor", "cm059_editor"))

FAILURES: list[str] = []


def cannot_run(why: str) -> "None":
    print(f"CANNOT-RUN: {why}", file=sys.stderr)
    raise SystemExit(2)


def check(ok: bool, label: str) -> bool:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    if not ok:
        FAILURES.append(label)
    return ok


try:
    from compiler import interest_profile as ip
except Exception as exc:  # noqa: BLE001
    cannot_run(f"cannot import compiler.interest_profile: {exc!r}")

NOW = datetime(2026, 9, 17, 12, 0, 0, tzinfo=timezone.utc)
FRESH = (NOW - timedelta(days=30)).isoformat()
UNNAMED = "__a_source_the_table_does_not_name__"


def survives(category: str, source: str, n: int = 1) -> bool:
    """Does one synthetic row of this shape reach a customer's profile?

    The subject is the whole compiled profile, not a helper: this calls the same
    ``compile_profile`` the shipped emitter calls, so a change that keeps the
    arithmetic and moves the screen elsewhere still moves this gate.
    """
    raws = [{"subject": "Synthetic Topic", "category": category, "source": source,
             "strength": 0.6, "observed_at": FRESH} for _ in range(n)]
    stats = ip.compile_profile(raws, now=NOW)["stats"]
    return (stats["interests"] + stats["dislikes"]) > 0


def main() -> int:
    for name in ("CATEGORY_TRUST", "CATEGORY_DOMAIN", "SOURCE_TRUST",
                 "DECLARED_SOURCES", "_LOW_TRUST_CATEGORIES", "MIN_CONFIDENCE"):
        if not hasattr(ip, name):
            cannot_run(f"interest_profile has no {name}; the matrix cannot be enumerated")

    cats = sorted(ip.CATEGORY_TRUST)
    srcs = sorted(ip.SOURCE_TRUST) + [UNNAMED]
    domains = sorted(set(ip.CATEGORY_DOMAIN.values()))
    declared = sorted(ip.DECLARED_SOURCES)

    if not cats or not srcs or not domains or not declared:
        cannot_run("an enumerated set came back empty; a zero denominator reads as success")

    print("DENOMINATORS, all enumerated from the module under test, none hard-coded here:")
    print(f"  categories in CATEGORY_TRUST ........ {len(cats)}")
    print(f"  categories in CATEGORY_DOMAIN ....... {len(ip.CATEGORY_DOMAIN)}")
    print(f"  sources in SOURCE_TRUST (+1 unnamed)  {len(srcs)}")
    print(f"  distinct domains .................... {len(domains)}  {domains}")
    print(f"  declared sources .................... {len(declared)}  {declared}")
    print(f"  full matrix ......................... {len(cats)} x {len(srcs)} = "
          f"{len(cats) * len(srcs)} (category, source) pairs")
    print(f"  membership floor .................... {ip.MIN_CONFIDENCE}")
    print()

    # ---- the full matrix, printed in full. Nothing here is capped with head
    # ---- or tail: all pairs are evaluated and all are printed.
    matrix = {}
    print(f"{'category':<18}{'source':<38}{'domain':<17}{'reliab':>8}{'shown':>8}  verdict")
    print("-" * 100)
    for c in cats:
        for s in srcs:
            src = "" if s == UNNAMED else s
            raw = {"subject": "Synthetic Topic", "category": c, "source": src,
                   "strength": 0.6, "observed_at": FRESH}
            it = ip.build_interest(raw, NOW)
            ip.finalise_confidence(it, NOW)
            ok = survives(c, src)
            matrix[(c, s)] = ok
            print(f"{c:<18}{s:<38}{ip.category_domain(c):<17}"
                  f"{it['reliability']:>8.4f}{it['confidence']:>8.4f}  "
                  f"{'SHOWN' if ok else 'screened'}")
    shown = sum(1 for v in matrix.values() if v)
    print(f"\n{shown} of {len(matrix)} pairs reach a customer's profile; "
          f"{len(matrix) - shown} are screened.\n")

    # ---- 1. REACHABILITY ---------------------------------------------------
    # The excluded domain is derived, not chosen: a domain every one of whose
    # feeder categories sits in _LOW_TRUST_CATEGORIES IS the declared noise
    # bucket, and screening it is the lever working, not a domain dying.
    feeders = {}
    for cat, dom in ip.CATEGORY_DOMAIN.items():
        feeders.setdefault(dom, []).append(cat)
    noise_domains = {d for d, fs in feeders.items()
                     if all(f in ip._LOW_TRUST_CATEGORIES for f in fs)}
    asserted = [d for d in domains if d not in noise_domains]
    print(f"1. REACHABILITY. {len(asserted)} of {len(domains)} domains asserted; "
          f"{len(noise_domains)} excluded as the declared noise bucket {sorted(noise_domains)}.")
    print(f"   {len(asserted)} domains x {len(declared)} declared sources = "
          f"{len(asserted) * len(declared)} requirements.")
    if not asserted:
        cannot_run("every domain was excluded as noise; the assertion has a zero denominator")
    met = 0
    for dom in asserted:
        for s in declared:
            ok = any(matrix[(c, s)] for c in feeders[dom])
            met += 1 if ok else 0
            if not ok:
                check(False, f"domain {dom!r} is unreachable from declared source {s!r} "
                             f"(feeders {sorted(feeders[dom])})")
    print(f"   {met} of {len(asserted) * len(declared)} requirements met.")
    check(met == len(asserted) * len(declared),
          f"every asserted domain reaches a customer from every declared source "
          f"({met}/{len(asserted) * len(declared)})")

    # ---- 2. CORROBORATION LIFTS -------------------------------------------
    print("\n2. CORROBORATION LIFTS. CM051 #1872 measured 1, 3, 10, 20, 50 identical "
          "`interest` rows\n   from an unnamed source and got ZERO interests at every N. "
          "Re-measured here, all 5 Ns:")
    curve = {}
    for n in (1, 3, 10, 20, 50):
        curve[n] = survives("interest", "", n=n)
        print(f"   n={n:<3} -> {'SHOWN' if curve[n] else 'screened'}")
    check(curve[1] is False,
          "a single unnamed-source `interest` row is still screened (the floor still screens)")
    check(any(curve[n] for n in (10, 20, 50)),
          "repeated observations of the same `interest` row CAN clear the floor "
          "(evidence_factor is a boost, as its docstring says)")
    ef1 = ip.evidence_factor(1, 1)
    check(abs(ef1 - 1.0) < 1e-9,
          f"evidence_factor(1, 1) is neutral, not a discount (got {ef1})")
    check(ip.evidence_factor(50, 1) > 1.0,
          f"evidence_factor saturates ABOVE neutral (got {ip.evidence_factor(50, 1)})")

    # ---- 3. THE NOISE LEVER STILL WORKS -----------------------------------
    # 🔴 THESE TWO SETS ARE NAMED, NOT DERIVED FROM THE TRUST TABLES, and that is
    # deliberate. The first draft read them back as "everything scoring <= 0.18",
    # which made the DENOMINATOR a function of the very numbers under test: a
    # mutant that raised `csv` from 0.18 to 0.98 simply left the set, the
    # assertion ran over a smaller denominator, and it PASSED. Measured - that is
    # mutant 3 in tests/test_the_interests_gates_actually_fire.sh, and it survived
    # until this was named. A gate's denominator must not be able to exclude its
    # own subject. The names come from the module's own comments: "known noise
    # (matches CM059)" over csv/email/imap, and the two weakest categories.
    NOISE_SOURCES = ("csv", "email", "imap")
    NOISE_CATEGORIES = ("facebook_content", "page")
    missing = ([s for s in NOISE_SOURCES if s not in ip.SOURCE_TRUST]
               + [c for c in NOISE_CATEGORIES if c not in ip.CATEGORY_TRUST])
    if missing:
        cannot_run(f"named noise rows are absent from the tables: {missing}; the "
                   f"assertion would run over a denominator that excludes its subject")
    pairs = {(c, s) for c in cats for s in NOISE_SOURCES}
    pairs |= {(c, s) for c in NOISE_CATEGORIES for s in srcs}
    print(f"\n3. THE NOISE LEVER STILL WORKS. noise sources, named: {list(NOISE_SOURCES)}; "
          f"\n   weakest categories, named: {list(NOISE_CATEGORIES)}; "
          f"{len(pairs)} distinct pairs must all be screened at one observation.")
    if not pairs:
        cannot_run("no noise pairs enumerated; the assertion has a zero denominator")
    for s in NOISE_SOURCES:
        check(ip.SOURCE_TRUST[s] <= 0.20,
              f"known-noise source {s!r} is still distrusted "
              f"(trust {ip.SOURCE_TRUST[s]}, must be <= 0.20)")
    for c in NOISE_CATEGORIES:
        check(ip.CATEGORY_TRUST[c] <= 0.25,
              f"weakest category {c!r} is still distrusted "
              f"(trust {ip.CATEGORY_TRUST[c]}, must be <= 0.25)")
    leaked = sorted(p for p in pairs if matrix[p])
    check(not leaked, f"every one of the {len(pairs)} noise pairs is still screened "
                      f"(leaked: {leaked})")

    # ---- 4. THE CODE AND ITS DOCUMENTATION AGREE --------------------------
    src_path = os.path.join(REPO, "vendor", "cm059_editor", "compiler",
                            "interest_profile.py")
    try:
        with open(src_path, encoding="utf-8") as fh:
            source = fh.read()
    except OSError as exc:
        cannot_run(f"cannot read {src_path}: {exc!r}")
    retired = "low-trust categories still\n# appear in the profile but sink"
    positive_control = "CATEGORY_TRUST = {"
    print("\n4. THE CODE AND ITS DOCUMENTATION AGREE.")
    print(f"   read {len(source)} bytes of {os.path.relpath(src_path, REPO)}")
    if positive_control not in source:
        cannot_run("the positive control is absent from the file just read; the "
                   "search cannot distinguish 'not present' from 'not looking'")
    print(f"   positive control {positive_control!r} FOUND, so the search can find things")
    check(retired not in source,
          "the retired claim that low-trust categories 'still appear in the profile' "
          "is gone (they are deleted and counted, not sunk)")
    check("suppressed_low_confidence" in source,
          "the screen is still accounted for in stats.suppressed_low_confidence")

    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} assertion(s)")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    print("OK: the Interests domain is reachable, corroboration lifts, noise is "
          "still screened, and the comment matches the code.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
