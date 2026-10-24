# l10n

1. **Write English as normal.** It is the source of truth. A new string simply shows in English until the next translation run; Apple's catalogues and our installer loaders fall back to English, so a missing translation never blocks a PR or a cut.
2. **Changed an existing English string?** The pre-commit hook (`.githooks/pre-commit`) falls its translations back to English for you. Without the hook, PR CI says so and the fix is `python3 l10n/ostler_l10n.py stale` (offline).
3. **PR CI** (`l10n-check.yml`, offline, no secrets): blocks on placeholder parity, verbatim tokens (INSTALL...), catalogue validity, and stale translations; prints coverage per language, which never blocks.
4. **Translations** run out of band: `l10n-weekly.yml` (Mondays, or "Run workflow") or locally `OSTLER_L10N_KEY_FILE=<key file> python3 l10n/ostler_l10n.py run` before a cut. Only new or changed strings are sent; the result is one PR for review.
5. `diff` shows what a run would send and its estimated cost; `run` refuses above `budget_usd`. Local runs log cost to `~/walkdriver/API_SPEND_LOG.tsv`, CI runs to the job summary and PR body.
6. Rules (brand names, Apple UI terms, register, "transcribing" not "recording", no em dashes): `glossary.yaml`, versioned. Languages and catalogues: `config.yaml`.
7. `provenance.json` records which English each translation was made from. Never edit it by hand.
8. **Legal / consent keys** (`legal_patterns` in config.yaml) stay ENGLISH in every locale (Andy ruling 2026-10-22, `legal_english_only: true`). A `legal_reviews.tsv` row cannot make a translation ship; `legal-approve` refuses. Reviewer names are never recorded here (opaque ids only, public repo); `tests/test_l10n_legal_strings_stay_english.py` enforces it.
9. `python3 l10n/ostler_l10n.py self-test` proves the gate fails on a dropped `%@`, a lost INSTALL and a changed English string.
10. The canonical tool and glossary live here (CM051, public, free Actions). Other repos vendor them byte-for-byte; see their `l10n/VENDORED_FROM`.
