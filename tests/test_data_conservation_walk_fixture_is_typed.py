#!/usr/bin/env python3
"""The walk's preference fixture is seeded as TYPED preference nodes.

Walk 131 (triage A): 24 walk_fixture rows read STORED 4 or 8 and GRAPH 0. The
graph counter (data_conservation.py collect_oxigraph) reads only typed
Like/Dislike/Neutral preferences with a subject, a dataSource and a category.
The overlay triples the seed wrote carry none of those, so the fixture was
invisible to the count and read as lost. The fix is in the SEED. The judge is
not changed to filter the rows out.

Pure: no box, no Oxigraph. The check below is the same shape the counter
reads, applied to the seed's own N-Triples. Its negative control is the
overlay-only output the walk used to seed, which must FAIL the check.
Synthetic data only. Exit 0 pass, 1 fail.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib"))
import smart_prefs as sp  # noqa: E402

fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


RDF_TYPE = "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>"
PREF_TYPES = {"<%sLikePreference>" % sp.PREF_NS, "<%sDislikePreference>" % sp.PREF_NS,
              "<%sNeutralPreference>" % sp.PREF_NS}


def typed_subjects(lines):
    """Subjects that the graph counter would count: a rdf:type to one of the
    three preference classes, AND the subject, dataSource and category it reads."""
    typed, has = set(), {}
    for ln in lines:
        m = re.match(r"^<([^>]+)> <([^>]+)> (.+) \.$", ln)
        if not m:
            continue
        s, p, o = m.group(1), m.group(2), m.group(3)
        if p == RDF_TYPE.strip("<>") and o in PREF_TYPES:
            typed.add(s)
        for key in ("subject", "dataSource", "category"):
            if p == sp.PREF_NS + key:
                has.setdefault(s, set()).add(key)
    return {s for s in typed if has.get(s, set()) >= {"subject", "dataSource", "category"}}


pts = sp.qdrant_points([0.0])
want = {"urn:ostler:preference:%s" % p["id"] for p in pts}
check("the fixture has preference points to seed ({})".format(len(want)), len(want) > 0)

got = typed_subjects(sp.typed_preference_triples())
check("every fixture preference is seeded as a typed, counted preference node ({} of {})".format(
    len(got & want), len(want)), want <= got)

# Negative control: the overlay-only seed the walk used before the fix. The
# same check must find NONE of the fixture typed, or it cannot see the defect.
ctrl = typed_subjects(sp.overlay_triples())
check("negative control: the overlay-only seed is NOT typed (the check can fail; typed={})".format(len(ctrl & want)),
      not (want & ctrl))

# The dataSource the counter groups by is the fixture's own source, never a
# real one: the walk_fixture_ prefix is what forget keys on.
srcs = set(re.findall(r'<%sdataSource> "([^"]+)"' % re.escape(sp.PREF_NS), "\n".join(sp.typed_preference_triples())))
check("every typed fixture preference names a walk_fixture source ({})".format(sorted(srcs)),
      srcs and all(x.startswith("walk_fixture_") for x in srcs))

print("FAIL: " + "; ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
