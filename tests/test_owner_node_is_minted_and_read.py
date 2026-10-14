"""pwg:isOwner has a writer, and now install.sh calls it (walk #27, shape S1).

contact_syncer/owner_node.py mints the owner anchor
``pwg:user_<id> a pwg:Person ; pwg:isOwner true ; pwg:displayName <name>``.
Nothing in install.sh ever ran it, so on the walk box the predicate had 0
triples and every reader ran blind:

  lib/ostler-confirm-identity.py      looks up the owner by user_<id> or
                                      isOwner; with neither it proposes nothing
  generate_pwg_context._owner_uris    isOwner arm
  ical-server._load_people_list_self_uris   "unconfirmed as ever minted"

Three things are asserted:

  1. install.sh runs the writer, after the contacts sync, non-fatally, with the
     id and name it asked the owner for;
  2. once written, the reader that depends on it (confirm-identity) gets the
     owner row, and before it is written it does not (the control);
  3. the batch identity resolver never offers the anchor as an auto-merge
     candidate. It carries only the owner's name, so exact_name (0.9, over the
     0.8 auto threshold) would pair it with the owner's own contact card, and
     the CONTROL below shows exactly that pair being found for an identical
     node that is not flagged isOwner.

Real pyoxigraph engine behind a socket (tests/_fake_oxigraph.py). Cast names.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import httpx
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT))                      # contact_syncer (root copy ships)
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))  # identity_resolver

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from contact_syncer import owner_node  # noqa: E402
from identity_resolver import batch_resolver as br  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "ostler_confirm_identity", ROOT / "lib" / "ostler-confirm-identity.py")
ci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ci)

USER_ID = "jo"
OWNER = owner_node.owner_uri(USER_ID)
CARD = "urn:test:person:owner-card"


# ---------------------------------------------------------------------------
# 1. install.sh calls the writer.
# ---------------------------------------------------------------------------

def _install_lines():
    return (ROOT / "install.sh").read_text().splitlines()


def test_install_runs_the_owner_writer_after_the_contacts_sync():
    lines = _install_lines()
    sync = [i for i, l in enumerate(lines)
            if '"$_HYDRATE_PIPELINE_PY" -m contact_syncer.syncer' in l]
    mint = [i for i, l in enumerate(lines)
            if re.search(r'-m contact_syncer\.owner_node\b', l) and not l.lstrip().startswith("#")]
    assert len(sync) == 1, sync
    assert len(mint) == 1, "install.sh has no call site for contact_syncer.owner_node"
    assert mint[0] > sync[0], "the owner node must be minted after the contacts sync"
    block = "\n".join(lines[mint[0] - 2: mint[0] + 4])
    assert '--user-id "$USER_ID"' in block and '--display-name "$USER_NAME"' in block, block
    # Non-fatal: the call is the condition of an `if`, never a bare command
    # that `set -e` could turn into an install abort.
    assert lines[mint[0]].lstrip().startswith("if ("), lines[mint[0]]


# ---------------------------------------------------------------------------
# 2. Once written, the reader gets the owner; before, it does not.
# ---------------------------------------------------------------------------

@pytest.fixture
def ox():
    store = FakeOxigraph()
    store.update(f"""
    INSERT DATA {{
      <{CARD}> a pwg:Person ; pwg:displayName "Jane Doe" .
      <urn:test:person:frag> a pwg:Person ; pwg:displayName "Jane Doe" .
    }}""")
    yield store
    store.close()


def _owner_from_reader(url):
    by_uri = ci.build_candidates(ci.fetch_rows(url), ci.owner_uri(USER_ID))
    return by_uri.get(ci.owner_uri(USER_ID))


def test_control_without_the_writer_confirm_identity_has_no_owner(ox):
    assert _owner_from_reader(ox.url) is None


def test_after_the_writer_confirm_identity_reads_the_owner(ox):
    owner_node.write_owner_node(ox.url, USER_ID, "Jane Doe")
    owner = _owner_from_reader(ox.url)
    assert owner is not None, "confirm-identity still cannot see the owner"
    assert owner["is_owner"] is True
    assert owner["name"] == "Jane Doe"
    assert ox.ask(f"ASK {{ <{OWNER}> pwg:isOwner true }}")


# ---------------------------------------------------------------------------
# 3. The batch resolver never auto-merges the anchor.
# ---------------------------------------------------------------------------

def _persons(url):
    with httpx.Client(timeout=10.0, trust_env=False) as client:
        return br._fetch_all_persons(url, client, dict(br.DEFAULT_CONFIG))


def _pairs(persons):
    return {frozenset((m.uri_a, m.uri_b))
            for m in br.detect_exact_name_matches(persons, dict(br.DEFAULT_CONFIG))}


def test_the_owner_anchor_is_never_an_auto_merge_candidate(ox):
    owner_node.write_owner_node(ox.url, USER_ID, "Jane Doe")
    persons = _persons(ox.url)
    assert OWNER not in persons
    assert CARD in persons
    assert not any(OWNER in p for p in _pairs(persons))


def test_control_the_same_node_without_isowner_is_paired_by_exact_name(ox):
    # Identical anchor shape minus the flag: exact_name finds it. This is the
    # merge the filter prevents, and it proves the predicate can see a pair.
    plain = "urn:test:person:unflagged-anchor"
    ox.update(f'INSERT DATA {{ <{plain}> a pwg:Person ; pwg:displayName "Jane Doe" . }}')
    pairs = _pairs(_persons(ox.url))
    assert any(plain in p for p in pairs), pairs
