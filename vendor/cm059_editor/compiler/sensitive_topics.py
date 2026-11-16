"""The ONE list of GDPR Art. 9 special-category topics that must never become
an interest or preference CARD (board row 2471).

Every path in this package that turns a profile interest into a card, or into
an outbound scout query whose results become a card, asks ``sensitive_class``
of the subject. Add a term HERE, never a second list elsewhere:

  * frontpage.is_cardable_interest  (interest, rotation and hunch cards)
  * frontpage.sensitive_card_gate   (last gate over the assembled feed)
  * scout_external.l1_interests     (scout topics, so a special-category
                                      subject never leaves the machine nor
                                      comes back as a scout card)

The interest is NOT deleted from the profile; it is only never carded.

Art. 9(1) classes, all eight required:
  racial_ethnic_origin, political_opinions, religious_philosophical_beliefs,
  trade_union_membership, genetic_data, biometric_data, health,
  sex_life_orientation.

Matching (stdlib only; the Front Page producer has no third-party deps):
  * text is NFKC-normalised and case-folded; hyphens, dots, slashes,
    underscores, apostrophes and '#' read as spaces;
  * a term ending in ``*`` is a STEM: it matches at the START of a word
    ("diabet*" matches "diabetes" and "diabetic", never mid-word);
  * any other term matches as whole word(s), with an optional plural -s/-es
    (so "tory" never matches "history");
  * an ``EXCEPTIONS`` phrase is blanked out first, so "retail therapy" and
    "diet coke" are not read as health.
Word-start matching is deliberate: the previous substring list blocked
"History", "Story", "Magazine" and "Archive" as political or health topics.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Dict, Optional, Tuple

ART9_CLASSES: Dict[str, Tuple[str, ...]] = {
    "racial_ethnic_origin": (
        "ethnicity", "ethnic*", "racial*", "racism", "racist*", "race relations",
        "black lives matter", "black history", "african american",
        "afro caribbean", "south asian heritage", "indigenous", "first nations",
        "aboriginal", "hispanic", "latino", "latina", "latinx", "romani",
    ),
    "political_opinions": (
        "politic*", "election*", "memorial", "campaign*", "protest*", "maga",
        "democrat*", "republican*", "conservative party", "labour party",
        "tory", "tories", "brexit*", "socialis*", "communis*", "fascis*",
        "libertarian*", "activis*", "left wing", "right wing", "far right",
        "far left", "green party", "liberal democrats",
    ),
    "religious_philosophical_beliefs": (
        "religio*", "church*", "mosque*", "synagogue*", "temple", "gurdwara*",
        "islam*", "muslim*", "christian*", "catholic*", "protestant*",
        "evangelical*", "jewish", "judaism", "kosher", "halal", "hindu*",
        "buddhis*", "sikh*", "atheis*", "agnostic*", "humanist*", "bible*",
        "quran", "koran", "prayer*", "ramadan", "worship*", "spiritual*",
        "scientolog*", "faith",
    ),
    "trade_union_membership": (
        "trade union*", "labour union*", "labor union*", "union member*",
        "unionis*", "teamsters", "tuc", "collective bargaining", "picket line*",
    ),
    "genetic_data": (
        "genetic*", "genome*", "genomic*", "dna test*", "dna kit*",
        "ancestry dna", "23andme", "carrier status", "brca*", "gene therap*",
    ),
    "biometric_data": (
        "biometric*", "fingerprint*", "face id", "facial recognition",
        "iris scan*", "retina scan*", "retinal scan*", "voiceprint*",
        "voice print*", "palm print*", "palm vein*",
    ),
    "health": (
        "diabet*", "cancer*", "oncolog*", "chemo*", "tumour*", "tumor*", "hiv",
        "aids", "depression", "depressed", "anxiety", "mental health",
        "therap*", "rehab*", "addiction*", "ozempic", "wegovy", "mounjaro",
        "pregnan*", "ivf", "fertility", "abortion*", "adhd", "autism",
        "autistic", "bipolar", "ptsd", "eating disorder*", "anorexi*",
        "bulimi*", "dialysis", "hospice*", "psychiatr*", "disabilit*",
        "chronic illness", "medication*", "prescription*", "insulin",
        "asthma*", "epilep*", "dementia", "alzheimer*", "parkinson*",
        "multiple sclerosis", "crohn*", "coeliac", "celiac", "sober",
        "sobriety", "alcoholics anonymous", "in recovery", "health condition*",
    ),
    "sex_life_orientation": (
        "lgbt*", "gay", "gays", "lesbian*", "bisexual*", "transgender*",
        "queer", "homosexual*", "non binary", "nonbinary", "gender identity",
        "grindr", "pride parade", "pride march", "sexual*", "sex life",
        "kink*", "fetish*", "bdsm", "polyamor*", "asexual*",
    ),
}

# Common names that merely CONTAIN a term. Whole phrase, same normalisation.
EXCEPTIONS: Tuple[str, ...] = (
    "retail therapy", "diet coke", "great depression", "tropical depression",
    "as roma",
)

REQUIRED_CLASSES = frozenset(ART9_CLASSES)


def _norm(text) -> str:
    t = unicodedata.normalize("NFKC", str(text or "")).casefold()
    return re.sub(r"[\s\-_./'’#]+", " ", t).strip()


def _compile(terms) -> "re.Pattern[str]":
    alts = []
    for raw in terms:
        stem = raw.endswith("*")
        w = _norm(raw[:-1] if stem else raw)
        if not w:
            raise ValueError("empty sensitive term")
        alts.append(re.escape(w) + (r"\w*" if stem else r"(?:e?s)?(?!\w)"))
    alts.sort(key=len, reverse=True)
    return re.compile(r"(?<!\w)(?:%s)" % "|".join(alts))


_RX = {cls: _compile(terms) for cls, terms in ART9_CLASSES.items()}
_EXC = re.compile(r"(?<!\w)(?:%s)(?!\w)" % "|".join(
    re.escape(_norm(e)) for e in sorted(EXCEPTIONS, key=len, reverse=True)))


def sensitive_class(text) -> Optional[str]:
    """The Art. 9 class ``text`` falls in, else None."""
    low = _EXC.sub(" ", _norm(text))
    if not low.strip():
        return None
    for cls, rx in _RX.items():
        if rx.search(low):
            return cls
    return None


def is_sensitive_topic(text) -> bool:
    return sensitive_class(text) is not None
