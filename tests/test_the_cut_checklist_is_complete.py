#!/usr/bin/env python3
"""The one pre-cut checklist must stay complete, and must be EMPTY of ungated
rows before a cut.

WHY THIS EXISTS. Andy, 2026-09-05, on being shown the first honest count of
remaining work: "maintain this discipline. Do NOT let it slip."

A discipline that lives in an agent's memory is exactly the thing that has been
slipping. `cut-manifests/v1.0.72.yaml` registers every open issue and marks the
ones with no proof written as `gate: NONE YET`. Two ways that decays:

  1. A NEW issue is opened and nobody adds it, so the register silently stops
     being the register. The checklist still looks complete because you cannot
     see what is not in it.
  2. A cut happens while `NONE YET` rows remain, which is the whole failure
     this file exists to prevent: shipping with untracked known defects.

So this gate asserts both, and the second is the one that blocks a cut.

THREE STATES. 0 pass, 1 fail, 2 cannot-run. A cannot-run is NOT a pass: if the
open-issue list cannot be read, this says so and refuses rather than reporting
a clean register it never saw.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_DIR = REPO / "cut-manifests"

# The label `red-main-opens-an-issue.yml` applies to the issues it files.
ALARM_LABEL = "main-red"
# Sentinel: set when EVERY open issue carries the alarm label, which is a
# label being misused rather than a repository with no work in it.
CANNOT_RUN_ALL_ALARMS = [0]
SLUG = "andygmassey/CM051-Home-Hub-Installer"

PASS = 0
FAIL = 0
CANNOT_RUN = 0


def ok(m: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {m}")


def bad(m: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {m}")


def cannot_run(m: str) -> int:
    print(f"CANNOT-RUN: {m}", file=sys.stderr)
    return 2


class _ScopeRefused(Exception):
    """The title scope found nothing, which is a refusal and not an answer."""


def _is_ungated(r) -> bool:
    """True when a row carries no proof.

    Module level ON PURPOSE, so the control suite in
    tests/test_a_ci_alarm_is_not_a_register_gap.py can import and test it.
    While it was nested inside main() nothing could reach it, which is part of
    why it went eight months without anyone noticing it matched nothing.
    """
    return "NONE YET" in " ".join(str(r.get("gate", "")).upper().split())


def newest_manifest() -> pathlib.Path | None:
    """The highest-versioned per-cut manifest. `permanent.yaml` is excluded:
    it is the never-regress backstop, not the working checklist."""
    best = None
    best_key = ()
    for p in MANIFEST_DIR.glob("v*.yaml"):
        m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", p.stem)
        if not m:
            continue
        key = tuple(int(x) for x in m.groups())
        if key > best_key:
            best_key, best = key, p
    return best


def main() -> int:
    if not MANIFEST_DIR.is_dir():
        return cannot_run(f"no {MANIFEST_DIR}")
    manifest = newest_manifest()
    if manifest is None:
        return cannot_run("no per-cut manifest (cut-manifests/vX.Y.Z.yaml) exists at all")

    try:
        doc = yaml.safe_load(manifest.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return cannot_run(f"{manifest.name} does not parse as YAML: {exc}")
    if not isinstance(doc, dict):
        # A truncated or empty manifest loads as None or a scalar. Reaching
        # `.get` on that raises AttributeError and exits 1, which reads as a
        # FAILED ASSERTION about a checklist nobody ever looked at. An
        # unreadable manifest is CANNOT-RUN. Found by driving this gate's own
        # red paths rather than by trusting that it compiled.
        return cannot_run(
            f"{manifest.name} did not load as a mapping (got {type(doc).__name__}). "
            "The checklist could not be read, so nothing about it was verified."
        )
    rows = doc.get("open_issues")
    if rows is None:
        return cannot_run(
            f"{manifest.name} has no `open_issues:` key. That key IS the register; "
            "without it this gate would pass by measuring nothing."
        )

    registered = {int(r["issue"]) for r in rows if "issue" in r}

    # ── EVERY ROW MUST NAME THE REPO ITS NUMBER BELONGS TO ─────────────────
    #
    # This gate used to resolve a bare number against ONE hardcoded repo. It
    # could not do otherwise: the rows carried `issue`, `title` and `gate` and
    # nothing that said where the number came from. GitHub numbers issues and
    # pull requests from ONE counter per repo, and CM051 and HR015 both have
    # four-digit numbers, so a bare integer is genuinely ambiguous and a lookup
    # against the wrong repo answers confidently and wrongly.
    #
    # MEASURED 2026-09-16: 41 rows of the v1.0.99 checklist had been struck on
    # the reason "the issue this row names is CLOSED on GitHub". TEN named
    # HR015 issues that were OPEN and tagged [LAUNCH]; the other 31 named CM051
    # PULL REQUESTS. Not one named a closed issue. The three-bucket
    # classification below was added then, and it stops the gate ADVISING a
    # wrong strike -- but it still could not see the ten HR015 rows at all,
    # because the lookup never asked HR015.
    #
    # So the row now carries the answer and the gate stops inferring it:
    #
    #     repo: CM051    the number is an issue in CM051
    #     repo: HR015    the number is an issue in HR015
    #     repo: none     no issue of this number exists in either repo; the row
    #                    is a measured finding, not a pointer to a tracker item
    #
    # A MISSING FIELD IS CANNOT-RUN, NOT A DEFAULT. Defaulting to CM051 would
    # reproduce the original defect for every row added after this change, and
    # it would do it silently, which is how the first 41 happened.
    no_repo = sorted(int(r["issue"]) for r in rows
                     if "issue" in r and not str(r.get("repo", "")).strip())
    if no_repo:
        return cannot_run(
            f"{len(no_repo)} row(s) carry no `repo:` field: "
            f"{no_repo[:12]}{' ...' if len(no_repo) > 12 else ''}. A bare issue "
            "number is ambiguous because GitHub numbers issues and PRs from one "
            "counter per repo and both repos reach four digits. Resolving it "
            "against a guessed repo is what struck 41 rows wrongly. Add "
            "`repo: CM051`, `repo: HR015` or `repo: none` to each."
        )

    # ── THE TWO REPOS ARE NOT SCOPED THE SAME WAY, AND THAT IS DELIBERATE ──
    #
    # CM051 is the product repo: every open issue in it is cut-relevant, so the
    # register must cover all of them.
    #
    # HR015 is the source repo AND Andy's personal-infrastructure backlog. Its
    # open issues are a mixture of launch work and items explicitly marked
    # [BACKLOG], [INVESTOR] or [HARDWARE]. Measured 2026-09-16: 21 open HR015
    # issues were unregistered, and reading all 21 showed the launch-relevant
    # ones are exactly those whose TITLE begins `[LAUNCH]`. Demanding the whole
    # backlog be registered would hold a cut hostage to a wearable-ecosystem
    # ticket, and a gate that is red for reasons nobody can act on is a gate
    # that gets bypassed.
    #
    # SCOPING BY TITLE IS FRAGILE AND THIS FILE SAYS SO ELSEWHERE: a title
    # regex breaks the moment the wording changes, and it FAILS OPEN, which is
    # the wrong direction for the register that gates a cut. HR015 carries no
    # labels at all (measured: 0 labels on all 10 registered rows and on a
    # sample of 6 unregistered ones), so there is no label to key on instead.
    #
    # So the fragility is answered by making it FAIL CLOSED: if the title scan
    # finds ZERO [LAUNCH] issues, that is treated as the scan being broken, not
    # as a clean sheet, and the gate REFUSES. A prefix that stopped matching
    # cannot therefore read as "nothing to do".
    KNOWN_REPOS = {
        "CM051": "andygmassey/CM051-Home-Hub-Installer",
        "HR015": "andygmassey/HR015-Gaming-PC",
    }
    LAUNCH_PREFIX = "[LAUNCH]"
    SCOPED_BY_TITLE = {"HR015"}
    by_repo: dict[str, set[int]] = {k: set() for k in KNOWN_REPOS}
    no_issue_rows: set[int] = set()
    unknown_repo: list[tuple[int, str]] = []
    for r in rows:
        if "issue" not in r:
            continue
        n, key = int(r["issue"]), str(r.get("repo", "")).strip()
        if key in KNOWN_REPOS:
            by_repo[key].add(n)
        elif key == "none":
            no_issue_rows.add(n)
        else:
            unknown_repo.append((n, key))
    if unknown_repo:
        return cannot_run(
            f"{len(unknown_repo)} row(s) name a repo this gate does not know: "
            f"{unknown_repo[:8]}. Known: {sorted(KNOWN_REPOS)} plus `none`. "
            "Refusing rather than checking them against the wrong register."
        )

    # ── WHY THIS IS A SUBSTRING TEST AND NOT startswith ────────────────────
    # It was `startswith("NONE")` until 2026-09-16. Every row in every manifest
    # writes its status as `gate: 'GATE: NONE YET. ...'`, which does not start
    # with NONE, so this check matched NOTHING. Measured on v1.0.99 the day it
    # was found: 112 rows said NONE YET and this list held 0 of them. PROPERTY 2
    # is the one that BLOCKS A CUT, so for as long as that was true the cut
    # could be tagged with every row unproven and this gate would print a PASS
    # saying every registered issue was gated. It is the exact shape it exists
    # to catch: a gate that cannot fail reads identically to a clean sheet.
    ungated = [r for r in rows if _is_ungated(r)]
    print(f"== checklist: {manifest.name} ==")
    print(f"  registered issues : {len(registered)}")
    for k in sorted(KNOWN_REPOS):
        print(f"    repo {k:5}      : {len(by_repo[k])}")
    print(f"    repo none       : {len(no_issue_rows)}  (measured findings, not tracker items)")
    print(f"  rows with a gate  : {len(rows) - len(ungated)}")
    print(f"  NONE YET          : {len(ungated)}")
    print()

    # ── PROPERTY 1: the register must cover every OPEN issue, IN EVERY REPO ─
    # Absence of `gh`, or an unauthenticated runner, is a CANNOT-RUN and not a
    # pass: a register checked against nothing is not a checked register. Each
    # repo is measured separately and a failure in one does not stand in for
    # the other, because "we could not read HR015" must never read as "HR015
    # has nothing open".
    global CANNOT_RUN
    for key, slug in sorted(KNOWN_REPOS.items()):
        # ── A REPO NO ROW CLAIMS IS NOT A REPO TO CROSS-CHECK ───────────────
        # The completeness question is "does the register cover this repo's
        # open work". A repo that no row in this manifest names has nothing to
        # compare against, and querying it would turn every one of its open
        # issues into a missing registration. Say so out loud and move on,
        # rather than either failing or silently skipping.
        if not by_repo[key]:
            print(f"  [note] {key}: no row in {manifest.name} declares this repo, so there is "
                  f"nothing here to cross-check against it. Not measured, and not claimed as "
                  f"clean.")
            continue
        live = None
        alarms: set[int] = set()
        try:
            out = subprocess.run(
                ["gh", "issue", "list", "--repo", slug, "--state", "open",
                 "--limit", "500", "--json", "number,labels,title"],
                capture_output=True, text=True, timeout=90,
            )
            if out.returncode == 0 and out.stdout.strip():
                raw = json.loads(out.stdout)
                # ── THE ALARM IS NOT A WORK ITEM, AND INCLUDING IT LIVELOCKED THIS ──
                # `red-main-opens-an-issue.yml` files an issue labelled
                # `main-red` whenever a gate fails on main, and it closes itself
                # when that gate next SUCCEEDS on main. This gate is one of the
                # gates it watches, so on 2026-09-06 the estate reached a closed
                # loop: gate red -> watchdog opens #1713 -> #1713 open and
                # unregistered -> gate red. Main could not return to green by
                # any amount of correct work.
                #
                # The exclusion is deliberately narrow: the LABEL the watchdog
                # applies, not its author and not a title regex. Both of those
                # fail OPEN, which is the wrong direction for a cut register.
                # It is never silent: the excluded numbers are printed.
                alarms = {int(o["number"]) for o in raw
                          if any(l.get("name") == ALARM_LABEL for l in o.get("labels", []))}
                live = {int(o["number"]) for o in raw} - alarms
                if key in SCOPED_BY_TITLE:
                    # ── A MISSING FIELD IS NOT A MISSING MATCH ─────────────
                    # Scoping by title needs titles. If NOT ONE returned issue
                    # carries a `title` at all, the scope has no data to work
                    # on, and reporting that as "the prefix stopped matching"
                    # would blame the wording for what is actually an absent
                    # field. Two different causes, two different sentences,
                    # and only one of them means someone renamed an issue.
                    titled = [o for o in raw if str(o.get("title", "")).strip()]
                    if not titled:
                        CANNOT_RUN += 1
                        print(f"  [CANNOT-RUN] {key}: {len(raw)} open issue(s) came back and NOT "
                              f"ONE carries a title,")
                        print(f"               so this repo cannot be scoped by "
                              f"`{LAUNCH_PREFIX}` at all. That is an")
                        print("               absent FIELD, not an absent match. Registration "
                              "completeness here")
                        print("               is UNMEASURED, which is not a pass.")
                        raise _ScopeRefused()
                    launch = {int(o["number"]) for o in raw
                              if str(o.get("title", "")).lstrip().upper()
                                 .startswith(LAUNCH_PREFIX)} - alarms
                    if not launch:
                        # ── WHEN ZERO IS A REFUSAL AND WHEN IT IS AN ANSWER ──
                        # My first version refused on any zero here. That is
                        # wrong in one direction that matters: once the launch
                        # work is genuinely finished, zero [LAUNCH] issues is
                        # the CORRECT answer, and a gate that refuses forever
                        # at the finish line is a gate someone switches off.
                        #
                        # The refusal exists to catch a prefix that STOPPED
                        # MATCHING. The evidence for that is not "zero found",
                        # it is "zero found WHILE rows of this manifest still
                        # claim issues in this repo". That combination cannot
                        # both be true: the rows name issues the scope says do
                        # not exist.
                        #
                        # So refuse only on the contradiction, and let a clean
                        # zero through when no row contradicts it. We only
                        # reach here when by_repo[key] is non-empty, which is
                        # exactly the contradiction.
                        CANNOT_RUN += 1
                        print(f"  [CANNOT-RUN] {key}: {len(live)} open issue(s) and NOT ONE "
                              f"title begins `{LAUNCH_PREFIX}`,")
                        print(f"               yet {len(by_repo[key])} row(s) of {manifest.name} "
                              f"declare `repo: {key}`.")
                        print("               Those cannot both be true, so the prefix has "
                              "stopped matching rather")
                        print("               than the launch list being empty. Refusing to pass.")
                        live = None
                        raise _ScopeRefused()
                    deferred = len(live) - len(launch)
                    live = launch
                    print(f"  [note] {key}: scoped to the {len(live)} open issue(s) whose title "
                          f"begins `{LAUNCH_PREFIX}`.")
                    print(f"         {deferred} other open issue(s) are NOT checked for "
                          f"registration here. They are not launch work by their own title, "
                          f"and this line exists so that exemption cannot be silent.")
                if alarms:
                    print(f"  [note] {key}: {len(alarms)} open issue(s) excluded as CI "
                          f"alarms (label `{ALARM_LABEL}`): {sorted(alarms)}")
                if raw and not live:
                    CANNOT_RUN_ALL_ALARMS[0] = len(alarms)
        except _ScopeRefused:
            # Already counted and explained above. Do not double-count it as an
            # unreadable list, which would report the same refusal twice under
            # two different reasons.
            continue
        except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError, ValueError):
            live = None

        if live is None:
            CANNOT_RUN += 1
            print(f"  [CANNOT-RUN] {key}: the open-issue list could not be read (no gh,")
            print("               no auth, or the call failed). Registration completeness")
            print("               is UNMEASURED for this repo. This is not a pass.")
            print(f"                 gh issue list --repo {slug} --state open --json number")
            continue
        if not live:
            CANNOT_RUN += 1
            if CANNOT_RUN_ALL_ALARMS[0]:
                print(f"  [CANNOT-RUN] {key}: all {CANNOT_RUN_ALL_ALARMS[0]} open issue(s)")
                print(f"               carry the `{ALARM_LABEL}` label. That is the label")
                print("               being used for something it does not mean.")
            else:
                print(f"  [CANNOT-RUN] {key}: the open-issue list came back EMPTY. A repo")
                print("               with genuinely zero open issues and a broken query")
                print("               print identically, so this refuses rather than passing.")
            continue

        mine = by_repo[key]
        missing = sorted(live - mine)
        if missing:
            bad(f"{key}: {len(missing)} OPEN issue(s) are not in the checklist: "
                f"{missing}. The register has stopped being the register.")
        else:
            ok(f"{key}: every one of the {len(live)} open issues is registered in "
               f"{manifest.name}")

        # ── "NOT OPEN HERE" IS STILL NOT "CLOSED" ──────────────────────────
        # Even scoped to the right repo, a row that is not in the open list may
        # be closed, may be a PULL REQUEST (`gh issue list` never returns PRs),
        # or may be a number that no longer exists. Only the first is a strike
        # candidate, and the difference is one extra call, not one per row.
        stale = sorted(mine - live)
        if not stale:
            continue
        closed_here = None
        try:
            cout = subprocess.run(
                ["gh", "issue", "list", "--repo", slug, "--state", "closed",
                 "--limit", "1000", "--json", "number"],
                capture_output=True, text=True, timeout=90,
            )
            if cout.returncode == 0 and cout.stdout.strip():
                closed_here = {int(o["number"]) for o in json.loads(cout.stdout)}
        except Exception:
            closed_here = None

        if closed_here is None:
            print(f"  [note] {key}: {len(stale)} row(s) are not OPEN issues here, and the "
                  f"CLOSED list could not be read, so NONE is confirmed closed and none "
                  f"should be struck on this signal: "
                  f"{stale[:12]}{' ...' if len(stale) > 12 else ''}")
            continue
        really_closed = [n for n in stale if n in closed_here]
        not_an_issue = [n for n in stale if n not in closed_here]
        if really_closed:
            print(f"  [note] {key}: {len(really_closed)} registered issue(s) are CLOSED "
                  f"and can be struck: "
                  f"{really_closed[:12]}{' ...' if len(really_closed) > 12 else ''}")
        if not_an_issue:
            print(f"  [note] {key}: {len(not_an_issue)} row(s) declare `repo: {key}` but are "
                  f"NOT AN ISSUE THERE AT ALL, neither open nor closed. The declaration is "
                  f"wrong, or the number is a PULL REQUEST. DO NOT STRIKE: fix the `repo:` "
                  f"field: {not_an_issue[:12]}{' ...' if len(not_an_issue) > 12 else ''}")

    if no_issue_rows:
        print(f"  [note] {len(no_issue_rows)} row(s) declare `repo: none` and are exempt from "
              f"the registration check by declaration. They are measured findings, not "
              f"tracker items. They are NOT exempt from PROPERTY 2 below.")

    # ── PROPERTY 2: no ungated rows may survive to a cut ────────────────────
    # This is the one that blocks. It is deliberately advisory OUTSIDE a cut
    # (there is always work in progress) and blocking when a cut is being made,
    # signalled by OSTLER_CUT_IN_PROGRESS=1 from the cut workflow.
    cutting = os.environ.get("OSTLER_CUT_IN_PROGRESS") == "1"
    if ungated:
        ids = [r.get("issue") for r in ungated]
        msg = (f"{len(ungated)} row(s) still carry `gate: NONE YET` -- no proof has "
               f"been written for them: {ids[:14]}{' ...' if len(ids) > 14 else ''}")
        if cutting:
            bad("CUT IS BLOCKED. " + msg + ". Each needs either a proof authored "
                "or a written DEFER decision in its row.")
        else:
            print(f"  [note] {msg}")
            print("         Not a failure outside a cut. With OSTLER_CUT_IN_PROGRESS=1 "
                  "this is a FAIL and the cut stops.")
    else:
        ok("no `NONE YET` rows remain: every registered issue is either gated or "
           "carries a written decision")

    # ── PROPERTY 3: a row that SAYS BLOCKING must actually block ───────────
    # Andy's call, 2026-09-06, and it closes a gap he found by reading a
    # summary rather than a gate: NINE rows carried the word BLOCKING in their
    # `gate:` and NOTHING in this repo read it. Every gate script was grepped;
    # the only code matching the word was a CI conclusion set and a walk-probe
    # advisory, neither related. So a tag would have shipped straight past nine
    # self-declared blockers without one objection, including #1625 (the
    # customer's curl|bash URL, measured 404 that morning) and #1540 (a BIP39
    # recovery phrase generated, the DEK encrypted under it, and never shown to
    # the customer, which is unrecoverable BECAUSE the design is correct).
    #
    # A directive nobody enforces is a reminder, and the next reader widens it.
    # This makes the word load-bearing.
    #
    # SCOPED TO A CUT, like PROPERTY 2 and for the same reason: there is always
    # blocking work in flight, and reddening every PR would stop the work that
    # clears these rows. Outside a cut it prints every offending row BY NUMBER
    # -- never a bare count, which reads as "nothing to report".
    #
    # A row whose issue has CLOSED does not block. That is drift in the
    # register, reported separately above, not an outstanding blocker.
    def _says_blocking(g: str) -> bool:
        # THE DISPOSITION IS THE TEXT BEFORE THE FIRST COLON, AND ONLY THAT.
        #
        # This first scanned the WHOLE gate string for "BLOCKING", excluding the
        # literal "NOT BLOCKING". It caught its own tail within the hour: I
        # registered #1685 with a DEFER whose REASONING said "NOT gated BLOCKING
        # on purpose, and #1680 makes that word cost something". That is prose
        # explaining a deferral, and the gate read it as a self-declared
        # blocker. A register CITES its own findings, so the words a gate hunts
        # for arrive inside the rows it reads -- the control ends up in its own
        # subject.
        #
        # Rows are written as "<DISPOSITION>: <reasoning>", e.g.
        #   "FIX (BLOCKING): ..."   "FIX (apparatus, counted per Andy): ..."
        #   "DEFER: ..."            "NOT BLOCKING (reporting accuracy): ..."
        # so the disposition is the head, and the reasoning cannot reach it.
        # A row with no colon at all is treated as all-disposition, which is
        # the conservative direction: it can only ever over-report.
        head = g.split(":", 1)[0].upper()
        return "BLOCKING" in head and "NOT BLOCKING" not in head

    blocking_rows = [r for r in rows if _says_blocking(str(r.get("gate", "")))]
    if live is None or not live:
        # Already counted as CANNOT-RUN above. Say explicitly that THIS property
        # was not evaluated, rather than letting silence read as a pass.
        print(f"  [CANNOT-RUN] {len(blocking_rows)} row(s) say BLOCKING, but the open-issue")
        print("               list could not be read, so whether they are still open is")
        print("               UNMEASURED. Not a pass.")
    else:
        live_blocking = [r for r in blocking_rows if int(r["issue"]) in live]
        stale_blocking = len(blocking_rows) - len(live_blocking)
        if live_blocking:
            listing = "; ".join(
                f'#{r["issue"]} {str(r.get("title", ""))[:60]}' for r in live_blocking)
            msg = (f"{len(live_blocking)} row(s) are gated BLOCKING and their issue is "
                   f"still OPEN: {listing}")
            if cutting:
                bad("CUT IS BLOCKED. " + msg +
                    ". Fix them, or re-gate each row to what it truly is. "
                    "The word BLOCKING is now load-bearing and this is the gate "
                    "that reads it.")
            else:
                print(f"  [note] {msg}")
                print("         Not a failure outside a cut. With OSTLER_CUT_IN_PROGRESS=1 "
                      "this is a FAIL and the cut stops.")
            if stale_blocking:
                print(f"         ({stale_blocking} further BLOCKING row(s) name a CLOSED "
                      "issue and are drift, not blockers.)")
        else:
            ok(f"no row gated BLOCKING names a still-open issue "
               f"({len(blocking_rows)} BLOCKING row(s) examined, all closed or none present)")

    print()
    print(f"== {PASS} pass / {FAIL} fail / {CANNOT_RUN} cannot-run / "
          f"{PASS + FAIL} adjudicated ==")
    if FAIL:
        return 1
    if CANNOT_RUN:
        # AND A CUT MUST NOT PROCEED ON AN UNREADABLE REGISTER. TNM's judgement
        # call and I agree with the reasoning: a cut that cannot confirm the
        # checklist is complete is a cut shipping an unknown, which is what
        # OSTLER_CUT_IN_PROGRESS exists to stop. 2 rather than 1 so it stays
        # distinguishable from a real registration failure.
        print(f"  REFUSING: {CANNOT_RUN} check(s) could not run. That is not a pass.")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
