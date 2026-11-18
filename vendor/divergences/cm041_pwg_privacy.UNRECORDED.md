# cm041/pwg_privacy: a divergence the patch tool did not record

Tree: cm041/pwg_privacy (single file, vendor/cm041/pwg_privacy.py). Source: CM041 eee9b72 (PR #295, stacked on #291), pin not yet moved.

Until this graft the file was byte-identical to its pinned source. The graft (CM051 #3582) replaces it with the CM041 eee9b72 text, byte-identical to that commit. It adds `effective_level`, `sparql_effective_level`, `_classify_value`, `PRIVACY_PREDICATES`, the `_STRICT_RANK` ordering (ABSENT < L1 < L2 < L0 < UNREADABLE < L3), and changes `_record_level` and `is_l3` to read every spelling.

The pin should move to the CM041 commit once #295 merges. Until then this file is the one the patch cannot describe.

Revision (CM041 1e1523f, Archie ruling on #295): `ABSENT` is now a typed sentinel compared by identity, not the string "ABSENT". `sparql_effective_level` emits no absent marker; a subject with only blank tags has no row, and `effective_level(None)` gives `ABSENT`. The module docstring now states the outbound rule (every route not proven owner-local withholds L0, L3 and UNREADABLE).

Revision (CM041 be69c80, Archie blockers on #295): adds `outbound_ok` (L1, L2 served; L0, L3, UNREADABLE withheld; ABSENT per `absent_serves`) and `filter_outbound_facts`. `provenance_verdict` returns `"l0"` for an own or linked L0. `is_l3` is owner-local only.

Revision (CM041 866a7aa, canonical scale): the file is replaced by the CM041 866a7aa text, byte-identical. L0 is PUBLIC on the canonical scale; the "L0 = owner-private" rulings are withdrawn. The file adds `may_leave` (the outbound table), `outbound_ok` (a thin wrapper for the Hub route), `legacy_l0_guard` (an unmigrated L0 is withheld until the per-writer relabel; migrated when `privacy_scale == canonical-2026-11`), `CANONICAL_SCALE_KEY`/`CANONICAL_SCALE_VALUE`, and `provenance_verdict` reverted to the pre-canonical verdicts.

Tree: cm041/pwg_privacy (canonical re-graft, CM041 866a7aa).

Revision (CM041 531ac94, per-request destination). Tree: cm041/pwg_privacy. The file is byte-identical to CM041 531ac94: `DESTINATIONS` is now owner_local, owner_channel, cloud, others, export; the table has owner_local (L3 labelled); an undeclared or unknown destination is cloud; `resolve_destination` is added; `ROUTE_DESTINATION` is removed.

Revision (CM041 cf443dc, owner_local exemption). Tree: cm041/pwg_privacy. The file is byte-identical to CM041 cf443dc: owner_local is exempt from legacy_l0_guard, and served_label returns "private" for owner_local L3 and legacy L0.

Revision (CM041 #296 final head 6c5f709, re-graft for CM051 #3582). Tree: cm041/pwg_privacy. `pwg_privacy.py` is byte-identical to CM041 6c5f709: the scale, the outbound table and the stamp are read from the shared table through `privacy_scale.py`. Three files are added to vendor/cm041, each byte-identical to CM041 6c5f709: `privacy_scale.py` (the loader), `privacy_scale_canonical.tsv` (the table it reads, beside it) and `pwg_privacy_readers.py` (the reader helper `ical-server.py` and `derived_preferences.py` import). All three ship beside `pwg_privacy.py`: gui/project.yml (bundle step, hard-fails if absent), gui/Makefile stage-payload, release.sh, and install.sh at its three `pwg_privacy.py` copy sites (cold ical-server, pipeline dir, upgrade refresh). The pin should move to the CM041 merge of #296/#297.
