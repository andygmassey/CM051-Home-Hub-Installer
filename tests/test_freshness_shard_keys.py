#!/usr/bin/env python3
"""freshness_panel_has_dates must derive the panel row from a shard name the way
the panel names it.

Walk 130: settling_progress.d/emails.history.json was read as source 'history',
so the probe reported a missing 'history' row. The file's first component
('emails') names the panel row ('email'); the second ('history') is a sub-shard.
'messages.imessage.json' is the opposite case: the second component names the row.

Runs the probe's own key-derivation heredoc against a synthetic HOME. Exit 0 pass.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes", "freshness_panel_has_dates.sh")
fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


src = open(PROBE).read()
m = re.search(r"box_run \"python3 - <<'OSTLERPANEL'\n(.*?)\nOSTLERPANEL\"\n", src, re.S)
check("probe still carries the OSTLERPANEL heredoc (extractable)", m is not None)
body = m.group(1) if m else ""

home = tempfile.mkdtemp(prefix="freshness-keys-")
state = os.path.join(home, ".ostler", "state", "settling_progress.d")
os.makedirs(state)
for name in ("emails.history.json", "emails.json", "messages.imessage.json",
             "messages.whatsapp.json", "calendar.json"):
    with open(os.path.join(state, name), "w") as fh:
        fh.write('{"key": "%s", "updated_at": "2026-11-13T10:00:00Z"}' % name.split(".")[0])
script = os.path.join(home, "panel_keys.py")
with open(script, "w") as fh:
    fh.write(body + "\n")
env = dict(os.environ, HOME=home)
out = subprocess.run([sys.executable, "-I", script], capture_output=True, text=True, env=env).stdout
line = next((l for l in out.splitlines() if l.startswith("INGEST_KEYS=")), "")
keys = set(line.split("=", 1)[1].split(",")) if line else set()
check("ingest keys are the panel rows {calendar,email,imessage,whatsapp}; got %s" % sorted(keys),
      keys == {"calendar", "email", "imessage", "whatsapp"})
check("no sub-shard name leaks in as a source ('history' absent)", "history" not in keys)

print("FAIL: " + "; ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
