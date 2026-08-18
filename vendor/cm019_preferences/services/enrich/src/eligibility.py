"""Decide whether a preference subject may be sent to a third-party API.

WHY THIS EXISTS, measured 2026-08-17 from install.log on a real install.

Enrichment routes a preference to a client by its CATEGORY, and most clients
put the preference's SUBJECT straight into an outbound query string. The
category is assigned by an upstream classifier, and that classifier is not
perfect. When it is wrong, the subject still gets sent.

On the shipped box, one of the ten book lookups sent openlibrary.org this,
as a book title:

    "Simon is an exceptionally customer-focussed, and knows how to handle
     challenging scenarios in an efficient manner. He is able to defuse
     potentially incendiary situations quickly by his calm and courteous
     demeanour ..."                                         [400+ characters]

That is a LinkedIn recommendation about a named individual. It left the
customer's Mac, as a query, to a third party, because a classifier put it in
`book`. The same run had a paragraph of personal narrative sitting in
category `music`, one step away from going to MusicBrainz.

So this is not a data-quality filter. It is an egress control. It sits
between the classifier and the network, and it fails closed.

WHAT IT CATCHES
    Prose. Personal narrative. Testimonials. Anything with the shape of
    writing rather than the shape of a title or a name. The three signals
    are length, word count and sentence count, because those are robust
    across languages and cannot be fooled by vocabulary.

WHAT IT DOES NOT CATCH, AND WILL NOT
    A short, plausible-looking name in the wrong category. The single
    enrichment that exists in the product today is "Robert Walters" matched
    as a musical artist at 0.93 confidence. Robert Walters is a recruitment
    firm. Nothing about the STRING is wrong, so no shape test can reject it.
    That is a classifier problem and it needs a classifier fix. Do not read
    this module as covering it.

WHICH WAY IT ERRS
    Toward rejection. A rejected subject loses its enrichment. An accepted
    testimonial is personal text in someone else's logs, permanently. Those
    costs are not symmetric, so a genuinely long book title will sometimes
    be refused, and that is the correct trade.
"""

import re
from typing import Optional, Tuple

# Clients that place the SUBJECT into an outbound query. These are the ones
# the gate defends. Deliberately a positive list, keyed on the same client
# names as EnrichmentService.CATEGORY_CLIENTS, so a NEW client is ungated
# until someone adds it here on purpose rather than silently inheriting a
# policy that was never considered for it.
SUBJECT_IS_THE_QUERY = frozenset({
    "openlibrary",
    "tmdb",
    "musicbrainz",
    "wikidata",
    "wikidata_brand",
    "wikidata_film",
    "wikidata_place",
    "google_places",
    "foursquare",
    "events",
    "podcast_index",
})

# `url_fetcher` keys off extra["domain"], and `youtube` off a video id, so
# neither sends the subject anywhere. They are not in the set above and are
# not gated. That is a statement about what those clients DO, not an
# oversight -- if either starts querying by subject, it belongs in the set.

MAX_CHARS = 120
MAX_WORDS = 14

# A sentence terminator followed by whitespace and a capital: the join
# between two sentences. One title may legitimately contain a full stop
# ("Dr. Strangelove"); a run of sentences is prose.
_SENTENCE_JOIN = re.compile(r"[.!?][\"')\]]?\s+[A-Z\"'(\[]")

_EMAIL = re.compile(r"[^\s@]+@[^\s@]+\.[A-Za-z]{2,}")


def _reason(subject: str) -> Optional[str]:
    """Return a rejection reason, or None if the subject is safe to send."""
    if not subject or not subject.strip():
        return "empty"

    s = subject.strip()

    if "\n" in s or "\r" in s:
        return "multi-line: a title is one line"

    n_chars = len(s)
    if n_chars > MAX_CHARS:
        return f"too long: {n_chars} chars (limit {MAX_CHARS})"

    n_words = len(s.split())
    if n_words > MAX_WORDS:
        return f"too many words: {n_words} (limit {MAX_WORDS})"

    if _SENTENCE_JOIN.search(s):
        return "reads as prose: contains a sentence boundary"

    if _EMAIL.search(s):
        return "contains an email address"

    return None


def is_eligible(
    client_name: Optional[str],
    subject: str,
    category_inferred: bool = False,
) -> Tuple[bool, Optional[str]]:
    """
    May this subject be sent to this client as a query?

    Args:
        client_name: the client the category routes to, as named in
                     EnrichmentService.CATEGORY_CLIENTS. None means no
                     client, which is not this module's business.
        subject:     the preference subject that would become the query.
        category_inferred:
                     True when the routing category was GUESSED from the
                     subject text rather than declared by the source. See
                     below -- this is the limb the shape tests cannot cover.

    Returns:
        (True, None) to proceed, or (False, reason) to skip. The reason is
        for the operator's log, and names what was wrong with the SHAPE --
        it never quotes the subject back, because the subject is the thing
        we have just decided is too sensitive to hand around.
    """
    if client_name is None or client_name not in SUBJECT_IS_THE_QUERY:
        return True, None

    # A GUESSED CATEGORY IS NOT AUTHORITY TO SEND. This is the limb the
    # docstring at the top of this file said was owed and out of scope:
    # "a short, plausible-looking name in the wrong category ... is a
    # classifier problem and it needs a classifier fix."
    #
    # It is checked BEFORE the shape tests on purpose. Shape cannot tell a
    # LinkedIn InMail subject from a film title -- both are short, one line,
    # title-cased, no sentence join. Measured on Andy's v1.0.35 box: eight
    # such subjects, carrying third-party company names, reached Wikidata and
    # a music service because csv_parser inferred music/movie/tv from a
    # substring match ("Technology" -> "techno"). Every category that fallback
    # can return routes to a client in SUBJECT_IS_THE_QUERY, including the
    # `interest` catch-all, so there is no safe category to guess into.
    #
    # The cost of refusing is a missed enrichment. The cost of accepting is
    # somebody else's data in a third party's logs, permanently. Not symmetric.
    if category_inferred:
        return False, "category was inferred from the subject, not declared by the source"

    reason = _reason(subject)
    if reason is None:
        return True, None
    return False, reason
