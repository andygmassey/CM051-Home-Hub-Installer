# cm041/pwg_privacy: a divergence the patch tool did not record

Tree: cm041/pwg_privacy (single file, vendor/cm041/pwg_privacy.py). Source: CM041 eee9b72 (PR #295, stacked on #291), pin not yet moved.

Until this graft the file was byte-identical to its pinned source. The graft (CM051 #3582) replaces it with the CM041 eee9b72 text, byte-identical to that commit. It adds `effective_level`, `sparql_effective_level`, `_classify_value`, `PRIVACY_PREDICATES`, the `_STRICT_RANK` ordering (ABSENT < L1 < L2 < L0 < UNREADABLE < L3), and changes `_record_level` and `is_l3` to read every spelling.

The pin should move to the CM041 commit once #295 merges. Until then this file is the one the patch cannot describe.
