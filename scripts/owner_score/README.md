# Owner-knowledge score (Lane 17)

The v1.0.108 "so what" gate: 80 questions about the owner, asked over the same
chat path a customer uses, graded by deterministic rules, nothing uploaded.
Built as a FIXED numeric check a small model can grind against, so the check
must not move while it is being ground.

```
scripts/owner_score.sh                      60 visible questions, prints SCORE / PER-CATEGORY / WORST 10
scripts/owner_score.sh --limit 8            stratified sample (this is what the walk probe runs)
scripts/owner_score.sh --set all --enforce  the release gate: all 80, exit 1 under 70%
scripts/owner_score.sh --questions mine.jsonl   the owner's real questions, locked on first use
```

## What it asks, and how

- Route: `ws://127.0.0.1:8000/ws/chat`, `Authorization: Bearer <admin token>` from
  `~/.ostler/secrets/zeroclaw_admin_token`, subprotocol `zeroclaw.v1`. Same
  handshake as `scripts/box_walk_probes/probes/assistant_answers_grounded.sh`
  (`TOKEN_PATH` at `:104`, `GET /ws/chat` at `:247`); server side
  ostler-assistant `crates/zeroclaw-gateway/src/ws.rs` `handle_ws_chat` (`:302`).
  A real customer reaches it through iOS pairing; the bearer check is the same
  one (`pairing.is_authenticated`), so a score here means "answerable", not
  "reachable by a customer".
- One fresh socket per question (no carry-over). The reply graded is
  `done.full_response`, falling back to the chunks, as the grounding probe does.
- The owner cheat sheet the assistant answers from is
  `~/.zeroclaw/workspace/CONTEXT.md` (written by ostler-assistant
  `scripts/generate_pwg_context.py`, injected by `crates/zeroclaw-runtime/src/agent/prompt.rs`).
- The gateway must be loopback. A non-loopback `--gateway` is refused; the only
  socket opened is to it. Results print to the terminal; `--out FILE` writes a
  local file. No telemetry.

## The persona and the questions

`persona.json` is a SYNTHETIC owner (Jane Smith: work history, family,
tastes, routines, people, upcoming events, open todos, recent conversations;
as-of 2026-10-08). `CONTEXT.persona.md` is that persona rendered as a
CONTEXT.md. `build_questions.py` holds the 80 questions (8 categories x 10) and
writes the two question files. Every question has:

- `require`: groups of accepted aliases, each group one required fact or entity
- `none_of`: wrong-person traps; `forbid_regex` on the 8 `absent` questions
  (things the persona does not hold, e.g. salary; the assistant must say it
  does not know and must not invent a figure)
- `gold`: a known-good answer, used only by the self-tests

No LLM judge. If one is ever needed, pin its prompt and model in `grading.py`
so the checksum covers it.

Limits, stated: matching is textual, so a negation ("not Globex") of a trap
still trips it, and a correct fact inside a wrong sentence still passes. The
answer-length cap (1500 chars) and the 8 absent questions are the guards
against shotgun answers.

## The check is immutable to the tuning loop

`CHECKSUM.lock` holds the sha256 of `questions_visible.jsonl`,
`questions_heldout.jsonl`, `grading.py` and the runner `owner_score.py`. Every run
prints `CHECK  built-in sha256 <hex>` and the runner's own sha256 and refuses (exit 3, no score) if it differs
from the lock. A custom questions file is locked on first use in
`<file>.lock` and verified on every later run. A deliberate change is
`build_questions.py` then `scripts/owner_score.sh --relock`, with the reason in
the commit message.

## The 20 held-back questions

`questions_heldout.jsonl` is the held-back set. **The tuning loop must never
read it** and never run `--set heldout|all`. The default is `--set visible`.
When the held-back set is scored (the release gate does this) the output carries
only ids, the aggregate and per-category percentages; its questions, gold
answers and replies are withheld. The checksum step reads the file's bytes, as
any integrity check must, but nothing from it reaches the output.

## Validating the instrument

`python3 -I scripts/owner_score/test_owner_score.py` (wired by
`tests/test_owner_score_instrument_is_valid.sh` and
`.github/workflows/owner-score-instrument.yml`). It asserts: gold answers score
100%; blank, global shuffle (wrong person), within-category rotation, "I don't
know", echoing the question, and pasting every fact all score about 0 (measured:
0 / 3.75 / 0 / 10 / 0 / 0 percent; the 10 is the 8 absent questions earned
honestly); every required fact is present in the persona digest; edited
questions or graders are refused; the held-back text never reaches the output;
and the runner works end to end against a loopback gateway that enforces the
bearer token.

## In the walk

`scripts/box_walk_probes/probes/owner_knowledge_score.sh` runs a stratified
sample of 8 visible questions on the box (each is a full LLM turn, 2 to 5
minutes), puts the persona digest at `~/.zeroclaw/workspace/CONTEXT.md` for the
run and restores the file after (`context_swap.sh`: atomic backup, restore on
EXIT/INT/TERM/HUP, a leftover backup from a SIGKILLed run is restored first, and
it REFUSES, as CANNOT-RUN, unless the existing file is the synthetic seed: it
names the walk's known person, holds the persona marker, or the box is declared
with `~/.ostler/state/synthetic-box`), and prints scores and ids only (never reply
text). `scripts/walk_promote_scope.tsv` carries it as `advisory`: a score under
70% prints `VERDICT: ADVISORY`, is tallied on the walk's own ADVISORY line, is
not a FAIL and does not make the walk exit non-zero. Set the row to `blocking`
and the same score is a FAIL. It CANNOT-RUNs (never a 0) if the token or gateway is missing, and FAILs if
the check was changed.

### Turning it into the weekly-release gate

1. Agree the target (70% is the working number; `OSTLER_OWNER_SCORE_TARGET` / `--target`).
2. Change the probe's row in `scripts/walk_promote_scope.tsv` from `advisory`
   to `blocking` (the ratchet test only allows that direction).
3. Raise `OSTLER_OWNER_SCORE_LIMIT=0` for the walk, or add a weekly job on the
   Hub running `scripts/owner_score.sh --set all --enforce`; exit 1 is below target.

## Pointing it at the owner's real data (later)

Write `mine.jsonl` in the same schema (`id`, `category`, `question`, `kind`,
`require` groups of aliases, optional `none_of`) on the Hub, then
`scripts/owner_score.sh --questions mine.jsonl`. It never leaves the Mac.
Real data stays out of this repo: keep that file outside the checkout.

## Not done (TODO)

- Seeding the persona into the graph. Today the persona reaches the assistant
  only through `CONTEXT.md`; the OS003 seed oracle (`gates/seed/load_seed.py`,
  see `box_walk_probes/lib/grounding_seed.sh`) writes one person and one fact.
  A full persona seed would exercise the `pwg_*` tools too.
- A first run on a real installed Hub. Everything here is validated against a
  loopback stand-in for the gateway, not against a live model.
