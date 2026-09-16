#!/usr/bin/env python3
"""An empty Interests page must tell the customer WHICH empty it is.

THE DEFECT. Two different facts rendered identically:

    "this box has no preference data"                     -> blank page
    "this box has 830 preference points and none of them
     cleared the confidence bar"                          -> the same blank page

Nothing anywhere told the customer which one they had. This repo has already
fixed exactly this pattern once: the Doctor consent tile returned "" for an
unreadable registry, indistinguishable from "no records yet" (task #429), and
now reports RED with a reason. Same treatment here.

THE SUBJECT OF EVERY ASSERTION BELOW IS A PERSON. Not the compiler, not the
artefact: the rendered Front Page HTML that a customer's Hub actually displays.
The chain exercised end to end, through a real file on disk, is

    compile_profile  ->  build_artefact  ->  interest_profile.json (written)
                     ->  render_frontpage._obtain_profile(from_artefact=True)
                     ->  frontpage.build_frontpage  ->  render_frontpage.render

so a change that keeps the numbers in the compiler but loses them on the way to
the page still fails this gate. That is the "present but dead" failure mode, and
it is the one this row smells of: the compiler has counted
``suppressed_low_confidence`` since the day it was written, and NOTHING RENDERED
IT. Present in the repo, present in the DMG, and dead.

FOUR STATES, FOUR OUTCOMES. The three the customer can be in, plus the one the
evidence discipline requires: an artefact compiled by an older build carries no
``raw_rows``, and could-not-look must never be rendered as found-nothing.

RUN:  env -u PYTHONPATH python3 tests/test_an_empty_interests_page_says_which_empty.py
EXIT: 0 pass · 1 fail · 2 CANNOT-RUN (a third state, and not a pass)

No network, no subprocess, no HTTP: nothing here can be killed by a proxy.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime, timedelta, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The test inserts its own path. A test that only passes because the caller
# exported PYTHONPATH reports CANNOT-RUN in CI, which is neither pass nor fail.
sys.path.insert(0, os.path.join(REPO, "vendor", "cm059_editor"))

FAILURES: list[str] = []


def cannot_run(why: str):
    print(f"CANNOT-RUN: {why}", file=sys.stderr)
    raise SystemExit(2)


def check(ok: bool, label: str) -> bool:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    if not ok:
        FAILURES.append(label)
    return ok


try:
    from compiler import emit_artefact as ea
    from compiler import emit_frontpage as ef
    from compiler import frontpage as fp
    from compiler import interest_profile as ip
    from compiler import render_frontpage as rf
    from compiler import render_html as rh
except Exception as exc:  # noqa: BLE001
    cannot_run(f"cannot import the editor compiler package: {exc!r}")

NOW = datetime(2026, 9, 17, 12, 0, 0, tzinfo=timezone.utc)
FRESH = (NOW - timedelta(days=30)).isoformat()

# Synthetic only. No real person's name, interest or employer appears here.
ABOVE_FLOOR = {"subject": "Synthetic Topic Alpha", "category": "music",
               "source": "facebook", "strength": 0.6, "observed_at": FRESH}
BELOW_FLOOR = {"subject": "Synthetic Topic Beta", "category": "interest",
               "source": "a_source_the_table_does_not_name", "strength": 0.6,
               "observed_at": FRESH}


def _strip_tags(markup: str) -> str:
    """What a person READS: tag content with the markup taken out. An assertion
    against raw HTML can be satisfied by an attribute or a comment nobody sees."""
    text = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", markup)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def render_for(raws: list[dict], workdir: str, *, drop_stats: bool = False) -> str:
    """The full customer chain, through a real artefact file on disk."""
    profile = ip.compile_profile(raws, now=NOW)
    artefact = ea.build_artefact(profile, now=NOW)
    if drop_stats:
        # An artefact compiled by a build older than the stats contract.
        artefact.pop("stats", None)
    path = os.path.join(workdir, "interest_profile.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(artefact, fh)
    os.environ["OSTLER_INTEREST_PROFILE"] = path
    # from_artefact=True is the shipped read: the Front Page tick reads the file
    # the emitter wrote. Never the in-process profile object.
    read_back = ef._obtain_profile(None, from_artefact=True)
    feed = fp.build_frontpage(read_back, now=NOW)
    return rf.render(feed)


def state_of(raws: list[dict], *, drop_stats: bool = False) -> str:
    profile = ip.compile_profile(raws, now=NOW)
    stats = dict(profile.get("stats", {}))
    if drop_stats:
        stats = {"interests": 0}
    return fp.interest_page_state(stats)


def main() -> int:
    if not hasattr(fp, "interest_page_state"):
        cannot_run("frontpage.interest_page_state is absent; nothing distinguishes the states")

    work = tempfile.mkdtemp(prefix="interests_page_")
    saved_env = os.environ.get("OSTLER_INTEREST_PROFILE")
    try:
        # ---- the four boxes ------------------------------------------------
        # 830 is the number measured on the walk box. Scaled down only so the
        # test stays fast; the shape, not the magnitude, is the subject.
        n_below = 40
        boxes = {
            "nothing_read":  [],
            "all_held":      [dict(BELOW_FLOOR, subject=f"Synthetic Topic {i:03d}")
                              for i in range(n_below)],
            "populated":     [ABOVE_FLOOR],
        }
        print(f"DENOMINATORS: {len(boxes) + 1} customer states asserted "
              f"(3 named in the defect + 1 unmeasured-artefact state).")
        print(f"  the all_held box carries {n_below} synthetic below-floor rows; "
              f"the walk box carried 830.")
        print()

        rendered: dict[str, str] = {}
        read: dict[str, str] = {}
        for name, raws in boxes.items():
            stats = ip.compile_profile(raws, now=NOW)["stats"]
            got = state_of(raws)
            print(f"  box {name:<13} stats raw_rows={stats['raw_rows']:<4} "
                  f"interests={stats['interests']:<4} "
                  f"suppressed={stats['suppressed_low_confidence']:<4} "
                  f"-> state {got!r}")
            check(got == name, f"box {name!r} classifies as {name!r} (got {got!r})")
            rendered[name] = render_for(raws, work)
            read[name] = _strip_tags(rendered[name])

        got_unmeasured = state_of(boxes["all_held"], drop_stats=True)
        print(f"  box {'unmeasured':<13} an older artefact with no raw_rows "
              f"-> state {got_unmeasured!r}")
        check(got_unmeasured == "unmeasured",
              "an artefact with no raw_rows is 'unmeasured', not 'nothing_read' "
              f"(got {got_unmeasured!r})")
        rendered["unmeasured"] = render_for(boxes["all_held"], work, drop_stats=True)
        read["unmeasured"] = _strip_tags(rendered["unmeasured"])
        print()

        # ---- what the PERSON sees ------------------------------------------
        print("WHAT A PERSON READS on the rendered Front Page (the customer surface):")
        for name in ("nothing_read", "all_held", "populated", "unmeasured"):
            snippet = read[name]
            idx = snippet.find("Ostler has")
            if idx < 0:
                idx = 0
            print(f"  {name:<13} ...{snippet[idx:idx + 150]}...")
        print()

        # ---- 1. the two facts must not share one output --------------------
        check(read["nothing_read"] != read["all_held"],
              "'nothing read' and 'read but all held back' render DIFFERENT text "
              "to the customer")
        check(read["all_held"] != read["populated"],
              "'all held back' and 'has interests' render different text")
        check(read["nothing_read"] != read["populated"],
              "'nothing read' and 'has interests' render different text")
        check(read["unmeasured"] not in (read["nothing_read"], read["all_held"]),
              "'cannot tell' renders as neither of the two facts it cannot choose between")
        distinct = len({read[k] for k in read})
        print(f"  {distinct} distinct rendered pages out of {len(read)} states.")
        check(distinct == len(read),
              f"all {len(read)} states render distinctly ({distinct} distinct)")

        # ---- 2. the held-back page names the reason AND the number ---------
        held = read["all_held"]
        check(str(n_below) in held,
              f"the held-back page tells the customer how many signals were read "
              f"({n_below})")
        check("held back" in held.lower(),
              "the held-back page says the signals were HELD BACK, not that there "
              "are none")
        check("read" in held.lower(),
              "the held-back page says something WAS read")

        nothing = read["nothing_read"]
        check("0 signals read" in nothing,
              "the nothing-read page states the zero it measured")
        check("not read anything" in nothing.lower(),
              "the nothing-read page says plainly that nothing has been read")

        # ---- 3. the preview renderer agrees with the shipping card ---------
        # Two surfaces disagreeing about which cause a profile has teaches the
        # reader the wrong thing from whichever they open first.
        print("\n  render_html preview (the data-contract reference), same three profiles:")
        for name, raws in boxes.items():
            prof = ip.compile_profile(raws, now=NOW)
            prev = _strip_tags(rh.render(prof))
            print(f"    {name:<13} ...{prev[-170:]}...")
            if name == "all_held":
                check(str(n_below) in prev and "held back" in prev.lower(),
                      "the preview's empty page also names the count and the reason")
            if name == "nothing_read":
                check("0 signals read" in prev,
                      "the preview's empty page states the zero when nothing was read")

        # ---- 4. house rules on the copy this PR adds -----------------------
        # Built from its codepoint, not typed: this repo bans the character
        # outright, and a detector that carries its own quarry as a literal
        # is an occurrence of the thing it hunts.
        em_dash = chr(0x2014)
        offenders = sorted(k for k in read if em_dash in rendered[k])
        # Positive control: the detector must be able to find an em dash.
        if em_dash not in ("a" + em_dash + "b"):
            cannot_run("the em-dash detector cannot find an em dash in a string "
                       "that contains one")
        card_copy = " ".join(
            fp.confirm_interests_card({"stats": s}, NOW)["title"]
            + " " + fp.confirm_interests_card({"stats": s}, NOW)["body"]
            + " " + (fp.confirm_interests_card({"stats": s}, NOW)["evidence"] or "")
            for s in ({"interests": 3},
                      {"interests": 0, "raw_rows": 40, "suppressed_low_confidence": 40},
                      {"interests": 0, "raw_rows": 0, "suppressed_low_confidence": 0},
                      {"interests": 0}))
        print(f"\n  scanned {len(card_copy)} bytes of the four card bodies for "
              f"house-rule violations (offending rendered pages, pre-existing "
              f"chrome included: {offenders})")
        check(em_dash not in card_copy, "no em dash in any of the four card bodies")
        check("recording" not in card_copy.lower(),
              "no 'recording' in customer copy")

        return 1 if FAILURES else 0
    finally:
        if saved_env is None:
            os.environ.pop("OSTLER_INTEREST_PROFILE", None)
        else:
            os.environ["OSTLER_INTEREST_PROFILE"] = saved_env
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    rc = main()
    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} assertion(s)")
        for f in FAILURES:
            print(f"  - {f}")
    else:
        print("OK: an empty Interests page now says which empty it is.")
    raise SystemExit(rc)
