# Briefing note for counsel: what we built, and why

Written 2026-09-16 so that when legal advice is affordable, a solicitor
**reviews decisions already made** rather than discovering them. Every position
below was taken on engineering judgement, not legal advice, and is recorded
with the reason so it can be confirmed, corrected or overturned quickly.

**Nothing in this document is a legal claim.** It is a description of what the
software does.

## The one rule that governs everything else

**Building conservatively carries no legal exposure. Claiming compliance does.**

That asymmetry is why the product could be built to a defensible standard
without counsel. Four phrases are therefore banned from every public surface
(privacy policy, website, Kickstarter, investor and accelerator applications,
marketing) until a solicitor signs them off:

- "outside BIPA scope"
- "no biometric processing"
- "nothing to hand over if subpoenaed"
- "falls closer to portraiture law than surveillance law"

Each is a legal **conclusion**. We state facts about the architecture instead,
which are provable and ours to make: *processing happens on the customer's own
Mac and nothing leaves it* does the same work without asserting a legal
position. HR015 #938 holds the rule.

## The product's legal shape, as built

**The customer is the recorder. Ostler is the tool.** Liability attaches to the
person doing the recording, in the same shape as Zoom, Otter and every
dictation app. The consent copy says this in terms: *"You are the one
recording. Ostler is the tool."*

**Creative Machines is neither controller nor processor** of what a customer
keeps on their Mac, and receives none of it. Single-machine architecture is the
product design and also the reason this position holds.

**Personal, non-commercial use by a natural person.** Business use is asked
against, in the consent and in the licence. If an employer deploys Ostler to
staff, the employer becomes the controller for every colleague, client and
patient captured, and the household-activity position under UK GDPR Article
2(2)(c) that protects a private individual stops applying to them. That pulls
in impact assessments, works-council duties in parts of the EU and vicarious
liability in the US, none of which a company this size survives. It all
disappears if the product is personal-use only.

## Decisions taken, with their reasons

### Consent is asked once, and remembered

Asked at install, recorded with a timestamp and the wording version. Not asked
again.

**Why:** the operator knows their own situation and carries the
responsibility. A product that asks before every recording gets its consent
dialog dismissed unread, which is a worse record than asking once and meaning
it. The timestamped confirmation gives a defensible account of what was asked
and what was answered.

**What is recorded is an ATTESTATION, not third-party consent.** The operator
cannot consent on behalf of the other person in the conversation. All-party
consent laws exist to protect the participant who is not holding the device. So
the record says the operator attested; it does not claim the other party
agreed. This distinction is deliberate and is the one a lawyer should look at
first.

### Jurisdiction: warn, do not stop

Crossing into a jurisdiction that requires everyone's agreement **warns** the
operator and lets them proceed. It does not pause capture and demand
reconfirmation.

**Decided by Andy, 2026-09-16**, against the alternative, and the alternative
was seriously considered: stopping converts "we told them" into "it stopped by
default", which is a materially stronger position. It was declined because the
operator is the responsible party and a tool that halts mid-conversation is one
people stop using. HR015 #937 records both the decision and the reasoning.

**A lawyer may well disagree with this one.** It is the most consequential
choice in this document and it is flagged as such rather than buried.

### Unknown jurisdictions are treated as the strictest

267 jurisdictions are recorded. 210 are `unclear`, which is honest: most of the
world has no clean statutory mapping for this. An unknown, unparseable or
absent answer is treated as requiring everyone's agreement, never as permitting
one-party recording.

**Why:** the failure that matters is recording where consent was required. The
opposite failure, asking unnecessarily, costs a customer one question.

The jurisdiction table itself is research produced by two language models
(`gemini+kimi-2026-09`), marked as such on every row, and **is not relied on as
law**: it drives the strictness of a prompt, not a claim.

### Country first, escalate only where the law varies below it

The country is resolved from the device's own region setting, which needs no
permission. 242 of 245 countries are answered outright. Only the United States,
Australia and Canada escalate, because only they carry sub-national variation.

There, the software asks. It shows a best guess and lets the person confirm or
correct it rather than acting on the guess silently, because an IP or carrier
lookup is usually right and occasionally confidently wrong for entirely
innocent reasons.

### Minors and privileged settings are named, not implied

The install consent asks directly, in plain words:

> Do not record children without a parent or guardian agreeing. A child cannot
> give that agreement themselves, and your own assurance does not stand in for
> theirs.
>
> Do not record in places where people expect real privacy: a doctor's
> appointment, a solicitor's meeting, a therapy session, a religious
> confession, a bathroom or changing room.

**Why named rather than folded into a general assurance:** a minor cannot
consent, so an operator's tickbox is meaningless on their behalf, and a
privileged setting is a different order of wrong even where recording is
otherwise lawful. A general "I have consent" does not reach either. The same
two cases are repeated as one line at the moment jurisdiction is asked about.

**What is NOT built, and is the known gap:** a context denylist that
technically DISABLES capture in those settings. Today they are asked against,
not prevented. HR015 #937 holds it.

### A skipped check is visible to the person it concerns

If the software cannot determine which law applies, recording proceeds and the
operator is **told, on screen**, that the check was skipped. That notice cannot
be permanently silenced.

**Why:** refusing to record because a location lookup failed is worse for the
customer than recording. But a bypass nobody can see is indistinguishable from
a check that passed, and a notice with an off switch is a bypass with an off
switch.

## Known gaps, stated rather than left to be found

| gap | shape of the fix | status |
|---|---|---|
| Context denylist that disables capture for minors and privileged settings | technical, needs the capture app | open, HR015 #937 |
| UK workplace: the **employer** is the controller, not the employee wearing it | a deployment guide and a DPIA template | not started |
| US workplace: vicarious liability | an explicit prohibition on employer-mandated use without notice | not started |
| 41 US states have no recorded position | they currently fall back to "ask", which is safe and asks more than necessary | data, not code |
| Jurisdiction table provenance | two language models, not counsel | needs review, this document |

## What we would ask counsel, in priority order

1. **Is warn-not-stop defensible** for an all-party jurisdiction, given the
   operator is the recording party and has attested? This is the biggest single
   exposure and the one decision most likely to be overturned.
2. **Is the operator-attestation model sound**, and is the wording of the
   attestation adequate, particularly on minors?
3. **Does personal-use-only hold**, and is the licence wording enough to
   preserve the household-activity position if a customer ignores it?
4. **Which of the four banned phrases, if any, can be published**, and in what
   form.
5. **The workplace cases**, UK and US, which are currently unaddressed.

## Where the detail lives

- `docs/PRIVACY_LEVELS.md` : the two privacy scales and their directions
- `docs/CONSENT_JURISDICTION.md` : how jurisdiction is decided, end to end
- `vendor/legal/consent_strings.py` : the exact wording a customer is shown
- `lib/transcription_consent_rules.csv` : the jurisdiction table and its provenance
- HR015 #937 : the warn-versus-stop decision and what remains
- HR015 #938 : the rule on what may be said publicly
