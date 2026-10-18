#!/usr/bin/env python3
"""DMG #23. The real person for hub_screens_render_for_a_customer is a REAL
person's name and the walk record is public. This test uses a SYNTHETIC
stand-in and asserts it appears in neither stdout nor stderr of the judge, in
no scrubbed error text, and that the collector keeps no screenshot of the page.
Also: real_person_pick.py's own self-test (positive control) and a mutation
(a picker that stops rejecting organisations must be caught)."""
import json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "scripts", "box_walk_probes", "lib")
sys.path.insert(0, LIB)
STAND_IN = "Robbie Wang"
fails = []


def check(cond, msg):
    print(("  [PASS] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fails.append(msg)


import hub_screens as hs

# 1. scrub: name in any case, and its slug, never survive
raw = ('Timeout waiting for locator main a[href*="/People/robbie-wang/"] while asking '
       '"Who is ROBBIE WANG?" ... Robbie Wang')
scrubbed = hs._scrub_name(raw, STAND_IN)
check(not re.search(r"robbie|wang", scrubbed, re.I), "scrub removes the name (any case) and the slug")
check(hs._scrub_name("plain", STAND_IN) == "plain", "scrub leaves unrelated text alone (control)")

# 2. judge: rp error carrying the scrubbed text prints nothing identifying
facts = {"person_link": {"person_checked": True, "asks": [], "real_person": {"checked": True, "anchor": False, "error": scrubbed}}}
env = dict(os.environ, HUB_SCREENS_REAL_PERSON=STAND_IN,
           HUB_SCREENS_REAL_PERSON_DETAIL="no real person with a compiled page after 0s; examined people=0")
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
    json.dump(facts, fh); fp = fh.name
r = subprocess.run([sys.executable, os.path.join(LIB, "hub_screens.py"), "judge", fp],
                   env=env, capture_output=True, text=True)
os.unlink(fp)
blob = r.stdout + r.stderr
check(not re.search(r"robbie|wang", blob, re.I), "judge stdout+stderr never carry the stand-in name")
check("a real person's compiled page renders with their name" in blob, "control: the real-person row was actually judged")
# the NOT MEASURED row names the runner's reason, not a bare 'set the env'
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
    json.dump({"person_link": {"person_checked": True, "asks": []}}, fh); fp = fh.name
r2 = subprocess.run([sys.executable, os.path.join(LIB, "hub_screens.py"), "judge", fp],
                    env=env, capture_output=True, text=True)
os.unlink(fp)
check("compiled page after 0s" in r2.stdout or "no real person" in r2.stdout,
      "an unchosen person is reported with the runner's declared reason")

# 3. the collector keeps no screenshot of the real person's page
src = open(os.path.join(LIB, "hub_screens.py")).read()
check("person-real.png" not in re.sub(r"#.*", "", src.replace("NO screenshot", "")) or
      'screenshot(path=os.path.join(out_dir, "person-real.png"))' not in src,
      "no screenshot of the real person's page is written into the walk record")

# 4. picker self-test + mutation
pick = os.path.join(LIB, "real_person_pick.py")
check(subprocess.run([sys.executable, pick, "--self-test"], capture_output=True).returncode == 0, "real_person_pick self-test passes")
mut = open(pick).read().replace("if _org_like(name):", "if False:")
check(mut != open(pick).read(), "mutant applied")
with tempfile.NamedTemporaryFile("w", suffix=".py", dir=LIB, delete=False) as fh:
    fh.write(mut); mp = fh.name
try:
    check(subprocess.run([sys.executable, mp, "--self-test"], capture_output=True).returncode != 0,
          "MUTANT (organisations no longer rejected) is caught by the self-test")
finally:
    os.unlink(mp)

print("\n{} failed".format(len(fails)))
sys.exit(1 if fails else 0)
