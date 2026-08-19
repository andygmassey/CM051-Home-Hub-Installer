# Doctor governor re-vendor recipe (HR015 #282)

**Status:** staged for ORM cut-time execution. `#282` has since MERGED (`6639c79`), but the re-vendor below is **still not done** and the pin is still `b0b3831`.
**Guard:** `scripts/verify_doctor_governor_revendor.sh` (run AFTER re-vendor; fails loud if the vendor-only bridge was dropped).

> **2026-08-14 -- half of `#282` was grafted ahead of this recipe (v1018-D024).** The
> customer-facing half could not wait for the re-vendor: the Hub sidebar renders
> Governor with `show: true`, its Pause button calls `GET /api/v1/governor-status`,
> `GET`+`POST /api/v1/pause` and `POST /api/v1/resume`, and the shipped Doctor payload
> registered **none** of them, so every install answered `404` and the UI said
> "Could not pause".
>
> **What is now in `vendor/doctor/agent`:** `pause_control.py` byte-identical to
> `6639c79`, plus the four route handlers appended verbatim to `web_ui.py` before
> `register_proxy_routes(app)`. Both are carried by `doctor.patch` (a `/dev/null`
> new-file hunk and a regenerated `web_ui.py` section), and `source@b0b3831` +
> `doctor.patch` still reconstructs all 30 examined vendored files byte-identical.
>
> **What is still owed to this recipe:** `#282`'s `config_panel.py` rework
> (`build_env_map` / `sync_env_file`, the compose `.env` bridge). That is the one
> remaining `FAIL` in the guard and it is deliberate, not an oversight.
>
> **Why a graft and not the re-pin.** Measured, not assumed: `doctor.patch` applies to
> `source@b0b3831` with `rc=0` and fails on **9 of 11 files** against `source@origin/main`
> (`config_panel`, `diagnostic_copy`, `diagnostic_rules`, `import_evernote`,
> `import_evernote_runner`, `proxy`, `requirements`, `web_ui_copy`, `web_ui`). The
> re-pin is a reconciliation project across the customer copy catalogue and the
> bearer-oracle proxy, and it would additionally assert `51957f4` (Pro vault writer
> SPA + LOCK-3 schema, 1,817 lines of v1.1 Pro-tier surface) into a v1.0 DMG.
>
> **When you do run the recipe:** step 3 must now also drop the `pause_control.py`
> new-file hunk and the governor-route hunks from `doctor.patch`, because both go
> native at the new pin. `tests/test_doctor_governor_routes_vendored.sh` is
> pin-agnostic -- it asserts the routes are in the shipped payload however they got
> there, so it stays valid across the re-pin and will catch a half-applied one.

## Why the doctor re-vendor is NOT a plain drop-in

`vendor/doctor` already carries a **governor graft** (see the `[doctor]` `note` in `vendor/VENDOR_MANIFEST.toml`). HR015 `#282` is the *upstream native* version of that same governor. They diverge:

| file | CM051 vendored (ships today) | HR015 #282 (upstream) | re-vendor action |
|---|---|---|---|
| `config_panel.py` | `render_governor_env` + `_write_governor_env` → `governor.env`; imports `daemon_cron` | governor.env writer **+** new `build_env_map`/`sync_env_file` (compose `.env` bridge) | adopt #282. **Assert** `_write_governor_env` + `from daemon_cron import` survive |
| `pause_control.py` | **ABSENT** | **NEW** pause state machine (governor.env: `OSTLER_PAUSED`/`OSTLER_PAUSE_UNTIL`) | adopt native from #282 |
| `daemon_cron.py` | **PRESENT (~319 L, VENDOR-ONLY)** — `apply_pause_to_cron` + `launchctl kickstart` | **ABSENT** | **PRESERVE** as vendor-only new-file hunk in `doctor.patch` |
| `web_ui.py` | CM051 grafts (proxy #258, iMessage-FDA, governor routes) | #178 hydration union + governor routes | reconcile — union both graft sets; keep CM051's proxy + iMessage-FDA grafts |

## The trap (verified 2026-08-02)

- `config_panel.py:481` → `from daemon_cron import DaemonCronError, apply_pause_to_cron`. `daemon_cron.py` is **vendor-only** (not in HR015 source). Without it the Doctor Settings Pause toggle raises `ModuleNotFoundError` → **HTTP 500**, while `governor.env` is already written `paused` (ticks look paused but the 09:00 brief / 18:00 wrap still fire — a ships-dark pause).
- `daemon_cron.py` + `test_daemon_cron.py` live in `vendor/divergences/doctor.patch` as **hand-authored `/dev/null` new-file hunks**.
- **`sync_vendor.sh doctor --regen-patch` STRIPS vendor-only new-file hunks** (`gen_patch`/`vlib_shared_diff` only capture files in BOTH trees). Verified behaviour, documented in the manifest note.

## Recipe

1. **After #282 merges**, set `[doctor]` `pinned_sha` in `vendor/VENDOR_MANIFEST.toml` to HR015 `main`'s new tip. Drop `#282`'s SHA (and the superseded governor SHAs) from `hold_ack_shas` if present.
2. `scripts/sync_vendor.sh doctor` **(apply mode — NO `--regen-patch`)** → pulls native `pause_control.py`, `test_pause_control.py`, `test_governor_routes.py`, `test_config_env_bridge.py`, and the reconciled `config_panel.py`/`web_ui.py` from `source@newpin`, then `git apply`s `doctor.patch`.
3. Hand-edit `doctor.patch`: **drop** the governor graft hunks that went NATIVE at #282 (config-env-bridge, pause routes, config_panel governor rework). **KEEP** the `daemon_cron.py` + `test_daemon_cron.py` new-file hunks + the `config_panel.py` `from daemon_cron import` hunk + surviving CM051-local deploy grafts (proxy, iMessage-FDA, README). **Never `--regen-patch`** without hand-re-adding the two `daemon_cron` new-file hunks after.
4. `VENDOR_FRESH_STRICT=1 scripts/verify_vendor_fresh.sh` → doctor reconciles at the new pin (only vendor-only + accepted-RED lines remain).
5. **`scripts/verify_doctor_governor_revendor.sh`** → asserts the vendor-only bridge + native pieces are all present. Fails the cut if `daemon_cron.py` was dropped.

## Launch-criticality

The governor **already ships** via the vendored graft. `#282` upstreams it + adds `pause_control.py`, closing the divergence. If the cut is time-pressed the existing vendored governor is a valid fallback — but `#282` must be **all-or-nothing** (no half-apply, or you get a divergent twin). Recommended: land `#282` + this recipe in v1.0.14.

_Authored by TNM, 2026-08-02, from a live diff of CM051 `origin/main` vendored doctor vs HR015 `#282`._
