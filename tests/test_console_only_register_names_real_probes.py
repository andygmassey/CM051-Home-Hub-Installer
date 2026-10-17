#!/usr/bin/env python3
"""console_only_probes.tsv parses (3 tab columns, surface tcc|gui) and every
listed name is a probe on disk. A typo'd name is a silent non-exemption, so a
row naming a probe that does not exist must fail. Self-checks with a mutant."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "scripts", "box_walk_probes")


def problems(reg_text, probe_dir):
    out, names = [], []
    for n, line in enumerate(reg_text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        c = line.split("\t")
        if c == ["probe", "surface", "why"]:
            continue
        if len(c) != 3 or not all(x.strip() for x in c):
            out.append("line %d: want exactly 3 non-empty tab columns" % n); continue
        if c[1] not in ("tcc", "gui"):
            out.append("line %d: surface %r is not tcc|gui" % (n, c[1]))
        if not os.path.isfile(os.path.join(probe_dir, c[0] + ".sh")):
            out.append("line %d: %r is not a probe in probes/" % (n, c[0]))
        names.append(c[0])
    if len(names) != len(set(names)):
        out.append("duplicate probe rows")
    return out, names


txt = open(os.path.join(BASE, "console_only_probes.tsv")).read()
pd = os.path.join(BASE, "probes")
p, names = problems(txt, pd)
fails = list(p)
for need in ("app_signature_survives_first_run", "assistant_sends_over_whatsapp_and_email", "todos_reach_reminders"):
    if need not in names:
        fails.append("missing row " + need)
print("rows:", len(names))
mp, _ = problems(txt + "no_such_probe\tgui\twhy\n", pd)
if not any("no_such_probe" in x for x in mp):
    fails.append("CONTROL: a row naming a non-existent probe was not caught")
else:
    print("control: a non-existent probe row is caught")
for f in fails:
    print("FAIL", f)
sys.exit(1 if fails else 0)
