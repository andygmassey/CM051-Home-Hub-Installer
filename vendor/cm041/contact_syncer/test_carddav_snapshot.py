"""A PUT into the customer's address book must be undoable.

WHAT WAS MEASURED, 2026-08-21, before this existed:

    carddav.put_vcard             a real HTTP PUT to the customer's CardDAV
                                  server -- propagates to every device
    called from                   linkedin_connections.py:778 (live, not dry-run)
    reached on install via        install.sh:14422  contact_syncer.import_all
    backup of the customer's contacts, anywhere in the shipping tree:   NONE

Searched backup / snapshot / export / preserve across vendor/ and install.sh.
The twelve "backup" hits in install.sh are Time Machine EXCLUSIONS, the
Oxigraph graph backup, and vault-passphrase notes. The graph backup protects
OUR data. Nothing protected theirs.

Andy had been told this safety net existed. It did not. These tests are what
make that statement true rather than intended.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from contact_syncer.carddav import CardDAVClient  # noqa: E402

ORIGINAL = "BEGIN:VCARD\nVERSION:3.0\nFN:A Person\nEND:VCARD\n"
MODIFIED = "BEGIN:VCARD\nVERSION:3.0\nFN:A Person\nTITLE:Added\nEND:VCARD\n"
HREF = "/addressbooks/user/default/abc123.vcf"


class _Client(CardDAVClient):
    """Real snapshot code, no network. Records what would have been PUT."""

    def __init__(self, *, current=ORIGINAL, get_raises=False):
        self.url, self.username, self.password = "https://example/", "u", "p"
        self._auth = None
        self._current = current
        self._get_raises = get_raises
        self.puts = []

    def get_vcard(self, href):
        if self._get_raises:
            raise RuntimeError("server unreachable")
        return self._current

    def _request(self, method, url=None, **kw):
        self.puts.append((method, kw.get("content")))
        return None


def _fresh(tmp):
    CardDAVClient._snapshot_dir = None
    os.environ["OSTLER_DIR"] = tmp


def test_the_original_is_on_disk_before_the_put_lands():
    """THE POINT. Without this there is no undo."""
    with tempfile.TemporaryDirectory() as tmp:
        _fresh(tmp)
        c = _Client()
        c.put_vcard(HREF, MODIFIED, "etag-1")

        d = CardDAVClient._snapshot_dir
        cards = [f for f in os.listdir(d) if f.endswith(".vcf")]
        assert len(cards) == 1, f"expected one snapshot, found {cards}"
        saved = open(os.path.join(d, cards[0]), encoding="utf-8").read()
        assert saved == ORIGINAL, (
            "the snapshot is not the ORIGINAL card. If this holds the MODIFIED "
            "text, the backup is of the thing we were about to write and the "
            "undo restores the damage."
        )
        assert c.puts and c.puts[0][0] == "PUT", "the PUT did not happen"


def test_a_failed_snapshot_BLOCKS_the_write():
    """🔴 THE ONE THAT MATTERS MOST.

    A snapshot that swallows its error is worse than none: the PUT proceeds,
    the run reports success, and the undo silently does not exist. Same shape
    as a guard that cannot go red.
    """
    with tempfile.TemporaryDirectory() as tmp:
        _fresh(tmp)
        c = _Client(get_raises=True)
        try:
            c.put_vcard(HREF, MODIFIED, "etag-1")
        except Exception:
            assert c.puts == [], "the PUT ran anyway after the snapshot failed"
            return
        raise AssertionError(
            "put_vcard returned normally with no snapshot saved — the "
            "customer's card would have been overwritten with no undo"
        )


def test_the_first_snapshot_of_a_contact_wins():
    """Two edits in one run must not collapse. The FIRST is the pre-Ostler
    state and it is the one worth keeping."""
    with tempfile.TemporaryDirectory() as tmp:
        _fresh(tmp)
        c = _Client()
        c.put_vcard(HREF, MODIFIED, "etag-1")
        c._current = MODIFIED           # server now holds our edit
        c.put_vcard(HREF, MODIFIED + "X", "etag-2")

        d = CardDAVClient._snapshot_dir
        cards = [f for f in os.listdir(d) if f.endswith(".vcf")]
        assert len(cards) == 1
        assert open(os.path.join(d, cards[0]), encoding="utf-8").read() == ORIGINAL


def test_the_manifest_says_enough_to_restore():
    with tempfile.TemporaryDirectory() as tmp:
        _fresh(tmp)
        _Client().put_vcard(HREF, MODIFIED, "etag-1")
        line = open(os.path.join(CardDAVClient._snapshot_dir, "manifest.jsonl"),
                    encoding="utf-8").readline()
        rec = json.loads(line)
        for field in ("href", "file", "sha256", "bytes", "saved_at"):
            assert field in rec, f"manifest cannot drive a restore without {field}"
        assert rec["href"] == HREF, "without the href nobody knows where to PUT it back"


def test_no_partial_file_survives():
    """A reader must never find a half-written card and treat it as the backup."""
    with tempfile.TemporaryDirectory() as tmp:
        _fresh(tmp)
        _Client().put_vcard(HREF, MODIFIED, "etag-1")
        leftovers = [f for f in os.listdir(CardDAVClient._snapshot_dir)
                     if f.endswith(".partial")]
        assert leftovers == [], leftovers


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok   {name}")
            except AssertionError as exc:
                failed += 1
                print(f"  FAIL {name}: {exc}")
    print(f"\n{'FAILED' if failed else 'PASSED'}: {failed} failing")
    sys.exit(1 if failed else 0)
