#!/usr/bin/env python3
"""no_person_holds_two_contact_cards: three verdict holes (Archie, CM051 #3231 review).

Drives the REAL probe end to end through the same synthetic-store harness as
tests/test_walk_probes_print_causes.py (imported, not copied), varying only what
the fake Oxigraph answers to the distinct-uid and candidate-pair queries.

  1 FAIL-OPEN FALLBACK  the distinct-uid query returns garbage: CANNOT-RUN, never
                        a substitute denominator (mutant: the old identifier-node
                        fallback turned this into a PASS)
  2 SELF-INCONSISTENT   the candidate-pair query returns garbage: CANNOT-RUN, so a
                        broken query cannot score better than an honest zero
  3 WRONG CANNOT-RUN    2+ card nodes all excused by the merge journal and 0
                        unmerged shared-key nodes: the merge path WAS exercised,
                        so PASS with the denominator printed
  N negatives           no excused merges and 0 pairs stays CANNOT-RUN; a clean
                        graph with real pairs still PASSES

Synthetic only. Exit 0 pass, 1 fail, 2 cannot-run.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pc", os.path.join(HERE, "test_walk_probes_print_causes.py"))
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)

NAME = "no_person_holds_two_contact_cards"


def run(env, cards, uids, opp, journal=None):
    pc.CARDS_FIXTURE[0] = cards
    pc.UIDS[0] = uids
    pc.OPP[0] = opp
    jdir = os.path.join(env["HOME"], ".ostler/import-pipeline/backups/merge_journal")
    shutil.rmtree(jdir, ignore_errors=True)
    if journal:
        os.makedirs(jdir)
        with open(os.path.join(jdir, "merge_journal.jsonl"), "w") as fh:
            fh.write("".join(json.dumps(r) + "\n" for r in journal))
    return pc.run_probe(NAME, env)


def main():
    for tool in ("/bin/bash", "/usr/bin/shasum", "curl"):
        if not shutil.which(tool):
            print("CANNOT-RUN: %s missing" % tool)
            return 2
    tmp = tempfile.mkdtemp(prefix="tcvh-")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), pc.Store)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        env = pc.make_env(tmp, srv.server_address[1])
        keyed = [pc.jrow(pc._KEYED)]

        rc, out = run(env, "clean", "not-a-number", 3)
        pc.check(rc == 78 and "VERDICT: CANNOT-RUN" in out and "was not measured" in out,
                 "1 unreadable distinct-uid query is CANNOT-RUN, not a substituted PASS", "rc=%s %s" % (rc, out[-300:]))

        rc, out = run(env, "clean", 6, "not-a-number")
        pc.check(rc == 78 and "VERDICT: CANNOT-RUN" in out and "not measured" in out,
                 "2 unreadable candidate-pair query is CANNOT-RUN, not a PASS", "rc=%s %s" % (rc, out[-300:]))

        rc, out = run(env, "pass", 6, 0, journal=keyed)
        pc.check(rc == 0 and "VERDICT: PASS" in out and "1 excused merges + 0 unmerged shared-key nodes" in out,
                 "3 every 2+ card node excused by the journal and 0 unmerged pairs PASSES, denominator printed",
                 "rc=%s %s" % (rc, out[-400:]))

        rc, out = run(env, "clean", 6, 0)
        pc.check(rc == 78 and "ZERO candidate merge pairs" in out,
                 "N1 no excused merges and 0 pairs stays CANNOT-RUN", "rc=%s %s" % (rc, out[-300:]))

        rc, out = run(env, "clean", 6, 4)
        pc.check(rc == 0 and "0 excused merges + 4 unmerged shared-key nodes" in out,
                 "N2 a clean graph with 4 real pair nodes still PASSES", "rc=%s %s" % (rc, out[-300:]))

        rc, out = run(env, "norow", 6, 0)
        pc.check(rc == 1, "N3 a 2+ card node with NO journal row still FAILS even when opp is 0", "rc=%s %s" % (rc, out[-300:]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("== %d pass / %d fail / %d total ==" % (pc.PASS, pc.FAIL, pc.PASS + pc.FAIL))
    return 1 if pc.FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
