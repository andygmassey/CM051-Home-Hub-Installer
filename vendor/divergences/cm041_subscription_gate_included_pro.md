# Included Pro window: the gate's plan, fail-closed and no-shrink rules

**Recorded 2026-11-16. Location and shape only, never content.**

Upstream (source of truth): CM052 `src/cm052/subscription_gate.py`, PR #21
(`feat/pro-included-months-180-90`), head `7fc1a52` at the time of this
record. This is NOT a divergence from CM041 upstream: CM041 has no
`subscription_gate.py` (checked 2026-11-16, no history on any branch).

## What changed, per file

| tree | file | change |
|---|---|---|
| `cm041/assistant_api` | `subscription_gate.py` | byte-identical to the CM052 upstream file |
| `cm052_ai_conversations` | `src/cm052/subscription_gate.py` | byte-identical to the CM052 upstream file |
| `cm041/assistant_api` | `tests/test_subscription_gate.py` | 30-day expectations moved to the 90-day provisional window; helper passes a signed licence |
| `tests` | `test_g7_gate_copies_are_one.py` | digest pin re-set to the new file; helper passes a signed licence |
| `tests` | `test_the_trial_must_actually_end.sh` | day boundaries 29/31/40 moved to 89/91/100 |
| `tests` | `test_install_first_month_free.sh` | expiry bound 90 days, grace bound 104 days, signed licence |
| `tests` | `test_subscription_activation_path.sh` | symbol check accepts the `activate_first_month_free` alias |

## Why

The Hub grants the included Pro window from the signed licence plan:
founding and ff 180 days, standard 90, no plan = provisional 90. Unsigned or
absent licence grants nothing; a lapsed licence grants no new window; a
running window never shrinks. Decided by Andy 2026-11-16 ("yes, pull into 133").
