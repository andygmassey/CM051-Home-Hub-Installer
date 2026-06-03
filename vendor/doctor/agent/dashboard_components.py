"""
Ostler Doctor – Reusable dashboard HTML components.

Extracted from web_ui.py for cleaner code and reusability.
Each function returns an HTML string.
"""

from __future__ import annotations

from status_collector import SystemSnapshot, is_ostler_container

# Security posture is read via ostler_security.posture, but Doctor must
# stay runnable even when ostler_security has not been pip-installed
# yet (e.g. very early in install.sh, or in CI with a minimal venv).
# Doctor's job is to surface "this is broken" – it cannot itself
# refuse to render because the package it would diagnose is absent.
#
# This is the only place in the codebase where a soft fall-through
# for ostler_security is permitted. Every other entry point must
# hard-fail per the silent-fallback rule (HR015
# ENCRYPTION_FALLBACK_RUNTIME_GAP_2026-04-28.md). The pre-commit
# guard at .githooks/check_security_imports.py respects the noqa
# marker on the except-line below.
try:
    from ostler_security.posture import all_postures
    _HAS_POSTURE = True
except ImportError:  # noqa: SECURITY-IMPORT-SOFT-ALLOWED
    _HAS_POSTURE = False
    def all_postures() -> dict:  # type: ignore[no-redef]
        return {}

# Observability-posture markers (per-tick health for hourly
# LaunchAgents like email-ingest, wiki-recompile) follow the same
# soft fall-through rule. Doctor's job is to surface "this is
# broken"; it cannot refuse to render because the module it would
# diagnose is absent.
try:
    from ostler_security.observability_posture import (  # noqa: SECURITY-IMPORT-SOFT-ALLOWED
        all_observability_postures,
    )
    _HAS_OBSERVABILITY_POSTURE = True
except ImportError:  # noqa: SECURITY-IMPORT-SOFT-ALLOWED
    _HAS_OBSERVABILITY_POSTURE = False
    def all_observability_postures() -> dict:  # type: ignore[no-redef]
        return {}

# iMessage TCC posture marker (task #278). Sibling of the
# observability-posture readers but lives inside the doctor agent
# rather than ostler_security because the marker is written by
# CM051 install.sh, not by an Ostler service. No soft fall-through
# needed: the reader module is part of the doctor package itself
# and is always importable.
from imessage_tcc_posture import read_imessage_tcc_posture

# A7+A8: consent registry. Same soft-fall-through rule as posture –
# Doctor must keep rendering even when ostler_security is missing.
# The wording-hash check is best-effort: if the legal package is
# absent we cannot detect drift but we can still surface the records.
try:
    from ostler_security.consent import all_consents  # noqa: SECURITY-IMPORT-SOFT-ALLOWED
    _HAS_CONSENT = True
except ImportError:  # noqa: SECURITY-IMPORT-SOFT-ALLOWED
    _HAS_CONSENT = False
    def all_consents() -> dict:  # type: ignore[no-redef]
        return {}

try:
    from legal import (  # noqa: SECURITY-IMPORT-SOFT-ALLOWED
        ARTICLE_9_EU_CONSENT,
        EU_VOICE_SPEAKER_ID_CONSENT,
        THIRD_PARTY_DATA_NOTICE,
        WHATSAPP_UNOFFICIAL_RISK_CONSENT,
    )
    # tickbox_id -> ConsentString. Drives the bundled-hash check.
    _BUNDLED_CONSENTS = {
        ARTICLE_9_EU_CONSENT.tickbox_id: ARTICLE_9_EU_CONSENT,
        WHATSAPP_UNOFFICIAL_RISK_CONSENT.tickbox_id: WHATSAPP_UNOFFICIAL_RISK_CONSENT,
        EU_VOICE_SPEAKER_ID_CONSENT.tickbox_id: EU_VOICE_SPEAKER_ID_CONSENT,
        THIRD_PARTY_DATA_NOTICE.tickbox_id: THIRD_PARTY_DATA_NOTICE,
    }
except ImportError:  # noqa: SECURITY-IMPORT-SOFT-ALLOWED
    _BUNDLED_CONSENTS = {}


def _any_ostler_container_running(snapshot: SystemSnapshot) -> bool:
    return any(
        is_ostler_container(c) and c.state == "running"
        for c in snapshot.docker_containers
    )


def render_system_overview(snapshot: SystemSnapshot) -> str:
    """Render a compact system overview card showing overall status."""
    # Count statuses
    total_services = len(snapshot.services)
    healthy = sum(1 for s in snapshot.services if s.status == "healthy")
    containers_running = sum(1 for c in snapshot.docker_containers if c.state == "running")
    total_containers = len(snapshot.docker_containers)
    model_count = len(snapshot.ollama_models)

    # Overall status
    if healthy == total_services and total_services > 0:
        overall = "healthy"
        overall_text = "All systems operational"
        overall_color = "#5cb579"
    elif healthy > 0:
        overall = "degraded"
        overall_text = f"{healthy}/{total_services} services healthy"
        overall_color = "#d4a052"
    else:
        overall = "down"
        overall_text = "Services not responding"
        overall_color = "#d96666"

    # Disk summary
    disk_text = ""
    if snapshot.disk_usage:
        root = next((d for d in snapshot.disk_usage if d.mount_point == "/"), snapshot.disk_usage[0])
        disk_text = f"{root.free_gb:.0f} GB free"

    return f"""
    <div style="background:var(--bg-card);border:1px solid var(--border);border-radius:12px;padding:20px 24px;margin-bottom:24px;display:flex;align-items:center;gap:20px;flex-wrap:wrap;">
        <div style="display:flex;align-items:center;gap:10px;">
            <div style="width:12px;height:12px;border-radius:50%;background:{overall_color};box-shadow:0 0 8px {overall_color}40;"></div>
            <div style="font-weight:600;font-size:0.95rem;">{overall_text}</div>
        </div>
        <div style="display:flex;gap:24px;font-size:0.82rem;color:var(--text-muted);">
            <span>{containers_running}/{total_containers} containers</span>
            <span>{model_count} model{'s' if model_count != 1 else ''}</span>
            <span>{disk_text}</span>
            <span>{snapshot.hostname or 'unknown'}</span>
        </div>
    </div>"""


def render_quick_actions(snapshot: SystemSnapshot) -> str:
    """Render quick action buttons for common tasks."""
    actions = []

    # Start services if not running
    ostler_running = _any_ostler_container_running(snapshot)
    if not ostler_running and snapshot.docker_version:
        actions.append({
            "label": "Start services",
            "command": "cd ~/.ostler && docker compose up -d",
            "icon": "&#9654;",
        })

    # Pull embed model if missing
    has_embed = any("nomic-embed" in m.name for m in snapshot.ollama_models)
    if snapshot.ollama_version and not has_embed:
        actions.append({
            "label": "Pull embedding model",
            "command": "ollama pull nomic-embed-text",
            "icon": "&#11015;",
        })

    # Restart all if some are unhealthy
    unhealthy = [s for s in snapshot.services if s.status == "unhealthy"]
    if unhealthy and ostler_running:
        actions.append({
            "label": "Restart services",
            "command": "cd ~/.ostler && docker compose restart",
            "icon": "&#8634;",
        })

    if not actions:
        return ""

    buttons = ""
    for a in actions:
        buttons += f"""
        <button onclick="navigator.clipboard.writeText('{a['command']}').then(()=>this.style.borderColor='#5cb579')"
                style="display:inline-flex;align-items:center;gap:6px;padding:8px 14px;background:var(--bg-card);border:1px solid var(--border);border-radius:6px;color:var(--text-secondary);font-size:0.82rem;cursor:pointer;font-family:inherit;transition:border-color 0.2s;"
                title="Click to copy: {a['command']}">
            <span>{a['icon']}</span> {a['label']}
        </button>"""

    return f"""
    <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:24px;">
        {buttons}
    </div>"""


def render_security_posture() -> str:
    """Render the security-posture section as one tile per service.

    Reads ~/.ostler/security-posture/<service>.json markers written by
    each long-running service at boot. Empty section if no markers
    exist (e.g. fresh install before any service has booted, or
    ostler_security itself not installed).

    Colour rules:
      - encryption=enabled     -> green
      - encryption=disabled    -> red (this is the bug we surface)
      - marker absent          -> not rendered
    """
    postures = all_postures()
    if not postures:
        return ""

    tiles = ""
    for service in sorted(postures.keys()):
        p = postures[service]
        encryption = p.get("encryption", "unknown")
        if encryption == "enabled":
            colour = "#5cb579"
            icon = "&#10003;"
            detail = f"{p.get('backend', 'sqlcipher')} via {p.get('key_source', 'OSTLER_DB_KEY')}"
        elif encryption == "disabled":
            colour = "#d96666"
            icon = "&#9888;"
            reason = p.get("reason") or "unknown"
            detail = f"plaintext &ndash; reason: {reason}"
        else:
            colour = "rgba(236,232,221,0.40)"
            icon = "?"
            detail = encryption
        tiles += f"""
        <div class="status-card">
            <div class="status-indicator" style="background:{colour}">{icon}</div>
            <div class="status-info">
                <div class="status-name">{service}</div>
                <div class="status-detail">{detail}</div>
            </div>
        </div>"""

    return f"""
    <div class="section" id="securityPostureSection">
        <div class="section-title">Security Posture (per service)</div>
        <div class="status-grid">{tiles}</div>
    </div>"""


# ── Observability posture (per-tick LaunchAgent health) ─────────

# Default expected-tick interval per service, in seconds. Used by
# the stale-detection check: a marker older than 2x this value is
# treated as "service has gone silent" even if the last reported
# status was success. Operators with non-default cadences can
# extend this map without touching call sites.
#
# email-ingest ticks hourly per
# email-ingest/launchd/com.creativemachines.ostler.email-ingest.plist
# (StartInterval=3600). Other services default to 3600s; specific
# overrides land here as new LaunchAgents come online.
DEFAULT_TICK_INTERVAL_SECONDS = 3600
EXPECTED_TICK_INTERVAL_SECONDS: dict[str, int] = {
    "email-ingest": 3600,
}

# Multiplier applied to the expected interval before flagging stale.
# 2x means "the LaunchAgent missed at least one full tick window".
# Less than 2x produces false positives on the boundary tick (a
# marker written at T-1h, viewed at T-1h-and-a-bit). More than 2x
# delays the alert too long.
STALE_INTERVAL_MULTIPLIER = 2


def _format_relative_time(ts_iso: str | None, now_dt=None) -> str:
    """Format an ISO-8601 timestamp as a short human-readable
    relative span ("3 minutes ago", "2 hours ago"). Falls back to
    "unknown" when the input is missing or unparseable -- never
    raises, because Doctor must keep rendering.
    """
    if not ts_iso:
        return "unknown"
    try:
        from datetime import datetime, timezone
        ts = datetime.fromisoformat(ts_iso)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        now = now_dt or datetime.now(tz=timezone.utc)
        delta = now - ts
        seconds = int(delta.total_seconds())
    except (TypeError, ValueError):
        return "unknown"
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    if seconds < 86400:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"


def _is_stale(marker: dict, now_dt=None) -> bool:
    """Return True when the marker's last_tick_at is more than
    STALE_INTERVAL_MULTIPLIER * expected interval old. A missing
    or unparseable timestamp is also treated as stale -- a marker
    we can't date is one we can't trust.
    """
    service = marker.get("service") or ""
    expected = EXPECTED_TICK_INTERVAL_SECONDS.get(
        service, DEFAULT_TICK_INTERVAL_SECONDS,
    )
    threshold = expected * STALE_INTERVAL_MULTIPLIER
    ts_iso = marker.get("last_tick_at")
    if not ts_iso:
        return True
    try:
        from datetime import datetime, timezone
        ts = datetime.fromisoformat(ts_iso)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        now = now_dt or datetime.now(tz=timezone.utc)
        return (now - ts).total_seconds() > threshold
    except (TypeError, ValueError):
        return True


# Status colour map. Stale takes precedence over the reported
# status so a service that died after one happy tick is rendered
# grey rather than green; a silent death is more dangerous than a
# loud failure.
_STATUS_COLOURS = {
    "success": "#5cb579",
    "fda_denied": "#d96666",
    "extract_failed": "#d96666",
    "mailbox_unreadable": "#d96666",
    "other": "#d4a052",
    "stale": "rgba(236,232,221,0.40)",
    "unknown": "rgba(236,232,221,0.40)",
}
_STATUS_ICONS = {
    "success": "&#10003;",
    "fda_denied": "&#9888;",
    "extract_failed": "&#9888;",
    "mailbox_unreadable": "&#9888;",
    "other": "&#9888;",
    "stale": "?",
    "unknown": "?",
}


def _service_specific_detail(marker: dict) -> str:
    """Render the service-specific metric line for a marker.

    Today only email-ingest has bespoke fields; other services
    fall back to a generic "no metrics reported" line. Future
    services that emit observability markers can add a branch
    here without touching the call site.

    Every interpolated value is HTML-escaped via
    `_html_escape()`. The marker is on-disk JSON written by the
    LaunchAgent at tick time; an attacker with write access to
    the marker dir could inject a `<script>` payload into
    `oldest_processed` or any other field. The literal HTML
    entities in the f-strings (`&middot;`, `&rarr;`) are
    template content and stay un-escaped; only the user-derived
    values are escaped.
    """
    service = marker.get("service") or ""
    if service == "email-ingest":
        count = _html_escape(str(marker.get("mail_count_processed_this_tick", 0)))
        oldest = marker.get("oldest_processed")
        newest = marker.get("newest_processed")
        bits = [f"{count} mail this tick"]
        if oldest and newest:
            oldest_safe = _html_escape(str(oldest)[:10])
            newest_safe = _html_escape(str(newest)[:10])
            bits.append(f"backfill {oldest_safe} &rarr; {newest_safe}")
        elif newest:
            newest_safe = _html_escape(str(newest)[:10])
            bits.append(f"newest {newest_safe}")
        return " &middot; ".join(bits)
    return "no service-specific metrics reported"


def render_observability_posture(now_dt=None) -> str:
    """Render the observability-posture section.

    Reads ~/.ostler/observability-posture/<service>.json markers
    written by each LaunchAgent on every tick (success or
    failure). Empty section when no markers exist.

    Status colour:
      - stale (>2x expected interval since last_tick_at) -> grey,
        flagged ahead of any other status because silent death is
        worse than visible failure.
      - last_tick_status=success                 -> green
      - last_tick_status=fda_denied              -> red
      - last_tick_status=extract_failed          -> red
      - last_tick_status=mailbox_unreadable      -> red
      - last_tick_status=other                   -> amber
      - last_tick_status absent / unrecognised   -> grey
    """
    postures = all_observability_postures()
    if not postures:
        return ""

    tiles = ""
    for service in sorted(postures.keys()):
        marker = postures[service]
        if _is_stale(marker, now_dt=now_dt):
            status = "stale"
        else:
            status = marker.get("last_tick_status") or "unknown"
        colour = _STATUS_COLOURS.get(status, _STATUS_COLOURS["unknown"])
        icon = _STATUS_ICONS.get(status, _STATUS_ICONS["unknown"])
        last_tick_at = marker.get("last_tick_at")
        relative = _format_relative_time(last_tick_at, now_dt=now_dt)
        detail = _service_specific_detail(marker)
        error_msg = (marker.get("last_error_message") or "").strip()
        error_line = ""
        if error_msg and status != "success":
            # Truncate display copy too -- the full message is
            # already capped at 1 KiB in the marker writer, but
            # the dashboard tile would still wrap awkwardly on a
            # 1 KiB string.
            short = error_msg if len(error_msg) <= 200 else error_msg[:197] + "..."
            error_line = (
                f'<div class="status-detail" style="color:#ef4444">'
                f'{_html_escape(short)}</div>'
            )
        # Click-through expand: full marker JSON wrapped in a
        # <details> block. No JS framework; plain HTML.
        import json as _json
        full_json = _html_escape(_json.dumps(marker, indent=2, sort_keys=True))
        stale_badge = ""
        if status == "stale":
            # Stale badge: muted-cream background, contrasts against
            # the warm panel without competing with the oxblood accent.
            stale_badge = (
                '<span style="background:rgba(236,232,221,0.16);'
                'color:rgba(236,232,221,0.90);'
                'padding:2px 8px;border-radius:999px;font-size:10px;'
                'font-family:Outfit,system-ui,sans-serif;font-weight:500;'
                'letter-spacing:0.16em;text-transform:uppercase;'
                'margin-left:8px">STALE</span>'
            )
        tiles += f"""
        <div class="status-card">
            <div class="status-indicator" style="background:{colour}">{icon}</div>
            <div class="status-info">
                <div class="status-name">{_html_escape(service)}{stale_badge}</div>
                <div class="status-detail">{status} &middot; {relative}</div>
                <div class="status-detail">{detail}</div>
                {error_line}
                <details style="margin-top:8px">
                    <summary style="cursor:pointer;font-size:12px;color:rgba(236,232,221,0.50);font-family:'IBM Plex Mono','SF Mono',Menlo,monospace;letter-spacing:0.04em">
                        Full marker JSON
                    </summary>
                    <pre style="font-size:11px;background:#07060a;color:rgba(236,232,221,0.74);font-family:'IBM Plex Mono','SF Mono',Menlo,monospace;padding:10px;border-radius:6px;border:1px solid rgba(236,232,221,0.08);overflow:auto;margin-top:6px">{full_json}</pre>
                </details>
            </div>
        </div>"""

    return f"""
    <div class="section" id="observabilityPostureSection">
        <div class="section-title">Observability Posture (per-tick LaunchAgent health)</div>
        <div class="status-grid">{tiles}</div>
    </div>"""


def _html_escape(s: str) -> str:
    """Minimal HTML escape for tile rendering. Matches what the
    rest of dashboard_components.py does inline -- pulled out into
    a helper here because the observability tile interpolates
    error messages and JSON which must not break layout when they
    contain `<` or `&`.
    """
    return (
        s.replace("&", "&amp;")
         .replace("<", "&lt;")
         .replace(">", "&gt;")
         .replace('"', "&quot;")
    )


# ── Consent tile (A7+A8 region-aware consent registry) ─────────────


def render_consent_status() -> str:
    """Render the Consent tile.

    Reads ``~/.ostler/posture/consent.json`` records, compares each
    against the bundled wording hash from ``legal/consent_strings.py``,
    and surfaces:

    - **Green** when every present record is current and accepted.
    - **Amber** on a wording-hash drift (renewal needed).
    - **Red** on a missing required record (gate failed; bridge
      blocked).
    - Empty string when no records have been written yet (fresh
      install pre-consent screen) so the dashboard does not render an
      empty section.

    The tile only surfaces records the registry actually contains.
    A missing ``voice_speaker_id_eu`` record is fine for a US/UK
    user; the bridges decide whether they need it. Doctor's job is
    to surface drift, not to enforce policy.
    """
    if not _HAS_CONSENT:
        return ""

    records = all_consents()
    if not records:
        return ""

    tiles = ""
    for tickbox_id in sorted(records.keys()):
        rec = records[tickbox_id]
        decision = rec.get("decision") or "unknown"
        wording_version = rec.get("wording_version") or "unknown"
        region = rec.get("region_at_capture") or "unknown"
        timestamp = rec.get("timestamp")
        relative = _format_relative_time(timestamp)

        bundled = _BUNDLED_CONSENTS.get(tickbox_id)
        if decision == "declined":
            colour = "#d96666"
            icon = "&#9888;"
            state = "declined"
        elif bundled is None:
            # Record exists but the bundled wording doesn't (legal
            # package missing or unknown tickbox). We can show the
            # decision but not check drift.
            colour = "rgba(236,232,221,0.40)"
            icon = "?"
            state = "unknown wording"
        elif rec.get("wording_hash") != bundled.sha256():
            colour = "#d4a052"
            icon = "&#9888;"
            state = f"renewal needed ({wording_version} -> {bundled.version})"
        else:
            colour = "#5cb579"
            icon = "&#10003;"
            state = f"current ({wording_version})"

        scope = rec.get("scope")
        scope_line = (
            f'<div class="status-detail">scope: {_html_escape(scope)}</div>'
            if scope else ""
        )

        tiles += f"""
        <div class="status-card">
            <div class="status-indicator" style="background:{colour}">{icon}</div>
            <div class="status-info">
                <div class="status-name">{_html_escape(tickbox_id)}</div>
                <div class="status-detail">{_html_escape(state)} &middot; region: {_html_escape(region)} &middot; {relative}</div>
                {scope_line}
            </div>
        </div>"""

    return f"""
    <div class="section" id="consentSection">
        <div class="section-title">Consent (A7+A8 records)</div>
        <div class="status-grid">{tiles}</div>
    </div>"""


# ── iMessage TCC posture tile (task #278) ─────────────────────────


# Colour map for the four states emitted by CM051 install.sh.
# ``granted-and-working`` is green; the two failure states are
# coloured by severity (``tcc-denied`` = amber warning because the
# customer can fix it themselves via System Settings;
# ``check-failed`` = red error because the snapshot itself is
# untrustworthy and the customer has no clear remediation).
# ``unknown`` matches the other tiles' grey fallback for an
# unrecognised status field.
_IMESSAGE_TCC_COLOURS = {
    "granted-and-working": "#5cb579",
    "tcc-denied": "#d4a052",
    "check-failed": "#d96666",
    "unknown": "rgba(236,232,221,0.40)",
}
_IMESSAGE_TCC_ICONS = {
    "granted-and-working": "&#10003;",
    "tcc-denied": "&#9888;",
    "check-failed": "&#9888;",
    "unknown": "?",
}


def render_imessage_tcc_posture(now_dt=None) -> str:
    """Render the iMessage TCC posture tile.

    Reads ``~/.ostler/imessage-posture/state.md`` written by CM051
    install.sh section 3.18. Returns:

    - Empty string when the marker is absent (e.g. fresh install
      before install.sh has run, or an install with the iMessage
      channel not enabled). Doctor falls through to no section
      rather than rendering an empty header.
    - A single status card otherwise. Colour is status-dependent
      (green / amber / red / grey) and the body carries the
      detail copy plus a click-through ``<details>`` block with
      remediation guidance and the full marker text.

    The render is server-side static HTML; no JS needed for the
    expand-collapse (it uses the native ``<details>`` element).
    """
    # Imports kept function-scoped to mirror the rest of the
    # dashboard renderers and to avoid importing the catalogue at
    # module-load time (which would break the no-catalogue
    # fallback test surface).
    from web_ui_copy import (
        IMESSAGE_TCC_CAPTURED_AT_PREFIX_FMT,
        IMESSAGE_TCC_DETAIL_CHECK_FAILED,
        IMESSAGE_TCC_DETAIL_DENIED,
        IMESSAGE_TCC_DETAIL_GRANTED,
        IMESSAGE_TCC_DETAIL_UNKNOWN,
        IMESSAGE_TCC_FULL_MARKER_LABEL,
        IMESSAGE_TCC_HOW_TO_FIX_LABEL,
        IMESSAGE_TCC_REMEDIATION_CHECK_FAILED,
        IMESSAGE_TCC_REMEDIATION_DENIED,
        IMESSAGE_TCC_SECTION_TITLE,
        IMESSAGE_TCC_SOURCE_PREFIX_FMT,
        IMESSAGE_TCC_STATUS_CHECK_FAILED,
        IMESSAGE_TCC_STATUS_DENIED,
        IMESSAGE_TCC_STATUS_GRANTED,
        IMESSAGE_TCC_STATUS_UNKNOWN,
        IMESSAGE_TCC_STDERR_LABEL,
    )

    marker = read_imessage_tcc_posture()
    if marker is None:
        return ""

    status = marker.get("status", "unknown")
    if status not in _IMESSAGE_TCC_COLOURS:
        status = "unknown"
    colour = _IMESSAGE_TCC_COLOURS[status]
    icon = _IMESSAGE_TCC_ICONS[status]

    status_label_map = {
        "granted-and-working": IMESSAGE_TCC_STATUS_GRANTED,
        "tcc-denied": IMESSAGE_TCC_STATUS_DENIED,
        "check-failed": IMESSAGE_TCC_STATUS_CHECK_FAILED,
        "unknown": IMESSAGE_TCC_STATUS_UNKNOWN,
    }
    detail_map = {
        "granted-and-working": IMESSAGE_TCC_DETAIL_GRANTED,
        "tcc-denied": IMESSAGE_TCC_DETAIL_DENIED,
        "check-failed": IMESSAGE_TCC_DETAIL_CHECK_FAILED,
        "unknown": IMESSAGE_TCC_DETAIL_UNKNOWN,
    }
    remediation_map = {
        "tcc-denied": IMESSAGE_TCC_REMEDIATION_DENIED,
        "check-failed": IMESSAGE_TCC_REMEDIATION_CHECK_FAILED,
    }

    status_label = status_label_map[status]
    detail = detail_map[status]
    remediation = remediation_map.get(status)

    captured_at = marker.get("captured_at")
    captured_line = ""
    if captured_at:
        relative = _format_relative_time(captured_at, now_dt=now_dt)
        captured_line = (
            f'<div class="status-detail">'
            f'{IMESSAGE_TCC_CAPTURED_AT_PREFIX_FMT.format(relative=_html_escape(relative))}'
            f'</div>'
        )

    source = marker.get("source")
    source_line = ""
    if source:
        source_line = (
            f'<div class="status-detail">'
            f'{IMESSAGE_TCC_SOURCE_PREFIX_FMT.format(source=_html_escape(source))}'
            f'</div>'
        )

    # How-to-fix expandable. Only renders for non-granted statuses
    # (the customer does not need fix guidance for a working
    # state). The block carries:
    #   - the remediation copy from the catalogue (catalogue copy
    #     wins over marker copy so wording bumps land in i18n)
    #   - the in-marker remediation prose written by install.sh
    #     (which carries the exact System Settings path the user
    #     should follow on their specific macOS version, when
    #     install.sh has a fresh enough copy to include it)
    #   - the stderr fragment for check-failed status, when present
    how_to_fix = ""
    in_marker_remediation = marker.get("remediation")
    stderr_fragment = marker.get("stderr_fragment")
    if status != "granted-and-working":
        fix_bits = []
        if remediation:
            fix_bits.append(
                f'<div class="status-detail">{_html_escape(remediation)}</div>'
            )
        if in_marker_remediation:
            fix_bits.append(
                '<pre style="font-size:12px;background:#07060a;'
                'color:rgba(236,232,221,0.74);font-family:'
                '\'IBM Plex Mono\',\'SF Mono\',Menlo,monospace;padding:10px;'
                'border-radius:6px;border:1px solid rgba(236,232,221,0.08);'
                'overflow:auto;margin-top:6px;'
                f'white-space:pre-wrap">{_html_escape(in_marker_remediation)}</pre>'
            )
        if stderr_fragment:
            fix_bits.append(
                f'<div class="status-detail" style="margin-top:8px">'
                f'<strong>{_html_escape(IMESSAGE_TCC_STDERR_LABEL)}:</strong></div>'
                '<pre style="font-size:11px;background:#07060a;'
                'color:rgba(236,232,221,0.74);font-family:'
                '\'IBM Plex Mono\',\'SF Mono\',Menlo,monospace;padding:10px;'
                'border-radius:6px;border:1px solid rgba(236,232,221,0.08);'
                'overflow:auto;margin-top:6px;'
                f'white-space:pre-wrap">{_html_escape(stderr_fragment)}</pre>'
            )
        body = "".join(fix_bits)
        how_to_fix = f"""
                <details style="margin-top:8px">
                    <summary style="cursor:pointer;font-size:12px;color:rgba(236,232,221,0.50);font-family:'IBM Plex Mono','SF Mono',Menlo,monospace;letter-spacing:0.04em">
                        {_html_escape(IMESSAGE_TCC_HOW_TO_FIX_LABEL)}
                    </summary>
                    {body}
                </details>"""

    # Full marker click-through. Mirrors the observability tile's
    # bottom <details>; useful for support copy-paste.
    raw_text = marker.get("raw_text") or ""
    full_marker_block = ""
    if raw_text:
        full_marker_block = f"""
                <details style="margin-top:8px">
                    <summary style="cursor:pointer;font-size:12px;color:rgba(236,232,221,0.50);font-family:'IBM Plex Mono','SF Mono',Menlo,monospace;letter-spacing:0.04em">
                        {_html_escape(IMESSAGE_TCC_FULL_MARKER_LABEL)}
                    </summary>
                    <pre style="font-size:11px;background:#07060a;color:rgba(236,232,221,0.74);font-family:'IBM Plex Mono','SF Mono',Menlo,monospace;padding:10px;border-radius:6px;border:1px solid rgba(236,232,221,0.08);overflow:auto;margin-top:6px;white-space:pre-wrap">{_html_escape(raw_text)}</pre>
                </details>"""

    tile = f"""
        <div class="status-card">
            <div class="status-indicator" style="background:{colour}">{icon}</div>
            <div class="status-info">
                <div class="status-name">{_html_escape(status_label)}</div>
                <div class="status-detail">{_html_escape(detail)}</div>
                {captured_line}
                {source_line}
                {how_to_fix}
                {full_marker_block}
            </div>
        </div>"""

    return f"""
    <div class="section" id="imessageTccPostureSection">
        <div class="section-title">{_html_escape(IMESSAGE_TCC_SECTION_TITLE)}</div>
        <div class="status-grid">{tile}</div>
    </div>"""
