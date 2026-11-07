#!/usr/bin/env python3
"""The walk's preference seed lands BOTH rows, and the screen has a row on each side.

THE DEFECT (v1.0.124 and v1.0.125 walks, the same line both times):

    ingest rc 0 (Preferences created 2, filtered 7, triples 2, vectors 2)
    graph post-count 1 of expected 2, loader exit 1, 'a write was lost'

Nothing was lost. The seed's clearing row was 8 Spotify PLAYS, and since CM051
#2921 (a play is not a like) the ingest aggregates plays to a
pwg:NeutralPreference. "filtered 7" is the 8 plays collapsing into 1. The
loader (OS003 gates/seed/load_preference_seed.py, _seed_pattern) counts
pwg:LikePreference only, so it saw the twitter row alone and exited 1, and
every preference probe after it lost its subject. The product filter is right;
the FIXTURE was stale. Its second row (0.1732) had also stopped being screened
when the compiler floor moved from 0.28 to 0.10, so even a landed pair would
have read suppressed=0 on a seed-only store.

WHAT THIS RUNS. The fixture the harness SHIPS (asked of
scripts/box_walk_probes/lib/preference_seed.sh itself, not assumed), through
the vendored cm019 IngestPipeline.ingest_directory (the CLI's ingest-dir path,
two-phase aggregation, the real _process_batch and to_turtle) into a pyoxigraph
store, then the loader's own count pattern, then the vendored cm059
build_from_live (the function the seed's screen step runs on the box). Only
the network edges are replaced: the Oxigraph INSERT lands in the in-memory
store, the embedder returns zeros, the Qdrant upsert returns True.

A CONTROL THAT MUST FAIL is built in: the old shape (8 plays of one track)
through the same pipeline must read Neutral and a Like-count of 1. If it ever
reads 2, the instrument cannot see this defect and the green above means
nothing.

Synthetic data only.
"""
from __future__ import annotations

import asyncio
import inspect
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "scripts" / "box_walk_probes" / "lib" / "preference_seed.sh"
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))

import pyoxigraph  # noqa: E402

PWG_NS = "https://schema.ostler.ai/ontology#"


# The loader's count, copied from OS003 gates/seed/load_preference_seed.py
# (_seed_pattern + count_seed_rows). test_the_count_pattern_is_the_loaders
# compares it with the real loader whenever an OS003 checkout is reachable.
def _seed_pattern(subjects):
    return (
        "  ?s a pwg:LikePreference ;\n"
        "     pwg:subject ?subject ;\n"
        "     pwg:category ?category ;\n"
        "     pwg:preferenceStrength ?strength ;\n"
        "     pwg:dataSource ?source .\n"
        "  VALUES ?subject { " + " ".join(json.dumps(s) for s in subjects) + " }\n"
    )


def _bash_lib(snippet: str, env: dict | None = None) -> subprocess.CompletedProcess:
    e = dict(os.environ)
    e.pop("OSTLER_PREF_SEED_FIXTURE_DIR", None)
    e.pop("OSTLER_SEED_DIR", None)
    e.update(env or {})
    return subprocess.run(["/bin/bash", "-c", '. "$1"; ' + snippet, "_", str(LIB)],
                          capture_output=True, text=True, env=e, timeout=60)


def shipped_fixture_root() -> Path:
    """The directory holding preferences/ that the walk would ship, asked of
    the lib. A lib without _ps_fixture_root ships whatever OS003 checkout
    _ps_find_seed_dir resolves (main before this fix)."""
    r = _bash_lib('if type _ps_fixture_root >/dev/null 2>&1; then _ps_fixture_root; '
                  'else _ps_find_seed_dir && printf "%s\\n" "$PREFERENCE_SEED_DIR"; fi')
    out = r.stdout.strip()
    if r.returncode != 0 or not out or not (Path(out) / "preferences" / "preference_fixture.json").is_file():
        pytest.fail("the harness ships no preference fixture this checkout can see "
                    "(rc %d, out %r, err %r)" % (r.returncode, out, r.stderr.strip()[-300:]))
    return Path(out)


def _materialise(fx: dict, src: Path, dest: Path) -> None:
    """The loader's materialise(): copy every export, substituting the
    __ENDTIME_n__ tokens with recent timestamps."""
    now = datetime.now(timezone.utc)
    for name in sorted(os.listdir(src)):
        text = (src / name).read_text(encoding="utf-8")
        for i in range(int(fx.get("plays", 8))):
            stamp = (now - timedelta(days=1 + (i % 21), hours=i)).strftime("%Y-%m-%d %H:%M")
            text = text.replace("__ENDTIME_%d__" % i, stamp)
        assert "__ENDTIME_" not in text, name
        (dest / name).write_text(text, encoding="utf-8")


def _ingest(exports: Path, monkeypatch) -> tuple[pyoxigraph.Store, dict]:
    from services.ingest.src import pipeline as pl

    store = pyoxigraph.Store()
    p = pl.IngestPipeline()

    async def insert_triples(turtle, *a, **k):
        store.load(turtle.encode("utf-8"), format=pyoxigraph.RdfFormat.TURTLE)
        return True

    async def upsert_vectors(*a, **k):
        return True

    monkeypatch.setattr(p.oxigraph, "insert_triples", insert_triples)
    monkeypatch.setattr(p.qdrant, "upsert_vectors", upsert_vectors)
    monkeypatch.setattr(pl.vectorizer, "embed_batch", lambda texts: [[0.0] * 8 for _ in texts])
    result = asyncio.run(p.ingest_directory(exports, "ostler"))
    return store, result


def _rows(store, query):
    res = store.query(query)
    names = [v.value for v in res.variables]
    return [{n: (row[n].value if row[n] is not None else "") for n in names} for row in res]


def _like_count(store, subjects) -> int:
    q = ("PREFIX pwg: <" + PWG_NS + ">\nSELECT (COUNT(DISTINCT ?s) AS ?n) WHERE {\n"
         + _seed_pattern(subjects) + "}")
    return int(_rows(store, q)[0]["n"])


@pytest.fixture()
def seeded(tmp_path, monkeypatch):
    root = shipped_fixture_root()  # before HOME moves: the lib searches under it
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    (tmp_path / "home").mkdir()
    fx = json.loads((root / "preferences" / "preference_fixture.json").read_text(encoding="utf-8"))
    exports = tmp_path / "exports"
    exports.mkdir()
    _materialise(fx, root / "preferences" / fx.get("exports_dir", "exports"), exports)
    store, result = _ingest(exports, monkeypatch)
    return fx, store, result


def test_both_rows_land_as_the_rows_the_loader_counts(seeded):
    fx, store, result = seeded
    subjects = [r["subject"] for r in fx["expect_rows"]]
    print("ingest:", {k: result.get(k) for k in ("total_preferences", "total_filtered", "total_triples")})
    got = _like_count(store, subjects)
    want = int(fx["graph_readback"]["post_count"])
    landed = _rows(store, "PREFIX pwg: <" + PWG_NS + ">\nSELECT ?t ?subject WHERE { ?s a ?t ; pwg:subject ?subject . }")
    assert got == want, ("loader Like-count %d, fixture expects %d. Every row the ingest wrote: %s"
                         % (got, want, sorted((r["t"].rsplit("#", 1)[-1], r["subject"]) for r in landed)))
    q = ("PREFIX pwg: <" + PWG_NS + ">\nSELECT DISTINCT ?subject ?category ?source WHERE {\n"
         + _seed_pattern(subjects) + "}")
    by_subject = {r["subject"]: r for r in _rows(store, q)}
    for expect in fx["expect_rows"]:
        row = by_subject.get(expect["subject"])
        assert row is not None, expect["subject"]
        assert row["category"] == expect["category"], (expect["subject"], row)
        assert row["source"] == expect["source"], (expect["subject"], row)


def test_the_screen_has_a_row_on_each_side_of_the_floor(seeded, monkeypatch):
    fx, store, _ = seeded
    from compiler import interest_profile as ip

    # The box's step-2 compile is build_from_live() with no floor argument, so
    # the floor that matters is compile_profile's default. The fixture's floor
    # (used by the API read-back) must be that same number.
    floor = inspect.signature(ip.compile_profile).parameters["min_confidence"].default
    assert float(fx["compiler"]["min_confidence"]) == floor, (fx["compiler"]["min_confidence"], floor)

    monkeypatch.setattr(ip, "_sparql_select", lambda url, query, timeout=30.0: _rows(store, query))
    prof = ip.build_from_live("http://store.invalid")
    stats = prof["stats"]
    kept = {it["subject"]: it["confidence"] for b in prof["domains"] for it in b["interests"]}
    print("stats:", stats, "kept:", kept, "floor:", floor)
    assert stats["interests"] >= int(fx["compiler"]["expect_interests_at_least"]), stats
    assert stats["suppressed_low_confidence"] >= int(fx["compiler"]["expect_suppressed_low_confidence_at_least"]), stats
    for expect in fx["expect_rows"]:
        if expect["clears_floor"]:
            assert expect["subject"] in kept, (expect["subject"], kept)
            assert kept[expect["subject"]] >= floor
            assert abs(kept[expect["subject"]] - float(expect["measured_confidence"])) < 0.005, kept
        else:
            assert expect["subject"] not in kept, (expect["subject"], kept)


def test_control_the_old_play_shape_is_neutral_and_counts_one(tmp_path, monkeypatch):
    """MUST read 1: the 124/125 shape, through the same instrument."""
    monkeypatch.setenv("HOME", str(tmp_path))
    exports = tmp_path / "exports"
    exports.mkdir()
    now = datetime.now(timezone.utc)
    plays = [{"endTime": (now - timedelta(days=1 + i, hours=i)).strftime("%Y-%m-%d %H:%M"),
              "artistName": "ostler seed ensemble", "trackName": "control nocturne",
              "msPlayed": 214000} for i in range(8)]
    (exports / "StreamingHistory0.json").write_text(json.dumps(plays), encoding="utf-8")
    (exports / "personalization.js").write_text(
        'window.YTD.personalization.part0 = [{"p13nData": {"interests": {"interests": '
        '[{"name": "control cartography", "isDisabled": false}]}}}]', encoding="utf-8")
    store, result = _ingest(exports, monkeypatch)
    subjects = ["ostler seed ensemble - control nocturne", "control cartography"]
    assert result["total_preferences"] == 2 and result["total_filtered"] == 7, result
    assert _like_count(store, subjects) == 1
    neutral = _rows(store, "PREFIX pwg: <" + PWG_NS + ">\nSELECT ?subject WHERE "
                    "{ ?s a pwg:NeutralPreference ; pwg:subject ?subject . }")
    assert [r["subject"] for r in neutral] == ["ostler seed ensemble - control nocturne"]


def test_every_fixture_file_travels_to_the_box(tmp_path):
    """The remote path ships the composed seed: the loader plus EVERY file of
    the fixture the harness carries, captured off the ssh stdin."""
    root = shipped_fixture_root()
    want = sorted(str(p.relative_to(root)) for p in (root / "preferences").rglob("*") if p.is_file())
    os003 = tmp_path / "os003"
    os003.mkdir()
    (os003 / "load_preference_seed.py").write_text("# COUNT(DISTINCT ?s)\n", encoding="utf-8")
    cap = tmp_path / "payload.b64"
    r = _bash_lib(
        '_ps_box_exec_stdin() { cat > "$CAP"; return 0; }; '
        'PREFERENCE_SEED_BUNDLE=; _ps_run_loader "$SEED" --flag; echo "rc=$?"',
        env={"OSTLER_BOX_HOST": "box.invalid", "CAP": str(cap), "SEED": str(os003)})
    assert "rc=0" in r.stdout, (r.stdout, r.stderr)
    import base64
    files = json.loads(base64.b64decode(cap.read_text()))
    assert sorted(files) == sorted(["load_preference_seed.py"] + want), sorted(files)
    for name in want:
        assert files[name] == (root / name).read_text(encoding="utf-8"), name


def test_the_count_pattern_is_the_loaders():
    r = _bash_lib('_ps_find_seed_dir && printf "%s\\n" "$PREFERENCE_SEED_DIR"')
    seed_dir = r.stdout.strip()
    if r.returncode != 0 or not seed_dir:
        pytest.skip("CANNOT-RUN: no OS003 gates/seed checkout reachable from this tree; "
                    "the loader's pattern was not compared")
    import importlib.util
    spec = importlib.util.spec_from_file_location("ostler_pref_loader", Path(seed_dir) / "load_preference_seed.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    subjects = ["a subject", "another"]
    assert mod._seed_pattern(subjects).split() == _seed_pattern(subjects).split()


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v", "-rs"]))
