"""walk 34 (v1.0.113): the preference store held 1 raw row that the interest
compiler correctly screens out below its 0.28 floor (interest_profile.json:
raw_rows 1, interests 0, suppressed 1). The digest's empty Preferences section
was CORRECT and two arms failed on the raw count. The probe must count what
clears the floor. Synthetic only."""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_p = os.path.join(HERE, "..", "scripts", "box_walk_probes", "lib", "owner_digest.py")
_s = importlib.util.spec_from_file_location("owner_digest_under_test", _p)
od = importlib.util.module_from_spec(_s)
_s.loader.exec_module(od)

A0, A1 = od.DECLARED[0], od.DECLARED[1]


def rows(f):
    return {n: ok for n, ok, _ in od.judge(f)}


def facts(interests, raw, seed_state="unrun", empty_pref=True, nothing_stored=True):
    f = od._good()
    f["stores"]["preferences"] = interests
    f["stores"]["preferences_raw"] = raw
    f["pref_seed_state"] = seed_state
    if empty_pref:
        f["digest"]["preferences_lines"] = 0
    if nothing_stored:
        f["digest"]["nothing_stored"].append(od.PREFERENCES)
    return f


fails = []


def check(label, got, want):
    if got != want:
        fails.append("%s: got %r want %r" % (label, got, want))
    else:
        print("ok  " + label)


# 1. the walk-34 shape: raw 1 / interests 0 / suppressed 1, seed did not run.
r = rows(facts(interests=0, raw=1))
check("raw 1 / interests 0: 'nothing stored while store holds data' does not FAIL", r[A1], True)
check("raw 1 / interests 0, seed absent: preferences-non-empty arm is NOT MEASURED", r[A0], None)

# 2. the real defect: 2 preferences clear the floor, digest section empty.
r = rows(facts(interests=2, raw=2))
check("interests 2 + empty digest section: 'nothing stored' arm FAILS", r[A1], False)
check("interests 2 + empty digest section: preferences-non-empty arm FAILS", r[A0], False)

# 3. seed ran, so interests >= 1 was expected: a real check, empty digest FAILS.
r = rows(facts(interests=0, raw=1, seed_state="seeded"))
check("seed ran, interests 0, empty section: arm FAILS", r[A0], False)

# 4. unreadable profile is CANNOT-RUN, never a pass.
r = rows(facts(interests=None, raw=1))
check("profile unreadable: preferences arm NOT MEASURED", r[A0], None)
check("profile unreadable: nothing-stored arm NOT MEASURED", r[A1], None)

# 5. box half reads interests from interest_profile.json, not Qdrant rows.
with tempfile.TemporaryDirectory() as d:
    os.makedirs(os.path.join(d, "preferences"))
    with open(os.path.join(d, "preferences", "interest_profile.json"), "w") as fh:
        json.dump({"stats": {"raw_rows": 1, "interests": 0, "suppressed_low_confidence": 1}}, fh)
    os.environ["OSTLER_DIR"] = d
    real = od._http

    def fake(url, data=None, headers=None, timeout=30):
        if "6333/collections/preferences" in url and "points/count" not in url:
            return {"result": {"points_count": 1}}
        raise OSError("not part of this test")
    od._http = fake
    st = od.measure_stores()
    od._http = real
    check("measure_stores: preferences is the above-floor count (0), not the raw row (1)", st["preferences"], 0)
    check("measure_stores: raw count kept separately", st["preferences_raw"], 1)

# 6. mutant: judging on the raw count again must be caught by case 1.
mut = facts(interests=0, raw=1)
mut["stores"]["preferences"] = mut["stores"]["preferences_raw"]
check("MUTANT (count raw rows) is caught: it FAILS the walk-34 shape", rows(mut)[A1], False)

if fails:
    print("FAIL: " + "; ".join(fails))
    sys.exit(1)
print("PASS")
