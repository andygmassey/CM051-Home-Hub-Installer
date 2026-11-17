# cm041/pwg_privacy: a divergence the patch tool did not record

Tree: cm041/pwg_privacy (single file, vendor/cm041/pwg_privacy.py). Source: CM041 eee9b72 (PR #295, stacked on #291), pin not yet moved.

Until this graft the file was byte-identical to its pinned source. The graft (CM051 #3582) replaces it with the CM041 eee9b72 text, byte-identical to that commit. It adds `effective_level`, `sparql_effective_level`, `_classify_value`, `PRIVACY_PREDICATES`, the `_STRICT_RANK` ordering (ABSENT < L1 < L2 < L0 < UNREADABLE < L3), and changes `_record_level` and `is_l3` to read every spelling.

The pin should move to the CM041 commit once #295 merges. Until then this file is the one the patch cannot describe.

Revision (CM041 1e1523f, Archie ruling on #295): `ABSENT` is now a typed sentinel compared by identity, not the string "ABSENT". `sparql_effective_level` emits no absent marker; a subject with only blank tags has no row, and `effective_level(None)` gives `ABSENT`. The module docstring now states the outbound rule (every route not proven owner-local withholds L0, L3 and UNREADABLE).

Revision (CM041 be69c80, Archie blockers on #295): adds `outbound_ok` (L1, L2 served; L0, L3, UNREADABLE withheld; ABSENT per `absent_serves`) and `filter_outbound_facts`. `provenance_verdict` returns `"l0"` for an own or linked L0. `is_l3` is owner-local only.

Revision (CM041 866a7aa, canonical scale): the file is replaced by the CM041 866a7aa text, byte-identical. L0 is PUBLIC on the canonical scale; the "L0 = owner-private" rulings are withdrawn. The file adds `may_leave` (the outbound table), `outbound_ok` (a thin wrapper for the Hub route), `legacy_l0_guard` (an unmigrated L0 is withheld until the per-writer relabel; migrated when `privacy_scale == canonical-2026-11`), `CANONICAL_SCALE_KEY`/`CANONICAL_SCALE_VALUE`, and `provenance_verdict` reverted to the pre-canonical verdicts.

Tree: cm041/pwg_privacy (canonical re-graft, CM041 866a7aa).
