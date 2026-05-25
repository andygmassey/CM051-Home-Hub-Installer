from __future__ import annotations

import phonenumbers


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
