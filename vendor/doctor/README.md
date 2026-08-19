# vendor/doctor/

Vendored copy of the Ostler Doctor diagnostic dashboard. Source of truth:
`HR015 - Gaming PC/doctor/agent/`.

## Why vendor

`install.sh` probes `${SCRIPT_DIR}/doctor/agent/` at section 3.14h
(`Setting up Ostler Doctor diagnostic dashboard`, install.sh:4794) and
stages those files into `${OSTLER_DIR}/doctor/` so the launchd-managed
service can `python3 -m doctor.agent.web_ui` against the customer's
local Hub at `http://127.0.0.1:8089/doctor`. When `SCRIPT_DIR` is the
installer `.app`'s `Contents/Resources/`, `doctor/agent/` must travel
inside the bundle.

The pre-vendor behaviour was a soft skip: if the bundled copy was
missing and `PWG_DOCTOR_REPO` was not set, install.sh continued without
the dashboard. That left customers without the iframe target that
`Ostler.app`'s Pairing tab points at (`http://127.0.0.1:8089/pair-ios`,
served by Doctor's `web_ui.py`). Vendoring makes the customer install
path self-contained for the v1.0 launch.

## What is included

Pure-Python runtime under `agent/`. Listed in `install.sh:4802` as the
`${SCRIPT_DIR}/doctor/agent/` payload.

- `__init__.py` (empty, marks the package)
- `.env.example` (DOCTOR_PORT, GATEWAY_URL, OLLAMA_URL placeholders)
- `apple_style.css` (Dashboard chrome)
- `banner_copy.py`, `diagnostic_copy.py`, `first_run_copy.py`,
  `web_ui_copy.py`, `dashboard_components.py` (Rule 0.9 catalogues +
  rendered components)
- `chat_token.py` (chat-token mint endpoint for the iOS companion)
- `pair_status.py` (paircode + QR status the `/pair-ios` route serves)
- `imessage_tcc_posture.py` (iMessage Full Disk Access posture marker
  reader, rendered by `dashboard_components.py`)
- `diagnostic_rules.py`, `status_collector.py` (the diagnostic engine)
- `first_run.py` (first-launch wizard panels)
- `import_evernote.py`, `import_evernote_runner.py` (Evernote ingest UI
  + runner; gated by user action, safe to ship dormant)
- `proxy.py`, `wiki_correct.py` (wiki proxy + corrector)
- `web_ui.py` (FastAPI entry point: `/doctor`, `/pair-ios`,
  `/api/v1/pair/status`, `/api/v1/pair/regenerate`, panels)
- `requirements.txt` (`fastapi`, `uvicorn`, `httpx`, `pyyaml`, `qrcode`)

Last synced from HR015 `doctor/agent/` @ `1bb0a0d` (HR015 origin/main,
2026-06-16). This sync was a **surgical subset** carrying HR015 #187
(`6636fdd`, "native-aware Docker rules") to kill the false
"Docker not installed / not running" criticals that led the Doctor
dashboard on the productised native build (the data tier runs in Colima
containers, not Docker Desktop, so the Docker-Desktop check is a
false-RED). The .152 cold-wipe walk (2026-06-16) still showed those
criticals because the vendored copy predated #187.

Files re-vendored from upstream in this sync:
`diagnostic_rules.py`, `status_collector.py`, `web_ui.py`,
`apple_style.css`, `first_run.py`, and the new `config_panel.py`
(a lazy import target of the updated `web_ui.py`).

Surgical re-sync (HR015 #170, 2026-07-30): `pair_status.py` @ HR015
origin/main `b0b3831` (carries #185 `a088b26`, "unblock native Doctor
dashboard + pairing on single-machine install"). The prior vendored copy
predated #185, so `gateway_port()` read only `ZEROCLAW_GATEWAY_PORT` then
`PORT` and fell through to the dead default `42617` -- the Doctor
`/pair-ios` panel then reported the LIVE `:8000` gateway as `gateway_down`
and blocked iOS pairing on every fresh install. The upstream fix (already
committed, just never re-vendored) reads `OSTLER_CHAT_GATEWAY_PORT` first
-- the single canonical lever install.sh writes into the Doctor plist
(`OSTLER_CHAT_GATEWAY_PORT=8000`, in lockstep with the pinned `[gateway]
port = 8000`) and the same var `chat_token._zeroclaw_port()` reads. Now
byte-identical to source; no other file touched.

Files deliberately NOT overwritten -- these are **ahead of HR015**
(CM051-local, not yet upstreamed); future syncs must **graft**, never
blind-copy, preserving the local work until it lands upstream:

- `duplicate_decision.py` + `test_duplicate_decision_split.py`
  (CM051 PR #302's `split` action). A blind whole-directory `rm -rf` +
  copy (the generic recipe below) would have regressed #302.
- `web_ui.py` carries CM051 PR #401's governor **settings button**
  (`<a id="settingsBtn" href="/config">` + its `DASHBOARD_BTN_SETTINGS`
  copy imports + `.refresh-btn` `text-decoration`). HR015's Doctor has
  no governor, so this button exists **only** in the vendored copy. A
  straight copy of HR015 `web_ui.py` deletes it.
- `diagnostic_rules.py` + `diagnostic_copy.py` carry CM051 PR #469's
  **`check_last_upgrade`** (B-lite) upgrade audit-trail row (reads
  `preferences.json.last_upgrade_result`) and its `LAST_UPGRADE_*` copy
  catalogue. HR015 has no upgrade matrix, so this rule exists **only**
  in the vendored copy (pickaxe `--all` across HR015 finds it nowhere).
  A straight copy of HR015 deletes the rule + copy.

  **Both #401 and #469 were hand-added directly to the vendored copy
  (they skipped the upstream-first rule).** They should be upstreamed to
  HR015 `doctor/agent/` so a future sync is a clean copy; until then,
  graft. The three files above are therefore now "graft, don't copy",
  same as `duplicate_decision.py`.

Surgical graft (BW4 Part A, v1.0.10 security lockdown): `proxy.py` carries
the Doctor -> ical-server auth-boundary fix -- validate the client bearer
against the ZeroClaw gateway `[gateway].paired_tokens` store, then
substitute `PWG_SERVICE_TOKEN` on the `/api/v1/*` forwards (fixes the
ical-server 401 storm). Landed upstream in HR015 `doctor/agent/proxy.py`
first; this vendored `proxy.py` matches that source byte-for-byte, so the
next HR015 sync is a no-op for this file. Do NOT revert it in a re-sync.

### 2026-07-30 sync (v1.0.13) -- `web_ui.py`, `diagnostic_rules.py`, `diagnostic_copy.py` @ `eb5c8a9`

A **partial, grafted** re-sync of three files to HR015 origin/main
`eb5c8a9` (PR #273), catching up ~6 weeks of drift since the last full
directory sync (`1bb0a0d`). It carries two upstream changes:

- **#178** (`web_ui.py`): a new unauthenticated `GET
  /api/v1/hydration/status` passthrough so the wiki's first-run
  "still settling" panel can poll hydration status without a paired
  bearer (the proxy would otherwise 401 it). Non-PII payload; honest 502
  on upstream failure so the panel stays up rather than false-clearing.
- **#172** (`diagnostic_rules.py` + `diagnostic_copy.py`): a new
  `check_imessage_capture_stalled` Doctor card that fires when the
  iMessage capture bundle is crash-looping on SQLite pre-FDA (reads the
  tail of `~/.ostler/logs/imessage-bundle.err`; degrades to quiet on a
  fresh box with no log). Plus a one-line `CRITICAL_DISK_FIX` copy
  cosmetic.

This was a **graft, not a straight copy**: a blind copy would have
regressed CM051-local `#401` (`web_ui.py` settings button) and `#469`
(`check_last_upgrade` in both diagnostic files) -- see the
do-not-overwrite list above. The graft added only #178/#172/cosmetic and
left #401/#469 byte-for-byte. Verified: graft-vs-`eb5c8a9` diff is
exactly the #401/#469 hunks (nothing upstream missed); 18/18 vendored
doctor tests pass under python3.11; both `check_last_upgrade` and
`check_imessage_capture_stalled` are wired in `ALL_RULES` and quiet on a
fresh box.

A vendor-freshness guard, `vendor/doctor/test_vendor_pairing.sh`, fails
the build if a future re-sync drops the `/pair-ios` route, `pair_status.py`,
or leaves a `web_ui.py` import without its vendored module.

## What is NOT included

- `test_*.py` (10 files, CI-only) - never installed on a customer Mac.
- `__pycache__/`, `.pytest_cache/` - build artefacts.

## Test-only environment flags

`OSTLER_TEST_DISABLE_HEALTH=1` forces `GET /doctor/api/health` to return
503 instead of its normal 200 healthy body. It exists only for the
(B-lite) upgrade-matrix Row 6 rollback test (install.sh exits 0 but the
health route will not answer, so the Hub's 60s health poll times out and
C1 rolls back). Any other value (or the variable being unset) is a
complete no-op, so the route behaves exactly as before. Never set it in
production.

## How to sync

Until `make vendor-sync` lands (post-launch chore), syncing is manual:

```bash
SRC="$HOME/Documents/Projects/HR015 - Gaming PC/doctor/agent"
DST="$(git rev-parse --show-toplevel)/vendor/doctor/agent"

rm -rf "$DST"
mkdir -p "$DST"
for f in "$SRC"/*.py "$SRC"/*.css "$SRC"/*.txt "$SRC"/.env.example; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  case "$base" in
    test_*) continue ;;
  esac
  cp "$f" "$DST/"
done
```

Open a PR titled `chore(vendor): sync doctor agent from HR015 @ <sha>`
and link the upstream commit.

## Rule

HR015 is the upstream source of truth. Bug fixes go upstream first
(in `HR015 - Gaming PC/doctor/agent/`), then flow into this vendored
copy via a sync PR. Never edit `vendor/doctor/agent/` in place to fix
a bug - the next sync wipes it.
