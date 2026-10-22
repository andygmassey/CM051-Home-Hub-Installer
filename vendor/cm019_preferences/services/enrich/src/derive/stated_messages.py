"""Stated preferences from the owner's own lines in already-extracted conversations.

A second, higher-yield source for the stated-preference reader. CM048 turns a
conversation into a few model-extracted facts; this scans the owner's OWN lines
in the cleaned transcripts CM048 has already written
(``~/Documents/Ostler/Conversations/<date>/<slug>/transcript.md``), with no model,
using the same cue phrases, vocabulary, synonyms and polarity as ``stated.py``.

This is a READ for derive evidence, not a conversation writer: it writes nothing
to any store. It never opens chat.db or ChatStorage.sqlite (no new TCC surface);
it reads only the extracted transcripts.

Same privacy filters as the fact path, taken from what the extracted store
already carries:

- the conversation's ``privacy_level`` frontmatter: only the levels in
  ``allowed_privacy`` (default L0 and L1) are read, so L2 and L3 are skipped;
- chats with a person the owner marked "deceased / stop suggesting" (the
  ``pwg:SuggestionSuppression`` records, matched on identifier and slug). If that
  lookup fails the reader RAISES rather than reading without the filter;
- minors: no minors flag exists on the person in this graph, so a message that
  names a minor is dropped, and a caller can pass ``minor_conversations``.

Attribution: only lines the transcript labels as the owner ("You" by default,
see ``owner_labels``) are read, so a friend's line never counts. A quoted or
forwarded line inside an owner message is not the owner's taste: ``> `` quote
lines and "Forwarded"/"Fwd" blocks are removed, quoted strings are removed, and
the first-person gate rejects "he said he hates coffee". Known false positive:
an owner message that restates someone else's words in the first person without
quotation marks ("as Dave puts it, I hate coffee") is counted.

Output is dimension, value, polarity and counts. No text, no message id: the
evidence points at an opaque hash of the conversation and a month, and the
because line is "you said so in a message".

Repetition is counted per conversation per calendar month, at most three months
per conversation: a taste voiced across a year in one chat counts, fifty
messages in one afternoon do not.
"""

from __future__ import annotations

import hashlib
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Optional, Set, Tuple

from .model import PWG_NS, EvidenceItem
from .stated import STATED_BECAUSE, StatedMapper, mentions_a_minor

MAX_MONTHS_PER_CONVERSATION = 3
DEFAULT_CHANNELS = ("im", "imessage", "whatsapp")
DEFAULT_OWNER_LABELS = ("you", "me")
DEFAULT_ALLOWED_PRIVACY = ("L0", "L1")

ASSISTANT_SEND_PREFIX = "\U0001F916"
ASSISTANT_SEND_MARKER = "⁣⁤⁣"

_QUOTED = re.compile(r"“[^”]*”|\"[^\"]*\"")
_LABEL = re.compile(r"^\*\*(?P<who>[^*]+?)\*\* \((?P<ts>[^)]*)\):[ \t]?(?P<rest>.*)$")
_FORWARD = re.compile(r"^(?:-{2,}\s*)?(?:forwarded|fwd?:|begin forwarded)", re.I)


def conversation_key(raw: str) -> str:
    return hashlib.sha1(("conv|" + (raw or "")).encode()).hexdigest()[:12]


def split_frontmatter(text: str) -> Tuple[str, str]:
    if not text.startswith("---"):
        return "", text
    parts = text.split("---", 2)
    return (parts[1], parts[2]) if len(parts) == 3 else ("", text)


def fm_value(fm: str, key: str) -> str:
    m = re.search(r"^\s*" + re.escape(key) + r":\s*(.*)$", fm, re.M)
    return m.group(1).strip().strip('"').strip("'") if m else ""


def fm_participants(fm: str) -> List[str]:
    block = re.search(r"^participants:\s*\n((?:\s+-.*\n?)+)", fm, re.M)
    return re.findall(r'^\s+-\s*"?([^"\n]+)"?\s*$', block.group(1), re.M) if block else []


def normalise_identifier(v: str) -> str:
    v = (v or "").strip().lower()
    digits = re.sub(r"[^\d]", "", v)
    return digits if digits and re.fullmatch(r"[+\d\s().-]+", v) else v


@dataclass(frozen=True)
class OwnerLine:
    conv: str            # opaque hash of the conversation
    when: Optional[datetime]
    text: str
    src: str


def _parse_ts(v: str) -> Optional[datetime]:
    try:
        d = datetime.fromisoformat((v or "").strip())
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def owner_lines(body: str, owner_labels: Iterable[str]) -> Iterator[Tuple[Optional[datetime], str]]:
    """Yield (timestamp, text) for the lines the transcript labels as the owner."""
    owners = {o.lower() for o in owner_labels}
    cur: Optional[Tuple[str, str, List[str]]] = None
    blocks = []
    for line in body.splitlines():
        m = _LABEL.match(line)
        if m:
            if cur:
                blocks.append(cur)
            cur = (m.group("who").strip(), m.group("ts"), [m.group("rest")])
        elif cur:
            cur[2].append(line)
    if cur:
        blocks.append(cur)
    for who, ts, buf in blocks:
        if who.lower() in owners:
            yield _parse_ts(ts), "\n".join(buf)


def clean_owner_text(text: str) -> str:
    """Drop quoted/forwarded material: it is not the owner's own taste."""
    out, skipping = [], False
    for ln in text.splitlines():
        s = ln.strip()
        if _FORWARD.match(s):
            skipping = True
        if skipping or s.startswith(">"):
            continue
        out.append(ln)
    return _QUOTED.sub(" ", "\n".join(out))


@dataclass
class StatedTranscriptReader:
    """Owner lines in extracted iMessage/WhatsApp transcripts -> stated evidence."""

    gateway: object
    root: Path
    mapper: StatedMapper = field(default_factory=StatedMapper)
    channels: Tuple[str, ...] = DEFAULT_CHANNELS
    owner_labels: Tuple[str, ...] = DEFAULT_OWNER_LABELS
    allowed_privacy: Tuple[str, ...] = DEFAULT_ALLOWED_PRIVACY
    minor_conversations: Set[str] = field(default_factory=set)   # conversation_id values
    dimension: str = "stated.transcripts"
    domain: str = "stated"
    category: str = "stated"
    stats: Counter = field(default_factory=Counter)

    def _suppressed(self) -> Tuple[Set[str], Set[str]]:
        """Identifiers and slugs of people marked deceased / stop-suggesting.

        Raises on a failed lookup: reading without this filter is worse than
        reading nothing, and the engine records a raising reader as FAILED.
        """
        rows = self.gateway.sparql(
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?slug ?idv WHERE { ?s a pwg:SuggestionSuppression .\n"
            "  OPTIONAL { ?s pwg:suppressedSlug ?slug }\n"
            "  OPTIONAL { ?s pwg:suppressedIdentifier ?idv } }"
        )
        slugs = {r["slug"]["value"].lower() for r in rows if r.get("slug")}
        ids = {normalise_identifier(r["idv"]["value"]) for r in rows if r.get("idv")}
        return ids, slugs

    def _lines(self) -> Iterator[OwnerLine]:
        sup_ids, sup_slugs = self._suppressed()
        root = Path(self.root)
        if not root.is_dir():
            self.stats["root_absent"] += 1
            return
        for tpath in sorted(root.glob("*/*/transcript.md")):
            try:
                text = tpath.read_text(errors="ignore")
            except OSError:
                self.stats["unreadable"] += 1
                continue
            fm, body = split_frontmatter(text)
            if fm_value(fm, "channel").lower() not in self.channels:
                continue
            self.stats["conversations_seen"] += 1
            if fm_value(fm, "privacy_level") not in self.allowed_privacy:
                self.stats["skipped_privacy"] += 1
                continue
            cid = fm_value(fm, "conversation_id") or tpath.parent.name
            if cid in self.minor_conversations:
                self.stats["skipped_minor_conversation"] += 1
                continue
            others = [p for p in fm_participants(fm) if p.lower() != "user"]
            others.append(fm_value(fm, "chat_identifier"))
            if any(normalise_identifier(p) in sup_ids or p.lower() in sup_slugs for p in others if p):
                self.stats["skipped_deceased_or_suppressed"] += 1
                continue
            self.stats["conversations_read"] += 1
            key = conversation_key(cid)
            src = fm_value(fm, "channel").lower()
            for when, line in owner_lines(body, self.owner_labels):
                yield OwnerLine(key, when, line, src)

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        cell: Dict[Tuple[str, str, str, str], Tuple[float, str]] = {}
        for ol in self._lines():
            self.stats["owner_lines"] += 1
            text = ol.text
            if ASSISTANT_SEND_MARKER in text or text.lstrip().startswith(ASSISTANT_SEND_PREFIX):
                self.stats["skipped_assistant"] += 1
                continue
            if mentions_a_minor(text):
                self.stats["skipped_minor_mention"] += 1
                continue
            stances = self.mapper.parse_message(clean_owner_text(text))
            if not stances:
                continue
            self.stats["cue_hits"] += 1
            month = ol.when.strftime("%Y-%m") if ol.when else "0000-00"
            for st in stances:
                k = (ol.conv, month, st.dimension, st.value)
                if k not in cell or abs(st.strength) > abs(cell[k][0]):
                    cell[k] = (st.strength, ol.src)
        per: Dict[Tuple[str, str, str], List[Tuple[float, str, str]]] = {}
        for (conv, month, dim, val), (strength, src) in cell.items():
            per.setdefault((conv, dim, val), []).append((strength, month, src))
        for (conv, dim, val), rows in sorted(per.items()):
            rows.sort(key=lambda r: (-abs(r[0]), r[1]))
            for strength, month, src in rows[:MAX_MONTHS_PER_CONVERSATION]:
                self.stats["evidence_negative" if strength < 0 else "evidence_positive"] += 1
                pid = hashlib.sha1(f"tr|{conv}|{month}|{dim}|{val.lower()}".encode()).hexdigest()[:16]
                try:
                    observed = datetime.strptime(month, "%Y-%m").replace(tzinfo=timezone.utc)
                except ValueError:
                    observed = None
                yield EvidenceItem(
                    preference_id=pid,
                    user_id=user_id,
                    domain=dim.rsplit(".", 1)[0],
                    dimension=dim,
                    value=val,
                    value_qid=None,
                    item_strength=strength,
                    polarity_source="stated",
                    source="stated:" + src,
                    observed_at=observed,
                    enrichment_confidence=0.8,
                    raw_subject=STATED_BECAUSE,
                    provenance=f"urn:ostler:message-scan:{conv}:{month}",
                )
