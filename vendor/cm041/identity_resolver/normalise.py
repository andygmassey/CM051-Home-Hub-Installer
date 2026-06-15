from __future__ import annotations

import re
import unicodedata

import phonenumbers


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
       (``🌼Gemma🌼 Brewster`` -> ``Gemma Brewster``,
       ``🔍 Fermi Fang`` -> ``Fermi Fang``).
    2. Strip leading/trailing runs of decorative punctuation / format chars
       (``#AXA HK`` -> ``AXA HK``).
    3. Collapse internal whitespace runs to single spaces.
    4. Collapse an EXACT duplicate-token name to a single token
       (``AC AC`` -> ``AC``, ``Gemma Gemma`` -> ``Gemma``). Only fires
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
    """Jaro-Winkler string similarity (0.0 to 1.0)."""
    if s1 == s2:
        return 1.0
    len1, len2 = len(s1), len(s2)
    if len1 == 0 or len2 == 0:
        return 0.0

    match_distance = max(len1, len2) // 2 - 1
    if match_distance < 0:
        match_distance = 0

    s1_matches = [False] * len1
    s2_matches = [False] * len2

    matches = 0
    transpositions = 0

    for i in range(len1):
        start = max(0, i - match_distance)
        end = min(i + match_distance + 1, len2)
        for j in range(start, end):
            if s2_matches[j] or s1[i] != s2[j]:
                continue
            s1_matches[i] = True
            s2_matches[j] = True
            matches += 1
            break

    if matches == 0:
        return 0.0

    k = 0
    for i in range(len1):
        if not s1_matches[i]:
            continue
        while not s2_matches[k]:
            k += 1
        if s1[i] != s2[k]:
            transpositions += 1
        k += 1

    jaro = (
        matches / len1 + matches / len2 + (matches - transpositions / 2) / matches
    ) / 3

    # Winkler modification: boost for common prefix (up to 4 chars)
    prefix = 0
    for i in range(min(4, len1, len2)):
        if s1[i] == s2[i]:
            prefix += 1
        else:
            break

    return jaro + prefix * 0.1 * (1 - jaro)


def _country_code_to_region(code: int) -> str:
    """Map a numeric country calling code to an ISO region for phonenumbers parsing."""
    # phonenumbers.region_codes_for_country_code returns a tuple of region codes.
    regions = phonenumbers.region_codes_for_country_code(code)
    if regions:
        return regions[0]
    return "US"
