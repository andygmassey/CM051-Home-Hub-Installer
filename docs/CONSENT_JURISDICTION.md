# How Ostler decides whether everyone has to agree

Decided by Andy, 2026-09-16. This is the reference for anyone touching consent
jurisdiction in CM051, CM042 or CM031. If the code and this file disagree, the
code is what runs, and one of them is a bug.

## The rule in one sentence

**Answer from the country unless the country cannot answer, and never guess in
the permissive direction.**

## Why this is not obvious

Some places let one participant agree on everyone's behalf. Others require
every person in the conversation to agree. Getting that wrong is not a poor
experience, it is a criminal statute in several jurisdictions.

The obvious design is to ask the customer up front. That is safe and it is also
a question almost nobody needs to be asked, because most countries have a clean
national answer. The design below asks **242 of 245 countries nothing at all**.

## The flow

1. **Resolve the country from the device region.** `Locale.current.region` on
   the Mac. No permission, no prompt, no network. This is the region the person
   set themselves.

2. **If the country settles it, stop.** Look the country up in the table and
   use the answer. This is the path for 242 of 245 countries.

3. **If the country's law varies below the country, escalate.** Three countries
   carry sub-national rows: the United States, Australia and Canada. A
   country-level answer for these is a federal baseline, and a baseline applied
   to a state that decided otherwise is exactly the error this mechanism exists
   to prevent. So:
   - use GPS if the customer has already granted location,
   - otherwise **show a best guess and let them confirm or correct it**,
   - and if nothing resolves, **ask**.

4. **Never fall through to the permissive answer.** Unknown country, unknown
   state, unreadable table, empty region: all of these mean "treat as
   strictest", never "one party is enough".

## Show the guess, do not act on it silently

An IP lookup is usually right and occasionally confidently wrong. The ordinary
cause is innocent rather than nefarious: a mobile carrier routing through
another state, or a corporate VPN the customer did not choose and does not know
about.

Someone deliberately masking their location has taken that on themselves, and
best efforts is a fair posture. The problem is the person who simply has a
phone and would never learn we guessed wrong.

Putting the guess in front of them costs one tap and removes that whole class.
That is why step 3 confirms rather than assumes.

## What the operator is actually agreeing to

**The operator cannot consent on behalf of the other person.** All-party
consent laws exist to protect the participant who is not holding the device.

So when Ostler asks the Hub owner once and records their answer, what it has
captured is the **operator's attestation**, not the other party's consent. Two
consequences:

- The record says `operator_attested`. It does not say `all_party`, because
  writing that on the strength of one tickbox claims something we do not have,
  and the iOS app renders that field back to the operator during capture.
- Consent from the person you spoke to on Monday does not cover the person you
  speak to on Friday. A once-ever answer cannot carry per-conversation truth,
  and it is not presented as though it does.

The attestation is asked **once** and assumed thereafter. Not nagging is
deliberate: the operator is the one who knows their situation and carries the
responsibility, and a product that asks on every call gets its consent dialog
dismissed unread, which is worse than asking once and meaning it.

The attestation names minors and privileged settings (medical, legal,
therapeutic) explicitly, kept short and set as secondary text so the main
sentence stays readable.

## Where each piece lives

| piece | repo | file |
|---|---|---|
| the jurisdiction table | CM051 | `lib/transcription_consent_rules.csv` |
| the only reader of it | CM051 | `lib/ostler_consent_jurisdiction.py` |
| the table's guard | CM051 | `tests/test_the_consent_rules_table_is_safe.py` |
| resolution and escalation | CM042 | `RemoteCapture/Consent/JurisdictionManager.swift` |
| the escalation predicate | CM042 | `ConsentDatabase.hasSubdivisions(countryCode:)` |
| what a person sees when it fails | CM042 | `NoJurisdictionNoticeView` |
| display during capture | CM031 | `RecordingActivityAttributes.swift` |

**CM031 renders jurisdiction, it never determines one.** Measured: none of its
three jurisdiction files references `LocationService` or `CoreLocation`, all
zero, against a control showing `LocationService` is genuinely used in four
other files. Its own `LocationService` feeds the timeline. The whole burden of
being right sits on CM042.

## The table

`lib/transcription_consent_rules.csv`, 267 rows.

| column | meaning |
|---|---|
| `iso` | country (`DE`) or subdivision (`US-CA`) |
| `country` | readable name, so a row is checkable by eye |
| `all_party` | `yes`, `no`, or `unclear`. Three values, never a boolean |
| `needs_finer` | `yes` means a country-level answer is not good enough here |
| `source` | the statute or advice the row rests on |
| `decided_on` | the date, so staleness is visible |
| `decided_by` | who decided |

**It is data, not a Python literal, on purpose.** The list used to be a
`frozenset` inside `ical-server.py`, which made a legal determination into a
code edit: a stray comma there is a `SyntaxError` that takes out everything the
file powers, and reviewing it means reading Python. This repo has already lost
a day to that exact shape. As data, a solicitor can read and edit it and a
change reviews as one line per country.

**`unclear` is the majority answer** (210 of 267) and that is honest rather
than lazy. Most of the world has no clean statutory mapping for this, and
pretending otherwise in a file the product reads is worse than saying so. It
also means the `unclear` behaviour **is** the behaviour for most customers, so
it deserves more care than an edge case would.

**`needs_finer` cannot rot.** The guard recomputes it from the `iso` codes and
refuses if the column and the codes disagree. Adding a state to the data is
enough to make its country escalate; there is no second place to update.

## Provenance, and what this file is not

`decided_by` currently reads `gemini+kimi-2026-09` on every row. That means two
language models were asked and their answers combined.

**That is a research aid. It is not legal advice, it is not a citation, and the
statute references are what those models reported rather than anything verified
against the statute book.** The value is spelled that way so nobody reads "AI
Assistant" as a person or a firm six months from now.

A row becomes authoritative only when `decided_by` names a person or a firm and
`decided_on` is the date they said it. Until then the product still works,
because `unclear` behaves safely, but nothing in here should be quoted as
settled law.

## Things that are deliberately true

- **The reader never returns `no` for a place it does not know.** Unknown code,
  empty, `None`, and a subdivision we do not carry all return `unclear`. There
  is no branch returning `no` for anything not explicitly recorded as `no`.
- **An unreadable table raises rather than returning empty.** Empty would make
  every lookup fall through to the safe branch, which is safe by luck rather
  than by design, and would hide a deleted table behind behaviour that looks
  deliberate.
- **A subdivision we lack falls back to its country**, which for a granular
  country is itself `unclear` with escalation set. So you are told to ask
  rather than handed a baseline that is wrong for that state.
- **The "consent check skipped" notice cannot be permanently silenced.** The
  one-party reminder can, and should, because it reports a settled situation.
  This one reports that a check did not happen, and a notice the customer can
  switch off is a bypass with an off switch.

## The control that matters most

A predicate that always says "ask" is safe, useless, and reads **identically**
to a correct one, because everything escalates and nothing is ever wrong.

Both guards therefore carry an arm proving the answer can go the other way:

- CM051: `must_ask_everyone` returns `False` for all 15 places recorded
  one-party.
- CM042: `hasSubdivisions` returns `false` for Germany and `true` for the
  United States.

If either of those arms is ever deleted, the guard above it stops meaning
anything.

## Known gaps

- **CM042 has no CI.** No workflows directory, no Makefile, no test runner,
  measured against 63 tracked files. Its tests run when somebody runs them in
  Xcode and at no other time. A test nobody runs and a test that passes look
  identical from outside.
- **The confirm-the-guess step is specified here and not yet built.** CM042
  currently escalates by returning nil, which reaches the visible notice. The
  picker that lets someone correct a guessed state is the next piece.
- **US state coverage is partial.** 13 states are recorded; the rest fall back
  to the country row, which is `unclear`, so they are asked rather than
  assumed. That is the safe direction but it is more asking than necessary.
