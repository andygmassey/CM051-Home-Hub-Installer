# cm024_knowledge: divergence not captured by the patch (v1.0.123, 2026-11-04)

Regeneration REFUSED, measured 2026-11-04, against a CM024 checkout that holds
the pinned sha e0196b10 (`CM024=~/Developer/cm024-canon
VENDOR_PATCH_REGEN_CONFIRM=cm024_knowledge bash scripts/regenerate_divergence_patch.sh
cm024_knowledge --write`): "REFUSED: the written patch does not reconstruct the
vendored tree. The repo is back as it was." So this hand edit is recorded here.

## What changed

`vendor/cm024_knowledge/ostler_knowledge/storage/qdrant_store.py`:

- New module constants `UPSERT_ATTEMPTS = 3` and `UPSERT_RETRY_BASE_S = 1.0`,
  directly above `class QdrantStore`.
- `QdrantStore.upsert` (the per-chunk upsert): the single `upsert_vectors` call
  is retried up to `UPSERT_ATTEMPTS` times with a doubling back-off; each
  retried failure logs a WARNING; only the final failure logs the existing
  ERROR "Failed to upsert chunk: <e>" and returns False.

## Why

Walk v1.0.122 diag on Mini16: `hydrate-apple-notes.log` logged "Failed to
upsert chunk: timed out" once under load and the import wrote 17999 of 18000;
probe qdrant_has_fd_headroom_and_writes_land FAILed. The point id is
deterministic (md5 of note_id + chunk_index), so a retry is idempotent.

Proof: `tests/test_cm024k_upsert_chunk_retries_a_timeout.py` (wired in
tests-unwired-sweep-mz.yml); a mutant with one attempt fails arm 1.

## Owed upstream

Yes: CM024 `ostler_knowledge/storage/qdrant_store.py`. Retire this file when a
re-pin brings it in.
