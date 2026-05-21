# CM048 — PWG Conversation Processing

Hub-side pipeline that turns raw human-to-human conversation
transcripts into structured three-tier output:

- **Tier 1 — Conversation**: enriched summary, topics, decisions,
  action items, key quotes, cleaned transcript → Qdrant + MD file
- **Tier 2 — Person**: relationship signals (warmth, reciprocity,
  trust, energy, power dynamic) per non-user participant → Oxigraph
- **Tier 3 — User Coach**: behavioural observations about the user
  as a conversational actor → SQLite

## Status

- Phase A (prompts): **complete** — 14 prompts + 1 JSON schema
- Phase B (build): **complete** — full pipeline, 15 tests passing
- Phase B live: **validated** — 5 conversations processed end-to-end
  against a Hub Ollama (qwen3.5:9b classifier, qwen3.5:35b-a3b enrichment)
- Phase C (integration): **complete**. Linker wired, API spec landed, Hub assistant endpoint implementation merged (see CM041 ical-server.py `/api/v1/conversation/process` + `/api/v1/conversation/status/{id}`).
- Phase D (backfill): pending
- Phase E (graph optimisation): designed, pending 50+ conversations

## Quickstart

```bash
cd "CM048 - PWG Conversation Processing"
python3.11 -m venv .venv && source .venv/bin/activate
pip install -e '.[dev]'

# Run all tests (15 tests, <1s)
python -m pytest tests/ -v

# Dry-run against a fixture (no LLM calls, no sink writes)
python -m src.cli process \
  tests/fixtures/2026-04-15_alex_chen_zoom.md \
  tests/fixtures/2026-04-15_alex_chen_zoom.metadata.json \
  --dry-run --no-sinks
```

## Real pipeline run

Requires your Hub's Ollama (default `http://localhost:11434`,
override via `OSTLER_OLLAMA_URL`) plus Qdrant (:6333) and
Oxigraph (:7878) reachable on the LAN.

```bash
# Process a single conversation (all steps, write to sinks)
python -m src.cli process <transcript.md> <metadata.json>

# Batch process all fixtures in a directory
python -m src.cli batch tests/fixtures/

# Check status of all conversations
python -m src.cli list

# Retry all failed conversations
python -m src.cli retry-all

# Reprocess from a specific step — archives existing output files for
# the target step and every downstream step, clears those steps from
# state.json's completed_steps list, then re-invokes the pipeline.
# Exit codes: 0 = success, 1 = step failed or silently skipped,
# 2 = unknown --from-step or missing conversation id.
python -m src.cli reprocess <conversation_id> --from-step 02_enrich
```

## Pipeline steps

| Step | Model | Output | Time |
|------|-------|--------|------|
| 00_raw | — | Raw transcript + metadata saved | instant |
| 01_classify | qwen3.5:9b | 3-axis classification + sensitivity | ~10s |
| 02_enrich | qwen3.5:35b-a3b | Enriched conversation markdown | ~180s |
| 03_relationship_signal | qwen3.5:35b-a3b | Per-person signal JSON | ~150s/person |
| 04_coaching | qwen3.5:35b-a3b | User Coach observation JSON | ~175s |
| 05_fact_extraction | qwen3.5:35b-a3b | Structured facts JSON | ~60s |
| 06_speaker_feedback | — | Speaker label stub (v1) | instant |
| 07_sinks_written | — | Qdrant + Oxigraph + SQLite + MD | ~5s |
| 08_linked | nomic-embed-text | Cross-conversation similarity | ~5s |

Total: ~10 min for a one-on-one, ~14 min for a 3-person meeting.

## Test fixtures

| Fixture | Type | Classification |
|---------|------|---------------|
| Alex Chen zoom | work/one-on-one/medium | Remote Zoom call |
| Diana Thompson coffee | work/one-on-one/medium | In-person, CM031 iOS |
| Marco Petrov lunch | social/casual/medium | In-person, CM031 iOS |
| Pierre Laurent coffee | work/one-on-one/medium | In-person, CM031 iOS |
| ContactCo-I workshop prep | work/meeting/medium | WhatsApp call, 3 participants |

## CLI flags

```
--verbose / -v       Debug logging
--json-logs          Structured JSON log lines to stderr
--dry-run            Skip LLM calls (use stubs)
--no-sinks           Skip sink writes (Qdrant/Oxigraph/SQLite)
--stop-on-error      Stop batch on first failure
```

## Architecture

See `CLAUDE.md` for full architecture. See `docs/api.md` for the
Marvin unified API endpoint spec. See `PLAN.md` for phased build plan
with locked-in design decisions.

## Consumed by

- CM042 — Remote Conversations (Mac audio capture)
- CM031 — PWG Companion (iOS, Watch, wearable capture)
- CM044 — Personal Wiki compiler (Person pages, User Coach page)
- Marvin — via `/api/v1/conversation/process` endpoint on ical-server.py
- Manual paste (testing, historic imports)
