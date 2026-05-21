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
- `diagnostic_rules.py`, `status_collector.py` (the diagnostic engine)
- `first_run.py` (first-launch wizard panels)
- `import_evernote.py`, `import_evernote_runner.py` (Evernote ingest UI
  + runner; gated by user action, safe to ship dormant)
- `proxy.py`, `wiki_correct.py` (wiki proxy + corrector)
- `web_ui.py` (FastAPI entry point: `/doctor`, `/pair-ios`, panels)
- `requirements.txt` (`fastapi`, `uvicorn`, `httpx`, `pyyaml`)

## What is NOT included

- `test_*.py` (10 files, CI-only) - never installed on a customer Mac.
- `__pycache__/`, `.pytest_cache/` - build artefacts.

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
