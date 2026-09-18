# Privacy fields we WRITE and do not ENFORCE

Measured 2026-09-16 on `origin/main` at `bc17a0bb`.

This file exists because three of the four defects behind it shared one
shape: a privacy field is computed, stamped onto every record, and read by
nothing in the shipped artefact. A stamp is not an enforcement. Each entry
below names what is true, what is not, and what the customer would actually
experience, so that nobody reasons from the presence of a field to the
existence of the behaviour it describes.

Entries are removed only when the reader ships and a probe moves, never
when the writer is improved.

---

## 1. AI-conversation transcript `privacy_level` has no reader in the cut

**Status: OPEN. Declared, not enforced.**

`vendor/cm052_ai_conversations/src/cm052/wire.py:278` stamps the transcript
artefact with a privacy level, defaulting to `L3` as of this change (it
defaulted to `L2`, against the locked contract in `CLAUDE.md`, until
2026-09-16). The level lands in the markdown frontmatter of every file under
`~/Documents/Ostler/AI Conversations/`.

**Nothing in the DMG reads it back.** Measured:

| probe | result |
| --- | --- |
| files under `vendor/` matching `services/mcp` | 0 |
| files named `server.py` anywhere in the repo | 0 |
| CM044 wiki renderer under `vendor/` | absent |
| POSITIVE CONTROL: files in `vendor/cm019_preferences` | 84 |

The read-side `get_conversation` withholding that `CLAUDE.md` pairs with
this default is implemented at CM019 `services/mcp/src/server.py:478`, and
the MCP server is not part of the customer install. Every `get_conversation`
and `request_unredacted` reference inside this repo is a comment describing
a tool that ships elsewhere: `wire.py:33`, `wire.py:308`, `wire.py:444`,
`vendor/cm048_pipeline/src/privacy.py:12-13`, `privacy.py:33`,
`vendor/cm048_pipeline/src/conversation_writer.py:28`,
`conversation_writer.py:354`, `conversation_writer.py:456`,
`vendor/cm048_pipeline/src/processor.py:127`,
`vendor/ostler_fda/universal_import.py:1253`.

**What IS enforced:** the *gist* limb. `wire.py` short-circuits the CM048
POST when the gist level resolves to `L3`, in the shipped payload, so a
conversation the user marks `L3` is genuinely never embedded for search.
That half works today.

**What a customer experiences:** an AI transcript stamped `L3` is written to
disk, correctly labelled, and no shipped surface acts on the label. Nothing
currently renders those transcripts either, so there is no live leak; the
gap is that the label will not start being honoured merely because it is
now correct.

**To close:** either vendor a level-aware reader into the cut, or drop the
per-artefact transcript level and say the file's location is its only
protection. Closing it needs a probe whose subject is a person reading a
wiki page, not a file carrying a field.

---

## 2. `retention_tier` is written on every record and read by nothing

**Status: OPEN. Decorative.**

Written at:

- `vendor/cm048_pipeline/src/ingest.py` -- the Qdrant `base_payload`, spread
  into every `conversation_summary` and `fact` point and PUT to Qdrant.
- `vendor/cm048_pipeline/src/ingest.py` -- the SQLite `observations` DDL
  (`retention_tier TEXT NOT NULL`) and its INSERT.
- `vendor/cm048_pipeline/src/ingest.py` `_retention_tier_for` -- the
  classifier that produces the value.

Measured with `git grep -n retention_tier -- .`: **11 hits, 0 readers, 0
tests.** The remaining seven are CM048 prose and prompt templates. A search
for a sweeper, expiry, purge or TTL job across `vendor/`, `scripts/` and all
15 launchd plists returns nothing that acts on a tier; every apparent hit is
substring noise (`ThrottleInterval`, "throttled", "settle") or the GitHub
Actions `retention-days` artifact setting.

**What a customer experiences:** nothing expires. A record classified
`tier-3-years` is retained exactly as long as one classified
`tier-1-forever`. **There is no right-to-erasure mechanism behind the
retention tiers, so they must not be described to a customer as though
there is one.**

The companion field `retention_score_inputs`, named in `PLAN.md` and the
prompt templates, has zero source-code hits: it is written by nothing.

`vendor/cm048_pipeline/PLAN.md` pointed at `HR015/DATA_RETENTION.md` for the
cross-cutting spec. No file matching `*retention*` exists in the repo and
none ever did. That pointer has been corrected to say so rather than send
the next reader looking for a document that cannot be found.

**To close:** a sweeper is a DELETION of customer data and needs a designed,
consented, reversible mechanism plus a restore story -- it is not a
follow-on commit to this one. Until it exists, `RETENTION_TIERS` in
`ingest.py` carries the durations, so the policy is at least auditable
rather than encoded in strings nothing parses.

---

## 3. Calendar `pwg:aboutPerson` is withheld from the operator's own diary

**Status: OPEN. Noticed while fixing the calendar privacy default; not
fixed here.**

`vendor/cm041/contact_syncer/google_calendar.py` stamps
`pwg:aboutPerson <operator>` only when `_owner_denotes_operator(owner)`
holds. That predicate matches the tokens `you / me / self / myself /
my calendar / operator`, or the configured `USER_DISPLAY_NAME`.

On a real Google Takeout export the owner label comes from `X-WR-CALNAME`,
which for a primary calendar is **the account's email address** -- the
module's own docstring lists an address-shaped value among its examples. An
email address never equals a human display name, so the predicate is False
for the operator's own diary.

MEASURED 2026-09-16, against both calendar shapes a Takeout produces
(primary named by address, shared calendar named "Family"):
`_owner_denotes_operator` returned False for **2 of 2**, including the
operator's own. So `pwg:aboutPerson` is written for neither, and an
operator-scoped `aboutPerson=<operator>` read returns none of the
customer's own calendar events.

This is the fail-closed direction, so it leaks nothing -- which is why it
is filed rather than rushed. Fixing it means teaching the ingest the
operator's own addresses, which is a real identity question and wants its
own change and its own probe.

**To close:** resolve the operator's own calendar from the configured
operator identity rather than from a display-name token match, and prove it
with a probe whose denominator is the calendars in a real export.
