# CM052 – Build Plan

**Goal:** ship a unifier + CM048 wire good enough to power the
Companion's chat-history surface from real iMessage / WhatsApp /
gateway data, with the contract pre-shaped for v0.2's external-LLM
adapters.

---

## v0.1 – Launch (this branch)

### Delivered

- **Source-agnostic Conversation contract** (``provenance.py``,
  ``schemas.py``). ``ConversationProvenance`` matches Andy's spec
  verbatim. Round-trip tested.
- **Launch adapters** (``adapters/zeroclaw_sessions.py``,
  ``adapters/channel_jsonl.py``). Read-only, idempotent, deterministic
  conversation IDs.
- **Post-launch adapter stubs** (``claude_code_watcher.py``,
  ``chatgpt_export.py``, ``claude_desktop_leveldb.py``). Lock the
  plug-in interface from day 1; raise ``NotImplementedError`` on call.
- **Unifier** (``unifier.py``). Merges adapter outputs by
  ``conversation_id``, prefers higher-provenance sources on collision,
  returns most-recent first.
- **Continuation router stub** (``routing.py``). Always returns the
  user's local assistant for v0.1. Signature is the v0.2 contract.
- **CM048 wire** (``wire.py``). Stages ``transcript.md`` +
  ``metadata.json`` pair (with ``channel`` + ``provenance`` fields)
  and POSTs to CM048's endpoint.
- **Synthetic test fixtures** under ``tests/fixtures/``.
  ``+10000000000``-style placeholders only.
- **Productisation hook** symlinked from HR015.

### Not in v0.1 (deliberately)

- Live polling / fsevents watcher daemon. v0.1 is a library +
  fire-once-on-demand interface; the daemon comes when the iOS UI
  calls for it.
- CLI front-end. ``pyproject.toml`` declares the entry-point name
  ``pwg-ai-convo``; the actual CLI lands when there is a concrete
  invocation flow to wrap.
- Identity resolution of participants to PWG people. CM041 owns this;
  the wire passes raw participant strings through.
- Collapsing live + archive splits of a single conversation thread.
  Adapter emits both as the same ``conversation_id``; deduplication
  happens at the unifier layer for now.

---

## v0.2 – Post-launch external LLMs

### Delivered (dual-storage milestone)

- **``claude_code_watcher`` is real.** Tails
  ``~/.claude/projects/<encoded-cwd>/<sid>.jsonl``. Per-message ISO
  timestamps from the JSONL line itself (not just file mtime).
  Debounce window via ``CM052_CLAUDE_CODE_DEBOUNCE_SECS`` (default
  300s); ``lsof`` consulted opportunistically to skip active
  sessions. Cleaning rules: ``thinking`` blocks dropped,
  ``tool_use`` rendered as ``[tool: <name>]``, ``tool_result``
  rendered as ``[tool_result] ...`` in the user turn following the
  call, slash-command shells (``<command-message>`` /
  ``<command-name>``) stripped via regex.
- **Dual-storage path in ``wire.py``.** For
  ``provenance.source_kind == "external_llm"``, ``post()`` writes a
  durable episodic markdown artefact under
  ``OSTLER_AI_CONVERSATIONS_DIR`` alongside the existing CM048
  ``transcript.md + metadata.json`` POST. Frontmatter:
  ``conversation_id``, ``provenance``, ``channel``, ``participants``,
  ``started_at``, ``ended_at``, ``source_app``, ``privacy_level``.
  Idempotent overwrite (not append). Body: cleaned transcript with
  speaker labels and per-message timestamps. Episodic write failures
  log a warning but do not block the gist path.
- **Adapter registered in the unifier.** Claude Code conversations
  flow through ``unify()`` alongside hub-channel sources; the merge
  rule keeps ``external_llm`` as the highest-provenance bucket
  already encoded in ``_provenance_priority``.

### Also delivered (post-watcher follow-up)

- **``chatgpt_export`` is real.** Recursive scan of
  ``OSTLER_CHATGPT_IMPORT_DIR`` (default
  ``~/Documents/Ostler/imports/chatgpt``) for any ``conversations.json``
  inside the drop folder. Walks ChatGPT's ``mapping`` tree from the
  unique root, follows the first child at each fork (the
  chatgpt.com "current" thread; regenerated branches are skipped
  rather than over-counted in the episodic transcript). Drops
  ``system`` / ``tool`` nodes; flattens ``content.parts`` with a
  defensive multimodal fallback that pulls only the text. Per-
  message timestamps from the export are normalised to ISO-8601
  UTC. Provenance: ``source_kind=external_llm``,
  ``source_subtype=chatgpt``, ``external_provider=openai``,
  ``external_model`` from the conversation's ``default_model_slug``
  (or first assistant message's ``metadata.model_slug``),
  ``original_session_id`` is the export's conversation UUID.
  Idempotent: deterministic ``og-XXXXXXXXXXXXXXXX`` ids mean
  re-importing an export overwrites at the wire layer.
- **Adapter registered in the unifier.** ChatGPT exports flow
  through ``unify()`` alongside Claude Code sessions; the merge
  rule keeps both sources at the same ``external_llm`` priority.

### Still to fill in

- **``claude_desktop_leveldb``** – best-effort. Recommended path
  remains the claude.ai web export consumed via the chatgpt-style
  drop folder; LevelDB direct read is a stretch goal. **Still
  ``NotImplementedError`` at this revision.** Andy's call: ship
  ChatGPT first, defer LevelDB until the export-via-drop-folder
  route is proven in production.
- **Privacy classifier upstream of the wire.** v0.2 defaults
  ``privacy_level`` to ``L1``; an L3-detection short-circuit (which
  must run *before* episodic persist) is still a follow-up.
- **PR-side audit follow-up: visible-zone backup/sync.** The
  episodic store lives under ``~/Documents/`` so Time Machine,
  iCloud Drive, and Spotlight reach it. Lester's next audit pass
  needs to confirm the privacy posture matches.

### Continuation router fills in

- BYOM-keys lookup keyed by ``provenance.external_provider``.
- If a key is registered and ``can_continue_at_origin=True``, route
  to the provider API directly. Else fall back to the local assistant.
- Per-conversation override stored in the chat UI; the router accepts
  an optional ``override_provider`` arg.

### Other v0.2 work

- **ZeroClaw JSONL writer patch** – emit per-message timestamps in
  the JSONL line itself, removing the file-mtime + line-index
  fallback. Small Rust patch coordinated with ZeroClaw's in-flight
  patches branch.
- **Confidence-floor differentiation in CM048** – replace the blanket
  0.4 floor for ``participant_kind=ai`` with stated-vs-inferred
  differentiation. CM048 task; CM052 just emits the right metadata.

---

## v0.3 – Cross-repo schema PR (parallel track)

Seven additive fields to CM048 schema, two consumers (CM046 email
adapter, CM052 unifier). Not bundled into the CM052 v0.1 ship.

1. ``metadata.channel: Literal["spoken", "email", "im", "sms",
   "manual"] = "spoken"`` – both consumers
2. ``metadata.email_thread: dict | None`` – CM046 only
3. ``metadata.participants[].email`` – CM046 only
4. ``metadata.participants[].role: Literal["from", "to", "cc",
   "bcc"]`` – CM046 only
5. ``ExtractedFact.ai_provenance: dict | None`` – CM052 v0.2 only
6. ``Classification.participant_kind: Literal["human", "ai", "mixed"]
   = "human"`` – CM052 v0.2 only
7. ``pwg:mentionedInReasoning`` predicate (strength 0.2) – CM052 v0.2
   only

Coordination protocol: whichever consumer is mid-flight first opens
the PR; the other slots in as a rider.

---

## Backlog (unphased)

- **Live + archive thread collapse.** When the same
  ``conversation_id`` arrives from both live and archive directories,
  merge the message lists into one. Currently the unifier picks one
  and drops the other. Real cost only shows up when threads roll
  over.
- **Identity-resolution roundtrip.** When CM041 resolves a phone
  number to a person, the unifier should re-emit affected
  conversations with the resolved ``person:<slug>`` participant ID
  alongside the raw phone. Coupled to CM041's resolver release
  cadence.
- **Smart backfill prompt UX.** First-run "Backfill last 30 days?"
  prompt is currently env-driven; a CLI / installer-flow surface is
  the right home for the prompt itself.
- **Daemon mode.** When the chat UI is calling the unifier on every
  inbox refresh, the per-call SQLite open + JSONL re-read becomes
  visible. Cache + watch + invalidate is the right shape, but only
  worth building once the UI is actually hitting it.
