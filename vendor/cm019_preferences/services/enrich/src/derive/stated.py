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
a minor, L3 facts, facts with NO privacy level (fail closed: an unknown level is
never read as L1), and every statement the sensitive gate (sensitive.py, the
one terms file) withholds: a sentence touching health, religion, sexuality,
politics, ethnicity, union membership, diet or a child derives nothing ("I
avoid beer since I got sober" is a health inference, not a taste); a value
that is itself sensitive is dropped; and a DISLIKE of an abstention value
(alcohol, pork, meat) is dropped, because not drinking or not eating pork is a
health or religion signal. L2 facts are read and the derived node inherits L2.
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

from .cuisine_vocab import VENUE_LABELS
from .model import PRIVACY_ORDER, EvidenceItem
from .sensitive import is_about_minor_text, is_abstention_value, is_sensitive
from .readers import canonical_labels, load_vocab as shared_vocab, vocab_parents

VOCAB_YAML = Path(__file__).resolve().parent / "stated_vocab.yaml"

# The only text a stated node ever shows as its reason.
STATED_BECAUSE = "you said so in a message"
OWNER_ABOUT_PREFIX = "urn:ostler:user/"
# Facts at these privacy levels never feed a preference. L2 is admitted (Archie,
# 2026-10-22) and the derived node inherits it; L3 stays out.
BLOCKED_PRIVACY = {"L3"}

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
        (r"\b(?:is|am|'s|'m)\s+sick\s+of\b", -STRONG),
        # negative, soft: a negated verb or fan-phrase softened by an adverb
        (rf"\b{_NOT}\s+{_ADV}(?:\s+{_ADV})?\s+(?:{_LIKE_V}|{_FAN}|eat|drink)\b", -SOFT),
        (rf"\b{_NOT}\s+(?:a\s+(?:big|huge|massive)\s+fan\s+of|that\s+keen\s+on)\b", -SOFT),
        (r"\b(?:doesn't|does not|don't|do not)\s+love\b", -SOFT),
        (r"\b(?:isn't|is not|'s not|'m not)\s+really\s+(?:keen|into)\b(?:\s+on)?", -SOFT),
        # negative, medium
        (rf"\b{_INTENSE}\s+(?:dislikes?|disliked|disliking|avoids?)\b", -STRONG),
        (r"\b(?:dislikes?|disliked|disliking|avoids?|avoided|avoiding)\b", -MEDIUM),
        (rf"\b{_NOT}\s+(?:like|enjoy|care\s+for|have\s+a\s+taste\s+for)\b", -MEDIUM),
        (rf"\b{_NOT}\s+(?:a\s+fan\s+of|keen\s+on|into|fond\s+of)\b", -MEDIUM),
        (r"\b(?:is|am|'s|'m)\s+no\s+fan\s+of\b", -MEDIUM),
        # positive, strong
        (r"\b(?:loves?|loved|loving|adores?|adored|worships?)\b", STRONG),
        (r"\b(?:is|am|'s|'m)\s+(?:obsessed\s+with|crazy\s+about|mad\s+about|passionate\s+about|addicted\s+to)\b", STRONG),
        (r"\bcan't\s+get\s+enough\s+of\b", STRONG),
        (r"\b(?:is|am|'s|'m)\s+a\s+(?:big|huge|massive)\s+fan\s+of\b", STRONG),
        (r"\bfavou?rite\b", STRONG),
        # positive, medium
        (rf"\b{_INTENSE}\s+(?:likes?|enjoys?|prefers?|appreciates?)\b", STRONG),
        (r"\b(?:likes?|liked|enjoys?|enjoyed|enjoying|prefers?|preferred|preferring|appreciates?)\b", MEDIUM),
        (r"\b(?:is|am|'s|'m)\s+(?:a\s+fan\s+of|into|keen\s+on|fond\s+of|partial\s+to)\b", MEDIUM),
    ]
]

# Words in the shared cuisine file that, said on their own, are not a stated
# CUISINE: drinks and venues (other dimensions), a place's name, and generic dish
# or food words. The label itself (e.g. "sichuan", "sushi") is always accepted.
_NOT_A_STATED_CUISINE = frozenset({
    "coffee", "espresso", "latte", "flat white", "cafe", "café", "coffeehouse", "bakery", "brunch",
    "pub", "tavern", "taproom", "alehouse", "gastropub", "diner", "subway", "mcdonald", "kfc",
    "burger king", "english", "turkey", "bbq", "bbq grill", "halal", "wings", "steak", "ribeye",
    "sirloin", "rib eye", "steak house", "burger", "burgers", "cheeseburger", "hot dog", "milkshake",
    "noodle", "noodles", "dumpling", "dumplings", "crab", "lobster", "prawns", "oyster", "oysters",
    "china", "india", "japan", "korea", "vietnam", "thailand", "mexico", "france", "spain",
    "greece", "italy", "germany", "taiwan", "shanghai", "canton", "dal", "pide", "dosa",
})
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
_AGE = re.compile(r"\b(\d{1,2})[- ]years?[- ]old\b|\baged?\s+(\d{1,2})\b|[a-z]\s*\(\s*(\d{1,2})\s*\)")


def mentions_a_minor(text: str) -> bool:
    """True when the sentence is about, or names, someone who may be a minor."""
    t = (text or "").lower()
    if _MINOR_WORDS.search(t):
        return True
    if any(int(next(g for g in m.groups() if g)) < 18 for m in _AGE.finditer(t)):
        return True
    return is_about_minor_text(t)   # the shared minors terms (a kids' party, a nursery)


def gate_stances(text: str, stances: List["Stance"], stats: Optional[Counter] = None) -> List["Stance"]:
    """The ONE sensitive gate for stated evidence, on the fact path, the
    transcript path and the model path alike.

    - a statement whose text is sensitive derives NOTHING (the context is the
      inference: "I avoid beer since I got sober");
    - a value that is itself sensitive is dropped ("Bible study", "Alcoholics
      Anonymous" from a model);
    - a negative stance on an abstention value (alcohol, pork, meat) is dropped.
    """
    if not stances:
        return stances
    if is_sensitive(text):
        if stats is not None:
            stats["withheld_sensitive_statement"] += 1
        return []
    kept = []
    for st in stances:
        if is_sensitive(st.value):
            reason = "withheld_sensitive_value"
        elif st.strength < 0 and is_abstention_value(st.value):
            reason = "withheld_abstention"
        else:
            kept.append(st)
            continue
        if stats is not None:
            stats[reason] += 1
    return kept


@dataclass(frozen=True)
class Stance:
    dimension: str
    value: str
    strength: float          # signed, -1..1
    method: str              # "vocab" | "model"


# Texting drops apostrophes: "dont like", "cant stand", "im not a fan of".
_CONTRACTION_FIX = {
    "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "cant": "can't",
    "isnt": "isn't", "wouldnt": "wouldn't", "im": "i'm", "ive": "i've", "id": "i'd",
}
_CONTRACTIONS = re.compile(r"\b(?:" + "|".join(_CONTRACTION_FIX) + r")\b")


def _norm_text(text: str) -> str:
    t = (text or "").lower().replace("’", "'").replace("‘", "'")
    t = _CONTRACTIONS.sub(lambda m: _CONTRACTION_FIX[m.group(0)], t)
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

    def _cuisine_spans(self, clause: str) -> List[Tuple[int, int, str, str]]:
        """Cuisine words in a clause, mapped through the SHARED cuisine vocabulary
        (vocab/cuisine.yaml, owned by the food evidence work): there is no second
        cuisine list here. The label is that file's own (lowercase, hierarchical:
        sichuan and cantonese sit under chinese and are separate values; the
        parent is the derive roll-up's job, never added here).
        """
        parents = vocab_parents("cuisine")
        flat = clause.replace("-", " ")
        spans = []
        for label, rx in shared_vocab("cuisine"):
            if label in VENUE_LABELS:
                continue          # a venue type or eating style is not a stated cuisine
            for m in rx.finditer(flat):
                word = m.group(0)
                if word != label and word in _NOT_A_STATED_CUISINE:
                    continue      # coffee, pub, a country's name, a generic dish word
                if label not in canonical_labels(word, "cuisine", strict=True):
                    continue
                spans.append((m.start(), m.end(), "food.cuisine", label, 0 if label in parents else 1))
        return [(s, e, d, c, p) for s, e, d, c, p in spans]

    def _terms_in(self, clause: str) -> List[Tuple[int, int, str, str]]:
        cands = [(m.start(), m.end(), dim, canon, 1) for pat, dim, canon, _ in self._terms
                 for m in pat.finditer(clause)]
        cands += self._cuisine_spans(clause)
        # longest first; on a tie the REGIONAL label beats its parent
        cands.sort(key=lambda c: (-(c[1] - c[0]), c[4], c[0]))
        used: List[Tuple[int, int]] = []
        found = []
        for s, e, dim, canon, _p in cands:
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

    # -- first-person mode, for the owner's own sent messages ------------------
    _SENT = re.compile(r"[^.!?;\n]+[.!?;]*")
    _ADVERBS = re.compile(
        r"(?:(?:really|so|absolutely|just|honestly|actually|totally|literally|also|still|"
        r"always|completely|truly|genuinely|personally|definitely|obviously|simply)\s+)+$"
    )
    _SUBJECT_END = re.compile(r"(?:\bi|\bi'm|\bwe|\bwe're|\bmy)$")
    _CONNECTIVE_END = re.compile(r"(?:\band|\bplus|\balso|&|,)$")
    _BLOCK = re.compile(
        r"\b(?:you|your|you're|u|ur|if|would|could|should|wanna|want|wants|need|gonna|"
        r"going to|let's|lets|why|what|whether|hope|wish|suppose|imagine|maybe|might|"
        r"probably|i'd|i'll|will|can i|shall)\b"
    )
    _QUESTION_START = re.compile(
        r"^(?:do|does|did|is|are|was|were|would|will|can|could|have|has|how|what|why|who|where|when)\b"
    )
    _I_PREFER = re.compile(
        r"\bi\s+(?:really\s+)?prefer\s+(?P<a>.+?)\s+(?:to|over|rather\s+than|instead\s+of)\s+(?P<b>.+)"
    )

    def parse_message(self, text: str) -> List[Stance]:
        """Stances stated by the SPEAKER of one message ("I hate coffee").

        The caller guarantees the message was sent by the owner, so attribution
        is exact; what this adds is precision about WHO the sentence is about.
        A like or dislike counts only when its subject is the speaker: "I",
        "we", an elided "hate coffee", or "my favourite ...". Questions
        ("do you like jazz?"), wishes ("I'd love a coffee"), and other people's
        tastes ("she hates coffee", "my wife loves jazz") are dropped.
        """
        out: Dict[Tuple[str, str], Stance] = {}
        for sent in self._SENT.findall(text or ""):
            if sent.rstrip().endswith("?"):
                continue
            t = _norm_text(sent)
            t = re.sub(r"[.!?;]+$", "", t).strip()
            if not t or self._QUESTION_START.match(t):
                continue
            po = self._I_PREFER.search(t)
            if po and not self._BLOCK.search(t):
                for side, mag in (("a", MEDIUM), ("b", -SOFT)):
                    for _s, _e, dim, canon in self._terms_in(po.group(side)):
                        out[(dim, canon)] = Stance(dim, canon, mag, "vocab")
                continue
            for clause in _CLAUSE_SPLIT.split(t):
                clause = clause.strip()
                if not clause or self._BLOCK.search(clause):
                    continue
                accepted = []
                for cs, ce, mag in self._cues_in(clause):
                    prefix = self._ADVERBS.sub("", clause[:cs].strip() + " ").strip()
                    if prefix == "" or self._SUBJECT_END.search(prefix):
                        accepted.append((cs, ce, mag))
                    elif accepted and self._CONNECTIVE_END.search(prefix):
                        accepted.append((cs, ce, mag))
                if not accepted:
                    continue
                for ts, te, dim, canon in self._terms_in(clause):
                    before = [c for c in accepted if c[1] <= ts]
                    after = [c for c in accepted if c[0] >= te]
                    cue = before[-1] if before else (after[0] if after else None)
                    if cue is not None:
                        out[(dim, canon)] = Stance(dim, canon, cue[2], "vocab")
        return list(out.values())

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
            if dim == "food.cuisine":
                # a cuisine value goes through the SHARED vocabulary or is dropped
                labels = [l for l in canonical_labels(value, "cuisine", strict=True) if l not in VENUE_LABELS]
                if not labels:
                    continue
                value = labels[0]
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
        best: Dict[Tuple[str, str, str], Tuple[Stance, str, dict, str]] = {}
        for b in rows:
            self.stats["facts_seen"] += 1
            text = b.get("text", {}).get("value", "")
            level = b.get("priv", {}).get("value") or ""
            if not level:
                # Fail CLOSED, as the transcript path does: a fact with no level
                # is never read as L1.
                self.stats["skipped_no_privacy_level"] += 1
                continue
            if level in BLOCKED_PRIVACY or level not in PRIVACY_ORDER:
                self.stats["skipped_private"] += 1
                continue
            if mentions_a_minor(text):
                self.stats["skipped_minor"] += 1
                continue
            stances, how = self.mapper.map_fact(text)
            self.stats["via_" + how] += 1
            stances = gate_stances(text, stances, self.stats)
            if not stances:
                continue
            conv = b.get("conv", {}).get("value", "")
            fact = b.get("f", {}).get("value", "")
            hdr = _parse_header(b.get("hdr", {}).get("value", ""))
            for st in stances:
                k = (conv, st.dimension, st.value.lower())
                if k not in best or abs(st.strength) > abs(best[k][0].strength):
                    best[k] = (st, fact, hdr, level)
                elif PRIVACY_ORDER.get(level, 0) > PRIVACY_ORDER.get(best[k][3], 0):
                    best[k] = (best[k][0], best[k][1], best[k][2], level)
        for (conv, dim, _v), (st, fact, hdr, level) in sorted(best.items()):
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
                privacy_level=level,
            )
