#!/usr/bin/env python3
"""The owner's own lines in extracted iMessage/WhatsApp transcripts reach the derive engine.

Drives the VENDORED tree through build_readers (as derive_runner does) over
synthetic CM048 transcripts. Reads only transcripts: no message database is
opened. Synthetic text only.

  arm 1  filter L2/L3: conversations at L2 and L3 are skipped (L1 control reads).
  arm 2  filter deceased: a conversation with a suppressed contact is skipped; a
         failed suppression lookup RAISES instead of reading unfiltered.
  arm 3  filter minors: a minor conversation and a minor mention are skipped.
  arm 4  owner-only: a friend's line never counts; "he said he hates coffee",
         a "> " quote, a forwarded block and a quoted string are not the owner's.
  arm 5  coffee x3 beats x1; Cantonese negative, Sichuan positive.
  arm 6  counts and polarity only: no text and no conversation/message id in the
         evidence or the derived node; because is "you said so in a message".
  arm 7  MUTANT: with the registry row dropped the source disappears.
  arm 8  the module never opens a message database.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
for p in (SRC / "derive" / "stated_messages.py",):
    if not p.is_file():
        print(f"FAIL: {p.relative_to(REPO)} is not in the vendored tree")
        sys.exit(1)
try:
    import yaml
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyyaml")
    sys.exit(2)
sys.path.insert(0, str(TREE / "services" / "common"))
sys.path.insert(0, str(SRC))
from derive import stated_messages as sm  # noqa: E402
from derive.config import READERS_YAML, build_readers, load_dimensions  # noqa: E402
from derive.engine import Aggregator  # noqa: E402
from derive.stated import STATED_BECAUSE  # noqa: E402

NOW = datetime(2026, 10, 22, tzinfo=timezone.utc)
PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


class Gateway:
    def __init__(self, suppressed=(), fail=False):
        self.rows = [{"idv": {"value": v}} for v in suppressed]
        self.fail = fail

    def sparql(self, q):
        if self.fail:
            raise ConnectionError("down")
        return self.rows


class Store:
    def __init__(self, root):
        self.root, self.n = Path(root), 0

    def chat(self, lines, privacy="L1", handle="+15550100", cid=None):
        self.n += 1
        cid = cid or f"conv{self.n}"
        d = self.root / "2026-09-01" / f"slug-{self.n}"
        d.mkdir(parents=True)
        body = "\n".join(f"**{w}** (2026-09-01T10:00:00+00:00): {t}" for w, t in lines)
        (d / "transcript.md").write_text(
            f'---\nconversation_id: {cid}\nchannel: "im"\nprivacy_level: {privacy}\n'
            f'participants:\n  - "user"\n  - "{handle}"\nextra:\n  chat_identifier: "{handle}"\n---\n\n{body}\n')
        return cid

    def reader(self, gw=None, **kw):
        return sm.StatedTranscriptReader(gw or Gateway(), self.root, **kw)


def run(reader):
    items = list(reader.read("ostler"))
    nodes = {(n.dimension, n.subject): n for n in Aggregator(load_dimensions()).aggregate(items, now=NOW)}
    return items, nodes


def fresh():
    return Store(tempfile.mkdtemp())


def main():
    print("arm 1: privacy")
    s = fresh(); s.chat([("You", "I hate coffee")], "L2"); s.chat([("You", "I hate coffee")], "L3")
    r = s.reader()
    check(run(r)[0] == [] and r.stats["skipped_privacy"] == 2, "L2 and L3 skipped")
    s.chat([("You", "I hate coffee")], "L1")
    check(len(run(s.reader())[0]) == 1, "control: L1 reads")

    print("arm 2: deceased / suppressed")
    s = fresh(); s.chat([("You", "I hate coffee")], handle="+44 7700 900123"); s.chat([("You", "I love jazz")], handle="+15550199")
    items, _ = run(s.reader(Gateway(["+447700900123"])))
    check([i.value for i in items] == ["Jazz"], "the suppressed contact's chat is skipped, the other read")
    raised = False
    try:
        list(s.reader(Gateway(fail=True)).read("x"))
    except ConnectionError:
        raised = True
    check(raised, "a failed suppression lookup raises, never reads unfiltered")

    print("arm 3: minors")
    s = fresh(); flagged = s.chat([("You", "I hate coffee")])
    s.chat([("You", "my daughter and I hate coffee")]); s.chat([("You", "my 9 year old loves pizza")])
    r = s.reader(minor_conversations={flagged})
    check(run(r)[0] == [] and r.stats["skipped_minor_conversation"] == 1 and r.stats["skipped_minor_mention"] == 2,
          "minor conversation and mentions skipped")

    print("arm 4: owner-only")
    s = fresh(); s.chat([("Dave", "I hate coffee"), ("+15550100", "I love jazz")])
    check(run(s.reader())[0] == [], "a friend's line never counts")
    for text in ("he said he hates coffee", "> I hate coffee", "Forwarded message:\nI hate coffee",
                 'Dave wrote "I hate coffee"', "Dave told me he can't stand jazz"):
        s = fresh(); s.chat([("You", text)])
        check(run(s.reader())[0] == [], f"not the owner's taste: {text.splitlines()[0][:30]!r}")
    s = fresh(); s.chat([("Dave", "I hate coffee"), ("You", "I love jazz")])
    check([i.value for i in run(s.reader())[0]] == ["Jazz"], "control: the owner's own line counts")

    print("arm 5: repetition and polarity")
    s3 = fresh()
    for i in range(3):
        s3.chat([("You", "I hate coffee")], handle=f"+1555010{i}")
    s1 = fresh(); s1.chat([("You", "I hate coffee")])
    n3, n1 = run(s3.reader())[1], run(s1.reader())[1]
    c3, c1 = n3.get(("food.drink", "Coffee")), n1.get(("food.drink", "Coffee"))
    check(c3 is not None and c1 is not None and c3.preference_strength < 0 and c3.confidence > c1.confidence,
          "three conversations are more confident than one, negative")
    s = fresh(); s.chat([("You", "Not really a fan of Cantonese, love Sichuan though")])
    n = run(s.reader())[1]
    check(n.get(("food.cuisine", "Cantonese")) is not None and n[("food.cuisine", "Cantonese")].preference_strength < 0
          and n.get(("food.cuisine", "Sichuan")) is not None and n[("food.cuisine", "Sichuan")].preference_strength > 0,
          "Cantonese negative, Sichuan positive")

    print("arm 6: counts and polarity only")
    s = fresh(); s.chat([("You", "Honestly I absolutely hate coffee, the office machine ruins every morning")], cid="conv-secret-1")
    items, nodes = run(s.reader())
    node = nodes.get(("food.drink", "Coffee"))
    blob = repr(items) + (node.to_turtle() if node else "")
    check(node is not None and not any(f in blob for f in ("office machine", "ruins every", "absolutely hate", "conv-secret", "slug-")),
          "no text and no conversation id in the evidence or the node")
    check(node is not None and node.evidence_titles == [STATED_BECAUSE] and STATED_BECAUSE == "you said so in a message",
          "because line is fixed")
    check(all(re.fullmatch(r"urn:ostler:message-scan:[0-9a-f]{12}:\d{4}-\d{2}", i.provenance) for i in items),
          "provenance is an opaque hash and a month")

    print("arm 7: MUTANT, registry row dropped")
    rows = yaml.safe_load(Path(READERS_YAML).read_text())
    check(any(r["kind"] == "stated_transcripts" for r in rows), "the shipped registry carries the row")
    with tempfile.TemporaryDirectory() as d:
        mp = Path(d) / "readers.yaml"
        mp.write_text(yaml.safe_dump([r for r in rows if r["kind"] != "stated_transcripts"]))
        check(not any(isinstance(x, sm.StatedTranscriptReader) for x in build_readers(Gateway(), path=mp)),
              "without the row there is no transcript reader")
    check(any(isinstance(x, sm.StatedTranscriptReader) for x in build_readers(Gateway())), "with it there is")

    print("arm 8: no message database")
    src = (SRC / "derive" / "stated_messages.py").read_text()
    check("sqlite3" not in src and "import sqlite" not in src, "stated_messages.py does not import sqlite")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
