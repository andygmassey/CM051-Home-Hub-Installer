"""Customer-facing string catalogue for CM048.

Rule 0.9 (locked 2026-05-19 in HR015 memory
``feedback_customer_strings_extractable_from_day_one`` + PRODUCTISATION_CHECKLIST):
every customer-facing string lives in a per-repo extractable catalogue
from day one. CM048 v1.0 shipped these strings inline; this module is
the v1.1 lift so v1.2 +1-language work is a translation effort, not a
refactor effort.

Convention mirrors CM048's existing ``prompts.py`` module: plain Python
module, frozen ``str`` constants at module scope, no I/O at import
time. Templates use ``.format()``-style ``{placeholder}`` interpolation
rather than f-strings so the catalogue values stay declarative and the
caller can call ``.format(...)`` against the constant.

Locale: en-GB. Single-locale at v1.1; a future module shape (e.g.
``copy_de.py``) is the v1.2 translation target.

----------------------------------------------------------------------
Apple Restraint rule (encoded in ``reminders_push.py`` file header,
preserved here verbatim)
----------------------------------------------------------------------

The Apple Reminders push titles + notes MUST NOT carry:

  * Emoji prefixes ("[OK] Follow up..." / sparkle / robot / lock icons).
    The operator's Reminders.app list is theirs; we render plain text.

  * App-brand tags ("[Ostler] Follow up...") in the title. The notes
    body may carry a ``file://`` deep link to the source artefact, but
    the title is text only.

  * Source labels in the title ("from iMessage: Follow up..." or
    "from WhatsApp: ..."). The notes body carries the context line
    that names the conversation partner + date.

  * Transcript dump in the notes body. Apple Restraint is "the user
    doesn't want their conversations in their reminders body"; the
    notes line is a one-line context + ``file://`` link only.

Any future translation must preserve these properties. The catalogue
values below already do.

----------------------------------------------------------------------
Cross-repo frozen contract: markdown headings consumed by CM044
----------------------------------------------------------------------

The episodic markdown headings rendered by ``conversation_writer.py``
(``# Summary``, ``## Topics``, ``# Transcript``, ``# Todos``) are
ALSO load-bearing for CM044's wiki renderer. CM044 parses them as
anchors to render the per-section wiki view. Renaming any of these
breaks the wiki silently. The four heading constants below are
therefore byte-equal to their pre-lift inline values; the same is
true for the empty-state placeholders (``_(transcript was empty for
this conversation)_`` + ``_(none extracted)_``) that the wiki may
detect when deciding whether to show a "no content" pill.

If any future PR proposes renaming a heading, that is a CM048 +
CM044 PR pair (and possibly a CM052 wire schema bump), not a CM048-
only change.

----------------------------------------------------------------------
Out of scope
----------------------------------------------------------------------

``print()`` statements in ``src/cli.py`` are explicitly operator-facing
(the ``pwg-convo`` CLI is documented as a developer entry point). They
are not catalogued here. The Rule 0.9 lint guard's CM048 block
deliberately scopes to the three customer-rendered files only.

``prompts.py`` is a separate concern (LLM prompt templates loaded from
``prompts/*.md``); not catalogued here.
"""
from __future__ import annotations


# ---------------------------------------------------------------------------
# Reminders push titles
# ---------------------------------------------------------------------------
# Rendered into Apple Reminders.app and iCloud-synced to the operator's
# iPhone. Highly visible. Format with ``.format(participant=..., deadline=...)``
# where the template includes the matching placeholder.

# L2 + one-on-one: name the conversation partner via @-handle.
FOLLOW_UP_WITH_PERSON_TITLE = "Follow up with @{participant}"

# L2 + multi-party: do not name a specific participant (would mis-attribute).
FOLLOW_UP_ON_CONVERSATION_TITLE = "Follow up on conversation"

# L2 + solo bundle: e.g. a voice-memo to self, no non-user participants.
FOLLOW_UP_ON_COMMITMENT_TITLE = "Follow up on commitment"

# Title suffix when a deadline is attached. Joined to the base title with
# a literal " -- " separator (two ASCII hyphens, NOT an em-dash) per
# the no-em-dash brand rule (HR015 memory feedback_no_em_dashes).
TITLE_DEADLINE_SUFFIX = " -- {deadline}"

# Used when a todo has no meaningful text after stripping (the gate
# already filters empty todos; this is a defence-in-depth fallback that
# only ever surfaces if the gate path is bypassed).
EMPTY_COMMITMENT_TITLE = "(empty commitment)"


# ---------------------------------------------------------------------------
# Reminders push notes (body)
# ---------------------------------------------------------------------------
# One-line context above a ``file://`` deep link to the source ``summary.md``.

# L2: redacted context line, no participant names, no conversation content.
NOTES_PRIVATE_CONTEXT = "From a private conversation on {started}"

# L0 / L1 + identifiable single partner.
NOTES_CONVERSATION_WITH_PERSON = "From conversation with @{participant} on {started}"

# L0 / L1 + multi-party or unknown partner.
NOTES_CONVERSATION_WITH_GROUP = "From conversation with the group on {started}"

# Fallback when ``bundle.started_at`` is missing or malformed.
NOTES_UNKNOWN_DATE = "unknown date"


# ---------------------------------------------------------------------------
# Episodic markdown headings (load-bearing for CM044 wiki renderer)
# ---------------------------------------------------------------------------
# FROZEN cross-repo contract. CM044 parses these as anchors. Renaming
# requires a CM048 + CM044 PR pair.

SUMMARY_HEADING = "# Summary"
TOPICS_HEADING = "## Topics"
TRANSCRIPT_HEADING = "# Transcript"
TODOS_HEADING = "# Todos"

# Default topic label when ``Topic.name`` is empty / whitespace.
TOPIC_FALLBACK_NAME = "Topic"

# Empty-state placeholders rendered inside the heading sections.
TRANSCRIPT_EMPTY_PLACEHOLDER = "_(transcript was empty for this conversation)_"
TODOS_EMPTY_PLACEHOLDER = "_(none extracted)_"

# Fallback when a todo's text is empty / whitespace after stripping.
TODO_EMPTY_TEXT_PLACEHOLDER = "(empty)"


# ---------------------------------------------------------------------------
# HTTP API errors (semi-customer-facing)
# ---------------------------------------------------------------------------
# Sent as the JSON body's ``error`` key on validation / runtime failures.
# Surfaced to the browser-extension dev tools console + future error
# toast. Keep them short, actionable, en-GB, no jargon.

ERROR_EMPTY_REQUEST_BODY = "Empty request body"
ERROR_REQUEST_BODY_TOO_LARGE = "Request body too large"
ERROR_CONTENT_TYPE_NOT_JSON = "Content-Type must be application/json"
ERROR_INVALID_JSON = "Invalid JSON: {detail}"
ERROR_MISSING_TRANSCRIPT_PATH = "Missing required field: transcript_path"
ERROR_MISSING_METADATA_PATH = "Missing required field: metadata_path"
ERROR_TRANSCRIPT_NOT_FOUND = "Transcript file not found: {path}"
ERROR_METADATA_NOT_FOUND = "Metadata file not found: {path}"
ERROR_INVALID_METADATA_JSON = "Invalid metadata JSON: {detail}"
ERROR_METADATA_MISSING_CONVERSATION_ID = (
    "metadata.json must include a conversation_id"
)
ERROR_LIBRARY_UNAVAILABLE = (
    "CM048 processing library is not available in this server's "
    "Python environment. Service requires CM048 to be installed "
    "(pip install -e .) and re-deployed. See server logs for the "
    "underlying ImportError."
)


__all__ = [
    # Reminders titles
    "FOLLOW_UP_WITH_PERSON_TITLE",
    "FOLLOW_UP_ON_CONVERSATION_TITLE",
    "FOLLOW_UP_ON_COMMITMENT_TITLE",
    "TITLE_DEADLINE_SUFFIX",
    "EMPTY_COMMITMENT_TITLE",
    # Reminders notes
    "NOTES_PRIVATE_CONTEXT",
    "NOTES_CONVERSATION_WITH_PERSON",
    "NOTES_CONVERSATION_WITH_GROUP",
    "NOTES_UNKNOWN_DATE",
    # Markdown headings (frozen cross-repo contract with CM044)
    "SUMMARY_HEADING",
    "TOPICS_HEADING",
    "TRANSCRIPT_HEADING",
    "TODOS_HEADING",
    "TOPIC_FALLBACK_NAME",
    "TRANSCRIPT_EMPTY_PLACEHOLDER",
    "TODOS_EMPTY_PLACEHOLDER",
    "TODO_EMPTY_TEXT_PLACEHOLDER",
    # HTTP API errors
    "ERROR_EMPTY_REQUEST_BODY",
    "ERROR_REQUEST_BODY_TOO_LARGE",
    "ERROR_CONTENT_TYPE_NOT_JSON",
    "ERROR_INVALID_JSON",
    "ERROR_MISSING_TRANSCRIPT_PATH",
    "ERROR_MISSING_METADATA_PATH",
    "ERROR_TRANSCRIPT_NOT_FOUND",
    "ERROR_METADATA_NOT_FOUND",
    "ERROR_INVALID_METADATA_JSON",
    "ERROR_METADATA_MISSING_CONVERSATION_ID",
    "ERROR_LIBRARY_UNAVAILABLE",
]
