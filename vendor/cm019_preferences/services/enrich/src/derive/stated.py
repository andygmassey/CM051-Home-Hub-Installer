"""Stated preferences: what the owner SAYS in conversations becomes evidence.

The CM048 conversation processor already extracts facts of ``type: preference``
into the graph (``urn:ostler:Fact``, graph ``urn:ostler:user/<id>``). This module
is the bridge from those facts to Smart Preferences. It READS that store and
never writes to it (no side-writer); the derived nodes go where every other
derived node goes, through the engine and the regenerable derived graph.

For each owner-attributed preference fact it works out:

- a DIMENSION and a normalised VALUE ("Szechuan food" -> food.cuisine / Sichuan),
  from a deterministic vocabulary (stated_vocab.yaml) first, then, only when the
  vocabulary knows nothing in a sentence that plainly states a like or dislike,
  from a small local model that may answer ONLY with a registered dimension;
- a POLARITY and intensity ("hates" -0.9, "doesn't really like" -0.35);
- PROVENANCE: the fact node it came from and the date, with the fixed "because"
  line below. The words of the message are read in memory to classify and are
  never copied into the evidence, the derived node or its because line.

Repetition is counted per CONVERSATION: telling five different people you hate
coffee is five pieces of evidence, saying it five times in one chat is one.

Excluded by construction: facts about anyone but the owner (a friend loving jazz
is not the owner loving jazz; that belongs on a person page), facts that mention
a minor, and private (L2/L3) facts.
"""

from __future__ import annotations

import hashlib
import json
import re
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Tuple

import yaml

from .model import EvidenceItem

VOCAB_YAML = Path(__file__).resolve().parent / "stated_vocab.yaml"

# The only text a stated node ever shows as its reason.
STATED_BECAUSE = "you said so in a message"
OWNER_ABOUT_PREFIX = "urn:ostler:user/"
# Facts at or above these privacy levels never feed a preference.
BLOCKED_PRIVACY = {"L2", "L3"}

STRONG, MEDIUM, SOFT = 0.9, 0.6, 0.35

_NOT = r"(?:doesn't|does not|don't|do not|didn't|did not|isn't|is not|aren't|am not|wasn't|not|never|wouldn't)"
_ADV = r"(?:really|particularly|that|very|too|so|hugely|massively|overly|exactly|much)"
_LIKE_V = r"(?:like|love|enjoy|care for|adore)"
_INTENSE = r"(?:really|strongly|absolutely|truly|intensely|deeply|genuinely|definitely)"
_FAN = r"(?:a\s+(?:big\s+|huge\s+|massive\s+)?fan\s+of|keen\s+on|into|fond\s+of|crazy\s+about|mad\s+about|excited\s+by)"

# (pattern, signed magnitude). Overlaps resolve to the longest match, so
# "doesn't really like" beats the "like" inside it.
_CUES: List[Tuple[re.Pattern, float]] = [
    (re.compile(p), v) for p, v in [
        # negative, strong
        (r"\b(?:hates?|hated|hating|detests?|loathes?|despises?|abhors?)\b", -STRONG),
        (r"\b(?:can't|cannot|can not)\s+(?:stand|bear|abide)\b", -STRONG),
        (r"\b(?:is|'s)\s+sick\s+of\b", -STRONG),
        # negative, soft: a negated verb or fan-phrase softened by an adverb
        (rf"\b{_NOT}\s+{_ADV}(?:\s+{_ADV})?\s+(?:{_LIKE_V}|{_FAN}|eat|drink)\b", -SOFT),
        (rf"\b{_NOT}\s+(?:a\s+(?:big|huge|massive)\s+fan\s+of|that\s+keen\s+on)\b", -SOFT),
        (r"\b(?:doesn't|does not|don't|do not)\s+love\b", -SOFT),
        (r"\b(?:isn't|is not|'s not)\s+really\s+(?:keen|into)\b(?:\s+on)?", -SOFT),
        # negative, medium
        (rf"\b{_INTENSE}\s+(?:dislikes?|disliked|disliking|avoids?)\b", -STRONG),
        (r"\b(?:dislikes?|disliked|disliking|avoids?|avoided|avoiding)\b", -MEDIUM),
        (rf"\b{_NOT}\s+(?:like|enjoy|care\s+for|have\s+a\s+taste\s+for)\b", -MEDIUM),
        (rf"\b{_NOT}\s+(?:a\s+fan\s+of|keen\s+on|into|fond\s+of)\b", -MEDIUM),
        (r"\b(?:is|'s)\s+no\s+fan\s+of\b", -MEDIUM),
        # positive, strong
        (r"\b(?:loves?|loved|loving|adores?|adored|worships?)\b", STRONG),
        (r"\b(?:is|'s)\s+(?:obsessed\s+with|crazy\s+about|mad\s+about|passionate\s+about|addicted\s+to)\b", STRONG),
        (r"\bcan't\s+get\s+enough\s+of\b", STRONG),
        (r"\b(?:is|'s)\s+a\s+(?:big|huge|massive)\s+fan\s+of\b", STRONG),
        (r"\bfavou?rite\b", STRONG),
        # positive, medium
        (rf"\b{_INTENSE}\s+(?:likes?|enjoys?|prefers?|appreciates?)\b", STRONG),
        (r"\b(?:likes?|liked|enjoys?|enjoyed|enjoying|prefers?|preferred|preferring|appreciates?)\b", MEDIUM),
        (r"\b(?:is|'s)\s+(?:a\s+fan\s+of|into|keen\s+on|fond\s+of|partial\s+to)\b", MEDIUM),
    ]
]

_CLAUSE_SPLIT = re.compile(
    r"[;.!?\n]|\b(?:but|however|whereas|while|although|though|yet|except)\b"
)
_PREFER_OVER = re.compile(
    r"\bprefers?\s+(?P<a>.+?)\s+(?:to|over|rather\s+than|instead\s+of)\s+(?P<b>.+)"
)
_GENERIC_SUFFIX = r"(?:\s+(?:food|cuisine|cooking|dishes|restaurants?|music|films?|movies?))?"

_MINOR_WORDS = re.compile(
    r"\b(?:son|sons|daughter|daughters|child|children|kid|kids|toddler|baby|"
    r"teen|teens|teenager|teenagers|minor|nephew|niece|grandson|granddaughter|"
    r"schoolboy|schoolgirl|pupil)\b"
)
_AGE = re.compile(r"\b(\d{1,2})[- ]years?[- ]old\b")


def mentions_a_minor(text: str) -> bool:
    """True when the sentence is about, or names, someone who may be a minor."""
    t = (text or "").lower()
    if _MINOR_WORDS.search(t):
        return True
    return any(int(m.group(1)) < 18 for m in _AGE.finditer(t))


@dataclass(frozen=True)
class Stance:
    dimension: str
    value: str
    strength: float          # signed, -1..1
    method: str              # "vocab" | "model"


def _norm_text(text: str) -> str:
    t = (text or "").lower().replace("’", "'").replace("‘", "'")
    return re.sub(r"\s+", " ", t).strip()


def load_vocab(path: Path = VOCAB_YAML) -> Dict[str, Dict[str, List[str]]]:
    return yaml.safe_load(Path(path).read_text()) or {}


class StatedMapper:
    """Free text -> [(dimension, canonical value, signed strength)]."""

    def __init__(
        self,
        vocab: Optional[Dict[str, Dict[str, List[str]]]] = None,
        allowed_dimensions: Optional[Iterable[str]] = None,
        model: Optional[Callable[[str], List[dict]]] = None,
    ):
        self.vocab = vocab if vocab is not None else load_vocab()
        self.allowed = set(allowed_dimensions) if allowed_dimensions is not None else set(self.vocab)
        self.model = model
        self._terms: List[Tuple[re.Pattern, str, str, int]] = []
        self._lookup: Dict[str, Tuple[str, str]] = {}
        for dim, canon_map in self.vocab.items():
            for canon, syns in canon_map.items():
                for phrase in {canon.lower(), *[s.lower() for s in (syns or [])]}:
                    self._lookup[phrase] = (dim, canon)
                    pat = re.compile(
                        r"(?<![a-z0-9])" + re.escape(phrase) + r"(?:s|es)?" + _GENERIC_SUFFIX + r"(?![a-z0-9])"
                    )
                    self._terms.append((pat, dim, canon, len(phrase)))
        self._terms.sort(key=lambda t: -t[3])

    # -- vocabulary -------------------------------------------------------
    def canonical(self, value: str) -> Optional[Tuple[str, str]]:
        v = _norm_text(value)
        v = re.sub(r"\s+(?:food|cuisine|cooking|dishes)$", "", v)
        hit = self._lookup.get(v) or self._lookup.get(v.rstrip("s"))
        return hit

    def _terms_in(self, clause: str) -> List[Tuple[int, int, str, str]]:
        used: List[Tuple[int, int]] = []
        found = []
        for pat, dim, canon, _ in self._terms:
            for m in pat.finditer(clause):
                s, e = m.span()
                if any(s < ue and us < e for us, ue in used):
                    continue
                used.append((s, e))
                found.append((s, e, dim, canon))
        return sorted(found)

    @staticmethod
    def _cues_in(clause: str) -> List[Tuple[int, int, float]]:
        raw = []
        for pat, mag in _CUES:
            for m in pat.finditer(clause):
                raw.append((m.start(), m.end(), mag))
        raw.sort(key=lambda c: (-(c[1] - c[0]), c[0]))  # longest first
        kept: List[Tuple[int, int, float]] = []
        for s, e, mag in raw:
            if any(s < ke and ks < e for ks, ke, _ in kept):
                continue
            kept.append((s, e, mag))
        return sorted(kept)

    # -- the mapping ------------------------------------------------------
    def parse(self, text: str) -> Tuple[List[Stance], bool]:
        """Return (stances, cue_without_term).

        ``cue_without_term`` is True when a sentence states a like or dislike but
        the vocabulary found nothing in it: the only case the model is asked.
        """
        t = _norm_text(text)
        out: Dict[Tuple[str, str], Stance] = {}
        cue_without_term = False

        po = _PREFER_OVER.search(t)
        if po:
            for side, mag in (("a", MEDIUM), ("b", -SOFT)):
                for _s, _e, dim, canon in self._terms_in(po.group(side)):
                    out[(dim, canon)] = Stance(dim, canon, mag, "vocab")
            t = t[: po.start()] + " " + t[po.end():] if out else t

        for clause in _CLAUSE_SPLIT.split(t):
            clause = clause.strip()
            if not clause:
                continue
            cues = self._cues_in(clause)
            if not cues:
                continue
            terms = self._terms_in(clause)
            if not terms:
                cue_without_term = True
                continue
            for ts, te, dim, canon in terms:
                before = [c for c in cues if c[1] <= ts]
                after = [c for c in cues if c[0] >= te]
                cue = before[-1] if before else (after[0] if after else None)
                if cue is None:
                    continue
                out[(dim, canon)] = Stance(dim, canon, cue[2], "vocab")
        return list(out.values()), cue_without_term

    def map_fact(self, text: str) -> Tuple[List[Stance], str]:
        """Stances for one fact text, and how they were found (counted, never logged)."""
        stances, needs_model = self.parse(text)
        if stances or not needs_model:
            return stances, ("vocab" if stances else "none")
        if self.model is None:
            return [], "unmapped"
        return self._from_model(text), "model"

    def _from_model(self, text: str) -> List[Stance]:
        try:
            answers = self.model(text) or []
        except Exception:
            return []
        out: List[Stance] = []
        for a in answers:
            if not isinstance(a, dict):
                continue
            dim = str(a.get("dimension", "")).strip()
            value = str(a.get("value", "")).strip()
            if dim not in self.allowed:
                continue
            canon = self.canonical(value)
            if canon and canon[0] == dim:
                value = canon[1]
            elif not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 '&.-]{0,40}", value) or len(value.split()) > 4:
                continue  # a sentence is not a value
            pol = str(a.get("polarity", "")).lower()
            inten = str(a.get("intensity", "medium")).lower()
            mag = {"strong": STRONG, "medium": MEDIUM, "soft": SOFT}.get(inten, MEDIUM)
            if pol in ("dislike", "negative", "hate"):
                strength = -mag
            elif pol in ("like", "positive", "love"):
                strength = mag
            else:
                continue
            out.append(Stance(dim, value, strength, "model"))
        return out


class OllamaStatedModel:
    """Small local model fallback. Offline: loopback Ollama only, temperature 0.

    The caller passes the TIER model; this class never picks a bigger one.
    """

    PROMPT = (
        "A person said the sentence below about their own taste. Reply with JSON "
        '{"items":[{"dimension":D,"value":V,"polarity":"like"|"dislike",'
        '"intensity":"strong"|"medium"|"soft"}]}. D must be one of: %s. V is the '
        "thing liked or disliked, 1 to 3 words, your own wording, not a quote. "
        'If there is none, reply {"items":[]}.\n\nSentence: %s'
    )

    def __init__(self, model: str, dimensions: Iterable[str],
                 url: str = "http://127.0.0.1:11434", timeout: float = 60.0):
        self.model, self.dimensions, self.url, self.timeout = model, sorted(dimensions), url, timeout

    def __call__(self, text: str) -> List[dict]:
        body = json.dumps({
            "model": self.model, "stream": False, "format": "json",
            "options": {"temperature": 0},
            "prompt": self.PROMPT % (", ".join(self.dimensions), text),
        }).encode()
        req = urllib.request.Request(
            self.url + "/api/generate", data=body, headers={"Content-Type": "application/json"}
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=self.timeout) as r:
            resp = json.load(r).get("response", "")
        data = json.loads(resp)
        return list(data.get("items", [])) if isinstance(data, dict) else []


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


_HDR_PAIR = re.compile(r"(\w+)=([^\s\]]*)")


def _parse_header(h: str) -> dict:
    return dict(_HDR_PAIR.findall(h or ""))


def _date(v: str) -> Optional[datetime]:
    try:
        return datetime.fromisoformat((v or "").strip()).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


@dataclass
class StatedConversationReader:
    """Owner-attributed ``preference`` facts -> EvidenceItems with polarity.

    ``dimension`` is the registry label of this reader; the evidence it emits
    carries the dimension each stance maps to.
    """

    gateway: object
    mapper: StatedMapper
    dimension: str = "stated.conversations"
    domain: str = "stated"
    category: str = "stated"
    fact_types: Tuple[str, ...] = ("preference",)
    stats: Counter = field(default_factory=Counter)

    def _query(self, user_id: str) -> str:
        # Deliberately NOT filtered on o:userId. That literal is CM048's own
        # configured user name, while the derive runner's user id is a different
        # label (the Hub runs it as "ostler"); matching the two silently reads
        # nothing. The owner is whoever the fact is ABOUT: a urn:ostler:user/
        # node. This is a single-machine product, one owner per store.
        types = " ".join(f'"{_esc(t)}"' for t in self.fact_types)
        return (
            "PREFIX o:<urn:ostler:>\n"
            "SELECT ?f ?conv ?text ?priv ?hdr WHERE {\n"
            "  GRAPH ?g { ?f a o:Fact ; o:type ?type ; o:about ?a ;\n"
            "     o:fromConversation ?conv ; o:text ?text .\n"
            "     OPTIONAL { ?f o:privacyLevel ?priv }\n"
            "     OPTIONAL { ?f o:provenanceHeader ?hdr } }\n"
            f"  VALUES ?type {{ {types} }}\n"
            f'  FILTER(STRSTARTS(STR(?a), "{OWNER_ABOUT_PREFIX}"))\n'
            "} ORDER BY ?conv ?f"
        )

    def read(self, user_id: str) -> Iterable[EvidenceItem]:
        rows = self.gateway.sparql(self._query(user_id))
        # (conversation, dimension, value) -> best stance, so repeating yourself
        # inside one conversation is still one observation.
        best: Dict[Tuple[str, str, str], Tuple[Stance, str, dict]] = {}
        for b in rows:
            self.stats["facts_seen"] += 1
            text = b.get("text", {}).get("value", "")
            if (b.get("priv", {}).get("value") or "L1") in BLOCKED_PRIVACY:
                self.stats["skipped_private"] += 1
                continue
            if mentions_a_minor(text):
                self.stats["skipped_minor"] += 1
                continue
            stances, how = self.mapper.map_fact(text)
            self.stats["via_" + how] += 1
            if not stances:
                continue
            conv = b.get("conv", {}).get("value", "")
            fact = b.get("f", {}).get("value", "")
            hdr = _parse_header(b.get("hdr", {}).get("value", ""))
            for st in stances:
                k = (conv, st.dimension, st.value.lower())
                if k not in best or abs(st.strength) > abs(best[k][0].strength):
                    best[k] = (st, fact, hdr)
        for (conv, dim, _v), (st, fact, hdr) in sorted(best.items()):
            self.stats["evidence_" + ("negative" if st.strength < 0 else "positive")] += 1
            pid = hashlib.sha1(f"{conv}|{dim}|{st.value.lower()}".encode()).hexdigest()[:16]
            yield EvidenceItem(
                preference_id=pid,
                user_id=user_id,
                domain=dim.rsplit(".", 1)[0],
                dimension=dim,
                value=st.value,
                value_qid=None,
                item_strength=st.strength,
                polarity_source="stated",
                source="stated:" + (hdr.get("src") or "conversation"),
                observed_at=_date(hdr.get("date", "")),
                enrichment_confidence=0.8 if st.method == "vocab" else 0.5,
                raw_subject=STATED_BECAUSE,
                provenance=fact or None,
            )
