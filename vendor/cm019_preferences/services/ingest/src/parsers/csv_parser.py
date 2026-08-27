"""Generic CSV parser for preferences."""

import csv
import logging
import re
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, List, Sequence
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------
# EMAIL-EXPORT GUARD
#
# WHY THIS EXISTS. `csv` is a FORMAT, not a SOURCE. CSVParser is registered
# LAST in the pipeline as the catch-all fallback (see pipeline.py), and its
# subject-column detection is deliberately wide -- "subject" is the very first
# alias it looks for. An export of EMAIL SUBJECT LINES therefore lands in the
# fallback, is claimed on its first column, and every row becomes a
# "preference" with a keyword-guessed category.
#
# Five preference categories on a measured box were made ENTIRELY of one such
# file. That is the mechanism behind recruiter subject lines rendering as
# films, "Coffee meeting" as food, and a job ad as a place: one unattributed
# source, scattered by keyword.
#
# WHERE THE FIX BELONGS. At the WRITE side. A render-side filter would have to
# be re-implemented by every present and future consumer of the store (the
# wiki, the assistant, search, export) and each one is a separate exit. The
# row must not be written at all.
#
# WHAT THIS DOES NOT DO. It does not repair points already in the store --
# they were written by the previous code and stay until a repair pass deletes
# them. A green run of this gate is evidence about FUTURE ingests only.
# --------------------------------------------------------------------------

# Reply/forward prefixes across the locales a mail client is likely to stamp.
# `Re:` `RE:` `Fw:` `Fwd:` `AW:` (de) `TR:` (fr) `SV:` (da/no/sv) `Antw:` (nl),
# optionally counted ("Re[2]:"). Anchored: a subject may legitimately CONTAIN
# "re:" mid-string, only a PREFIX is the mail-client signature.
_REPLY_PREFIX = re.compile(
    r"^\s*(?:re|fw|fwd|aw|tr|sv|vs|antw|rif|odp)\s*(?:\[\d+\])?\s*:",
    re.IGNORECASE,
)

# Column names that only ever appear in a mail export. "subject" is NOT here
# and must not be: it is also PWG's own canonical preference column, so it
# cannot discriminate. These can.
_EMAIL_ONLY_HEADERS = frozenset({
    "from", "to", "cc", "bcc", "sender", "recipient", "recipients",
    "reply-to", "reply_to", "replyto",
    "message-id", "message_id", "messageid",
    "in-reply-to", "in_reply_to",
    "thread-id", "thread_id", "threadid", "x-gm-thrid",
    "delivered-to", "return-path", "envelope-to",
    "mailbox", "folder", "labels",
})

# A genuine preference CSV does not carry reply prefixes. One row might be a
# coincidence; a twentieth of the file is a mail export.
_EMAIL_ROW_RATIO = 0.05

# Below this many rows the ratio is noise -- three rows with one "Re:" is 33%
# and means nothing. Small files are still covered row-by-row by
# ``_is_reply_subject``; only the whole-FILE verdict needs the floor.
_EMAIL_RATIO_MIN_ROWS = 20


def _is_reply_subject(subject: str) -> bool:
    """True if this string carries a mail client's reply/forward prefix."""
    return bool(_REPLY_PREFIX.match(subject or ""))


def _email_export_reason(
    fieldnames: Sequence[str],
    subjects: Sequence[str],
) -> Optional[str]:
    """Return why this CSV is a mail export, or None if it may be ingested.

    The reason names the EVIDENCE and never quotes a subject back. It goes
    into the operator's ingest log, and a log is another surface -- the whole
    point of this gate is that these strings are other people's mail.
    """
    headers = {(f or "").strip().lower() for f in fieldnames}
    hit = sorted(headers & _EMAIL_ONLY_HEADERS)
    if hit:
        return (
            "carries mail-export columns "
            f"({', '.join(hit)}): an email is not a preference"
        )

    n = len(subjects)
    if n >= _EMAIL_RATIO_MIN_ROWS:
        replies = sum(1 for s in subjects if _is_reply_subject(s))
        ratio = replies / n
        if ratio >= _EMAIL_ROW_RATIO:
            return (
                f"{replies} of {n} rows ({ratio:.1%}) carry a reply/forward "
                f"prefix, over the {_EMAIL_ROW_RATIO:.0%} threshold: "
                "this is an email subject-line export, not preference data"
            )

    return None


class CSVParser(BaseParser):
    """
    Generic CSV parser for preference data.

    Expected columns (flexible - many alternatives supported):
    - subject: What the preference is about
      Alternatives: name, title, label, description, subreddit, destination,
                   product, track, artist, url, and many more
    - type/preference_type: Like, Dislike, Love, Hate, Neutral
    - strength/rating: Numeric strength 0-1 or 1-5 or 1-10
    - category: Category of the preference
    - compartment/compartment_level: Privacy level 0-6
    - context: Context for the preference
    - date/created_at/observed_at: When preference was recorded

    The parser auto-detects subject columns from a wide range of common names
    used in platform data exports (Reddit, Uber, Spotify, etc.).
    """

    source_name = "csv"

    # Column name mappings (lowercase)
    # Extended subject mappings to handle diverse CSV formats from various platforms
    COLUMN_MAPPINGS = {
        "subject": [
            "subject", "name", "item", "thing", "what", "preference",
            # Common column names from platform exports
            "title", "label", "description", "text", "content", "value",
            # Social media specific
            "subreddit", "topic", "hashtag", "tag",
            # Location/travel specific
            "destination", "location", "address", "place",
            # Product/media specific
            "product", "product_name", "product_type", "track", "artist", "album",
            "movie", "show", "book", "podcast", "episode",
            # URL/link content
            "url", "link", "uri",
        ],
        "type": ["type", "preference_type", "pref_type", "kind"],
        "strength": ["strength", "rating", "score", "value", "intensity"],
        # NB: "type" deliberately removed from the category aliases. It also
        # appears under the "type" (preference-type) key above, so a CSV with a
        # `type` column (Like/Dislike/...) was wrongly mapping the preference
        # TYPE into the category field -- producing junk categories like "Like"
        # and pre-empting the subject inference below. A preference type is not
        # a category.
        "category": ["category", "cat", "group", "genre"],
        "compartment": ["compartment", "compartment_level", "privacy", "level"],
        "context": ["context", "situation", "when", "where"],
        "date": ["date", "created_at", "observed_at", "timestamp", "time", "datetime"]
    }

    # Subject-keyword -> canonical category fallback.
    #
    # A generic CSV with no `category` column previously produced points with
    # category=None. The wiki reads `category` off every preference: the Food
    # page filters category == "food", the Music page category == "music", and
    # each Topic page is one distinct category value. A None category reaches
    # NO page, so those points silently vanish from the wiki. This map gives an
    # uncategorised row a best-effort canonical category (the exact strings the
    # wiki readers expect) from keywords in its subject. It is intentionally
    # conservative -- only confident hits map to a specific category; everything
    # else falls back to "interest" (a real category that renders a Topic page)
    # rather than None. Categories here match the canonical vocabulary used by
    # the platform parsers (spotify/uber/etc.) and enrich's VALID_CATEGORIES.
    SUBJECT_CATEGORY_KEYWORDS = {
        "music": (
            "song", "album", "artist", "band", "track", "playlist", "spotify",
            "concert", "gig", "vinyl", "guitar", "jazz", "techno", "hip hop",
            "hip-hop",
        ),
        "food": (
            "restaurant", "cuisine", "dish", "recipe", "cafe", "café", "coffee",
            "pizza", "sushi", "ramen", "burger", "cooking", "dining", "bakery",
            "wine", "beer", "cocktail", "vegan", "vegetarian", "takeaway",
        ),
        "movie": ("movie", "film", "cinema", "director", "documentary"),
        "tv": ("tv show", "tv series", "episode", "season", "netflix series"),
        "book": ("book", "novel", "author", "reading", "audiobook"),
        "podcast": ("podcast",),
        "place": (
            "travel", "destination", "city", "country", "hotel", "holiday",
            "vacation", "flight", "beach",
        ),
        "professional": (
            "career", "skill", "industry", "linkedin", "job", "profession",
            "certification", "conference",
        ),
    }

    def _infer_category(self, subject: str) -> str:
        """Best-effort canonical category from the subject text.

        Returns a specific category when a confident keyword matches, else
        "interest" -- never an empty/None value, so the point always reaches
        a wiki Topic page instead of silently disappearing.
        """
        text = (subject or "").lower()
        for category, keywords in self.SUBJECT_CATEGORY_KEYWORDS.items():
            for kw in keywords:
                # WORD BOUNDARY, not `kw in text`. Measured 2026-08-18 on Andy's
                # v1.0.35 box: substring matching put 12 of 12 ordinary business
                # subjects in a media category. "Technology" contains "techno"
                # (-> music), "bandwidth" and "husband" contain "band", "capacity"
                # and "electricity" contain "city", "Facebook" and "Booking"
                # contain "book", "Gigabyte" contains "gig", "concerted" contains
                # "concert". Real LinkedIn InMail subjects were then sent to
                # MusicBrainz and Wikidata as title lookups.
                #
                # \b would also match across an underscore; (?<!\w)/(?!\w) does
                # not, and a keyword abutting an underscore is not a word use.
                if re.search(r"(?<!\w)" + re.escape(kw) + r"(?!\w)", text):
                    return category
        return "interest"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a CSV."""
        return file_path.suffix.lower() == ".csv"

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        default_category: Optional[str] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse a CSV file and yield preferences.

        Args:
            file_path: Path to CSV file
            default_compartment: Default compartment level if not in CSV
            default_category: Default category if not in CSV
        """
        if default_compartment is None:
            default_compartment = settings.default_compartment

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        # Parse CSV
        reader = csv.DictReader(content.splitlines())
        fieldnames = reader.fieldnames or []

        # Map actual columns to standard names
        column_map = self._map_columns(fieldnames)

        if "subject" not in column_map:
            # Not an error: the generic CSV parser is the fallback for arbitrary
            # CSVs, and most (e.g. LinkedIn auxiliary exports -- Rich_Media,
            # PhoneNumbers, Ad_Targeting, SearchQueries, Logins, Registration,
            # Education, etc.) legitimately carry no preference "subject" column.
            # Log at DEBUG so a clean install does not spam WARNINGs; a genuinely
            # malformed preference CSV is still skipped (and visible at -v).
            logger.debug(
                f"CSV has no recognized subject column: {file_path}. "
                f"Available columns: {reader.fieldnames}. "
                f"Skipping (not a preference CSV)."
            )
            return

        # EMAIL-EXPORT GUARD (see module header). The whole file is already in
        # memory above, so materialising the rows to reach a file-level verdict
        # costs nothing extra -- and the verdict genuinely needs the whole file:
        # the reply-prefix ratio is a property of the FILE, not of any one row.
        rows: List[Dict[str, str]] = list(reader)
        subject_col = column_map["subject"]
        subjects = [(r.get(subject_col) or "").strip() for r in rows]

        reason = _email_export_reason(fieldnames, subjects)
        if reason is not None:
            logger.warning(
                "REFUSED %s: %s. Ingested 0 of %d rows. "
                "`csv` is a format, not a source -- a file that reaches the "
                "generic CSV fallback has no declared provenance, and mail "
                "subject lines keyword-matched into preference categories are "
                "what put recruiter subjects under Films & TV.",
                file_path,
                reason,
                len(rows),
            )
            return

        row_count = 0
        reply_rows = 0
        for row in rows:
            try:
                # Row-level backstop. A file can pass the whole-file verdict and
                # still contain mail -- a mixed export, or a mail export too
                # short for the ratio floor to speak. A reply prefix is the mail
                # client's own stamp; it is never part of a preference.
                if _is_reply_subject((row.get(subject_col) or "").strip()):
                    reply_rows += 1
                    continue

                pref = self._parse_row(row, column_map, default_compartment, default_category)
                if pref:
                    row_count += 1
                    yield pref
            except Exception as e:
                logger.warning(f"Failed to parse row: {e}")
                continue

        if reply_rows:
            logger.warning(
                "Dropped %d of %d rows from %s: reply/forward prefix "
                "(mail, not preference data)",
                reply_rows,
                len(rows),
                file_path,
            )

        logger.info(f"Parsed {row_count} preferences from {file_path}")

    def _map_columns(self, fieldnames: list) -> Dict[str, str]:
        """Map actual column names to standard names."""
        column_map = {}
        fieldnames_lower = {f.lower(): f for f in fieldnames}

        for standard_name, possible_names in self.COLUMN_MAPPINGS.items():
            for possible in possible_names:
                if possible in fieldnames_lower:
                    column_map[standard_name] = fieldnames_lower[possible]
                    break

        return column_map

    def _parse_row(
        self,
        row: Dict[str, str],
        column_map: Dict[str, str],
        default_compartment: int,
        default_category: Optional[str]
    ) -> Optional[ParsedPreference]:
        """Parse a single CSV row into a preference."""
        # Get subject (required)
        subject = row.get(column_map.get("subject", ""), "").strip()
        if not subject:
            return None

        # Get preference type
        pref_type = row.get(column_map.get("type", ""), "Like").strip()
        if pref_type.lower() not in ("like", "dislike", "love", "hate", "neutral"):
            pref_type = "Like"

        # Get strength
        strength_str = row.get(column_map.get("strength", ""), "")
        strength = self.classify_strength(strength_str) if strength_str else 0.5

        # Get category: explicit CSV column wins, then the caller-supplied
        # default, then a subject-keyword inference so a row never lands with
        # no category (which would make it invisible to every wiki page).
        category = row.get(column_map.get("category", ""), "").strip() or default_category
        category_inferred = False
        if not category:
            category = self._infer_category(subject)
            # A GUESSED CATEGORY MUST NOT AUTHORISE EGRESS.
            #
            # Enrichment routes by category, and EVERY category this fallback
            # can return sends the SUBJECT to a third party as a query string.
            # Measured 2026-08-18 against enricher.CATEGORY_CLIENTS and
            # eligibility.SUBJECT_IS_THE_QUERY:
            #
            #   music->musicbrainz  book->openlibrary  movie/tv->wikidata_film
            #   food->wikidata      place->wikidata_place  podcast->podcast_index
            #   interest->wikidata   <-- the catch-all default egresses too
            #
            # So word-boundary matching alone is not enough: it takes 12 wrong
            # in 12 down to 2, and those 2 still leave the machine. Only
            # provenance closes it. eligibility.is_eligible() refuses any
            # subject whose category was inferred rather than declared.
            category_inferred = True

        # Get compartment level
        compartment_str = row.get(column_map.get("compartment", ""), "")
        try:
            compartment = int(compartment_str) if compartment_str else default_compartment
            compartment = max(0, min(6, compartment))
        except ValueError:
            compartment = default_compartment

        # Get context
        context = row.get(column_map.get("context", ""), "").strip() or None

        # Get date
        date_str = row.get(column_map.get("date", ""), "").strip()
        observed_at = None
        if date_str:
            for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%m/%d/%Y"):
                try:
                    observed_at = datetime.strptime(date_str, fmt)
                    break
                except ValueError:
                    continue

        # Classify size
        size = self.classify_size(subject, category)

        return ParsedPreference(
            subject=subject,
            preference_type=pref_type.capitalize(),
            strength=strength,
            compartment_level=compartment,
            source=self.source_name,
            category=category,
            context=context,
            observed_at=observed_at,
            size=size,
            # Provenance, read by eligibility.is_eligible() before any outbound
            # query. Stated on every row, True or False, never left absent:
            # absence is reserved to mean "stored before this field existed",
            # which eligibility refuses. A row whose CSV declared its category
            # says so explicitly and enriches exactly as before.
            extra={"category_inferred": bool(category_inferred)},
        )
