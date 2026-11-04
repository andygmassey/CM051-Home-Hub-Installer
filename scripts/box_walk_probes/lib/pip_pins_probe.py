#!/usr/bin/env python3
"""Does each installed venv hold exactly the versions the shipped requirements
files pin? (S4, v1.0.124)

The requirements files are all == pins (tests/test_python_requirements_are_pinned.py).
That proves the SOURCE. This proves the INSTALL: a venv that drifted, or an
install path that bypassed the pinned file, shows up as a version mismatch.

Halves, so the judge can be mutation-tested without a box:
  box   -- runs ON the box with any python3. Prints ONE JSON line: for each
           known (venv, requirements files) pair that exists, the pins and the
           venv's `pip freeze`. Never prints anything else.
  judge -- pure. Reads that JSON.

Grading per venv, from counts only:
  MISMATCH  a pinned package is installed at a DIFFERENT version  -> FAIL
  MISSING   a pinned package is not installed                     -> FAIL
  EXTRA     installed but not pinned: FAIL for an `exact` venv (only the
            pinned files are ever installed into it), reported but not a FAIL
            for a `superset` venv (it also carries bundled ostler_* packages
            whose own pyproject dependencies are not yet constrained; hashes
            and a constraints file are the v1.0.125 step).
A venv absent from the box is N/A, not a pass: the denominator is printed.
"""
import json, os, re, subprocess, sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
IGNORE = {"pip", "setuptools", "wheel"}
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()

# label, venv (under OSTLER_DIR), mode, requirements globs (under OSTLER_DIR)
PAIRS = [
    ("pipeline", "import-pipeline/.venv", "exact",
     ["import-pipeline/*/requirements.txt", "import-pipeline/requirements.txt"]),
    ("consumer", ".venv", "superset",
     ["import-pipeline/*/requirements.txt", "import-pipeline/requirements.txt"]),
    ("cm019", "services/cm019/.venv", "exact", ["services/cm019/requirements.txt"]),
    ("doctor", "doctor/.venv", "exact", ["doctor/requirements.txt"]),
]

def parse_pins(text):
    pins = {}
    for ln in text.splitlines():
        ln = ln.split("#", 1)[0].strip()
        m = re.fullmatch(r"([A-Za-z0-9_.\-]+)(?:\[[^\]]*\])?==([^\s;]+)", ln)
        if m:
            pins[norm(m.group(1))] = m.group(2)
        elif ln:
            pins[ln] = None  # an unpinned line: judged FAIL
    return pins

def parse_freeze(text):
    out = {}
    for ln in text.splitlines():
        m = re.fullmatch(r"([A-Za-z0-9_.\-]+)==(\S+)", ln.strip())
        if m:
            out[norm(m.group(1))] = m.group(2)
    return out

def box():
    import glob
    base = os.environ.get("OSTLER_DIR") or os.path.expanduser("~/.ostler")
    facts = {"venvs": {}}
    for label, venv, mode, globs in PAIRS:
        pip = os.path.join(base, venv, "bin", "pip")
        files = sorted({f for g in globs for f in glob.glob(os.path.join(base, g))})
        if not os.path.exists(pip) or not files:
            facts["venvs"][label] = {"present": False, "mode": mode}
            continue
        r = subprocess.run([pip, "freeze", "--exclude-editable"], capture_output=True, text=True)
        if r.returncode != 0:
            facts["venvs"][label] = {"present": True, "mode": mode, "freeze_rc": r.returncode}
            continue
        pins = {}
        for f in files:
            pins.update(parse_pins(open(f).read()))
        facts["venvs"][label] = {"present": True, "mode": mode, "freeze_rc": 0,
                                 "files": len(files), "pins": pins,
                                 "freeze": parse_freeze(r.stdout)}
    print(json.dumps(facts))

def judge_one(v):
    """-> (status, detail) status in ok FAIL CANNOT N/A"""
    if not v.get("present"):
        return "N/A", "venv or requirements not on this box"
    if v.get("freeze_rc") != 0:
        return "CANNOT", "pip freeze failed rc=%s" % v.get("freeze_rc")
    pins, fz = v["pins"], v["freeze"]
    if not pins:
        return "FAIL", "no pins read (a zero is not a pass)"
    bad_lines = [k for k, x in pins.items() if x is None]
    mism = [k for k, x in pins.items() if x is not None and k in fz and fz[k] != x]
    miss = [k for k, x in pins.items() if x is not None and k not in fz]
    extra = [k for k in fz if k not in pins and k not in IGNORE]
    detail = "%d pinned, %d installed, mismatch=%d missing=%d extra=%d unpinned_lines=%d" % (
        len(pins), len(fz), len(mism), len(miss), len(extra), len(bad_lines))
    if mism or miss or bad_lines or (extra and v["mode"] == "exact"):
        return "FAIL", detail + " :: " + ",".join((mism + miss + bad_lines + extra)[:8])
    return "ok", detail + ((" (extra tolerated: superset venv)") if extra else "")

def judge(facts):
    rows, rc = [], EX_PASS
    measured = 0
    for label in [p[0] for p in PAIRS]:
        v = facts.get("venvs", {}).get(label, {"present": False})
        st, d = judge_one(v)
        rows.append("  %s %s: %s" % (st, label, d))
        if st in ("ok", "FAIL"):
            measured += 1
        if st == "FAIL":
            rc = EX_FAIL
        elif st == "CANNOT" and rc == EX_PASS:
            rc = EX_CANNOT
    if measured == 0 and rc == EX_PASS:
        rows.append("  CANNOT: no venv was measured (denominator 0)")
        rc = EX_CANNOT
    return rows, rc

def self_test():
    good = {"present": True, "mode": "exact", "freeze_rc": 0,
            "pins": {"httpx": "0.28.1", "idna": "3.20"},
            "freeze": {"httpx": "0.28.1", "idna": "3.20"}}
    assert judge_one(good)[0] == "ok", "control must pass"
    mut = {
        "version drift": dict(good, freeze={"httpx": "0.28.2", "idna": "3.20"}),
        "missing": dict(good, freeze={"httpx": "0.28.1"}),
        "extra in exact venv": dict(good, freeze={"httpx": "0.28.1", "idna": "3.20", "evil": "1"}),
        "unpinned line": dict(good, pins={"httpx": "0.28.1", "idna": None}),
        "no pins": dict(good, pins={}),
    }
    for name, v in mut.items():
        assert judge_one(v)[0] == "FAIL", "mutant not caught: " + name
    assert judge_one(dict(good, mode="superset", freeze={"httpx": "0.28.1", "idna": "3.20", "x": "1"}))[0] == "ok"
    assert judge_one(dict(good, freeze_rc=1))[0] == "CANNOT"
    assert judge({"venvs": {}})[1] == EX_CANNOT, "zero measured must not pass"
    print("self-test ok: 1 control, %d mutants, superset tolerance, cannot-run, zero denominator" % len(mut))

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--self-test"]:
        self_test()
    elif a[:1] == ["box"]:
        box()
    elif a[:1] == ["judge"]:
        rows, rc = judge(json.load(open(a[1])))
        print("\n".join(rows)); sys.exit(rc)
    else:
        sys.exit(__doc__)
