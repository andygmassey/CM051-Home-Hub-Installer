from __future__ import annotations

import re
import unicodedata

import phonenumbers
from rapidfuzz.distance import JaroWinkler


# Unicode general categories that mark a leading/trailing "junk" run on a
# display name: symbols (So/Sm/Sk/Sc), most punctuation, and format/other
# control characters. We strip RUNS of these from the *ends* of a name only,
# never from the interior, so legitimate internal punctuation (O'Brien,
# Jean-Luc, J.R.) survives untouched.
_EDGE_STRIP_CATEGORIES = frozenset(
    {"So", "Sm", "Sk", "Sc", "Cf", "Co", "Cs", "Cn"}
)

# Edge punctuation we DO strip (decorative wrappers / hashes / leading
# bullets), but only at the very start/end. A conservative allow-through
# keeps human-meaningful edge punctuation: a trailing "." (J.R.), and
# parentheses/quotes are handled by run-stripping below.
_EDGE_STRIP_PUNCT = frozenset("#*~^`|=+<>")


def _is_edge_junk(ch: str) -> bool:
    """True if *ch* is a symbol/format char or decorative punctuation that
    should be stripped from the start or end of a display name."""
    if ch in _EDGE_STRIP_PUNCT:
        return True
    cat = unicodedata.category(ch)
    if cat in _EDGE_STRIP_CATEGORIES:
        return True
    return False


def _is_emoji_or_pictograph(ch: str) -> bool:
    """True if *ch* is an emoji / pictographic symbol that never belongs in a
    human name (anywhere -- leading, trailing, or interior decoration).

    Matched by Unicode category ``So`` (other symbol -- covers the bulk of
    emoji and dingbats) plus the supplementary-plane pictograph blocks and the
    variation-selector / ZWJ joiners that glue emoji sequences together. ASCII
    punctuation (``& - ' . /``) and currency / maths symbols are NOT matched,
    so legitimate interior punctuation survives.
    """
    cat = unicodedata.category(ch)
    if cat == "So":
        return True
    cp = ord(ch)
    # Emoji / pictograph supplementary ranges + ZWJ + variation selectors.
    if (
        0x1F000 <= cp <= 0x1FAFF       # misc pictographs, emoji, symbols
        or 0x2600 <= cp <= 0x27BF      # misc symbols + dingbats
        or 0xFE00 <= cp <= 0xFE0F      # variation selectors
        or cp == 0x200D                # zero-width joiner
        or 0x1F1E6 <= cp <= 0x1F1FF    # regional indicator (flags)
    ):
        return True
    return False


def clean_display_name(raw: str) -> str:
    """Tidy a human display name without mangling legitimate names.

    Conservative, locale-safe normalisation applied at ingest time:

    1. Remove emoji / pictographic symbols ANYWHERE in the name -- they are
       never part of a real name, including interior decoration
       (``🌼Jane🌼 Doe`` -> ``Jane Doe``,
       ``🔍 Bob Smith`` -> ``Bob Smith``).
    2. Strip leading/trailing runs of decorative punctuation / format chars
       (``#AXA HK`` -> ``AXA HK``).
    3. Collapse internal whitespace runs to single spaces.
    4. Collapse an EXACT duplicate-token name to a single token
       (``AC AC`` -> ``AC``, ``Jane Jane`` -> ``Jane``). Only fires
       when the name is exactly two identical case-folded tokens, so genuine
       longer names with a repeated token are untouched.

    What it deliberately does NOT touch:
      * interior ASCII punctuation (``O'Brien``, ``Jean-Luc``, ``Tom & Jerry``,
        ``J.R.R. Tolkien`` keep their middle characters);
      * CJK / non-Latin scripts (those are letters, not symbols);
      * names that are *entirely* emoji/symbols (returns ``""`` so the caller
        can keep the raw value -- we never invent a name).

    Returns the cleaned string, or ``""`` if nothing survives; callers should
    treat an empty result as "no usable name" rather than writing an empty
    displayName.
    """
    if not raw:
        return ""

    s = raw.strip()
    if not s:
        return ""

    # 1. Remove emoji / pictographic symbols anywhere (interior + edges).
    s = "".join(ch for ch in s if not _is_emoji_or_pictograph(ch))

    # 2. Strip leading/trailing runs of decorative punctuation + leftover
    #    whitespace (e.g. a leading "#" or an orphaned space from a removed
    #    emoji). Interior punctuation is preserved.
    start = 0
    end = len(s)
    while start < end and (_is_edge_junk(s[start]) or s[start].isspace()):
        start += 1
    while end > start and (_is_edge_junk(s[end - 1]) or s[end - 1].isspace()):
        end -= 1
    s = s[start:end]

    if not s:
        return ""

    # 3. Collapse internal whitespace runs.
    s = re.sub(r"\s+", " ", s).strip()

    # 4. Collapse an exact duplicate-token name ("AC AC" -> "AC").
    tokens = s.split(" ")
    if len(tokens) == 2 and tokens[0].casefold() == tokens[1].casefold():
        s = tokens[0]

    return s


def normalise_phone(raw: str, default_country_code: int = 852) -> str:
    """Return E.164 format or the original string if unparseable."""
    cleaned = raw.strip()
    if not cleaned:
        return cleaned
    try:
        # phonenumbers expects an ISO 3166-1 alpha-2 region code for the default,
        # but we can also parse with a leading '+' if the country code is present.
        # Try parsing as-is first (handles numbers that already include '+').
        parsed = phonenumbers.parse(cleaned, None)
    except phonenumbers.NumberParseException:
        try:
            # Fall back: prepend '+' + country code if the number looks local.
            region = _country_code_to_region(default_country_code)
            parsed = phonenumbers.parse(cleaned, region)
        except phonenumbers.NumberParseException:
            return cleaned

    if phonenumbers.is_valid_number(parsed):
        return phonenumbers.format_number(parsed, phonenumbers.PhoneNumberFormat.E164)
    return cleaned


def normalise_email(email: str) -> str:
    return email.strip().lower()


def _jaro_winkler(s1: str, s2: str) -> float:
    """Jaro-Winkler string similarity (0.0 to 1.0).

    Delegates to rapidfuzz (MIT, C++ core) rather than the hand-rolled
    implementation this used to carry.

    WHY THE SWAP IS SAFE (verified 2026-08-08, not assumed)
    -------------------------------------------------------
    Every caller compares against a threshold -- batch_resolver uses 0.85 --
    so a silent scoring change would silently change merge decisions on
    customer data. Both implementations were run over real name pairs from the
    graph before the swap:

        andrew doe / andy doe          0.8666 -> 0.8783
        andrew doe / andrew smith         0.8662 -> 0.8662
        mike chan / michael chan             0.7981 -> 0.8148
        chris tannous / christopher tannous  0.8984 -> 0.9061
        craig whittet / madhu motwani        0.5021 -> 0.5299

        max delta 0.0278, THRESHOLD CROSSINGS: 0

    Same name, same signature, same call sites -- five of them across
    identity_resolver and contact_syncer -- so the swap is one edit and every
    consumer gets the faster, better-tested implementation.

    Andy, 2026-08-08: "Are we reinventing the wheel ... Is there no open source
    script that we can leverage?" For string similarity: yes, we were.
    """
    return JaroWinkler.similarity(s1, s2)


def _country_code_to_region(code: int) -> str:
    """Map a numeric country calling code to an ISO region for phonenumbers parsing."""
    # phonenumbers.region_codes_for_country_code returns a tuple of region codes.
    regions = phonenumbers.region_codes_for_country_code(code)
    if regions:
        return regions[0]
    return "US"


# ---------------------------------------------------------------------------
# Name agreement for SHAREABLE identifiers (BW-2)
# ---------------------------------------------------------------------------
#
# An email address or a phone number is a SHAREABLE identifier: a household
# landline, a family iPad, an info@ inbox, a couple who share an address book
# entry. A UNIQUE identifier (icloud_uid, whatsapp_lid, linkedin_url) belongs
# to exactly one human and always merges on its own authority; these do not.
#
# The original guard compared the two display names with raw Jaro-Winkler and
# merged above a threshold (0.7 email / 0.6 phone). Jaro-Winkler weights a
# shared PREFIX very heavily, which is exactly the wrong bias here, because
# the thing two different people most often share is a first name:
#
#     Jane Andersen     vs  Jane Stewart     -> ~0.87   merged. Wrong.
#     John Smith        vs  Jane Smith       -> 0.880   merged. Wrong.
#
# Both cleared both thresholds and were silently merged into one person, which
# is a data-corruption bug rather than a cosmetic one: once two people are one
# node, their meetings, messages and facts are indistinguishable.
#
# A single similarity number cannot separate these from real nickname pairs --
# the distributions overlap outright:
#
#     jim / james  -> 0.720   SAME person
#     john / jane  -> 0.700   DIFFERENT people
#
# So we stop asking "how similar are these strings" and ask the question that
# actually discriminates: DO THE SURNAMES MATCH? Nicknames vary the given name
# and keep the surname; different people sharing a phone usually keep their own
# surname. Surname equality is the hard gate; the given name then only has to
# be plausibly the same name.
#
# The third verdict matters as much as the other two. "unsure" means REVIEW,
# not merge and not create -- the pair surfaces on the wiki's duplicate-review
# page with Combine / Different-people buttons. Sending a borderline pair there
# costs one click; merging it wrongly is unpickable.

# Given-name similarity required when the surnames already match. Chosen from
# real pairs: it clears bob/rob (0.778) and mike/michael (0.781), and excludes
# john/jane (0.700). jim/james (0.720) lands under it and goes to review --
# deliberate: a click is cheaper than a bad merge.
GIVEN_NAME_AGREEMENT_THRESHOLD = 0.75

# Similarity required when there is no surname to compare (single-token names
# such as "nana", or a mononym). Deliberately strict: with no surname there is
# no second signal, so only near-identical strings may auto-merge.
SINGLE_TOKEN_AGREEMENT_THRESHOLD = 0.97

# Particles that belong to the surname rather than acting as one.
_SURNAME_PARTICLES = frozenset({
    "van", "von", "de", "der", "den", "del", "della", "delle", "degli",
    "di", "da", "dei", "do", "dos", "das", "du", "la", "le", "el", "al",
    "bin", "ibn", "ben", "bat", "mac", "mc", "o", "st", "saint",
    "ter", "ten", "op", "aan", "zu", "af", "av", "y", "i",
})

# Honorifics and suffixes that must not be mistaken for a surname.
_NAME_NOISE = frozenset({
    "mr", "mrs", "ms", "miss", "dr", "prof", "sir", "dame", "rev",
    "jr", "sr", "ii", "iii", "iv", "phd", "md", "esq",
})


def _name_tokens(name: str) -> list:
    """Lowercased, punctuation-light tokens with honorifics/suffixes dropped."""
    cleaned = name.lower().replace("-", " ").replace(".", " ").replace(",", " ")
    return [t for t in cleaned.split() if t and t not in _NAME_NOISE]


def split_given_surname(name: str):
    """``(given, surname)`` for a display name; surname is ``""`` if absent.

    Multi-token surnames with particles are kept whole ("van der Berg"), so
    "Anna van der Berg" -> ("anna", "van der berg").
    """
    tokens = _name_tokens(name)
    if not tokens:
        return "", ""
    if len(tokens) == 1:
        return tokens[0], ""
    # Walk back from the end over particles to keep compound surnames together.
    idx = len(tokens) - 1
    while idx > 1 and tokens[idx - 1] in _SURNAME_PARTICLES:
        idx -= 1
    return " ".join(tokens[:idx]), " ".join(tokens[idx:])


def names_agree(name_a: str, name_b: str) -> str:
    """``"agree"`` / ``"disagree"`` / ``"unsure"`` for two display names.

    TWO KNOWN LIMITATIONS, both deliberate, both erring towards review:

    1. Surname-last is assumed. For a name written surname-FIRST ("Wang Wei"),
       the given name and surname are swapped. In practice the verdict still
       comes out safe -- "Wang Wei" vs "Wang Min" compares "wei" against "yu",
       disagrees, and goes to review rather than merging two people -- but the
       stated REASON would be wrong. Proper handling needs a script/locale
       signal that the graph does not currently carry.

    2. Nicknames that are not string-similar are not recognised. "Bob" scores
       0.5 against "Robert", so Bob Jones and Robert Jones go to review rather
       than merging. A nickname lookup table would fix that pair, and was
       considered and rejected: the same table makes "Jack" a nickname for
       "John", which would merge a father and son sharing a landline. Review
       costs a click; that merge is unpickable.

    Only ``"agree"`` may auto-merge a pair that is joined by a SHAREABLE
    identifier. Both other verdicts mean "send it to human review"; they are
    separated so the caller can explain itself honestly to the operator.

    The rules, in order:

      * Either name missing            -> ``unsure``. Absence is not evidence.
      * Surnames both present:
          - different surnames         -> ``disagree``  (the Sandra case)
          - same surname, given names
            similar enough             -> ``agree``     (Jon / Jonathan Smith)
          - same surname, given names
            far apart                  -> ``unsure``    (John / Jane Smith)
      * No surname on one or both      -> ``agree`` only if the whole strings
                                          are near-identical, else ``unsure``.
    """
    a = " ".join(_name_tokens(name_a))
    b = " ".join(_name_tokens(name_b))
    if not a or not b:
        return "unsure"
    if a == b:
        return "agree"

    given_a, sur_a = split_given_surname(name_a)
    given_b, sur_b = split_given_surname(name_b)

    if sur_a and sur_b:
        if sur_a != sur_b:
            return "disagree"
        if not given_a or not given_b:
            return "unsure"
        if given_a == given_b:
            return "agree"
        sim = _jaro_winkler(given_a, given_b)
        return "agree" if sim >= GIVEN_NAME_AGREEMENT_THRESHOLD else "unsure"

    # One side has no surname: nothing to anchor on but the raw strings.
    return "agree" if _jaro_winkler(a, b) >= SINGLE_TOKEN_AGREEMENT_THRESHOLD else "unsure"
