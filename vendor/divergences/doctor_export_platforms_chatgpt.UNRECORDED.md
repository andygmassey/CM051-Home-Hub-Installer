# doctor: export_platforms.tsv gains a ChatGPT row (CM051, 2026-11-14)

Vendored edit in `vendor/doctor/agent/export_platforms.tsv`: one row, `ChatGPT`.
It mirrors the watcher's new ChatGPT label in `lib/ostler-detect-exports.sh` (SIGS).
Its request URL is also in installer Q11 (`install.sh`), which the drift test checks.

- request_url: `https://chatgpt.com/#settings/DataControls` (UNVERIFIED-FETCH: the
  help page at help.openai.com returned HTTP 403 to the fetcher; the path is the
  documented Settings > Data Controls > Export data).
- No upstream patch: the row lives only in CM051 until the same change lands in the
  Doctor source table. Re-vendor must keep this row or the drift test goes red.
