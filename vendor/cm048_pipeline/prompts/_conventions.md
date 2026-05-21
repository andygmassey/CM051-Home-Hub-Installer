# Prompt conventions — CM048

Shared rules every enrichment and analysis prompt must follow. When a
prompt says "follow the conventions," these apply.

---

## Language and tone

- **Locale-appropriate.** The user's preferred locale is injected at
  prompt-render time as `{target_locale}` (e.g. `en-GB`, `en-US`,
  `zh-HK`, `fr-FR`). Use that locale's standard orthography, idioms,
  date/number formats, and quoting conventions. Do NOT default to any
  particular locale — always respect `{target_locale}`. The user's
  locale is a setting in their PWG preferences; this prompt must not
  hardcode it.
  - *Examples (when `{target_locale} = en-GB`):* `colour`,
    `organisation`, `realise`, `favourite`, `analogue`. Trailing
    `-ise` / `-isation` not `-ize` / `-ization`. Single quotes for
    quoting speech in narrative prose; double inside cleaned-transcript
    quote blocks. Dates `DD/MM/YYYY` or `15 April 2026`.
  - *Examples (when `{target_locale} = en-US`):* `color`,
    `organization`, `realize`. Double quotes throughout. Dates
    `MM/DD/YYYY` or `April 15, 2026`.
  - When the transcript itself was in a different language from
    `{target_locale}`, preserve direct quotes in the original
    language; narrative prose follows `{target_locale}`.
- **Third person throughout**, using participants' names. Write
  "`{user_name}` said..." / "`{other_name}` suggested...", NOT
  "I said..." / "You said...".
- **No flattery.** No "great question" / "fascinating insight" /
  "brilliant point." Report what happened neutrally.
- **No assumptions beyond evidence.** If unsure, say "Sam didn't
  explicitly state..." rather than inferring. Hedging is better than
  fabricating.
- **Names, not pronouns** in summary sections. Pronouns OK inside
  quotes and cleaned-transcript passages, not in summary prose.
- **Preserve speakers' words.** In the cleaned transcript, filler
  removal and punctuation insertion are the ONLY permitted changes.
  Never alter a speaker's verb choice, sentence structure, dialect,
  or grammar. "I was gonna go" stays as "I was gonna go" — do not
  tidy it to "I was going to go." Preserve accent, idiom, hesitation
  that carries meaning, and non-native phrasing. The reader must hear
  the speaker's voice.

## Privacy and safety

Redaction is **user-configurable per category**. The user's PWG
settings supply a redaction policy injected as `{redaction_policy}`:

```yaml
redaction_policy:
  credentials: force              # non-configurable, always redacted
  financial: mask                 # mask | keep
  medical: mask                   # mask | keep
  legal: mask                     # mask | keep
  contact_info: mask              # mask | keep  (phone numbers, addresses)
  safeguarding: mask_and_escalate # non-configurable
```

- `mask` → replace specific content with `[redacted: TYPE]` in the
  cleaned transcript (e.g. `[redacted: amount]`, `[redacted: phone]`).
  The significance of the item may still be summarised ("discussed
  a financial figure the user was surprised by") but the figure
  itself is not retained.
- `keep` → the item appears verbatim in the cleaned transcript. Facts
  extracted from it are still classified at the appropriate
  privacy level (L2 for medical/financial/legal/contact_info) so
  downstream Person-tier rollups and wiki compilation respect the
  sensitivity even when the raw data is retained.

**`credentials: force`** is non-configurable. Passwords, API keys,
OAuth tokens, secret URLs, security questions and answers — never
retained, never echoed, masked always.

**`safeguarding: mask_and_escalate`** is non-configurable. Content
suggesting child welfare issues, domestic violence, self-harm, or
substance crisis is both redacted AND escalated: emit
`sensitivity_escalation: true` in the output, pause downstream
automated ingest, queue for user review.

The redaction policy applies to the cleaned transcript and any
quoted content in summary sections. It does NOT apply to the
classifier's own reasoning field — which never leaves the state
directory — nor to the sensitivity classification itself (the
classifier always labels honestly regardless of policy).

## Markdown discipline

- Output **must** be valid markdown that renders cleanly in Obsidian,
  MkDocs Material, and plain GitHub.
- Heading levels: `##` for top-level sections, `###` for subsections,
  `####` sparingly for sub-subsections. Never `#` (that's reserved
  for page title).
- **No emoji** unless inside a direct quote from the conversation.
- Code fences only when the content is actually code / config / a
  URL.
- Lists: prefer bullets over long paragraphs. Keep bullets under 2
  lines.
- Bold (`**`) for emphasis only on important nouns (names, numbers,
  decisions). Italic (`*`) for asides or tonal notes. Never both on
  the same token.
- Tables only when the data is genuinely tabular (action items with
  owner/deadline/priority columns). Otherwise bullets.

## Output structure

- Produce **only** the markdown sections the prompt specifies, in
  the order specified. No preamble ("Here's the summary..."), no
  epilogue ("Let me know if...").
- If a section's content is empty, emit the heading followed by
  `_Nothing to report._` on its own line. Don't skip the section
  entirely — downstream expects the full section list.
- Never hallucinate section headers that weren't asked for.

## Fact discipline

- Every summarised claim should be traceable to a statement someone
  actually made in the transcript. If the transcript is ambiguous,
  flag as `(per {user_name} / per {other_name} / unclear)`.
- Quantitative claims ("they paid $10K/month for photo editing") only
  reported if the transcript contains them verbatim.
- If a quote is used, reproduce it in the cleaned form — don't
  paraphrase and attribute.

## Sensitivity-aware behaviour

Prompts receive a `sensitivity.level` from the classifier. Behaviour
changes accordingly:

- `normal` — default processing.
- `personal` — same as normal; treat facts as L1 by default.
- `sensitive` — redact specifics in cleaned transcript (`[redacted:
  medication]`, `[redacted: settlement amount]`). Keep structure but
  remove identifying numbers. Note in summary that sensitive content
  was present without repeating it.
- `highly-sensitive` — produce only a short summary (2-3 sentences).
  Do NOT produce a cleaned transcript. Mark all facts L2. Emit
  `review_required: true` so downstream queues for user review
  before any durable write.
