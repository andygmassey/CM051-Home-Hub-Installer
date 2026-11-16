#!/usr/bin/env python3
"""An unconfirmed owner-employer seed removal is an ERROR, not a note.

Archie's ruling: the seed left in the graph on a real-data box is silent residue if it is only
a probe_note. The removal verdict now lives in lib/owner_seed_cleanup.sh, which prints
"ERROR: CLEANUP FAILED: owner-employer seed NOT confirmed removed" and returns 1. The probe
prints that to stderr and records a non-zero cleanup status. The probe's own verdict is
unchanged by it.

Checks, through the real helper under bash:
  - before 2, after 0   -> confirmed, rc 0, no ERROR
  - before 2, after 1   -> ERROR line, rc 1                      (RED: not silent)
  - before 2, after ""  -> unreadable is ERROR, rc 1             (RED: unreadable is not success)
  - before 0, after 0   -> nothing to remove, rc 0
Control: the probe must not report the unconfirmed case as a probe_note.
Exit 0 pass, 1 fail.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BOX = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes")
HELPER = os.path.join(BOX, "lib", "owner_seed_cleanup.sh")
PROBE = os.path.join(BOX, "probes", "owner_digest_knows_the_owner.sh")


def verdict(before, after):
    out = subprocess.run(["bash", "-c", '. "$H"; owner_seed_cleanup_verdict "$B" "$A"'],
                         env={"H": HELPER, "B": before, "A": after, "PATH": "/usr/bin:/bin"},
                         capture_output=True, text=True)
    return out.returncode, out.stdout


def main():
    bad = []
    rc, out = verdict("2", "0")
    if rc != 0 or "ERROR" in out:
        bad.append("confirmed removal must be rc 0 with no ERROR, got rc=%s" % rc)
    rc, out = verdict("2", "1")
    if rc != 1 or "ERROR: CLEANUP FAILED: owner-employer seed" not in out:
        bad.append("RED: an unconfirmed removal (after=1) must be the ERROR line with rc 1, got rc=%s %r" % (rc, out))
    rc, out = verdict("2", "")
    if rc != 1 or "ERROR" not in out:
        bad.append("RED: an unreadable after count must be an ERROR with rc 1, got rc=%s" % rc)
    rc, out = verdict("0", "0")
    if rc != 0:
        bad.append("nothing to remove (0,0) must be rc 0, got rc=%s" % rc)
    with open(PROBE, encoding="utf-8") as fh:
        src = fh.read()
    if "probe_note \"owner-employer seed NOT confirmed" in src:
        bad.append("CONTROL: the probe still reports the unconfirmed removal as a probe_note")
    if "owner_seed_cleanup_verdict" not in src:
        bad.append("the probe must call the cleanup verdict helper")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: confirmed removal is rc 0; an unconfirmed or unreadable removal is an ERROR with rc 1; the probe cannot downgrade it to a note")
    return 0


if __name__ == "__main__":
    sys.exit(main())
