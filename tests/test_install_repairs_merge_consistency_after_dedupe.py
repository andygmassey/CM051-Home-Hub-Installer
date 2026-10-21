"""install.sh must run repair_merge_consistency AFTER dedupe_merge (CM051 #3072, Archie, v1.0.116).

The first pass at "Reconciling merged people across both stores" runs before the dedupe_merge
sweep. When a contact card and an iMessage handle are the same person and the merge keeps the
iMessage-minted node, the contact_syncer vector on the merged-away card node stays (the hourly
people sync only prunes its own fda_people_index points): 9 vectors for 8 people, and the
BLOCKING probe people_stores_reconcile fails.

The sequence below is NOT hand-ordered. The repair invocations and the dedupe snippet are read
out of install.sh in the order they appear there, and each is run for real (vendored
identity_resolver, ostler_fda, contact_syncer) against the stand-in stores of #3072's harness.
The cast is that harness's synthetic cast (example.com, Ofcom drama range).
"""
from __future__ import annotations

import re
import shlex
import subprocess

import pytest

from test_contact_cards_seed_runs_the_probe import (  # noqa: F401  (fixtures + helpers)
    PWG, ROOT, fx, home, stores, _box_env,
)

INSTALL = ROOT / "install.sh"
REPAIR_RE = re.compile(r"-m identity_resolver\.repair_merge_consistency((?:[^\n]*\\\n)*[^\n]*)")
DEDUPE_MARK = "from ostler_fda.dedupe_merge import run"


def install_steps(text):
    """[(kind, argv_or_None)] in the order install.sh runs them."""
    steps = []
    for m in REPAIR_RE.finditer(text):
        args = m.group(1).replace("\\\n", " ")
        args = args.replace("${OXIGRAPH_URL:-http://localhost:7878}", "$OXI")
        args = args.replace("${QDRANT_URL:-http://localhost:6333}", "$QDR")
        steps.append((m.start(), "repair", args))
    for m in re.finditer(re.escape(DEDUPE_MARK), text):
        steps.append((m.start(), "dedupe", None))
    steps.sort()
    return [(k, a) for _, k, a in steps]


def run_install_order(home, stores, install_text, monkeypatch):
    env = _box_env(home, stores)
    pipe_py = home / ".ostler/import-pipeline/.venv/bin/python"
    fda_py = home / ".ostler/services/email-ingest/.venv/bin/python"
    d = home / ".ostler/walk-seed/contact-cards"
    d.mkdir(parents=True)
    work = home / "cwd"
    work.mkdir()
    pipe_cwd = ROOT / "vendor" / "cm041"

    def sh(cmd, cwd):
        r = subprocess.run(["bash", "-c", cmd], env=dict(env, OXI=stores.oxi, QDR=stores.qdrant),
                           cwd=str(cwd), capture_output=True, text=True, timeout=180)
        return r.returncode, r.stdout + r.stderr

    fixture = ROOT / "scripts/box_walk_probes/lib/contact_cards_fixture.py"
    rc, out = sh("%s %s stage %s" % (pipe_py, fixture, d), work)
    assert rc == 0, out
    rc, out = sh("%s -m contact_syncer.syncer --vcf %s/cards.vcf --graph-endpoint $OXI" % (pipe_py, d), pipe_cwd)
    assert rc == 0, out
    ingest = ("%s -c 'from pathlib import Path; from ostler_fda import pwg_ingest; "
              "pwg_ingest.ingest_imessage(Path(\"%s\")); print(pwg_ingest.ingest_people_to_qdrant())'" % (fda_py, d))
    rc, out = sh(ingest, work)          # install.sh: ingest, then the people resync, both before dedupe
    assert rc == 0, out

    ran = []
    for kind, args in install_steps(install_text):
        if kind == "repair":
            rc, out = sh("%s -m identity_resolver.repair_merge_consistency %s --backup-dir %s" % (pipe_py, args, home / "backups"), pipe_cwd)
        else:
            rc, out = sh("%s -c 'from ostler_fda.dedupe_merge import run; print(run())'" % fda_py, work)
        ran.append(kind)
        assert rc == 0, (kind, out)
    return ran


@pytest.mark.parametrize("survivor", ["high", "low"])
def test_install_order_leaves_vectors_equal_to_graph_people(stores, home, monkeypatch, survivor):
    monkeypatch.setenv("CCS_CARD_ID", survivor)
    ran = run_install_order(home, stores, INSTALL.read_text(), monkeypatch)
    live = stores.person_count()  # includes merged-away nodes; the live set is below
    live_uris = {str(r[0]) for r in stores.g.query(
        "PREFIX p:<%s> SELECT DISTINCT ?x WHERE { ?x a p:Person . FILTER NOT EXISTS { ?x p:mergedInto ?m } "
        "FILTER NOT EXISTS { ?x a p:RetiredPerson } }" % PWG)}
    vec_uris = {v["payload"].get("person_uri") for v in stores.points.values()}
    assert len(stores.points) == len(vec_uris), "two vectors on one person"
    assert vec_uris <= live_uris, "vector on a merged-away or retired node: %s" % (vec_uris - live_uris)
    assert len(stores.points) == len(live_uris), (len(stores.points), len(live_uris), live)
    assert ran[-1] == "repair" and "dedupe" in ran and ran.index("dedupe") < len(ran) - 1, ran


def test_the_installer_has_a_repair_after_the_dedupe_and_keeps_the_first():
    steps = [k for k, _ in install_steps(INSTALL.read_text())]
    assert steps.count("repair") >= 2 and steps.count("dedupe") == 1, steps
    assert steps[0] == "repair" and steps[-1] == "repair", steps


def test_mutant_without_the_second_repair_a_stale_vector_survives(stores, home, monkeypatch):
    monkeypatch.setenv("CCS_CARD_ID", "high")
    text = INSTALL.read_text()
    a = text.index("# MERGE-CONSISTENCY REPAIR, SECOND PASS")
    b = text.index("unset _INITIAL_HYDRATE_QDRANT _INITIAL_HYDRATE_FDA_DIR\n")
    mutant = text[:a] + text[b:]
    assert mutant != text
    ran = run_install_order(home, stores, mutant, monkeypatch)
    assert ran == ["repair", "dedupe"], ran
    assert len(stores.points) == len(fx.CARDS) + 1, "9 vectors for 8 people"
