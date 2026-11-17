#!/usr/bin/env python3
"""Judge for probes/included_pro_window_matches_plan.sh (stdlib only).

Reads the KEY=VALUE capture the box printed (never the licence: only whether
~/.ostler/license/license.json exists, and the non-secret fields of
~/.ostler/state/subscription_state.json) and the walker's expectation:

  founding  the box was installed with a signed plan=founding licence:
            status active, source first_month_free, included_plan founding,
            included_days 180, and expires_at - included_from = 180 days (+-1).

A box cannot be INSTALLED without a licence (install.sh refuses,
ERR-02-LICENCE-REQUIRED; scripts/ttywalk.sh LICENCE PREFLIGHT), so "no licence
gets 0 days" is proven by the second arm instead: the INSTALLED gate
(~/.ostler/services/ical-server/subscription_gate.py) is called the way
install.sh calls it with nothing verified (tier_state unverified, no plan),
writing to a temporary state file only (OSTLER_SUBSCRIPTION_STATE). Lines
prefixed NOLIC_. PASS: no state, or a state that is not active.

Exit / verdict: 0 PASS, 1 FAIL, 78 CANNOT-RUN. One reason line on stdout.
A capture the judge cannot read is CANNOT-RUN, never PASS.
"""
import sys
from datetime import datetime

WANT_DAYS = {"founding": 180, "ff": 180, "standard": 90}
TOL_DAYS = 1.0


def parse(text):
    out = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out.setdefault(k.strip(), v.strip())
    return out


def _iso(v):
    if not v:
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None


def judge(cap, expect):
    """Return (rc, reason)."""
    if expect not in ("founding", "ff", "standard", "none"):
        return 78, "OSTLER_INCPRO_EXPECT must be founding, ff or standard (got %r)" % expect
    lic = cap.get("LICENCE")
    state = cap.get("STATE")
    if lic not in ("present", "absent") or state not in ("absent", "ok", "unreadable", "unparseable"):
        return 78, "the box returned no LICENCE/STATE lines (transport or shell failure)"
    if state in ("unreadable", "unparseable"):
        return 78, "subscription_state.json exists but could not be read (%s)" % state
    if expect == "none":
        if lic != "absent":
            return 78, "a licence file is present on the box; the no-licence arm needs a box installed without one"
        if state == "absent":
            return 0, "no licence, no subscription state: 0 included days, as intended"
        if cap.get("status") != "active":
            return 0, "no licence, state status=%s: 0 included days, as intended" % cap.get("status")
        start, end = _iso(cap.get("included_from")), _iso(cap.get("expires_at"))
        days = round((end - start).total_seconds() / 86400, 2) if (start and end) else "unknown"
        return 1, "no licence, but an ACTIVE included window was written (status active, source=%s, days=%s); 0 expected" % (cap.get("source"), days)
    # A plan was expected.
    if lic != "present":
        return 78, "no licence file on the box (~/.ostler/license/license.json); stage the signed %s test licence before the install" % expect
    if state == "absent":
        return 1, "a %s licence is installed but no subscription state was written: 0 included days (the v1.0.133 absent-tier shape)" % expect
    if cap.get("status") != "active":
        return 1, "a %s licence is installed but the state status is %s (source=%s): 0 included days" % (expect, cap.get("status"), cap.get("source"))
    if cap.get("source") != "first_month_free":
        return 78, "the state was written by source=%s, not the included-Pro grant; this box cannot show the install grant" % cap.get("source")
    start, end = _iso(cap.get("included_from")), _iso(cap.get("expires_at"))
    if not (start and end):
        return 78, "included_from or expires_at missing or unparseable; the window cannot be measured"
    days = (end - start).total_seconds() / 86400
    want = WANT_DAYS[expect]
    problems = []
    if cap.get("included_plan") != expect:
        problems.append("included_plan=%s (want %s)" % (cap.get("included_plan"), expect))
    if cap.get("included_days") not in (str(want), "%s.0" % want):
        problems.append("included_days=%s (want %s)" % (cap.get("included_days"), want))
    if cap.get("included_provisional") in ("True", "true", "1"):
        problems.append("included_provisional=true (the plan was not read from the licence)")
    if abs(days - want) > TOL_DAYS:
        problems.append("window %.2f days (want %s)" % (days, want))
    if problems:
        return 1, "%s licence installed, but: %s" % (expect, "; ".join(problems))
    return 0, "%s licence installed: status active, plan %s, window %.2f days (want %s)" % (expect, expect, days, want)


def judge_nolic(cap):
    """The no-licence arm (installed gate, temporary state). (rc, reason)."""
    if cap.get("NOLIC_GATE") != "present":
        return 78, "no-licence arm: the installed subscription_gate.py was not found (%s)" % (cap.get("NOLIC_GATE") or "no NOLIC_GATE line")
    if cap.get("NOLIC_RC") != "0":
        return 78, "no-licence arm: the installed gate raised (rc %s)" % cap.get("NOLIC_RC")
    st = cap.get("NOLIC_STATE")
    if st == "absent":
        return 0, "no-licence arm: nothing written, 0 days"
    if st != "ok":
        return 78, "no-licence arm: the temporary state could not be read (%s)" % st
    if cap.get("NOLIC_status") != "active":
        return 0, "no-licence arm: state status=%s, 0 days" % cap.get("NOLIC_status")
    return 1, "no-licence arm: the installed gate granted an ACTIVE window with nothing verified (source=%s, plan=%s); 0 expected" % (cap.get("NOLIC_source"), cap.get("NOLIC_included_plan"))


def judge_both(cap, expect):
    a_rc, a_why = judge(cap, expect)
    b_rc, b_why = judge_nolic(cap)
    why = "%s | %s" % (a_why, b_why)
    if 1 in (a_rc, b_rc):
        return 1, why
    if a_rc == 0 and b_rc == 0:
        return 0, why
    return 78, why


GOOD = ("LICENCE=present\nSTATE=ok\nstatus=active\nsource=first_month_free\nincluded_plan=founding\n"
        "included_days=180\nincluded_provisional=False\nincluded_from=2026-11-18T00:00:00Z\n"
        "expires_at=2027-05-17T00:00:00Z\n")
CASES = [
    ("founding, 180-day window", GOOD, "founding", 0),
    ("founding, no state written (133 absent-tier shape)", "LICENCE=present\nSTATE=absent\n", "founding", 1),
    ("founding, state inactive", "LICENCE=present\nSTATE=ok\nstatus=inactive\nsource=default\n", "founding", 1),
    ("founding, provisional 90-day standard window", GOOD.replace("included_plan=founding", "included_plan=standard").replace("included_days=180", "included_days=90").replace("included_provisional=False", "included_provisional=True").replace("2027-05-17", "2027-02-16"), "founding", 1),
    ("founding, legacy 30-day window", GOOD.replace("2027-05-17", "2026-12-18"), "founding", 1),
    ("founding, licence not staged", "LICENCE=absent\nSTATE=absent\n", "founding", 78),
    ("founding, receipt-written state", GOOD.replace("source=first_month_free", "source=companion"), "founding", 78),
    ("founding, dates missing", GOOD.replace("included_from=2026-11-18T00:00:00Z\n", ""), "founding", 78),
    ("none, no state", "LICENCE=absent\nSTATE=absent\n", "none", 0),
    ("none, inactive state", "LICENCE=absent\nSTATE=ok\nstatus=inactive\nsource=default\n", "none", 0),
    ("none, an active window anyway", GOOD.replace("LICENCE=present", "LICENCE=absent"), "none", 1),
    ("none, licence present", "LICENCE=present\nSTATE=absent\n", "none", 78),
    ("empty capture", "", "founding", 78),
    ("unreadable state", "LICENCE=present\nSTATE=unreadable\n", "founding", 78),
    ("bad expectation", GOOD, "gold", 78),
]


NOLIC_OK = "NOLIC_GATE=present\nNOLIC_RC=0\nNOLIC_STATE=absent\n"
NOLIC_CASES = [
    ("no-licence: nothing written", NOLIC_OK, 0),
    ("no-licence: inactive state", "NOLIC_GATE=present\nNOLIC_RC=0\nNOLIC_STATE=ok\nNOLIC_status=inactive\n", 0),
    ("no-licence: an active window", "NOLIC_GATE=present\nNOLIC_RC=0\nNOLIC_STATE=ok\nNOLIC_status=active\nNOLIC_source=first_month_free\n", 1),
    ("no-licence: gate missing", "NOLIC_GATE=absent\n", 78),
    ("no-licence: gate raised", "NOLIC_GATE=present\nNOLIC_RC=1\n", 78),
    ("no-licence: no lines", "", 78),
]
BOTH_CASES = [
    ("both arms hold", GOOD + NOLIC_OK, "founding", 0),
    ("founding holds, no-licence grants", GOOD + "NOLIC_GATE=present\nNOLIC_RC=0\nNOLIC_STATE=ok\nNOLIC_status=active\n", "founding", 1),
    ("founding 0 days, no-licence holds", "LICENCE=present\nSTATE=absent\n" + NOLIC_OK, "founding", 1),
    ("founding holds, no-licence unmeasured", GOOD, "founding", 78),
    ("expectation unset", GOOD + NOLIC_OK, "", 78),
]


def self_test():
    bad = 0
    for name, text, want in NOLIC_CASES:
        rc, why = judge_nolic(parse(text))
        ok = rc == want
        bad += 0 if ok else 1
        print("  %s %-52s want=%s got=%s" % ("held  " if ok else "FAILED", name, want, rc))
    for name, text, exp, want in BOTH_CASES:
        rc, why = judge_both(parse(text), exp)
        ok = rc == want
        bad += 0 if ok else 1
        print("  %s %-52s want=%s got=%s" % ("held  " if ok else "FAILED", name, want, rc))
    for name, text, exp, want in CASES:
        rc, why = judge(parse(text), exp)
        ok = rc == want
        bad += 0 if ok else 1
        print("  %s %-52s want=%s got=%s" % ("held  " if ok else "FAILED", name, want, rc))
    total = len(CASES) + len(NOLIC_CASES) + len(BOTH_CASES)
    print("included_pro judge: %d of %d cases held" % (total - bad, total))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--self-test"]:
        sys.exit(self_test())
    if len(sys.argv) != 3:
        print("usage: included_pro.py <capture-file> <founding|ff|standard> | --self-test")
        sys.exit(78)
    with open(sys.argv[1]) as fh:
        rc, why = judge_both(parse(fh.read()), sys.argv[2])
    print(why)
    sys.exit(rc)
