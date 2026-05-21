# Prompt 02 - Enrich: correspondence (email thread)

**Stage:** enrichment for email-channel conversations (runs after
classifier, before relationship / coach / fact extraction).
**Model:** large. `qwen3.5:35b-a3b` on the Hub.
**Input:** full thread transcript (one turn per message, headers
reconstructed) + classifier output + metadata + email_thread sidecar.
**Output:** single markdown document matching the structure below.
**Scope:** Tier-1 (conversation) content only. Same scope boundaries
as the spoken-conversation enrichment prompts (no relationship
signals, no coaching, no structured facts - those are separate
prompts that run downstream).

**Precedence:** `_conventions.md` rules apply. Read those first if
you haven't.

---

## What this conversation type is

An email thread - one or more messages exchanged between the user
and one or more other participants, ordered by reply chain. Examples:

- Project coordination over reply-all
- 1:1 negotiation (price, terms, schedule)
- Information request and response
- Forwarded chain that the user joined mid-thread
- Single-message orphan (received and read, never replied to)

Email differs from spoken conversation in three ways the prompt is
tuned for:

1. **No overlapping speech.** Each message is one self-contained
   turn. Don't try to detect interruptions or filler.
2. **Message-level boundaries.** A "topic shift" usually corresponds
   to a new message rather than a within-message paragraph.
3. **Async time gaps.** A reply 4 days after the previous message
   is normal. Don't infer hesitation or coolness from latency
   unless the body content actually supports it.

Stakes typically `medium` but can be `high` (a difficult exchange,
a contract negotiation, a piece of news) or `low` (a one-line
acknowledgement). Stakes modulates depth, not structure.

---

## Sections to produce (in order)

### `## Summary`

Open with a `### Participants` subsection (an explicit bulleted list
of who was in the thread, with role labels if obvious from context -
`{user_name} (user)`, `Alice Lim (work contact)` - and email
addresses where available so downstream linking can match against
the people graph) and a `### Thread` subsection with:

- Subject line (cleaned of `Re:` / `Fwd:` prefixes for readability,
  but with the prefix-count noted in parens if the thread has been
  forwarded multiple times, e.g. `Project Phoenix handoff (Fwd x2)`).
- Span: first message date - last message date.
- Message count.

Then two to four sentences of factual, third-person summary. What
was the thread for, what got discussed, what came out. No value
judgement.

Final structure of this section:

```
## Summary

### Participants
- {user_name} (user, {user_email})
- Alice Lim (work contact, alice@example.test)
- Carol Mendez (work contact, carol@example.test)

### Thread
- Subject: Project Phoenix handoff - timeline
- Span: 2026-04-12 to 2026-04-15
- Messages: 5

### Narrative
Two to four sentences here.
```

### `## Key topics`

Each substantive topic as a `### Topic name` subheading with bullets.
Topics are grouped thematically, not chronologically. A topic gets
its own subsection only if it warrants more than a single sentence.
One-liner topics go in a final `### Other topics discussed` bullet
list.

Within a topic, attribute messages by sender display name when
attribution matters (`Alice raised...`, `{user_name} pushed back...`),
leave ambient observations unattributed.

### `## Decisions`

Two subsections:

#### `### Made`

Decisions actually concluded in the thread. Format:
`**Decision:** what was decided. _Context:_ one line on why / who
agreed. _Concluded in:_ message N (date).` If none made,
`_Nothing to report._`.

#### `### Pending`

Decisions discussed but not concluded. Format:
`**Question:** what needs deciding. _Needs:_ what's missing to
decide.` If none pending, `_Nothing to report._`.

### `## Action items`

Markdown table with columns: Owner | Action | Deadline | Priority |
Notes. Same rules as the spoken-conversation enrichments. Use `-`
when any cell is unknown.

**Reminders integration (downstream).** Action items where
`owner == {user_name}` are candidates for Apple Reminders sync.
Emit a structured sidecar for ingest:

```yaml
reminders_candidates:
  - action: "Send Carol the kickoff brief by EOD Friday"
    deadline: 2026-04-19
    priority: medium
    source_conversation_id: {conversation_id}
```

Include only actions where the user is the owner.

### `## Key quotes`

Between 0 and 5 notable verbatim quotes from message bodies. Each
on its own paragraph, attributed by sender + message date:

> "The quote itself, cleaned of HTML / signature trim but otherwise
> verbatim." - Alice, 2026-04-13

Email quote conventions:

- **Strip quoted-reply blocks.** A message body containing
  `> previous text\n\nMy reply` should quote only "My reply" - the
  `> previous text` was the prior message, already in the thread.
- **Strip signatures and disclaimers.** Anything below the message
  body proper.
- **Don't quote subject lines.** Quotes come from message bodies.

Don't include quotes just for length. Fewer, better quotes.

### `## Key insights`

Bullet list of the 2-5 most important takeaways. These are
meta-observations, not repetitions of individual points.

If the thread was routine and lacks insights worth surfacing,
`_Nothing to report._` is acceptable.

### `## Next steps`

Two subsections:

#### `### Immediate (next 48 hours)`

What happens in the next two days based on the most recent
exchanges.

#### `### Near-term (next 2 weeks)`

What happens in the next fortnight.

If either window is empty, `_Nothing scheduled._`.

### `## Cleaned thread`

The full thread, message-separated, with each message rendered as:

```
### {sender_display_name} - {date} ({direction})

{message body, signatures and quoted-reply blocks removed,
HTML-only messages converted to plain text, paragraphing preserved}
```

Where `{direction}` is `sent` if the user sent the message,
`received` if anyone else did. The cleaned thread should be
faithful to the body content - don't paraphrase. The body cleaner
in `cm046/adapter_email/cleaning.py` already handles signature
trimming and quoted-reply stripping; the prompt's job is to
preserve voice.

Rules for cleaning:

- **Preserve meaning and voice.** Don't paraphrase. The reader
  should be able to recognise the sender's writing style.
- **Body content only.** Headers (`From:`, `To:`, `Date:`,
  `Subject:`) are reconstructed in the message header line above,
  not in the body.
- **Forwarded blocks.** When a message contains `--- Forwarded
  message ---` followed by an embedded message, render the
  forwarded block as a nested `>` blockquote so the structure is
  visible without inflating the message count.
- **Redaction.** Per `_conventions.md`. `[redacted: amount]`,
  `[redacted: phone]`, etc.

---

## Sensitivity-aware modifications

Same as `02_enrich_work_one-on-one.md`:

- `sensitivity.level = normal | personal`: default. All sections.
- `sensitivity.level = sensitive`: still all sections BUT specifics
  are masked, key quotes drop quotes containing redactable items,
  cleaned thread redacts liberally.
- `sensitivity.level = highly-sensitive`: produce ONLY `## Summary`
  (2-3 sentences) and `## Next steps`. Emit `review_required: true`
  in the frontmatter. No topics, decisions, quotes, insights, or
  cleaned thread.

---

## Output frontmatter

Email-channel enrichment frontmatter extends the standard shape with
email-specific fields:

```yaml
---
conversation_id: 2026-04-15_email_thread_alice
classification:
  setting: correspondence
  shape: group-convo
  stakes: medium
  suggested_type_slug: correspondence_group-convo_medium
sensitivity:
  level: normal
  categories: []
channel: email
email_thread:
  thread_id: "<root@example.test>"
  subject: "Project Phoenix handoff - timeline"
  message_count: 5
  first_message_at: 2026-04-12T09:14:00+00:00
  last_message_at: 2026-04-15T17:42:00+00:00
  message_ids:
    - "<root@example.test>"
    - "<reply1@example.test>"
    - "<reply2@example.test>"
    - "<reply3@example.test>"
    - "<reply4@example.test>"
participants:
  - id: user
    display: {user_display_name}
    role: user
    email: {user_email}
  - id: alice_lim
    display: Alice Lim
    role: other
    email: alice@example.test
  - id: carol_mendez
    display: Carol Mendez
    role: other
    email: carol@example.test
prompt_version: 02-email_thread@1.0
locale: en-GB
redaction_policy_version: default@1.0
enrichment_model: qwen3.5:35b-a3b
enrichment_completed_at: 2026-04-15T18:00:00+00:00
retention_tier: tier-2-decade
retention_score_inputs:
  signal_density: 0.0       # populated by retention scorer
  centrality_refs:
    - person:alice_lim
    - person:carol_mendez
    - topic:project-phoenix
  fact_count: 0             # populated by fact-extraction pass
  is_pinned: false
related_conversation_ids: []
review_required: false
---
```

Then the `## Summary` heading begins. No preamble between
frontmatter and first heading.

**Notes on email-specific fields:**

- `email_thread` mirrors the sidecar in `metadata.json`. Reproducing
  it in the enrichment frontmatter lets downstream consumers read a
  single artefact rather than two.
- `participants[].email` is required for email-channel conversations
  so the people-graph linker can resolve participants unambiguously.
  Other channels treat this field as optional.
- `location` is omitted for email - threads don't have a single
  location. Per-message `From:` headers can carry IP-derived
  location hints if downstream wants them, but enrichment doesn't.

---

## Input the LLM receives

```
--- CLASSIFICATION ---
{classifier_json_output}

--- METADATA ---
Date: {date}
Source: {source}                  (mbox_inbox, imap_personal, etc.)
Channel: email
Participants: {participant_list}
Thread subject: {subject}
Message count: {message_count}
First message at: {first_message_at}
Last message at: {last_message_at}
User hint: {hint_or_none}
User locale: {locale}

--- CONVENTIONS ---
{contents of _conventions.md}

--- THREAD ---
{full_thread_transcript}
```

If the thread exceeds the model's context window, the orchestrator
chunks by message-pair (root + reply, then reply + reply-reply,
etc.) with metadata-only overlap rather than the 2-sentence body
overlap used for spoken transcripts. A reduce pass merges per-chunk
outputs using `02b_merge_chunks.md`.
