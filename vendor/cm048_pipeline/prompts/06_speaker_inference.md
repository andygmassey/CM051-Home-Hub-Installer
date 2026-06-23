# Prompt 06 - Speaker identity inference

**Stage:** speaker-feedback pass, after fact extraction.
**Model:** medium. `qwen3.5:9b` or `qwen3.5:35b-a3b` depending on the
configured fact-extraction model.
**Output scope:** for each unresolved `Speaker N` label in a transcript,
infer the most likely real person from the dialogue context plus a
candidate list drawn from the people graph. The inference is TEXT-ONLY:
it never sees, sends, or reasons about a voice embedding. The device's
voiceprint is referenced opaquely by `voice_fingerprint_ref` only.
**Precedence:** `_conventions.md`.

---

## What this prompt does

You are given a transcript whose speakers are tagged generically
("Speaker 1", "Speaker 2", ...). One of them is usually the user
(the device owner). Your job is to decide, for each generic speaker
label, whether the transcript gives you enough evidence to name the
real person behind it.

Use ONLY:

- direct address ("Thanks, Danny", "as Sarah said earlier"),
- self-introduction ("Hi, I'm Marco"),
- introductions by others ("this is my colleague Priya"),
- role / employer / relationship clues that uniquely match exactly one
  candidate ("our CFO" when only one candidate is the CFO),
- and the supplied CANDIDATE PEOPLE list (known contacts from the
  user's graph).

Do NOT invent a person who is neither named in the transcript nor in
the candidate list. If a speaker is named in the transcript but is not
in the candidate list, you may still suggest them with a freshly
slugged `inferred_person_id` (lower-case, underscores) and a LOWER
confidence - the device decides whether to adopt a new contact.

## Confidence

- `0.9-1.0`: the speaker is explicitly named AND that name maps to
  exactly one candidate (or an unambiguous self-introduction).
- `0.7-0.89`: strong but indirect evidence (unique role/employer match,
  named once without contradiction).
- `0.4-0.69`: weak / circumstantial - emit but the device will treat as
  review-required.
- below `0.4`: do NOT emit a label; put the speaker in
  `unresolved_labels` instead.

Never emit the user's own speaker turn as an `inferred_person_id` -
the user is identified by the device, not by the Hub. If you can tell
which speaker is the user (first person, owns the device, says "my
calendar/my meeting"), leave them out of `labels` and out of
`unresolved_labels`.

## Output

Respond with a JSON object of this exact shape:

```
{
  "labels": [
    {
      "raw_label": "Speaker 2",
      "inferred_person_id": "danny_kwan",
      "inferred_display_name": "Danny Kwan",
      "confidence": 0.92,
      "evidence": "Speaker 1 addresses Speaker 2 as 'Danny' at turn 4; 'Danny Kwan' is in the candidate list."
    }
  ],
  "unresolved_labels": [
    {
      "raw_label": "Speaker 3",
      "sample_turns": ["Speaker 3: I'll send the deck over."]
    }
  ]
}
```

Rules:

- `raw_label` MUST match the transcript label exactly ("Speaker 2", not
  "speaker 2" or "S2").
- `inferred_person_id` is a graph slug. Prefer a candidate's slug; mint
  a new lower_snake_case slug only when naming someone not in the list.
- `evidence` is one short sentence a human can verify.
- Put speakers you cannot name (with at least 0.4 confidence) in
  `unresolved_labels`, with up to three representative `sample_turns`.
- Emit nothing else: no prose, no markdown, just the JSON object.
