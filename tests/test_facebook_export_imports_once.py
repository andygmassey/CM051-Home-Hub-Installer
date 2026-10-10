"""F6 (Ostler DMG #16 console walk): one Facebook export, imported twice,
left people on two nodes.

WHAT THE BOX SHOWED. ``~/Downloads/01 - Facebook`` held the same export
twice: the archive extracted into ``facebook-<user>-<date>-<id>/`` AND the
same archive's contents extracted flat beside it. The detector reported both
``.../connections/friends`` folders, install.sh handed both roots to
``ostler-import``, and ``contact_syncer.import_all`` ran once per root, so
"Importing 897 Facebook friends..." printed twice (run 1: 517 matched / 380
created; run 2: 897 matched / 0 created). Run 2 resolved every friend again by
FUZZY NAME, and wherever another node with the same name had appeared since
run 1 (a Messenger correspondent from the universal importer, which runs
between the two roots), the friendship attached to THAT node instead: 1152
facebook_friend signals on 1152 nodes for 897 friends.

Two defects, two arms:

1. ONCE PER RUN. The same export bytes reached through two roots are imported
   once. Driven through the REAL entry point: the ``ostler-import`` heredoc
   carved out of install.sh, calling the VENDORED ``contact_syncer.import_all``
   (the tree that ships) against a real HTTP Oxigraph (pyoxigraph).
2. IDEMPOTENT. Importing the same friend again (a later watcher run, a
   re-install) attaches to the node that already carries that friendship,
   never to a second node, even when a same-named node now competes for the
   fuzzy match.

Controls: a DIFFERENT export in the second root is still imported (the
dedupe keys on content, not on "Facebook was seen"); and the counting
predicate reports a hand-planted duplicate, so a green count is not a counter
that cannot see one.

All names are synthetic cast tokens (.pii-name-registry.tsv).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
VENDOR = REPO_ROOT / "vendor" / "cm041"
INSTALL_SH = REPO_ROOT / "install.sh"
sys.path.insert(0, str(HERE))

from _fake_oxigraph import FakeOxigraph  # noqa: E402

# Synthetic cast names chosen so that no two score >= 0.85 Jaro-Winkler
# against each other: below the resolver's fuzzy floor, so every friend is a
# distinct person and the expected node count is exactly the friend count.
_CAST = [
    "Jane Doe", "Jane Smith", "John Jones", "John Patel", "Bob Doe", "Bob Smith",
    "Bob Stewart", "Robert Doe", "Alex Doe", "Mary Doe", "Mary Smith", "Raj Doe",
    "Raj Stewart", "Liz Doe", "Liz Smith", "Liz Stewart", "Elizabeth Doe",
    "Sam Doe", "Sam Stewart", "Jonathan Doe", "Ana Doe", "Ben Doe", "Carl Doe",
    "Tom Doe", "Tom Smith", "Zhang Doe", "Zhang Smith", "Wang Jones",
    "Wang Patel", "Wei Doe", "Min Doe", "Li Jones", "Li Ross", "Li Patel",
]
FRIENDS = [
    {"name": n, "timestamp": 1300000000 + 86400 * i} for i, n in enumerate(_CAST[:30])
]
OTHER_FRIENDS = [
    {"name": n, "timestamp": 1500000000 + 86400 * i} for i, n in enumerate(_CAST[30:])
]

FB_NODES = (
    "SELECT ?p ?n WHERE { ?p pwg:hasSignal ?s . ?s pwg:signalType \"facebook_friend\" . "
    "OPTIONAL { ?p pwg:displayName ?n } }"
)


def _carve_ostler_import(dest: Path) -> None:
    text = INSTALL_SH.read_text(encoding="utf-8").splitlines()
    opener = "cat > \"$IMPORT_SCRIPT\" <<'IMPORTEOF'"
    start = next(i for i, ln in enumerate(text) if ln.strip() == opener)
    end = next(i for i in range(start + 1, len(text)) if text[i] == "IMPORTEOF")
    dest.write_text("\n".join(text[start + 1:end]) + "\n", encoding="utf-8")
    dest.chmod(0o755)


def _write_export(path: Path, friends) -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "your_friends.json").write_text(
        json.dumps({"friends_v2": friends}, indent=2), encoding="utf-8"
    )


@pytest.fixture()
def box(tmp_path):
    store = FakeOxigraph()
    home = tmp_path / "home"
    ostler = home / ".ostler"
    pipe = ostler / "import-pipeline"
    (pipe / ".venv" / "bin").mkdir(parents=True)
    (ostler / "bin").mkdir(parents=True)
    (ostler / "config").mkdir(parents=True)
    # The pipeline dir exactly as install.sh stages it: the vendored CM041
    # packages at its root.
    for child in VENDOR.iterdir():
        if child.name in ("tests",):
            continue
        (pipe / child.name).symlink_to(child)
    py = pipe / ".venv" / "bin" / "python3"
    py.write_text(f"#!/bin/sh\nexec {sys.executable} \"$@\"\n")
    py.chmod(0o755)
    (ostler / "config" / ".env").write_text('USER_ID=""\nUSER_NAME="Jane Doe"\n')
    imp = ostler / "bin" / "ostler-import"
    _carve_ostler_import(imp)

    env = {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "OXIGRAPH_URL": store.url,
        # Unreachable on purpose: the embed + vector legs fail fast and are
        # caught inside the importer; the graph is what this test reads.
        "QDRANT_URL": "http://127.0.0.1:9",
        "EMBED_OLLAMA_URL": "http://127.0.0.1:9",
        "DEFAULT_COUNTRY_CODE": "44",
        "OSTLER_FORGET_TOMBSTONE_FILE": str(tmp_path / "forgotten.json"),
        "OSTLER_STATE_DIR": str(tmp_path / "state"),
        "PYTHONDONTWRITEBYTECODE": "1",
    }

    def run(*roots: Path) -> str:
        r = subprocess.run(
            [str(imp), *map(str, roots)], env=env, capture_output=True,
            text=True, timeout=600,
        )
        out = r.stdout + r.stderr
        assert r.returncode == 0, out[-3000:]
        return out

    downloads = home / "Downloads" / "01 - Facebook"
    yield type("Box", (), {"store": store, "run": staticmethod(run), "dl": downloads,
                           "tmp": tmp_path})
    store.close()


def _fb_nodes(store) -> dict[str, set[str]]:
    """name -> set of nodes carrying a facebook_friend signal."""
    with store.lock:
        rows = store.ds.query(
            "PREFIX pwg: <https://schema.ostler.ai/ontology#>\n" + FB_NODES
        )
        out: dict[str, set[str]] = {}
        for r in rows:
            name = r["n"].value if r["n"] is not None else ""
            out.setdefault(name, set()).add(r["p"].value)
    return out


def _runs(out: str) -> list[int]:
    return [int(n) for n in re.findall(r"Importing (\d+) Facebook friends", out)]


def _report(label, out, store, expected):
    nodes = _fb_nodes(store)
    n_nodes = len(set().union(*nodes.values())) if nodes else 0
    dup = sorted(n for n, s in nodes.items() if len(s) > 1)
    print(f"{label}: runs={_runs(out)} fb_nodes={n_nodes} friends={expected} "
          f"names_on_2plus_nodes={len(dup)}")
    return n_nodes, dup


def test_same_export_under_two_roots_is_imported_once(box):
    # Andy's layout: the archive extracted into its own folder AND flat.
    nested = box.dl / "facebook-synthetic-01_01_2026-AbCdEf" / "connections"
    flat = box.dl / "connections"
    _write_export(nested / "friends", FRIENDS)
    _write_export(flat / "friends", FRIENDS)

    out = box.run(nested, flat)
    n_nodes, dup = _report("two roots, one export", out, box.store, len(FRIENDS))

    assert _runs(out) == [len(FRIENDS)], (
        f"the same your_friends.json was imported {len(_runs(out))} times: {_runs(out)}")
    assert n_nodes == len(FRIENDS) and not dup, (n_nodes, dup[:5])


def test_reimport_attaches_to_the_same_node(box):
    root = box.dl / "connections"
    _write_export(root / "friends", FRIENDS)
    box.run(root)
    before = _fb_nodes(box.store)
    assert len(before) == len(FRIENDS)

    # Between imports, a same-named node arrives from another source (on the
    # box: Messenger correspondents persisted by the universal importer, which
    # runs between the two roots). It carries no Facebook signal.
    for i, f in enumerate(FRIENDS):
        box.store.update(
            f"INSERT DATA {{ <https://schema.ostler.ai/ontology#person_000000mess{i:03d}> "
            f"a pwg:Person ; pwg:displayName \"{f['name']}\" ; "
            f"pwg:contactType \"person\" . }}"
        )

    out = box.run(root)  # a second, separate run: a re-install or watcher pass
    n_nodes, dup = _report("re-import with same-named competitors", out, box.store,
                           len(FRIENDS))
    after = _fb_nodes(box.store)
    moved = [n for n in before if after.get(n) != before[n]]
    assert not moved and n_nodes == len(FRIENDS), (
        f"{len(moved)} friends gained a second Facebook node on re-import "
        f"({n_nodes} nodes for {len(FRIENDS)} friends)")


def test_control_a_different_export_in_the_second_root_is_still_imported(box):
    a = box.dl / "connections"
    b = box.dl / "second-account" / "connections"
    _write_export(a / "friends", FRIENDS)
    _write_export(b / "friends", OTHER_FRIENDS)

    out = box.run(a, b)
    n_nodes, dup = _report("CONTROL two distinct exports", out, box.store,
                           len(FRIENDS) + len(OTHER_FRIENDS))
    assert _runs(out) == [len(FRIENDS), len(OTHER_FRIENDS)], _runs(out)
    assert n_nodes == len(FRIENDS) + len(OTHER_FRIENDS) and not dup


def test_control_the_counter_sees_a_planted_duplicate(box):
    root = box.dl / "connections"
    _write_export(root / "friends", FRIENDS)
    box.run(root)
    name = FRIENDS[0]["name"]
    box.store.update(
        "INSERT DATA { <https://schema.ostler.ai/ontology#person_plantedcopy1> a pwg:Person ; "
        f"pwg:displayName \"{name}\" ; pwg:hasSignal "
        "<https://schema.ostler.ai/ontology#signal_plantedcopy1_facebook_friend> . "
        "<https://schema.ostler.ai/ontology#signal_plantedcopy1_facebook_friend> "
        "pwg:signalType \"facebook_friend\" . }"
    )
    nodes = _fb_nodes(box.store)
    assert len(nodes[name]) == 2
    assert len(set().union(*nodes.values())) == len(FRIENDS) + 1
