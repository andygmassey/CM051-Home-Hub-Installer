"""A post-install email-only twin is folded at the NEXT hourly fda-rerun tick.

The email ingest mints an address-only person (``uuid5(address)``, a bare
``pwg:email``, no ``pwg:hasIdentifier``) for every new correspondent, every
hour. ``dedupe_merge.run()`` sweeps them at install only, so after a clean
install a customer re-grew them hourly. The hourly tick is
``com.ostler.fda-rerun`` -> ``run-source fda-rerun`` -> ``~/.ostler/bin/ostler-fda``,
which install.sh writes from the ``FDAEOF`` heredoc; its python block now
calls ``ostler_fda.dedupe_merge.tick_email_twins()`` after ``ingest_all``.

THIS RUNS THE WRAPPER THE INSTALLER WRITES, extracted verbatim from
install.sh, with HOME redirected. Only the extract (``run_all``, which reads
macOS stores) and ``ingest_all`` are stand-ins; ``dedupe_merge`` and the merge
journal are the shipped modules, against a pyoxigraph-backed Oxigraph. The
twin is written by the shipped email-ingest writer (cm021 ``_build_upsert``).
Synthetic data only.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import types
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from _fake_oxigraph import FakeOxigraph  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
JANE = PWG + "person_card_jane"
JANE_MAIL = "jane.stewart@example.com"
TOM_MAIL = "tom.jones@example.com"
TOM = PWG + "person_card_tom"


def _load_cm021():
    saved = {k: sys.modules.get(k) for k in
             ("src", "src.filters", "src.parsers", "src.parsers.fast_mbox_parser")}
    src = types.ModuleType("src"); src.__path__ = []
    flt = types.ModuleType("src.filters"); flt.EmailFilter = object
    par = types.ModuleType("src.parsers"); par.__path__ = []
    fmp = types.ModuleType("src.parsers.fast_mbox_parser")
    fmp.FastEmail = object; fmp.FastMboxParser = object
    sys.modules.update({"src": src, "src.filters": flt, "src.parsers": par,
                        "src.parsers.fast_mbox_parser": fmp})
    try:
        spec = importlib.util.spec_from_file_location(
            "cm021_cli_tick_twin", ROOT / "vendor" / "cm021" / "src" / "cli.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v


CLI = _load_cm021()


def _wrapper_body() -> str:
    lines, grab = [], False
    for line in (ROOT / "install.sh").read_text(encoding="utf-8").splitlines():
        if not grab and 'bin/ostler-fda" <<' in line:
            grab = True
            continue
        if grab and line == "FDAEOF":
            return "\n".join(lines) + "\n"
        if grab:
            lines.append(line)
    pytest.fail("CANNOT-RUN: the ostler-fda heredoc marker moved in install.sh")


@pytest.fixture()
def box(tmp_path):
    """A fake HOME holding the installed ~/.ostler/bin/ostler-fda and fda-module."""
    home = tmp_path / "home"
    ostler = home / ".ostler"
    pkg = ostler / "fda-module" / "ostler_fda"
    shutil.copytree(ROOT / "vendor" / "ostler_fda", pkg,
                    ignore=shutil.ignore_patterns("tests", "__pycache__"))
    # Stand-ins for the two halves that read macOS stores or load JSON.
    (pkg / "extract_all.py").write_text(
        "from pathlib import Path\n"
        'def run_all(output_dir=None, enabled_sources=None, skip_sources=None, writer="unrecorded"):\n'
        "    Path(str(output_dir)).mkdir(parents=True, exist_ok=True)\n"
        "    return {'sources': {}}\n")
    with open(pkg / "pwg_ingest.py", "a", encoding="utf-8") as fh:
        fh.write("\n\ndef ingest_all(fda_dir=None):  # test stand-in\n    return {}\n")
    (ostler / "imports" / "fda").mkdir(parents=True)
    (ostler / "bin").mkdir(parents=True)
    wrapper = ostler / "bin" / "ostler-fda"
    wrapper.write_text(_wrapper_body())
    wrapper.chmod(0o755)
    store = FakeOxigraph()
    jdir = tmp_path / "journal"
    env = {k: v for k, v in os.environ.items()
           if k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    # HOME is redirected, so a runner whose packages sit in the per-user site
    # (pip --user, derived from HOME) must be told where that site is.
    import site
    env.setdefault("PYTHONUSERBASE", site.getuserbase())
    env.update(HOME=str(home), OSTLER_PYTHON=sys.executable, OXIGRAPH_URL=store.url,
               QDRANT_URL="", OSTLER_MERGE_JOURNAL_DIR=str(jdir),
               OSTLER_PIPELINE_DIR=str(ROOT / "vendor" / "cm041"),
               OSTLER_PERSON_DELETION_LOG=str(tmp_path / "del.jsonl"),
               OSTLER_FORGET_TOMBSTONE_FILE=str(tmp_path / "tomb.json"),
               OSTLER_APP_WARMUP="0", OSTLER_NOTES_REFRESH="0",
               OSTLER_REMINDERS_REFRESH="0", DEFAULT_COUNTRY_CODE="44")
    yield types.SimpleNamespace(store=store, wrapper=wrapper, env=env, jdir=jdir)
    store.close()


def _card(b, uri, name, uid, *emails):
    ids = [("icloud_contact_uid", uid)] + [("email", e) for e in emails]
    body = " ".join(
        f'<{uri}> pwg:hasIdentifier <{uri}_i{i}> . <{uri}_i{i}> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "{t}" ; pwg:identifierValue "{v}" .'
        for i, (t, v) in enumerate(ids))
    b.store.update(f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{name}" . {body} }}')


def _email_tick(b, address, from_name=""):
    iri = CLI._live_person_iri(b.store.url, CLI._safe_person_iri(address))
    b.store.ds.update(CLI._build_upsert(iri, address, from_name, "2026-10-30T09:30:00Z"))
    return CLI._safe_person_iri(address)


def _live(b):
    with b.store.lock:
        return sorted(r["p"].value for r in b.store.ds.query(
            "PREFIX pwg: <%s> SELECT DISTINCT ?p WHERE { ?p a pwg:Person . "
            "FILTER NOT EXISTS { ?p pwg:mergedInto ?t } }" % PWG))


def _tick(b):
    p = subprocess.run(["/bin/bash", str(b.wrapper)], env=b.env, capture_output=True,
                       text=True, timeout=300)
    lines = [ln for ln in p.stdout.splitlines() if ln.startswith("[email-twins] ")]
    return p, lines


def test_a_post_install_twin_is_folded_at_the_next_tick(box):
    _card(box, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    twin = _email_tick(box, JANE_MAIL)            # an email arrives after install
    assert len(_live(box)) == 2
    p, lines = _tick(box)
    assert lines, ("the tick printed no [email-twins] line", p.returncode, p.stderr[-800:])
    assert p.returncode == 0, (p.returncode, p.stderr[-800:])
    stats = json.loads(lines[-1][len("[email-twins] "):])
    assert stats["email_twins_merged"] == 1, stats
    assert _live(box) == [JANE]
    assert box.store.ask(f"ASK {{ <{twin}> pwg:mergedInto <{JANE}> }}")
    rows = [json.loads(x) for x in (box.jdir / "merge_journal.jsonl").read_text().splitlines()]
    assert [r["discard"] for r in rows if r.get("kind") == "merge"] == [twin]
    # The next email for the same address follows the tombstone: no re-growth.
    _email_tick(box, JANE_MAIL)
    _tick(box)
    assert _live(box) == [JANE]


def test_the_tick_leaves_a_different_person_on_a_shared_address_alone(box):
    _card(box, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _email_tick(box, JANE_MAIL, "Tom Jones")
    p, lines = _tick(box)
    assert lines, ("the tick printed no [email-twins] line", p.stderr[-800:])
    stats = json.loads(lines[-1][len("[email-twins] "):])
    assert stats["email_twins_merged"] == 0 and stats["email_twins_name_differs"] == 1, stats
    assert len(_live(box)) == 2


def test_an_unreadable_store_is_a_cannot_run_line_and_the_tick_goes_on(box):
    box.env["OXIGRAPH_URL"] = "http://127.0.0.1:9"
    p, lines = _tick(box)
    assert lines and "CANNOT-RUN" in lines[-1], (lines, p.stderr[-800:])


def test_the_tick_is_capped_and_says_what_it_deferred(box):
    """Unattended, so capped: OSTLER_EMAIL_TWIN_MAX_FOLDS folds per tick, the
    rest next tick, counted on the tick's own line."""
    for i in range(3):
        uri = PWG + "person_card_%d" % i
        mail = "jane.stewart%d@example.com" % i
        _card(box, uri, "Jane Stewart", "SYNTHETIC-CARD-UID-%04d" % (10 + i), mail)
        _email_tick(box, mail)
    box.env["OSTLER_EMAIL_TWIN_MAX_FOLDS"] = "2"
    _, lines = _tick(box)
    s1 = json.loads(lines[-1][len("[email-twins] "):])
    assert (s1["email_twins_merged"], s1["email_twins_deferred"], s1["email_twins_max_folds"]) == (2, 1, 2), s1
    assert len(_live(box)) == 4
    _, lines = _tick(box)
    s2 = json.loads(lines[-1][len("[email-twins] "):])
    assert (s2["email_twins_merged"], s2["email_twins_deferred"]) == (1, 0), s2
    assert len(_live(box)) == 3


def test_the_default_tick_cap_is_set(box):
    _card(box, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _email_tick(box, JANE_MAIL)
    _, lines = _tick(box)
    s = json.loads(lines[-1][len("[email-twins] "):])
    assert s["email_twins_max_folds"] == 25, s
