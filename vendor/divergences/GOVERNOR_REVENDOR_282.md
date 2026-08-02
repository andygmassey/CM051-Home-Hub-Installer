# Doctor governor re-vendor recipe (HR015 #282)

**Status:** staged for ORM cut-time execution. **DO NOT run until HR015 `#282` is MERGED to `main`.**
**Guard:** `scripts/verify_doctor_governor_revendor.sh` (run AFTER re-vendor; fails loud if the vendor-only bridge was dropped).

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
