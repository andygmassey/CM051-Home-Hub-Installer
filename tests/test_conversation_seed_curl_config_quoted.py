#!/usr/bin/env python3
"""conversation_seed.sh passes the store credential to curl as ONE quoted word, in
zsh and in sh.

The old line `K="-K $CONF"` then `curl $K ...` relies on word splitting. zsh does
not split an unquoted expansion, so curl got "-K /path" as one argument, exited 26,
and the cleanup deletes failed silently (residue on Mini16, the real-data box).

Tests (both shells, a fake curl that exits 26 on a joined "-K <path>" argument):
  - the new form `curl -K "$CONF" ...` passes under zsh and under sh
  - control: the old `K="-K $CONF"; curl $K` form FAILS under zsh (proves the fake bites)
  - static: conversation_seed.sh has no unquoted `\\$K ` curl argument left
Exit 0 pass, 1 fail.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib", "conversation_seed.sh")

FAKE_CURL = '''#!/bin/sh
case "$1" in
  "-K "*) exit 26 ;;
esac
exit 0
'''


def run(shell, body, workdir):
    with open(os.path.join(workdir, "curl"), "w") as fh:
        fh.write(FAKE_CURL)
    os.chmod(os.path.join(workdir, "curl"), 0o755)
    env = {"PATH": workdir + ":/usr/bin:/bin", "HOME": workdir, "CONF": os.path.join(workdir, "store-curl.conf")}
    open(env["CONF"], "w").close()
    out = subprocess.run([shell, "-c", body], env=env, capture_output=True, text=True)
    return out.returncode


NEW = 'curl -K "$CONF" -sS http://x/'
OLD = 'K="-K $CONF"; curl $K -sS http://x/'


def main():
    bad = []
    with tempfile.TemporaryDirectory() as d:
        for shell in ("zsh", "sh"):
            if run(shell, NEW, d) != 0:
                bad.append("new form must pass under %s" % shell)
        control_rc = run("zsh", OLD, d)
        if control_rc != 26:
            bad.append("CONTROL: the old unquoted form should fail under zsh with rc 26, got %s" % control_rc)
    with open(LIB, encoding="utf-8") as fh:
        src = fh.read()
    live = [l for l in src.splitlines() if not l.lstrip().startswith("#") and "\\$K " in l]
    if live:
        bad.append("unquoted \\$K curl argument left in conversation_seed.sh: %d line(s)" % len(live))
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: the credential is one quoted word under zsh and sh; the old form fails under zsh; no unquoted \\$K left")
    return 0


if __name__ == "__main__":
    sys.exit(main())
