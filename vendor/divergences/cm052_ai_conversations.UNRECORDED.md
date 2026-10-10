# cm052_ai_conversations: local graft awaiting CM052 #14

Tree `cm052_ai_conversations`, file `src/cm052/subscription_gate.py`.

Pricing ruling 2026-10-10 (Andy): a standard Hub sale includes 3 months of Pro,
not 30 days. The gate is the same file CM051 vendors for the Hub
(`vendor/cm041/assistant_api/subscription_gate.py`, vendor-only per
`VENDOR_ONLY.tsv`), and a CM051 test requires the two copies to be identical, so
the change lands in both. Upstream: CM052 #14
(https://github.com/andygmassey/CM052/pull/14, branch head
`6670e30aef0552b5f336233ae46b13fce2c0727e`), HOLD with this PR.

Edits: `INCLUDED_MONTHS = 3`, `_add_months()`, and `activate_first_month_free`
computing `expires = _add_months(purchase_dt, INCLUDED_MONTHS)`; docstrings
reworded. Nothing else differs from CM052@1ec05783.

## What a future sync must preserve

Nothing, once CM052 #14 merges: re-pin to a CM052 sha that contains it and this
record retires. Until then `sync_vendor.sh cm052_ai_conversations` would revert
the Hub to 30 days; the guard is
`vendor/cm041/assistant_api/tests/test_subscription_gate.py::TestIncludedThreeMonths`
and `tests/test_no_divergent_vendor_twin.sh`.
