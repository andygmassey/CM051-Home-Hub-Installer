#!/usr/bin/env python3
"""verify_daemon_hold_registers_agree.py <version> [--root DIR]

THE DAEMON HOLD IS WRITTEN IN TWO REGISTERS AND READ BY TWO GATES.
  scripts/daemon_hold_ack.tsv            -> verify_cut_freshness.sh (check-freshness, preflight/dry run)
  cut-manifests/permanent.yaml           -> verify_cut_manifest.py permanent-daemon-freshness
     (proof.hold_ack.shas)                  (check-manifest, which reads the BUILT .app, so it
                                             runs only inside a real build)
v1.0.110 (cut run 39197687650) spent its tag on exactly this: Archie's hold of 16 oa
commits after hub-v0.5.22 was written in the .tsv only, so every dry run and the
rehearsal were green and the build died at check-manifest.

RULE: every SHA the .tsv holds for this cut's daemon pin (cuts/<version>/cut.env
DAEMON_COMMIT) must also be held in permanent.yaml. Prefix match, either direction,
minimum 7 hex. One direction only, deliberately: permanent.yaml carries earlier
epochs' SHAs, and a SHA held there but not in the .tsv is already caught by
check-freshness at preflight.

Exit: 0 agree (or nothing held for this pin, said so), 1 a SHA is held in one
register only (named), 2 CANNOT-RUN (a file is missing or unreadable).
"""
import argparse, os, re, sys

def die(msg):
    print("CANNOT-RUN: " + msg); sys.exit(2)

ap = argparse.ArgumentParser()
ap.add_argument("version"); ap.add_argument("--root", default=".")
a = ap.parse_args()
v = a.version if a.version.startswith("v") else "v" + a.version
env = os.path.join(a.root, "cuts", v, "cut.env")
tsv = os.path.join(a.root, "scripts", "daemon_hold_ack.tsv")
perm = os.path.join(a.root, "cut-manifests", "permanent.yaml")
for f in (env, tsv, perm):
    if not os.path.isfile(f): die("missing " + f)
try:
    import yaml
except Exception as e:
    die("PyYAML unavailable: %s" % e)
pin = ""
for line in open(env):
    m = re.match(r"^DAEMON_COMMIT=([0-9a-fA-F]{7,40})\s*$", line)
    if m: pin = m.group(1).lower()
if not pin: die("no DAEMON_COMMIT= in " + env)

def same(x, y):
    n = min(len(x), len(y)); return n >= 7 and x[:n] == y[:n]

held_tsv = []
rows = 0
for line in open(tsv):
    if line.startswith("#") or not line.strip(): continue
    f = line.rstrip("\n").split("\t")
    if len(f) < 2: continue
    if same(f[0].strip().lower(), pin):
        rows += 1
        held_tsv += [s.lower() for s in f[1].split() if re.fullmatch(r"[0-9a-fA-F]{7,40}", s)]
try:
    y = yaml.safe_load(open(perm))
except Exception as e:
    die("cannot parse %s: %s" % (perm, e))
ent = [e for e in (y.get("entries") or []) if isinstance(e, dict) and e.get("id") == "permanent-daemon-freshness"]
if len(ent) != 1: die("permanent.yaml has %d permanent-daemon-freshness entries (want 1)" % len(ent))
hold = ((ent[0].get("proof") or {}).get("hold_ack") or {})
held_perm = [str(s).split()[0].lower() for s in (hold.get("shas") or [])]

print("daemon hold registers for %s, pin DAEMON_COMMIT=%s" % (v, pin))
print("  scripts/daemon_hold_ack.tsv   rows for this pin: %d, SHAs held: %d" % (rows, len(held_tsv)))
print("  cut-manifests/permanent.yaml  permanent-daemon-freshness hold_ack SHAs: %d (all epochs)" % len(held_perm))
missing = [s for s in held_tsv if not any(same(s, p) for p in held_perm)]
if not held_tsv:
    print("  PASS nothing is held for this pin in the .tsv, so there is nothing to agree on"); sys.exit(0)
if missing:
    print("  FAIL %d SHA(s) held in daemon_hold_ack.tsv are NOT held in permanent.yaml; check-manifest" % len(missing))
    print("       will refuse the build for them after preflight and every dry run went green:")
    for s in missing: print("         " + s)
    print("  FIX: add each to permanent-daemon-freshness proof.hold_ack.shas with the same reason.")
    sys.exit(1)
print("  PASS all %d SHA(s) held in the .tsv are held in permanent.yaml too" % len(held_tsv)); sys.exit(0)
