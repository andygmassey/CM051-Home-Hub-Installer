#!/usr/bin/env python3
"""Judge for probes/included_pro_window_matches_plan.sh (stdlib only).

Reads the KEY=VALUE capture the box printed (never the licence: only whether
~/.ostler/license/license.json exists, and the non-secret fields of
~/.ostler/state/subscription_state.json) and the walker's expectation:

  founding  the box was installed with a signed plan=founding licence:
            status active, source first_month_free, included_plan founding,
            included_days 180, and expires_at - included_from = 180 days (+-1).
  none      the box was installed with NO licence: no state file, or a state
            whose status is not active. Any active window is FAIL (0 expected).

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
        return 78, "OSTLER_INCPRO_EXPECT must be founding, ff, standard or none (got %r)" % expect
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


def self_test():
    bad = 0
    for name, text, exp, want in CASES:
        rc, why = judge(parse(text), exp)
        ok = rc == want
        bad += 0 if ok else 1
        print("  %s %-52s want=%s got=%s" % ("held  " if ok else "FAILED", name, want, rc))
    print("included_pro judge: %d of %d cases held" % (len(CASES) - bad, len(CASES)))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--self-test"]:
        sys.exit(self_test())
    if len(sys.argv) != 3:
        print("usage: included_pro.py <capture-file> <founding|ff|standard|none> | --self-test")
        sys.exit(78)
    with open(sys.argv[1]) as fh:
        rc, why = judge(parse(fh.read()), sys.argv[2])
    print(why)
    sys.exit(rc)
