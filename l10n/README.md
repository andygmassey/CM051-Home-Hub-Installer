# l10n

1. **Write English as normal.** It is the source of truth. A new string simply shows in English until the next translation run; Apple's catalogues and our installer loaders fall back to English, so a missing translation never blocks a PR or a cut.
2. **Changed an existing English string?** The pre-commit hook (`.githooks/pre-commit`) falls its translations back to English for you. Without the hook, PR CI says so and the fix is `python3 l10n/ostler_l10n.py stale` (offline).
3. **PR CI** (`l10n-check.yml`, offline, no secrets): blocks on placeholder parity, verbatim tokens (INSTALL...), catalogue validity, and stale translations; prints coverage per language, which never blocks.
4. **Translations** run out of band: `l10n-weekly.yml` (Mondays, or "Run workflow") or locally `OSTLER_L10N_KEY_FILE=<key file> python3 l10n/ostler_l10n.py run` before a cut. Only new or changed strings are sent; the result is one PR for review.
5. `diff` shows what a run would send and its estimated cost; `run` refuses above `budget_usd`. Local runs log cost to `~/walkdriver/API_SPEND_LOG.tsv`, CI runs to the job summary and PR body.
6. Rules (brand names, Apple UI terms, register, "transcribing" not "recording", no em dashes): `glossary.yaml`, versioned. Languages and catalogues: `config.yaml`.
7. `provenance.json` records which English each translation was made from. Never edit it by hand.
8. **Legal / consent keys** (`legal_patterns` in config.yaml) ship translated ONLY with a `legal_reviews.tsv` row (reviewed_by + date) for their current English; otherwise English ships and the translation waits in `legal_pending/` (`legal-list`, then `legal-approve LANG CAT::KEY --by NAME --date YYYY-MM-DD`). Other reviewer flags: `# NEEDS REVIEW` in shell files, `REVIEW_FLAGS.<lang>.tsv` for the GUI JSON.
9. `python3 l10n/ostler_l10n.py self-test` proves the gate fails on a dropped `%@`, a lost INSTALL and a changed English string.
10. The canonical tool and glossary live here (CM051, public, free Actions). Other repos vendor them byte-for-byte; see their `l10n/VENDORED_FROM`.
