# cm019_preferences — divergence NOT captured by a patch (CM051 #2472)

`cm019_preferences` ships with `divergence_patch = ""`, which this tree's own
manifest note already documents as a POSITIVE ASSERTION of byte-identity to
source at the pin — an assertion that row's own history has already found to
be false once (the 42-file reconciliation gap). This file does not reopen
that finding; it records a SEPARATE, NEW hand-edit on top of it, so the gate
that watches for undescribed vendor changes has something to find.

## What changed, and why it has no patch

`vendor/cm019_preferences/services/ingest/src/vectorizer.py` gained a usage-
journal write in `embed_batch()`, plus a vendored copy of the shared
`ostler_usage_journal` writer at
`vendor/cm019_preferences/services/ingest/src/_vendor/`.

Source `andygmassey/personal-world-graph` has no Ollama call in its own
vectorizer at all — it embeds via `sentence-transformers`, the swap this
file's own docstring already documents. So there is no upstream commit this
fix could ever be a divergence FROM: the usage-journal wiring can only exist
here, vendor-side, permanently. Unlike `cm024_knowledge` and `cm059_editor`
(whose equivalent fixes landed upstream and were re-vendored, superseding
their first-commit vendor-side drafts), this tree's fix is terminal, not a
placeholder for a future re-pin.

A `sync_vendor.sh --regen-patch` run against this tree would not describe
this change either: the row's `divergence_patch` is deliberately empty, and
turning it on now would also turn on patch maintenance for the pre-existing,
much larger, already-declared 81-file reconciliation gap this row's note
describes — out of scope for this change and not this PR's decision to make.

## Method

- vendored file: `vendor/cm019_preferences/services/ingest/src/vectorizer.py`
- new vendor-only files:
  `vendor/cm019_preferences/services/ingest/src/_vendor/__init__.py`,
  `vendor/cm019_preferences/services/ingest/src/_vendor/ostler_usage_journal/__init__.py`,
  `vendor/cm019_preferences/services/ingest/src/_vendor/ostler_usage_journal/usage_journal.py`
  (verbatim copy of `vendor/cm048_pipeline/src/_vendor/ostler_usage_journal/`)
- proven by execution, not by this record: `tests/test_cm019_vectorizer_usage_journal.sh`
  and the embedder arm of `tests/test_usage_journal_producer_parity_2472.sh`

## 2026-10-02: moved from per-call writes to a 60-second rollup

A live walk (v1.0.107 candidate) measured `cm019_preferences`'s vectorizer
writing 1,099 journal rows from a single ingest run under the per-call shape
this file originally described -- a meaningful share of total journal
volume, with no rotation on the journal and no cache on the Bursar's
monthly-summary reader. `vectorizer.py` now holds a `RollingUsageRecorder`
(new sibling file,
`vendor/cm019_preferences/services/ingest/src/_vendor/ostler_usage_journal/rolling.py`,
kept separate from `usage_journal.py` because that file carries a "DO NOT
EDIT" banner pinning it byte-identical to its canonical HR015 source) that
sums real measured tokens across a 60-second window per (model, purpose) and
writes ONE rolled-up row on flush, matching the same fix already applied to
`cm024_knowledge`'s embedder for the identical reason.

`__init__.py` under that `_vendor/ostler_usage_journal/` directory changed
too, to export `RollingUsageRecorder` from the new `rolling.py` alongside
the existing re-exports from the pinned `usage_journal.py`.

Proven by execution: `tests/test_cm019_vectorizer_usage_journal.sh` (updated
for the rollup shape: a write is not visible until `flush()`) and the
`cm019_vectorizer` arm of `tests/test_usage_journal_producer_parity_2472.sh`
(N=3 calls fold into exactly 1 row, whose `input_tokens` is the exact SUM of
all three calls' measured tokens -- proving no call's tokens were dropped by
the rollup). Both confirmed RED against the pre-fix per-call code before
this change.

## 2026-10-02, same day: estimate on miss, never drop a call

The owner's product rule, same review: "I'd rather Bursar overcounted, than
undercounted." `RollingUsageRecorder.add()` gained an optional
`estimated_input_tokens` kwarg: when Ollama reports no `prompt_eval_count` at
all, `vectorizer.py` now computes a chars/4 estimate of the text it actually
submitted and folds that in instead of dropping the call. The flushed row's
`session_id` gets an "-est" suffix so it stays distinguishable from a purely
measured row, short of a dedicated wire-format field (none exists yet; filed
as a follow-up, not done here).

This is scoped to `cm019_preferences`'s vectorizer ONLY, the one producer
this walk-defect review actually touched. The other four #2472 producers
(`cm024k_embedder`, `cm024k_classifier`, `cm024k_email_summarizer`,
`cm059_scout_newsletters`) are UNCHANGED and still write nothing on a miss --
whether to roll this rule out estate-wide, and whether to add a real
"estimated" field to the Rust `TokenUsage` schema so the UI can show it
honestly, are decisions for Archie/the owner, not assumed here.

Proven by execution, same two files: both now also assert that an
unmeasured call writes one ESTIMATED row (not zero), with the `-est` suffix
and the correct chars/4 value.

## Second, unrelated hand-edit: the Netflix thumbs-value polarity bug (walk #6, candidate #10)

Tree `cm019_preferences`, file
`vendor/cm019_preferences/services/ingest/src/parsers/netflix.py`,
`_parse_ratings()`. UNRELATED to the vectorizer change above (different
file, different root cause); recorded in this same journal because the
manifest points one `unrecorded_divergence` pointer at this tree and that
pointer is this file.

A customer console walk (macmini16-walk) found shows rated positively
listed under "Dislikes" on the wiki. Root cause: this parser's docstring
documented the WRONG Netflix GDPR "Thumbs Value" encoding (0=down,
1=up, 2=strong-down, 3=strong-up) and the code matched it exactly. The
real encoding is 0=not rated, 1=down, 2=up, 3=strong up -- there is no
"strong down" tier. Values 1 and 2 were swapped, and 0 ("not rated") was
being stored as an explicit Dislike.

Matches CM019 PR #396 (upstream, open at time of writing), applied here
via `git apply` of that PR's own diff against this vendor copy's
byte-identical `_parse_ratings()` (confirmed identical before this fix --
the only pre-existing divergence in this file is the
`NETFLIX_UNIQUE_PATTERNS`/`NETFLIX_EXACT_LEAF_NAMES` file-detection fix
for a Foursquare filename collision, landed earlier, which this patch
does not touch). CM019's test suite
(`services/ingest/tests/test_netflix_parser.py`) is NOT vendored (tests/
is outside this tree's shipping subset per this manifest row's own
note), so there is no vendor-side test to point at here -- proof is
upstream, at CM019 PR #396.

Also ships, as a SEPARATE file not vendored FROM anywhere (CM019's own
`scripts/` directory is likewise outside the shipping subset, so this is
a CM051-native script, not a graft): `scripts/repair_netflix_rating_polarity.py`
plus `tests/test_repair_netflix_rating_polarity.py`. One-time, idempotent
repair for Netflix preference points already written by the buggy parser
on an upgraded box. Dry-run by default, `--apply` to mutate. Measured on
macmini16-walk's own `preferences` collection (a test/walk box): 95 of
5,000 Netflix points carried a wrong label; repaired, then re-run twice
more with zero candidates found both times (idempotent, proven by
execution, not asserted). NOT wired into install.sh as an automatic
upgrade step in this PR -- that decision (same shape as `repair_lid_as_
phone`'s install.sh wiring) is flagged for Archie/the owner, not assumed here.
Retire the parser-fix portion by landing CM019 PR #396 and re-pinning;
the repair script has no upstream to retire against since it is native
to this repo.

## cm019_preferences: an enrichment miss is not an import error (walk #16)

A second hand-edit on `cm019_preferences`, recorded here because this tree's
manifest block declares this file as its `unrecorded_divergence` record.

**Measured refusal:** `scripts/regenerate_divergence_patch.sh cm019_preferences --write`
prints `CANNOT RUN -- cm019_preferences declares no divergence_patch path in the
manifest` (2026-10-10). Turning a patch on would also take on the pre-existing
reconciliation gap described above, which is not this change's decision.

**Location and shape of every edit in cm019_preferences:**

- `vendor/cm019_preferences/services/enrich/src/enricher.py`
  - `import re` added.
  - `EnrichmentStats`: new fields `no_match: int` and `misses: List[str]`;
    `attempted()` now adds `no_match`; `summary()` prints `No match: N`.
  - New module-level `_MISS_MESSAGE` regex and `is_enrichment_miss(result)`:
    true only for `MatchType.NONE` AND a fixed "answered, no confident match"
    phrasing. Fail-closed; `MatchType.UNAVAILABLE` is never a miss.
  - `enrich_batch()`: a new `elif` before the failure branch counts a miss in
    `no_match`/`misses` and logs it at INFO instead of `failed`/`errors`.
  - `enrich_categories()`: merges `no_match` and `misses` like the others.
- `vendor/cm019_preferences/services/enrich/src/cli.py`
  - `_run_enrichment()`: prints misses under
    `--- No enrichment match (N, not errors) ---` before the errors block; the
    exit rule (`failed > successful`) is unchanged and now excludes misses.

**Why:** three Wikidata look-ups that found nothing made the enrich CLI exit 1,
which `ostler-import` carried into install.sh's warn branch, so import_data went
red over a fully successful import. Tests:
`tests/test_an_enrichment_miss_is_not_an_import_error.py` and
`tests/test_ostler_import_exit_code_separates_misses_from_failures.sh`.
Also recorded in `vendor/divergences/CM019_DIVERGENCE_REGISTRY.md`.

**Upstream status:** not ported; owed to personal-world-graph `services/enrich`.

## Apple Music library parser (CM051, walk #27, 2026-10-14)

**Files:**
- `vendor/cm019_preferences/services/ingest/src/parsers/apple_music_library.py` (NEW):
  `AppleMusicLibraryParser`, source `apple_music`, claims only the exact file
  name `ostler_apple_music_library.json` written by `ostler_fda.apple_music`.
  One `music` preference per library track, subject `Artist - Title`, base
  strength from the SAME constants `parsers/spotify.py` uses for the same
  evidence (dislike -0.45, star map, loved 0.40, user playlist 0.30, played or
  in library 0.10). Play count, skips, last played and date added ride in
  `extra` / `observed_at`.
- `parsers/__init__.py`: imports and exports it.
- `pipeline.py`: imports it and lists it FIRST in `self.parsers` (exact-name
  match, so it cannot shadow another parser).

**Why:** the owner's Apple Music listening never reached the preference store;
every music preference came from Spotify. Test:
`tests/test_apple_music_library_reader.py` (parser scale, registry order, and
an additive-only ingest against recording fake stores).

## One scale for every music service: plays and recency (CM051, walk #27, 2026-10-14)

**File:** `vendor/cm019_preferences/services/ingest/src/filters.py`
- `is_duplicate()` (aggregation mode): a row adds `_observation_weight(pref)`
  to its key's frequency instead of 1, and the kept row takes the LATEST
  `observed_at` of its duplicates (`_with_latest_observation`).
- `_observation_weight()` (NEW): `extra["play_count"]` when it is an integer
  above 1, else 1 (never 0, never negative, bool rejected).
- `_with_latest_observation()` (NEW): keeps the most recent observation.

**Why:** frequency counted rows, so a per-play history (Spotify) outscored a
per-track library with the same plays (Apple Music: 42 plays scored frequency
1), and time decay used the first row seen, so file order changed a score.
Rows without a play count (email, likes, per-play histories) are unchanged.

**File:** `vendor/cm019_preferences/services/ingest/src/parsers/apple.py`
(the privacy.apple.com export): `_parse_track_play_history`,
`_parse_play_activity` and `_parse_daily_tracks` now emit Spotify's
passive-play base strength (`MUSIC_PASSIVE_PLAY_STRENGTH` 0.10) with the play
count in `extra["play_count"]`, instead of count-encoded strengths
(0.5 + n x 0.03..0.05, capped 0.75..0.8) that would double count once the
filter weighs play_count. Last played is the LATEST event (`_later`), not the
first row. Play Activity drops plays under 30 s (`MUSIC_MIN_PLAY_MS`, Spotify's
rule); Daily Tracks counts plays, not skips, and drops a track with 0 plays.
Test: `tests/test_music_services_score_on_one_scale.py`.
## No per-source storage cap (CM051 #28, the owner 2026-10-14: "Need everything.")

**File:** `vendor/cm019_preferences/services/ingest/src/filters.py`
- `PreferenceFilter.MAX_PREFS_PER_SOURCE`: 5000 -> `None` (no cap).
- `cap_by_source()`: with no cap, every source is still RANKED (category
  priority, strength, frequency) and returned WHOLE, empty trim log. An integer
  restores the old trimming (operator override only; nothing ships one).
- `is_non_preference_shape(subject, category=None)`: `category` in the new
  `_STRUCTURED_TITLE_CATEGORIES` (`music`) skips the prose gates (more than
  `_MAX_PREFERENCE_WORDS` = 12 words, and the boilerplate phrases); the
  Re:/Fwd:, email-address and URL checks still apply. `is_low_value` passes
  `pref.category`. A classical work's "Composer - Symphony No. 9 ..." title
  ran past 12 words and was dropped as prose.
- `parsers/discord.py` (channels `most_common(20)`, games `(15)`, link
  domains `(10)`), `parsers/whatsapp.py` (contacts `(20)` and `(10)`, topic
  keywords `(15)`), `parsers/pinterest.py` (followees `[:50]`): every item
  above the existing evidence floor is yielded, no top-N. The floors (e.g. 10
  messages for a channel) are unchanged.
- `tail_queue.py` (NEW) + `pipeline.py` `_queue_tail` (called right after
  `cap_by_source` on both aggregation paths) + `cli.py` `ingest-tail` (NEW):
  when the caller sets `OSTLER_PREFS_FOREGROUND_PER_SOURCE` and
  `OSTLER_PREFS_TAIL_QUEUE` (install.sh does, for the install import only),
  the first N ranked rows per source are stored now and the rest are queued
  as JSONL (ids and created_at preserved) for `ingest-tail`, run by
  `ostler-scan-exports` (com.ostler.export-scan). Resumable per-file
  checkpoint, idempotent rewrites; an unwritable queue stores everything now.
- Callers unchanged: `pipeline.py` `ingest_file_with_aggregation` and
  `_ingest_directory_with_aggregation` (both call `cap_by_source`).

**Why:** 5000 per source was a storage cap on the owner's data. Mini16,
2026-10-14 (read-only scroll of `preferences`, 40,320 points): `netflix` 5000,
`apple` 5000, `csv` 5001. Tests: `tests/test_owner_data_is_never_capped_at_storage.py`,
`tests/test_pref_noise_source_cap.py` (updated: all rows kept, head first).

**Upstream status:** not ported; owed to personal-world-graph `services/ingest`.

## Walk #28 -- cm019_preferences enrich CLI consent backstop (extended in place)

- vendored file: `vendor/cm019_preferences/services/enrich/src/cli.py`
- edit: `require_public_lookup_consent()` plus its two readers
  (`consent_env_file()`, `public_lookups_decision()`), defined under
  `DEFAULT_USER_ID`, called in `enrich` before the non-dry-run branch and at the
  top of `parallel`. Reads `OSTLER_CONSENT_ENRICHMENT_DECISION` from
  `~/.ostler/config/.env`; only "accepted" proceeds.
- why no patch: same reason as above, this row's `divergence_patch` is
  deliberately empty and turning it on would take on the whole reconciliation
  gap. Upstream has no consent gate, so the edit is owed upstream as well.
- detail: `vendor/divergences/CM019_DIVERGENCE_REGISTRY.md`, "Walk #28".
- proven by execution: `tests/test_enrichment_honours_a_decline.sh` (arm C).

## 2026-10-15 Ostler #30 console walk: a play is not a like; recommendations are not tastes

Tree: `cm019_preferences`. Regeneration was not attempted: this tree is `verify = "skip"` (see the manifest row), so there is no reconstructible baseline to diff against; this is the sanctioned fallback.

Edits, all under `vendor/cm019_preferences/services/ingest/src/`:

- `parsers/apple.py`: the three music play parsers (track play history, play activity, daily tracks) write `preference_type="Neutral"` and `extra["passive_play"]=True`; strength is UNCHANGED (0.10) so nothing is down-weighted. `_parse_music_favorites` maps the `Preference` column: LIKE/LOVE -> Like, DISLIKE -> Dislike (strength -0.45), anything else -> Neutral at 0.0.
- `parsers/apple_music_library.py`: `score_track` returns Neutral for a library-only row (evidence "library").
- `parsers/spotify.py`: music stream plays write Neutral with `passive_play`, identical to Apple.
- `filters.py`: `get_aggregated_preferences` labels a passive-play row Neutral instead of deriving Like from the positive strength; `is_duplicate` lets an explicit signal replace an already-seen passive row for the same key (`_is_passive`).
- `parsers/linkedin.py`: `recommendations_given.csv` / `recommendations_received.csv` are claimed (so the generic CSV parser cannot read the Text column as a taste) and yield nothing (`NO_PREFERENCE_FILES`).

Proof: `tests/test_passive_plays_are_not_likes.py`, `tests/test_linkedin_recommendations_are_not_preferences.py`; both fail on origin/main.

## 2026-10-17 v1.0.108: cm019_preferences local-store clients ignore HTTP(S)_PROXY

Tree: `cm019_preferences`. RETIRED AS A DIVERGENCE 2026-10-17: upstream personal-world-graph #409 merged as 4e023299 and this tree is pinned there, so the hunk below IS upstream (changed lines measured identical per file). Kept as history. Regeneration was not attempted: this tree is `verify = "skip"`, and `--regen-patch` here would publish upstream-side lines in this public repo (see the 2026-10-17 manifest note on the #408 re-pin).

Edits, all under `vendor/cm019_preferences/services/enrich/src/`: every `httpx.AsyncClient(...)` that talks to the local Qdrant or Oxigraph now passes `trust_env=False`, 13 call sites (`enricher.py` 4, `hierarchy.py` 3, `cli.py` 6), plus one comment block per file. Public API clients under `clients/` are unchanged.

Why: with `HTTP(S)_PROXY` set and no matching `NO_PROXY`, loopback writes went to the proxy and `_store_enrichment` returned False (measured on a dev Mac, proxy 127.0.0.1:8118).

Retired: re-pinned to 4e023299 (see the manifest note).

Proof: `tests/test_cm019_local_store_ignores_proxy.py` (dead proxy in the env, real loopback server, own control, AST check of all 13 sites); fails on origin/main with 17 failures.

## 2026-10-21: Facebook watched rows emit `facebook_watched` (personal-world-graph #419, 5d1cdf13)

Tree `cm019_preferences`. Pin HELD at 7fd66daf; 5d1cdf13 added to `hold_ack_shas` (grafted, pin held).

- `services/ingest/src/parsers/meta.py`: the single upstream hunk (the movie_tv Like rows from Facebook watched history use `source="facebook_watched"`), applied by exact replacement because the vendored file carries earlier CM051 grafts. Measured: the changed lines equal upstream's for this file. The upstream test file is not in the vendored set.
- Why not re-pin: main is 10 commits past the pin, nine of them the smart-prefs derive engine this row holds.
- Paired in the same CM051 change: the data_conservation `expected.json` movie_tv row moves from `facebook` to `facebook_watched`, and cm059_editor is re-pinned to 5f3e94ce (#36), which pins `facebook_watched` as observed and local-only.
- Retire: a re-pin past 5d1cdf13 once the smart-prefs hold is lifted.

## 2026-10-21: enrich consent gate, merged from personal-world-graph #421 (UNMERGED upstream, head 455fb8e1)

Tree `cm019_preferences`. Pin HELD at 7fd66daf and NOT moved to the #421 head: that SHA is unmerged (a squash will rewrite it), and the branch carries the nine held smart-prefs commits as ancestors, so a pin there would make the freshness gate stop listing them while the tree still does not vendor them. Re-pin to the merge commit once #421 lands.

Method: `git merge-file` three-way, base = upstream@7fd66daf, ours = the vendored file, theirs = upstream@455fb8e1, for `services/enrich/src/cli.py` (clean) and `enricher.py` (two import conflicts, both kept). `consent.py` is new, copied byte for byte. CM051's own local changes are kept, including cli.py's `--budget-seconds` and its file-only `require_public_lookup_consent()` backstop (walk #28).

- `consent.py`: `public_lookup_allowed()` reads the env var if set and non-empty, else `${OSTLER_DIR}/config/.env` exactly as the install.sh gates do; exact match on `accepted`.
- `enricher.py`: every `EnrichmentService` entry point refuses without consent; the topic skip-checks also look in the default graph.
- `cli.py`: `normalize` runs a local offline pass without consent; `enrich` and `parallel` refuse. The upstream gate is imported as `require_enrichment_consent` because cli.py already defines a zero-argument `require_public_lookup_consent()`; importing it under the upstream name would be shadowed by that def and every `enrich` run would raise TypeError.

Open tension, not resolved here: the CM051 backstop deliberately ignores the environment ("a variable left in a caller's shell is not the customer's recorded answer"); upstream consent.py lets the env var win. Both gates now run, so the stricter one decides (env accepted + file declined: refused; env declined + file accepted: refused).

Retire: re-pin past the #421 merge commit.

Proof: `tests/test_cm019_enrich_consent_gate_vendored.py` (wired in `enrichment-reaches-corpus.yml`); fails on origin/main (no `src/consent.py`).


## 2026-10-21 addendum: personal-world-graph #421 MERGED as 5622a763, pin moved

Pin re-pinned 7fd66daf -> 5622a76360cc6ce5b91fe023295e1bb6eb8a0589 (the #421 merge commit). `consent.py` re-synced byte for byte to that commit; it supersedes the 455fb8e1 copy described above: the file must say accepted AND the environment variable, when set at all (even empty), must say accepted; the file is read as bytes and split on LF only, so a CRLF line is refused. This resolves the "open tension" above: upstream no longer lets the env var win, so the stricter-decides behaviour is now upstream's own. `enricher.py` and `cli.py` upstream are byte-identical between 455fb8e1 and the merge commit, so they are unchanged here. CM051's local changes (`--budget-seconds`, the file-only backstop, the `require_enrichment_consent` import name) are kept. The upstream tests for the gate are not vendored; `tests/test_cm019_enrich_consent_gate_vendored.py` carries arm 1b for the new rules.

## 2026-10-21 smart-prefs: the derive engine is grafted at the current pin (CM051 #2954)

Tree `cm019_preferences`. Pin NOT moved: it stays 5622a763, which main set in #3074. That re-pin moved past the nine smart-prefs derive commits while holding the engine out of the vendored subset; this change brings it in.

- Added, byte-identical to upstream@96ff272d and unchanged at 5622a763: `services/enrich/src/derive/` (11 `.py`, `dimensions.yaml`, `readers.yaml`, `contract/derived_preferences_response.example.json`), `services/common/strength.py`, `ontology/shacl/derived-preference-shapes.ttl`, `ontology/upper/pwg-derived.ttl`. Measured: `git diff --stat 96ff272d 5622a763` over those paths is empty, and `cmp` against upstream passes 17 of 17.
- `requirements.txt` (vendor-only, its own VENDOR_ONLY row): `pyyaml`, `rdflib`, `pyshacl`.
- NOT carried, recorded in `CM019_DIVERGENCE_REGISTRY.md`: the `services/ingest/src/filters.py` delegation to `strength.py` (aae370bc). The vendored filters.py keeps its inline copy of the same maths.
- Manifest: the nine derive shas leave `hold_ack_shas`; 5d1cdf13 stays.
- These files are not a divergence from source at the pin. They are recorded here because the pin did not move in this diff, and this is the tree's declared record.
- Retire: nothing to retire for the engine itself. It is source at the pin.

## 2026-10-23 smart-prefs stated: what the owner says in conversations (personal-world-graph #423)

Tree `cm019_preferences`. Pin NOT moved. DIVERGENCE from source at the pin: it ACKS UPSTREAM andygmassey/personal-world-graph PR #423 (branch feat/smart-prefs-stated-conversations, head 01dc7e7a, rebased onto #427 570da936 which sits on #422). Stacked on this repo's #3124 (acks #427).

- Changed, byte-identical to #423's head: `services/enrich/src/derive/{stated.py,stated_messages.py,stated_model.py,stated_vocab.yaml}` (new), `derive/{config,engine,model,query,endpoint,consume,writer}.py`, `derive/{dimensions,readers}.yaml`, `ontology/upper/pwg-derived.ttl` (declares `pwg:privacyLevel`).
- What it does: owner-attributed CM048 `preference` facts (read-only SPARQL on the fact store) and the owner's own lines in the extracted iMessage/WhatsApp transcripts (`~/Documents/Ostler/Conversations/*/*/transcript.md`; never chat.db) become evidence with a dimension, a normalised value, polarity and intensity, counted once per conversation per month (at most three months). Adds `food.drink` and `food.ingredient`. Cuisines map through the SHARED hierarchical `vocab/cuisine.yaml` (lowercase keys; sichuan and cantonese are separate values under chinese; no second cuisine list). No message text reaches the derived node; its because line is the fixed "you said so in a message".
- Privacy: same filters as the fact path (L3 out, deceased/suppressed contacts via `pwg:SuggestionSuppression`, minors by text guard and a caller set; no person-level minors flag exists). L2 is ADMITTED and every derived node inherits the HIGHEST privacy level of its evidence (`pwg:privacyLevel`, mirror payload and endpoint item `privacy_level`). Consumers must read it: that lift is outside this tree (MERGED, not PROVEN).
- Tier-model polarity stage (`stated_model.py`): after every filter; the model decides polarity only, schema-constrained and validated; cap, timeout, user-active lease, atomic salted-hash verdict cache. DISABLED BY DECISION (precision 2/6 on the Mini16, under the 80% bar); no LaunchAgent is installed. `scripts/ostler-stated-model-tick.sh` + `tests/test_stated_model_tick_yields.sh` pin the slot / tier-defer / tier-model-only guarantees.
- Proof on this tree: `tests/test_vendored_stated_preferences_reach_the_derive_engine.py` and `tests/test_vendored_stated_transcripts_reach_the_derive_engine.py`, both wired in `derived-preferences.yml`.
- 2026-10-25 (CM051 #3129 shrink): the `derive/**` files and ontology above are now on main byte-equal to upstream@5af9f5b5 (T0j #3160); this PR carries only the tick script, its test and the two reach tests.
- Retire: when #423 merges, re-pin to its merge commit and delete this section.

## 2026-10-22 smart-prefs: derive across all of life (personal-world-graph #422)

Tree `cm019_preferences`. Pin NOT moved: it stays 5622a763. This is a DIVERGENCE from source at the pin, because upstream #422 is open. It ACKS UPSTREAM andygmassey/personal-world-graph PR #422 (branch feat/smart-prefs-all-of-life): the same diff, except `ingest/src/parsers/linkedin.py` (see the round-2 bullet).

- Changed, byte-identical to #422's head: `services/enrich/src/derive/{config,engine,model,query,readers}.py`, `services/enrich/src/derive/{dimensions,readers}.yaml`, `ontology/upper/pwg-derived.ttl` (declares `pwg:evidenceTitle`). The other 10 files grafted in #2954 are unchanged.
- What it does: the registry goes from three film dimensions to 21 across films, tv, music, books, podcasts, interests, web, news, food, places and brands, same output contract. Engine guards: one preference is one observation of a value, `max_items` per dimension, evidence titles on the node, an overlay tag node with two labels is dropped, the gateway scrolls once per category set.
- Also (round 2): `services/ingest/src/parsers/linkedin.py` gains `_parse_positions` and `_parse_profile_industry` (Positions.csv; only the Industry column of Profile.csv) and a directory export now reaches Skills, Positions and Profile. Applied by patch(1) onto the vendored file, which keeps its own claim-by-shape divergence; there `positions.csv` and `profile.csv` join `LINKEDIN_AMBIGUOUS_FILES` with LinkedIn's column names, so a foreign file of the same name is not claimed. The upstream diff is the plain-list version of the same change. Registry also gains food.restaurant, health.activity, work.*, place.area, finance.spend_category (union with personal-world-graph feat/pwg-derive-general chunk 6).
- Round 3 (Archie ruling): `derive/{consume,query,endpoint}.py` also carry #422's category interleave: the endpoint's top-N is round-robin by category (`get_mixed_preferences`, `interleave_by_category`), so one wide category cannot own the list. The HUB route that actually serves /api/v1/preferences/derived is `vendor/cm041/assistant_api/derived_preferences.py` (CM041 #215, vendored by #3111), a verbatim lift of this builder with its own reader; it still ranks by confidence alone and needs the same lift (see the PR body).
- Round 4 (the owner: types before things): dimensions carry `tier: broad|specific`; the endpoint takes `tier` (default `broad`, `all` = old behaviour, broad first within a category); new reader kinds `rollup` (a tag known for some items under an artist/album/series/restaurant applies to all of them) and `lexicon`, and SHARED vocabularies `derive/vocab/{cuisine,music_style}.yaml` (food.cuisine and media.music.genre map into them). Same files as #422's round 4. The walk probe's route URL gains `&tier=all` so it still counts every derived preference.
- Round 5 (Archie ruling, 2026-10-24): `derive/readers.py` is no longer byte-identical to #422's head: its SCROLL_FIELDS block carries personal-world-graph main's three extra keys (`privacy_level`, `compartment_level`, `user_id`) so the privacy gate sees a scrolled point's level. See the privacy-gate section below.
- Proof on this tree: `tests/test_vendored_derive_covers_all_of_life.py` and `tests/test_vendored_linkedin_career_reaches_the_derive_engine.py` (both wired in `derived-preferences.yml`): RED on main, GREEN here.
- Retire: when #422 merges, re-pin to its merge commit and delete this section; the files are then source at the pin.
## 2026-10-22: ingest contract (Apple Music artist and play time, Uber event time)

Tree `cm019_preferences`. Pin NOT moved. Hand edits, no patch (`divergence_patch` is empty for this tree, see above).

- `services/ingest/src/parsers/apple.py`: (1) new helpers `_split_artist_track`, `_first_timestamp`, `_artist_lookup` and the constants `_APPLE_PLAY_TIMESTAMP_COLUMNS`, `_APPLE_HISTORY_FILES`, directly after `_later`. (2) `_parse_track_play_history` and `_parse_daily_tracks` now put `extra["artist"]` and `extra["track"]` on every row whose description is "artist - title". (3) `_parse_play_activity` reads the play time from the plain event column, then the event-end, event-start and event-received columns, matched case-insensitively (it read only the first, which is blank on about two thirds of completed plays in a real export), and sets `extra["artist"]` from the sibling history files when the title maps to exactly one artist. Subjects are unchanged on purpose: the stable preference id derives from them.
- `services/ingest/src/parsers/uber.py`: `observed_at` is now the trip or order request time on trip records, food order records, restaurant aggregates and food item aggregates (it was only a display string in `extra["timestamp"]`). New helpers `_as_utc`, `_later_dt`.
- Why no patch: same reason as above, the tree has no recorded patch and the shared-file delta is the 42-file reconciliation owed to the CM019 owner.
- Owed upstream: yes. Both changes are ports of personal-world-graph PR "ingest contract: Apple Music artist and real play time, Uber event time"; retire this section when that merges and the tree is re-pinned past it.
- Proof: tests/test_ingest_contract.py (RED on origin/main, GREEN here, 7 mutants caught), wired in .github/workflows/derived-preferences.yml.
## 2026-10-23: per-item privacy gate on online enrichment (personal-world-graph fix/enrich-privacy-gate, UNMERGED upstream)

Tree `cm019_preferences`. Pin NOT moved (5622a763). Grafted ahead of the upstream merge for v1.0.118.

- Added `services/enrich/src/privacy_gate.py`, byte-identical to the upstream PR head (sha256 87698fb4385bca3cca8728de6b605d7429e9af1943a28909eb4f40b01eee65e2 on both sides).
- `services/enrich/src/enricher.py`: the upstream hunks applied by exact replacement, because the vendored file carries earlier CM051 divergence (eligibility gate, budget, wikidata_film routing). Measured: the sorted multiset of changed lines equals upstream's for this file (38 lines, identical sha256 of the sorted set).
- CLOSED (CM051 #3116, 2026-10-24): upstream's `derive/readers.py` SCROLL_FIELDS change is now carried. It was first NOT carried because the vendored derive tree predated SCROLL_FIELDS; #3116 brought SCROLL_FIELDS in without the level keys, so a point scrolled by a derive reader reached `privacy_gate` with no level and was refused as `level_unknown` (L2 too). The SCROLL_FIELDS block is now byte-identical to personal-world-graph main (`privacy_level`, `compartment_level`, `user_id`). Proof: `tests/test_vendored_derive_scroll_carries_privacy_level.py` (wired in `derived-preferences.yml`): an L3 point scrolled by a real `QdrantFieldReader` through the real `HttpStoreGateway` is refused as `level_L3`, legacy compartment 3 as `level_legacy_3`, the L2 control passes; with the three keys removed all 4 arms are red (`level_unknown`).
- Proof: `tests/test_cm019_enrich_privacy_gate_vendored.py` (wired in `enrichment-reaches-corpus.yml`); fails on origin/main (no `src/privacy_gate.py`; with the module present and the old enricher, the stats field it counts into does not exist).
- Retire: re-pin past the upstream merge commit.

## 2026-10-23: an explicit L0 survives ingest (personal-world-graph fix/ingest-explicit-l0-survives, UNMERGED upstream)

Tree `cm019_preferences`. Pin NOT moved (5622a763). Grafted ahead of the upstream merge for v1.0.118.

- `services/ingest/src/pipeline.py` (3 sites), `services/ingest/src/parsers/email.py` (1), `services/ingest/src/parsers/apple.py` (1): `x or default` became `x if x is not None else default`, so compartment_level 0 (L0Personal) is no longer stored as 2. Applied by exact replacement; the changed lines equal upstream's for each file.
- Proof: `tests/test_cm019_explicit_l0_survives_ingest_vendored.py` (wired in `enrichment-reaches-corpus.yml`); on origin/main 5 of 11 arms FAIL (explicit 0 stored as 2).
- Retire: re-pin past the upstream merge commit.

## 2026-10-24 T0j: smart-prefs to personal-world-graph 5af9f5b5 (thematic rollup, sensitive gate, QID pass, minors producer)

Tree `cm019_preferences`. RE-PINNED 5622a763 -> 5af9f5b5 (Archie, 2026-10-24: consolidate; the smart-prefs files ARE that commit). verify stays skip: the shared-file reconciliation in the manifest ack is still owed (measured at the new pin: 52 of 115 shared files differ, 3642 changed lines, nearly all the pre-existing CM051 divergence). Upstream: andygmassey/personal-world-graph main at 5af9f5b5 (#439), which includes #424/#425/#427/#428/#429/#431/#432/#433 (sensitive gate), #434 (minors producer), #437, #438 (thematic rollup) and #439 (QID pass).

- BYTE-IDENTICAL to upstream@5af9f5b5, cmp-verified per file: every file under `services/enrich/src/derive/` except the four paraphrased below (adds `cuisine_local_model.py`, `cuisine_vocab.py`, `patterns.py`, `representatives.py`, `sensitive.py`, `sensitive_terms.yaml`, `stated.py`, `stated_messages.py`, `stated_model.py`, `stated_vocab.yaml`, `thematic.py`; updates the rest), `services/common/recency.py` (new; `derive/scoring.py` and `derive/patterns.py` import it), `services/enrich/src/hierarchy.py` (was source at the pin; upstream adds the bridge join and the consent fail-close), `services/ingest/src/minors.py` (new; `derive/stated_messages.py` loads it by path, and the ingest pipeline below calls it), `ontology/upper/pwg-derived.ttl`, `ontology/shacl/derived-preference-shapes.ttl`.
- PARAPHRASED, comments and docstrings only (this is a PUBLIC repository; same practice as the 2026-08-27 csv_parser.py note): `derive/engine.py` (1 comment), `derive/sensitive.py` (2 docstrings), `derive/sensitive_terms.yaml` (2 comments) name public persons, bands and brands as examples. They are described in words here. `services/ingest/src/minors.py` docstring example uses the approved cast. `derive/patterns.py` (module docstring, line 3): the upstream branch name contains the retired project prefix that `tests/test_enrichment_identity_and_disclosure.sh` forbids anywhere in the enrich tree (case-insensitive); it now says "the derive-general branch". No code, data or YAML value differs from upstream: with the comment lines masked the files are identical.
- GRAFTED by exact replacement, because the vendored files carry earlier CM051 divergence (eligibility gate, whole-pass budget, `require_enrichment_consent`, wikidata_film routing): `services/enrich/src/enricher.py` takes upstream's `_WIKIDATA_PENDING_TOPICS_QUERY` and `_LOCAL_PENDING_TOPICS_QUERY` (default graph AND named graphs), new `_HIERARCHY_PENDING_QUERY`, reason codes and `_turtle_escape`, and the methods `_topic_owner_refusals`, `_gate_topic_labels`, `normalize_topics_with_wikidata`, `store_topic_hierarchies`, `run_qid_pass`, each byte-identical to upstream's method body; imports `time`, `REASON_UNKNOWN_LEVEL`, `derive.sensitive.never_read_categories`, `derive.thematic`. `services/enrich/src/cli.py` gains `--qid-pass/--no-qid-pass`, `--qid-pass-seconds`, `QID_PASS_CAP_SECONDS`, `_qid_allowance`, `_run_qid_pass` (byte-identical to upstream) and the call in `_run_enrichment` before the exit decision. The vendored `--budget-seconds` (whole pass) is kept; the QID allowance defaults to it, capped at 300 s.
- `services/ingest/src/pipeline.py`: upstream #434's hunks applied by patch(1), clean, no fuzz, no backup: `_process_batch` stamps `extra.about_minor` from the owner's minors registry before embedding and writing; an unreadable registry stamps every item (stored, never derived).
- NOT carried, and HELD BY NAME because the pin now sits past them (a re-pin must not hide an ungrafted upstream hunk). Measured by a 3-way merge of each vendored file against upstream 5622a763 -> 5af9f5b5:
  - #432 food evidence: `parsers/food_evidence.py` and `clients/osm_cuisine.py` (absent), the food registration in `parsers/__init__.py` (12 lines), the food routing in `enricher.py`, one line in `models/enrichment.py`, the food hunks in `ingest/src/pipeline.py`. Owed by CM051 #3124 (the food half).
  - #431 representative-first: the `--representative-first` option and pass in `cli.py`. `derive/representatives.py` IS carried (byte-identical) but nothing in the vendored CLI calls it yet. Owed by CM051 #3120.
  - #422 `parsers/linkedin.py`: upstream's plain-list version; the vendored claim-by-shape version is deliberate (see "2026-10-22 smart-prefs" above).
  - #436 explicit L0: already grafted (see the 2026-10-23 L0 section); the 3-way merge changes 0 lines in `apple.py`.
- Tests: `tests/test_vendored_derive_tiers_and_rollup.py` and `tests/test_vendored_derive_covers_all_of_life.py` fake stores return no rows for a non-overlay query (same change as CM051 #3129's e7313d49); the broad set gains `theme.concept`.
- Proof: `tests/test_vendored_qid_pass_reaches_the_thematic_rollup.py` (wired in `derived-preferences.yml`): `python -m services.enrich.src.cli enrich --all` from this tree, then `derive_runner.run` over pyoxigraph, writes one `theme.concept` node from exactly the 3 admitted preferences; sensitive, minor, L3 and never-read topics are never sent. RED with the QID call unwired (13 of 29 fail).
- Retire: the held hunks above when #3124 and #3120 land; verify=full once the shared-file reconciliation is done. The paraphrased comment lines stay a recorded divergence until upstream drops the names.

## 2026-10-25 food evidence (personal-world-graph #432, CM051 #3124)

Tree `cm019_preferences`. Pin NOT moved: 5af9f5b5. `derive/**` is byte-equal to the pin (the food derive pieces came with T0j). ACKS the upstream food PR #432 (feat/food-prefs-evidence).

- New, byte-identical to the PR head: `services/ingest/src/parsers/food_evidence.py`, `services/enrich/src/clients/osm_cuisine.py`.
- Applied by patch(1), the rest of each file untouched: `enricher.py` (a food point with `extra.restaurant` and no known cuisine routes to `osm_cuisine`; every other food point stays on wikidata, see "2026-10-28 food routing"), `models/enrichment.py`, `ingest/src/pipeline.py`, `ingest/src/parsers/__init__.py`.
- Consent: the OSM client returns before any HTTP client exists unless `public_lookup_allowed()` (exact `accepted` only). Nominatim policy: identifying User-Agent, one request per second across processes, a per-run lookup ceiling.
- Retire: when #432 is re-pinned, delete this section.

## 2026-10-25 patterns wiring (CM051 #3130 shrink)

Tree `cm019_preferences`. Pin NOT moved: 5af9f5b5. `derive/**` (including `patterns.py`) is byte-equal to the pin on main, so only the vendor-only runner is edited here.

- `services/enrich/src/derive_runner.py`: builds the derivers with `default_derivers(dimensions)`, passes them to `DerivationEngine`, prints the trend, contradiction and context counts, and reports a failed deriver by name and exception type only (base nodes are kept).
- Proof: `tests/test_vendored_derive_patterns.py` (wired in `derived-preferences.yml`).
- Retire: when the runner change lands upstream and the tree is re-pinned past it.

## 2026-10-24: geocoders never log an address, venue or coordinates (personal-world-graph #442, UNMERGED upstream; S8, 118)

Tree `cm019_preferences`. Pin NOT moved by this graft (it was 5622a763 when written; main has since re-pinned to 5af9f5b5, see the T0j section above, and upstream #442 is still unmerged there). Grafted ahead of the upstream merge for v1.0.118.

- `services/enrich/src/geo/geocoder.py` (3 sites) and `services/enrich/src/clients/geocoder.py` (7 sites): the upstream PR head's hunks applied with `git apply --directory=vendor/cm019_preferences`. Each log line now carries a status, presence flag, exception type, count or the preference id, never the address, a prefix of it, the venue name or the coordinates. The only remaining difference from the upstream PR head in each file is the existing User-Agent line (2 diff lines per file, measured).
- Proof: `tests/test_vendored_logs_carry_no_personal_values.py` (wired in `.github/workflows/no-pii-in-logs.yml`); on origin/main's vendored files every geocoder arm FAILS.
- Retire: re-pin past the upstream merge commit.

## 2026-10-28 food routing (CM051 #3130)

Tree `cm019_preferences`. Pin NOT moved: 5af9f5b5. Corrects the food graft above, which added a SECOND `"food"` key (`osm_cuisine`) to `CATEGORY_CLIENTS` that silently overrode the first (`wikidata`) and whose branch returned None without `extra.restaurant`, so every non-restaurant food preference lost its Wikidata enrichment.

- `services/enrich/src/enricher.py`: ONE `"food": "wikidata"` key (as on main). In `enrich_preference`, `category == "food"` with `extra.restaurant` and no `extra.cuisine` re-routes to `osm_cuisine`; everything else falls through to the wikidata branch. The `osm_cuisine` branch no longer has a None return. Consent/L3/minor gating untouched (`consent_or_log`, `outbound_refusal` run first).
- Proof: `tests/test_enrichment_reaches_the_corpus.sh` (restaurant point -> osm_cuisine; plain food, empty extra, and cuisine-known -> wikidata). Red on ee0a2e47, green here, red on the any-food-to-osm mutant.
- Owed upstream: yes, CM019 (personal-world-graph #432, the food PR). The upstream branch carries the second key; carry this routing into it. Row: `CM019_DIVERGENCE_REGISTRY.md`, "food routing". Retire: when #432 lands with this routing and the tree is re-pinned.
