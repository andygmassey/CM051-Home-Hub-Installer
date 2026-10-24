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

Andy's product rule, same review: "I'd rather Bursar overcounted, than
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
honestly, are decisions for Archie/Andy, not assumed here.

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
phone`'s install.sh wiring) is flagged for Archie/Andy, not assumed here.
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
## No per-source storage cap (CM051 #28, Andy 2026-10-14: "Need everything.")

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

## 2026-10-23: per-item privacy gate on online enrichment (personal-world-graph fix/enrich-privacy-gate, UNMERGED upstream)

Tree `cm019_preferences`. Pin NOT moved (5622a763). Grafted ahead of the upstream merge for v1.0.118.

- Added `services/enrich/src/privacy_gate.py`, byte-identical to the upstream PR head (sha256 87698fb4385bca3cca8728de6b605d7429e9af1943a28909eb4f40b01eee65e2 on both sides).
- `services/enrich/src/enricher.py`: the upstream hunks applied by exact replacement, because the vendored file carries earlier CM051 divergence (eligibility gate, budget, wikidata_film routing). Measured: the sorted multiset of changed lines equals upstream's for this file (38 lines, identical sha256 of the sorted set).
- NOT carried: upstream's `derive/readers.py` SCROLL_FIELDS change. The vendored derive tree predates SCROLL_FIELDS, and nothing in the vendored tree drives an online lookup from the derive scroll (representative-first enrichment, upstream #431, is not vendored). The vendored enricher reads the full Qdrant payload (`with_payload: True`), so `compartment_level` reaches the gate.
- Proof: `tests/test_cm019_enrich_privacy_gate_vendored.py` (wired in `enrichment-reaches-corpus.yml`); fails on origin/main (no `src/privacy_gate.py`; with the module present and the old enricher, the stats field it counts into does not exist).
- Retire: re-pin past the upstream merge commit.

## 2026-10-23: an explicit L0 survives ingest (personal-world-graph fix/ingest-explicit-l0-survives, UNMERGED upstream)

Tree `cm019_preferences`. Pin NOT moved (5622a763). Grafted ahead of the upstream merge for v1.0.118.

- `services/ingest/src/pipeline.py` (3 sites), `services/ingest/src/parsers/email.py` (1), `services/ingest/src/parsers/apple.py` (1): `x or default` became `x if x is not None else default`, so compartment_level 0 (L0Personal) is no longer stored as 2. Applied by exact replacement; the changed lines equal upstream's for each file.
- Proof: `tests/test_cm019_explicit_l0_survives_ingest_vendored.py` (wired in `enrichment-reaches-corpus.yml`); on origin/main 5 of 11 arms FAIL (explicit 0 stored as 2).
- Retire: re-pin past the upstream merge commit.
