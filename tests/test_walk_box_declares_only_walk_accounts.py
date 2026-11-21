#!/usr/bin/env python3
"""The synthetic-box declaration is made only for walk accounts.

Walk 132: owner_knowledge_score refused the CONTEXT.md swap because nothing
declared the walk box synthetic. The declaration is now made by
lib/walk_box_identity.sh, and ONLY for ostlerwalk or walkN. The owner's account
must never be declared (Mini16 holds real personal data).

Runs the real lib under bash with a throwaway HOME. Control: a mutant that
declares every account must be caught by the owner-account case. Exit 0/1.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib", "walk_box_identity.sh")


def declare(user, lib=LIB):
    home = tempfile.mkdtemp(prefix="wbi-")
    cmd = '. "%s" && walk_box_declare_synthetic "%s"' % (lib, user)
    out = subprocess.run(["bash", "-c", cmd], env={"HOME": home, "PATH": os.environ["PATH"]},
                         capture_output=True, text=True, stdin=subprocess.DEVNULL)
    marker = os.path.exists(os.path.join(home, ".ostler", "state", "synthetic-box"))
    return out.stdout.strip(), marker


def main():
    bad = []
    for user, want_marker in [("ostlerwalk", True), ("walk3", True), ("andy", False)]:
        word, marker = declare(user)
        if marker != want_marker:
            bad.append("%s: marker=%s want %s (%s)" % (user, marker, want_marker, word))
    # control: a mutant that declares everything must be caught on the owner account
    mutant = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    mutant.write('walk_box_declare_synthetic() { mkdir -p "$HOME/.ostler/state" && : > "$HOME/.ostler/state/synthetic-box" && echo DECLARED; }\n')
    mutant.close()
    _, mm = declare("andy", lib=mutant.name)
    os.unlink(mutant.name)
    if not mm:
        bad.append("CONTROL: the declare-everything mutant should have declared the owner account")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: ostlerwalk and walkN declared; the owner account is not; the declare-all mutant is caught")
    return 0


if __name__ == "__main__":
    sys.exit(main())
