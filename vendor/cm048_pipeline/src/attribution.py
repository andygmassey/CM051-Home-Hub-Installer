"""Facts about someone else must carry that person as the subject.

DMG #27 walk: the assistant summarised real messages about ANOTHER person's
family event as concerning the owner's own parent. The fact extractor (a local
model) labels a first-person line with ``subject: "user"`` whoever said it:
"my dad's ..." written by the other participant reads, to the model, like the
owner talking. Nothing downstream checked who actually said the evidence line,
so the fact was stored about the owner and repeated back as the owner's own
family news.

This is a deterministic post-check on the model's output, run after
``_fix_speaker_subjects``. It only ever moves a fact AWAY from the owner, and
only on evidence it can read in the transcript:

1. SPEAKER. A ``subject: "user"`` fact whose ``evidence`` is found in exactly
   one speaker's turns, that speaker being a known NON-owner participant, and
   whose evidence speaks in the first person ("I", "my", "me") without
   addressing the listener ("you", "your"). The speaker is the person
   concerned: the subject becomes ``other:<their id>``.

2. THE PERSON CONCERNED, named by the owner. A ``subject: "user"`` fact whose
   evidence is the OWNER's line but names another participant's relative
   ("Bob's dad", "Bob's mum"). The fact is about that participant's family:
   the subject becomes ``other:<their id>``.

In both cases, where the fact TEXT names the owner (their display name, or
"the user") and does not already name the person concerned, the owner's name
is replaced by that person's, so the sentence the assistant reads back says
the same thing as the subject. Anything ambiguous (evidence not found, found
under two speakers, an unknown speaker label, second-person wording) is left
exactly as the model produced it.
"""
from __future__ import annotations

import logging
import re
from typing import Iterable, List, Optional, Tuple

from .participants import normalise_participants

logger = logging.getLogger(__name__)

# Speaker headers the three producers write:
#   iMessage  "**Name** (ts): body"
#   WhatsApp  "**Name** (ts):" then the body on the next lines
#   gateway   "**label:** body"
_HEADER = re.compile(
    r"^\*\*(?P<a>[^*\n]+?)\*\*(?:\s*\([^)\n]*\))?:\s?(?P<ra>.*)$"
    r"|^\*\*(?P<b>[^*\n]+?):\*\*\s?(?P<rb>.*)$"
)
_FIRST_PERSON = re.compile(r"\b(i|i'm|i've|i'd|i'll|my|me|mine|myself)\b", re.I)
_SECOND_PERSON = re.compile(r"\b(you|your|yours|you're|you've|yourself)\b", re.I)
_RELATIVES = (
    "dad", "father", "mum", "mom", "mother", "parents", "brother", "sister",
    "son", "daughter", "wife", "husband", "partner", "grandad", "grandfather",
    "grandma", "granny", "grandmother", "uncle", "aunt", "auntie", "cousin",
    "family", "nephew", "niece", "kids", "children",
)
_EVIDENCE_PREFIX = re.compile(r"^\s*[^:\"]{1,60}?\b(said|says|wrote|writes)\s*:\s*", re.I)


def _norm(s: str) -> str:
    s = s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    return re.sub(r"\s+", " ", s).strip().strip('"').strip().lower()


def speaker_turns(transcript: str) -> List[Tuple[str, str]]:
    """[(speaker_label, text)] in order. Continuation lines join the open turn."""
    turns: List[Tuple[str, List[str]]] = []
    for line in (transcript or "").splitlines():
        m = _HEADER.match(line)
        if m:
            label = (m.group("a") or m.group("b") or "").strip()
            rest = m.group("ra") if m.group("a") else m.group("rb")
            turns.append((label, [rest or ""]))
        elif turns:
            turns[-1][1].append(line)
    return [(label, _norm(" ".join(parts))) for label, parts in turns]


def _evidence_core(evidence: str) -> str:
    return _norm(_EVIDENCE_PREFIX.sub("", evidence or "", count=1))


def speaker_of(evidence: str, turns: Iterable[Tuple[str, str]]) -> Optional[str]:
    """The single speaker whose turns contain the evidence, else None."""
    core = _evidence_core(evidence)
    if len(core) < 8:
        return None
    labels = {label for label, text in turns if core in text}
    return next(iter(labels)) if len(labels) == 1 else None


def _participant_for(label: str, participants: List[dict]) -> Optional[dict]:
    want = _norm(label)
    for p in participants:
        for key in ("display", "id", "handle"):
            v = p.get(key)
            if isinstance(v, str) and v.strip() and _norm(v) == want:
                return p
    return None


def _is_owner_label(label: str, participants: List[dict]) -> bool:
    if _norm(label) == "you":
        return True
    p = _participant_for(label, participants)
    return bool(p) and p.get("role") == "user"


def _rewrite_text(text: str, owner_names: List[str], other_display: str) -> str:
    """Replace the owner's name in ``text`` with the person concerned's,
    unless the text already names that person."""
    if not other_display or other_display.split()[0].lower() in text.lower():
        return text
    out = text
    for name in sorted({n for n in owner_names if n}, key=len, reverse=True):
        out = re.sub(rf"\b{re.escape(name)}\b", other_display, out)
    out = re.sub(r"\b[Tt]he user's\b", f"{other_display}'s", out)
    out = re.sub(r"\b[Tt]he user\b", other_display, out)
    out = re.sub(r"\b[Uu]ser's\b", f"{other_display}'s", out)
    return out


def reattribute(facts: list, transcript: str, metadata: dict) -> list:
    """Move subject=user facts that are about another participant onto that
    participant. Returns ``facts`` (mutated in place); logs a count only."""
    participants = normalise_participants(metadata.get("participants"))
    others = [p for p in participants if p.get("role") != "user" and p.get("id")]
    if not others or not facts:
        return facts
    owner = next((p for p in participants if p.get("role") == "user"), {})
    owner_display = (owner.get("display") or "").strip()
    owner_names = [owner_display] + ([owner_display.split()[0]] if owner_display else [])
    turns = speaker_turns(transcript)
    moved = 0
    for fact in facts:
        if not isinstance(fact, dict) or fact.get("subject", "user") != "user":
            continue
        evidence = fact.get("evidence") or ""
        core = _evidence_core(evidence)
        label = speaker_of(evidence, turns)
        if label is None:
            continue
        target = None
        reason = None
        if not _is_owner_label(label, participants):
            p = _participant_for(label, participants)
            if (p and p.get("role") != "user" and p.get("id")
                    and _FIRST_PERSON.search(core) and not _SECOND_PERSON.search(core)):
                target, reason = p, "speaker"
        else:
            for p in others:
                first = (p.get("display") or "").split()
                if not first:
                    continue
                if re.search(rf"\b{re.escape(first[0].lower())}'s ({'|'.join(_RELATIVES)})\b", core):
                    target, reason = p, "named_relative"
                    break
        if target is None:
            continue
        fact["subject"] = f"other:{target['id']}"
        fact["text"] = _rewrite_text(fact.get("text") or "", owner_names,
                                     (target.get("display") or "").strip())
        fact["attribution_corrected"] = reason
        moved += 1
    if moved:
        logger.info("Re-attributed %d fact(s) from the owner to another participant", moved)
    return facts
