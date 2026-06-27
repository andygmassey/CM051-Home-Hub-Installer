"""
Ostler Doctor – Local Diagnostic Dashboard

Serves a diagnostic dashboard at http://localhost:8089/doctor that
shows live system status, applies built-in diagnostic rules, and lets
the user send a diagnostic report to support via their email client.

Everything runs locally. No data is ever sent automatically.

Features:
- Auto-refresh via JavaScript (10s polling, toggle on/off)
- Built-in diagnostic rules (30+ rules, no cloud needed)
- "Send by Email" button – opens the user's mail client with the
  diagnostic report pre-populated as the body
- History of last 10 snapshots with change tracking
- Copy-to-clipboard on fix commands

Note for i18n: the word "Doctor" is the English label. Translate to
equivalent meaning in other locales (someone who diagnoses and helps
fix issues).
"""

from __future__ import annotations

import json
import os
import urllib.parse
from collections import deque
from dataclasses import asdict
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

from status_collector import (
    collect_full_snapshot,
    SystemSnapshot,
    detect_ostler_prefix,
    is_native_deployment,
    is_ostler_container,
    EXPECTED_OSTLER_SERVICES,
)
from diagnostic_rules import run_all_rules
from first_run import is_first_run, get_wizard_steps, render_wizard, mark_setup_complete
from dashboard_components import (
    all_observability_postures,
    render_consent_status,
    render_imessage_tcc_posture,
    render_observability_posture,
    render_security_posture,
)
from web_ui_copy import (
    ALL_HEALTHY_DETAIL,
    ALL_HEALTHY_TITLE,
    APP_TITLE,
    CONSOLE_RUNNING_FMT,
    CONTAINER_EXITED_DETAIL_FMT,
    CONTAINER_EXITED_FIX,
    CONTAINER_EXITED_FIX_COMMAND_FMT,
    CONTAINER_EXITED_TITLE_FMT,
    CONTAINER_NOT_RUNNING_DETAIL_FMT,
    CONTAINER_NOT_RUNNING_FIX,
    CONTAINER_NOT_RUNNING_FIX_COMMAND,
    CONTAINER_NOT_RUNNING_TITLE_FMT,
    DASHBOARD_ALERT_REPORT_ERROR_FMT,
    DASHBOARD_ALERT_REPORT_FAIL,
    DASHBOARD_BTN_AUTO_OFF,
    DASHBOARD_BTN_AUTO_ON,
    DASHBOARD_BTN_EMAIL,
    DASHBOARD_BTN_EMAIL_PREPARING,
    DASHBOARD_BTN_EMAIL_TITLE,
    DASHBOARD_BTN_REFRESH,
    DASHBOARD_FIX_LABEL_FMT,
    DASHBOARD_FIX_NOTE,
    DASHBOARD_HEADING,
    DASHBOARD_HELP_PARAGRAPH_1,
    DASHBOARD_HELP_PARAGRAPH_2,
    DASHBOARD_HOSTNAME_UNKNOWN,
    CONFIG_BTN_SAVE,
    CONFIG_BTN_SAVING,
    CONFIG_ERR_LOAD_PREFIX,
    CONFIG_ERR_SAVE_GENERIC,
    CONFIG_ERR_SAVE_PREFIX,
    CONFIG_HEADING,
    CONFIG_META_FOOTER,
    CONFIG_OPT_UNSET,
    CONFIG_READONLY_INTRO,
    CONFIG_SAVED,
    CONFIG_SECRET_SET,
    CONFIG_SECRET_UNSET,
    CONFIG_SECTION_READONLY,
    CONFIG_SUBTITLE,
    CONFIG_TITLE_TAG,
    DASHBOARD_CONFIG_LINK,
    DASHBOARD_IMPORT_EVERNOTE_LINK,
    DASHBOARD_PAIR_IOS_LINK,
    DASHBOARD_LAST_CHECKED_JUST_NOW,
    DASHBOARD_LAST_CHECKED_PREFIX,
    DASHBOARD_LAST_CHECKED_SUFFIX,
    DASHBOARD_META_DOCKER_NONE,
    DASHBOARD_META_FMT,
    DASHBOARD_META_OLLAMA_NONE,
    DASHBOARD_META_OS_UNKNOWN,
    DASHBOARD_NO_CONTAINERS,
    DASHBOARD_NO_MODELS,
    DASHBOARD_SECTION_CONTAINERS,
    DASHBOARD_SECTION_DISK,
    DASHBOARD_SECTION_FINDINGS,
    DASHBOARD_SECTION_HELP,
    DASHBOARD_SECTION_MODELS,
    DASHBOARD_SECTION_SERVICES,
    DASHBOARD_SUBTITLE_FMT,
    DASHBOARD_TITLE_TAG,
    DISK_GETTING_FULL_DETAIL_FMT,
    DISK_GETTING_FULL_TITLE_FMT,
    DISK_NEARLY_FULL_DETAIL_FMT,
    DISK_NEARLY_FULL_FIX,
    DISK_NEARLY_FULL_FIX_COMMAND,
    DISK_NEARLY_FULL_TITLE_FMT,
    DOCKER_NOT_RUNNING_DETAIL,
    DOCKER_NOT_RUNNING_FIX,
    DOCKER_NOT_RUNNING_FIX_COMMAND,
    DOCKER_NOT_RUNNING_TITLE,
    DOCKER_VERSION_OLD_DETAIL,
    DOCKER_VERSION_OLD_FIX,
    DOCKER_VERSION_OLD_FIX_COMMAND,
    DOCKER_VERSION_OLD_TITLE_FMT,
    EMBED_MODEL_MISSING_DETAIL,
    EMBED_MODEL_MISSING_FIX,
    EMBED_MODEL_MISSING_FIX_COMMAND,
    EMBED_MODEL_MISSING_TITLE,
    EVERNOTE_BTN_IMPORT_ANOTHER,
    EVERNOTE_BTN_START,
    EVERNOTE_BTN_STARTING,
    EVERNOTE_ERROR_JOB_NOT_FOUND,
    EVERNOTE_ERROR_NETWORK_PREFIX,
    EVERNOTE_ERROR_NO_PATH,
    EVERNOTE_ERROR_STATUS_FAIL_PREFIX,
    EVERNOTE_HEADING,
    EVERNOTE_HELP_TIP_HTML,
    EVERNOTE_INTRO_HTML,
    EVERNOTE_LABEL_PATH,
    EVERNOTE_META_FOOTER_HTML,
    EVERNOTE_PILL_STARTING,
    EVERNOTE_PLACEHOLDER_PATH,
    EVERNOTE_SECTION_LOG_TAIL,
    EVERNOTE_SECTION_SOURCE,
    EVERNOTE_SECTION_STATUS,
    EVERNOTE_SUBTITLE,
    EVERNOTE_TITLE_TAG,
    EVERNOTE_WAITING_FIRST_LOG,
    HISTORY_ALL_CLEAR,
    HISTORY_COL_CONTAINERS,
    HISTORY_COL_FINDINGS,
    HISTORY_COL_SERVICES,
    HISTORY_COL_TIMESTAMP,
    HISTORY_CRITICAL_FMT,
    HISTORY_EMPTY,
    HISTORY_HEADING,
    HISTORY_RUNNING_FMT,
    HISTORY_SUBTITLE_FMT,
    HISTORY_TITLE_TAG,
    HISTORY_WARNING_FMT,
    HISTORY_WAS_FMT,
    MAILTO_BODY_INTRO,
    MAILTO_BODY_OUTRO,
    MAILTO_SUBJECT_FMT,
    NETWORK_FAIL_DETAIL_FMT,
    NETWORK_FAIL_FIX_FMT,
    NETWORK_FAIL_TITLE_FMT,
    NO_OLLAMA_MODELS_FOUND_DETAIL,
    NO_OLLAMA_MODELS_FOUND_FIX,
    NO_OLLAMA_MODELS_FOUND_FIX_COMMAND,
    NO_OLLAMA_MODELS_FOUND_TITLE,
    OLLAMA_CONSIDER_UPDATE_DETAIL,
    OLLAMA_CONSIDER_UPDATE_FIX,
    OLLAMA_CONSIDER_UPDATE_FIX_COMMAND,
    OLLAMA_CONSIDER_UPDATE_TITLE_FMT,
    OLLAMA_MODELS_DISK_USE_DETAIL,
    OLLAMA_MODELS_DISK_USE_FIX,
    OLLAMA_MODELS_DISK_USE_FIX_COMMAND,
    OLLAMA_MODELS_DISK_USE_TITLE_FMT,
    PAIR_IOS_BTN_REGENERATE,
    PAIR_IOS_BTN_REGENERATING,
    PAIR_IOS_CAMERA_HINT_HTML,
    PAIR_IOS_DISABLED_DETAIL,
    PAIR_IOS_DISABLED_TITLE,
    PAIR_IOS_EMPTY_DETAIL,
    PAIR_IOS_EMPTY_TITLE,
    PAIR_IOS_ENVELOPE_INVALID_DETAIL,
    PAIR_IOS_ENVELOPE_INVALID_TITLE,
    PAIR_IOS_ERROR_NETWORK_PREFIX,
    PAIR_IOS_ERROR_REGENERATE_PREFIX,
    PAIR_IOS_HEADING,
    PAIR_IOS_HUB_ADDR_LABEL,
    PAIR_IOS_INTRO_HTML,
    PAIR_IOS_META_FOOTER_HTML,
    PAIR_IOS_NETWORK_BANNER_HTML,
    PAIR_IOS_NO_CODE_DETAIL,
    PAIR_IOS_NO_CODE_TITLE,
    PAIR_IOS_QR_RENDER_DETAIL,
    PAIR_IOS_QR_RENDER_TITLE,
    PAIR_IOS_SECTION_CODE,
    PAIR_IOS_SUBTITLE,
    PAIR_IOS_TITLE_TAG,
    PORT_CONFLICT_DETAIL_FMT,
    PORT_CONFLICT_FIX,
    PORT_CONFLICT_FIX_COMMAND_FMT,
    PORT_CONFLICT_TITLE_FMT,
    QDRANT_NO_EMBED_MODEL_DETAIL,
    QDRANT_NO_EMBED_MODEL_FIX,
    QDRANT_NO_EMBED_MODEL_FIX_COMMAND,
    QDRANT_NO_EMBED_MODEL_TITLE,
    REPORT_DOCKER_LABEL,
    REPORT_FIX_LABEL,
    REPORT_GENERATED_LABEL,
    REPORT_HEADER,
    REPORT_HOST_OS_LABEL,
    REPORT_NOTES_PLACEHOLDER,
    REPORT_OLLAMA_LABEL,
    REPORT_SECTION_CONTAINERS,
    REPORT_SECTION_DISK,
    REPORT_SECTION_FINDINGS,
    REPORT_SECTION_MODELS,
    REPORT_SECTION_NOTES,
    REPORT_SECTION_SERVICES,
    SERVICE_UNHEALTHY_DETAIL_FMT,
    SERVICE_UNHEALTHY_FIX_COMMAND_FMT,
    SERVICE_UNHEALTHY_FIX_FMT,
    SERVICE_UNHEALTHY_TITLE_FMT,
    SERVICE_UNREACHABLE_DETAIL_FMT,
    SERVICE_UNREACHABLE_FIX_COMMAND_FMT,
    SERVICE_UNREACHABLE_FIX_FMT,
    SERVICE_UNREACHABLE_TITLE_FMT,
)

app = FastAPI(title=APP_TITLE)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

SUPPORT_EMAIL = os.getenv("DOCTOR_SUPPORT_EMAIL", "support@creativemachines.ai")

# ── Snapshot history (in-memory, last 10) ─────────────────────────

_history: deque[dict] = deque(maxlen=10)


def _snapshot_to_dict(snapshot: SystemSnapshot) -> dict:
    """Convert snapshot to a JSON-serialisable dict."""
    return {
        "timestamp": snapshot.timestamp,
        "hostname": snapshot.hostname,
        "os_version": snapshot.os_version,
        "docker_version": snapshot.docker_version,
        "ollama_version": snapshot.ollama_version,
        "containers": [
            {"name": c.name, "image": c.image, "state": c.state, "status": c.status}
            for c in snapshot.docker_containers
        ],
        "models": [
            {"name": m.name, "size_gb": m.size_gb}
            for m in snapshot.ollama_models
        ],
        "services": [
            {"name": s.name, "status": s.status, "status_code": s.status_code}
            for s in snapshot.services
        ],
        "disk": [
            {"mount": d.mount_point, "percent_used": d.percent_used, "free_gb": d.free_gb, "total_gb": d.total_gb}
            for d in snapshot.disk_usage
        ],
    }


def _record_snapshot(snapshot: SystemSnapshot, findings: list[dict]) -> None:
    """Store a snapshot + findings in the history ring buffer."""
    _history.append({
        "snapshot": _snapshot_to_dict(snapshot),
        "findings": findings,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
    })


# ── Built-in diagnostic rules (no cloud needed) ─────────────────────


def run_local_diagnostics(snapshot: SystemSnapshot) -> list[dict]:
    """Apply built-in rules to detect common issues without cloud LLM."""
    findings = []

    # Check Docker containers. Detect the deployment's prefix dynamically
    # so we work for productised installs (ostler-) and the dev compose
    # setup (pwg-).
    #
    # This Docker-container management section is suppressed on the
    # productised native build. NOTE: native does NOT mean "no Docker" --
    # the data tier (Qdrant/Oxigraph/Redis) runs in containers via Colima
    # even here. The section is suppressed because its criticals are framed
    # around Docker *Desktop* container management, which is false-RED on a
    # healthy native install (Colima, not Docker Desktop) and leads the
    # support-email report. A genuine data-tier outage is already surfaced
    # by the per-service unreachable rules, so suppressing this loses no
    # coverage. The legacy Docker-Desktop dev deploy opts back in via
    # OSTLER_DEPLOY_MODE=docker. See is_native_deployment().
    docker_deployment = not is_native_deployment()
    prefix = detect_ostler_prefix(snapshot)
    expected_containers = {f"{prefix}{svc}" for svc in EXPECTED_OSTLER_SERVICES}
    running_names = {c.name for c in snapshot.docker_containers if c.state == "running"}
    missing = expected_containers - running_names

    if docker_deployment and not snapshot.docker_containers:
        findings.append({
            "severity": "critical",
            "title": DOCKER_NOT_RUNNING_TITLE,
            "detail": DOCKER_NOT_RUNNING_DETAIL,
            "fix": DOCKER_NOT_RUNNING_FIX,
            "fix_command": DOCKER_NOT_RUNNING_FIX_COMMAND,
            "risk": "low",
        })
    elif docker_deployment and missing:
        for name in missing:
            findings.append({
                "severity": "critical",
                "title": CONTAINER_NOT_RUNNING_TITLE_FMT.format(name=name),
                "detail": CONTAINER_NOT_RUNNING_DETAIL_FMT.format(
                    short_name=name.replace(prefix, ""),
                ),
                "fix": CONTAINER_NOT_RUNNING_FIX,
                "fix_command": CONTAINER_NOT_RUNNING_FIX_COMMAND,
                "risk": "low",
            })

    for c in snapshot.docker_containers:
        if c.state == "exited":
            findings.append({
                "severity": "warning",
                "title": CONTAINER_EXITED_TITLE_FMT.format(name=c.name),
                "detail": CONTAINER_EXITED_DETAIL_FMT.format(status=c.status),
                "fix": CONTAINER_EXITED_FIX,
                "fix_command": CONTAINER_EXITED_FIX_COMMAND_FMT.format(name=c.name),
                "risk": "low",
            })

    # Check Ollama
    if not snapshot.ollama_models:
        findings.append({
            "severity": "warning",
            "title": NO_OLLAMA_MODELS_FOUND_TITLE,
            "detail": NO_OLLAMA_MODELS_FOUND_DETAIL,
            "fix": NO_OLLAMA_MODELS_FOUND_FIX,
            "fix_command": NO_OLLAMA_MODELS_FOUND_FIX_COMMAND,
            "risk": "low",
        })
    else:
        model_names = {m.name.split(":")[0] for m in snapshot.ollama_models}
        if "nomic-embed-text" not in model_names:
            findings.append({
                "severity": "warning",
                "title": EMBED_MODEL_MISSING_TITLE,
                "detail": EMBED_MODEL_MISSING_DETAIL,
                "fix": EMBED_MODEL_MISSING_FIX,
                "fix_command": EMBED_MODEL_MISSING_FIX_COMMAND,
                "risk": "low",
            })

    # Check services
    for svc in snapshot.services:
        if svc.status == "unreachable":
            findings.append({
                "severity": "critical",
                "title": SERVICE_UNREACHABLE_TITLE_FMT.format(name=svc.name),
                "detail": SERVICE_UNREACHABLE_DETAIL_FMT.format(name=svc.name),
                "fix": SERVICE_UNREACHABLE_FIX_FMT.format(name=svc.name),
                "fix_command": SERVICE_UNREACHABLE_FIX_COMMAND_FMT.format(name=svc.name),
                "risk": "low",
            })
        elif svc.status == "unhealthy":
            findings.append({
                "severity": "warning",
                "title": SERVICE_UNHEALTHY_TITLE_FMT.format(
                    name=svc.name, status_code=svc.status_code,
                ),
                "detail": SERVICE_UNHEALTHY_DETAIL_FMT.format(name=svc.name),
                "fix": SERVICE_UNHEALTHY_FIX_FMT.format(name=svc.name),
                "fix_command": SERVICE_UNHEALTHY_FIX_COMMAND_FMT.format(
                    prefix=prefix, name=svc.name,
                ),
                "risk": "low",
            })

    # Check disk space
    for disk in snapshot.disk_usage:
        if disk.percent_used > 95:
            findings.append({
                "severity": "critical",
                "title": DISK_NEARLY_FULL_TITLE_FMT.format(
                    percent_used=disk.percent_used,
                    mount_point=disk.mount_point,
                ),
                "detail": DISK_NEARLY_FULL_DETAIL_FMT.format(free_gb=disk.free_gb),
                "fix": DISK_NEARLY_FULL_FIX,
                "fix_command": DISK_NEARLY_FULL_FIX_COMMAND,
                "risk": "medium",
            })
        elif disk.percent_used > 85:
            findings.append({
                "severity": "warning",
                "title": DISK_GETTING_FULL_TITLE_FMT.format(
                    percent_used=disk.percent_used,
                    mount_point=disk.mount_point,
                ),
                "detail": DISK_GETTING_FULL_DETAIL_FMT.format(free_gb=disk.free_gb),
                "fix": None,
                "fix_command": None,
                "risk": "low",
            })

    # Network checks
    for check in snapshot.network_checks:
        if not check.reachable:
            findings.append({
                "severity": "warning",
                "title": NETWORK_FAIL_TITLE_FMT.format(
                    source=check.source, target=check.target,
                ),
                "detail": NETWORK_FAIL_DETAIL_FMT.format(
                    source=check.source, target=check.target,
                ),
                "fix": NETWORK_FAIL_FIX_FMT.format(target=check.target),
                "fix_command": None,
                "risk": "low",
            })

    # Check Docker version (too old can cause issues)
    if snapshot.docker_version:
        try:
            major = int(snapshot.docker_version.split(".")[0])
            if major < 24:
                findings.append({
                    "severity": "warning",
                    "title": DOCKER_VERSION_OLD_TITLE_FMT.format(
                        version=snapshot.docker_version,
                    ),
                    "detail": DOCKER_VERSION_OLD_DETAIL,
                    "fix": DOCKER_VERSION_OLD_FIX,
                    "fix_command": DOCKER_VERSION_OLD_FIX_COMMAND,
                    "risk": "low",
                })
        except (ValueError, IndexError):
            pass

    # Check Ollama version
    if snapshot.ollama_version:
        try:
            parts = snapshot.ollama_version.split(".")
            minor = int(parts[1]) if len(parts) > 1 else 0
            if minor < 16:
                findings.append({
                    "severity": "info",
                    "title": OLLAMA_CONSIDER_UPDATE_TITLE_FMT.format(
                        version=snapshot.ollama_version,
                    ),
                    "detail": OLLAMA_CONSIDER_UPDATE_DETAIL,
                    "fix": OLLAMA_CONSIDER_UPDATE_FIX,
                    "fix_command": OLLAMA_CONSIDER_UPDATE_FIX_COMMAND,
                    "risk": "low",
                })
        except (ValueError, IndexError):
            pass

    # Check for large Ollama models that might be filling disk
    total_model_gb = sum(m.size_gb or 0 for m in snapshot.ollama_models)
    if total_model_gb > 50:
        findings.append({
            "severity": "warning",
            "title": OLLAMA_MODELS_DISK_USE_TITLE_FMT.format(total_gb=total_model_gb),
            "detail": OLLAMA_MODELS_DISK_USE_DETAIL,
            "fix": OLLAMA_MODELS_DISK_USE_FIX,
            "fix_command": OLLAMA_MODELS_DISK_USE_FIX_COMMAND,
            "risk": "low",
        })

    # Check for port conflicts (services healthy but unexpected containers).
    # Anything that looks like an Ostler-managed container is "ours";
    # everything else is a candidate for a port clash.
    other_containers = [
        c for c in snapshot.docker_containers
        if not is_ostler_container(c) and c.state == "running"
    ]
    port_conflict_hints = {
        "6333": "qdrant",
        "7878": "oxigraph",
        "6379": "redis",
        "11434": "ollama",
    }
    for c in other_containers:
        for port, service in port_conflict_hints.items():
            if port in c.status or port in c.image:
                findings.append({
                    "severity": "warning",
                    "title": PORT_CONFLICT_TITLE_FMT.format(
                        name=c.name, service=service,
                    ),
                    "detail": PORT_CONFLICT_DETAIL_FMT.format(
                        name=c.name, image=c.image, port=port,
                    ),
                    "fix": PORT_CONFLICT_FIX,
                    "fix_command": PORT_CONFLICT_FIX_COMMAND_FMT.format(name=c.name),
                    "risk": "low",
                })

    # Check for Qdrant specifically – it needs a collection
    qdrant_healthy = any(s.name == "qdrant" and s.status == "healthy" for s in snapshot.services)
    if qdrant_healthy and not snapshot.ollama_models:
        findings.append({
            "severity": "info",
            "title": QDRANT_NO_EMBED_MODEL_TITLE,
            "detail": QDRANT_NO_EMBED_MODEL_DETAIL,
            "fix": QDRANT_NO_EMBED_MODEL_FIX,
            "fix_command": QDRANT_NO_EMBED_MODEL_FIX_COMMAND,
            "risk": "low",
        })

    # Check RAM (if we can detect it from OS info)
    if snapshot.os_version and "Darwin" in (snapshot.os_version or ""):
        # On macOS, check if we're on Apple Silicon
        pass  # RAM check is done in install.sh, not here

    # All clear
    if not findings:
        findings.append({
            "severity": "info",
            "title": ALL_HEALTHY_TITLE,
            "detail": ALL_HEALTHY_DETAIL,
            "fix": None,
            "fix_command": None,
            "risk": "low",
        })

    return findings


# ── Build diagnostic report (for "Send by Email") ───────────────────


def _format_report(snapshot: SystemSnapshot, findings: list[dict]) -> str:
    """Format a human-readable diagnostic report for support emails.

    The user can see exactly what they are about to send before their
    mail client opens – nothing here is personal data, only system
    status.
    """
    lines: list[str] = []
    lines.append(REPORT_HEADER)
    lines.append("=" * 42)
    lines.append(f"{REPORT_GENERATED_LABEL} {datetime.now(timezone.utc).isoformat()}")
    lines.append(f"{REPORT_HOST_OS_LABEL}   {snapshot.os_version}")
    if snapshot.docker_version:
        lines.append(f"{REPORT_DOCKER_LABEL}    {snapshot.docker_version}")
    if snapshot.ollama_version:
        lines.append(f"{REPORT_OLLAMA_LABEL}    {snapshot.ollama_version}")
    lines.append("")

    lines.append(REPORT_SECTION_SERVICES)
    lines.append("-" * 42)
    for svc in snapshot.services:
        code = f" (HTTP {svc.status_code})" if svc.status_code else ""
        lines.append(f"  {svc.status:<12} {svc.name}{code}")
    lines.append("")

    if snapshot.docker_containers:
        lines.append(REPORT_SECTION_CONTAINERS)
        lines.append("-" * 42)
        for c in snapshot.docker_containers:
            lines.append(f"  {c.state:<10} {c.name}  ({c.image})")
        lines.append("")

    if snapshot.ollama_models:
        lines.append(REPORT_SECTION_MODELS)
        lines.append("-" * 42)
        for m in snapshot.ollama_models:
            lines.append(f"  {m.size_gb:>6.2f} GB  {m.name}")
        lines.append("")

    if snapshot.disk_usage:
        lines.append(REPORT_SECTION_DISK)
        lines.append("-" * 42)
        for d in snapshot.disk_usage:
            lines.append(f"  {d.percent_used:>3}%  {d.mount_point}  ({d.free_gb} GB free of {d.total_gb} GB)")
        lines.append("")

    if findings:
        lines.append(REPORT_SECTION_FINDINGS)
        lines.append("-" * 42)
        for f in findings:
            severity = f.get("severity", "info")
            lines.append(f"  [{severity}] {f.get('title', '')}")
            desc = f.get("description", "")
            if desc:
                lines.append(f"         {desc}")
            fix = f.get("fix_command")
            if fix:
                lines.append(f"         {REPORT_FIX_LABEL} {fix}")
        lines.append("")

    lines.append(REPORT_SECTION_NOTES)
    lines.append("-" * 42)
    lines.append(f"  {REPORT_NOTES_PLACEHOLDER}")
    lines.append("")

    return "\n".join(lines)


def _build_mailto(report: str, version: str = "1.0.0") -> str:
    """Build a mailto: URL with pre-populated subject and body."""
    today = datetime.now().strftime("%Y-%m-%d")
    subject = MAILTO_SUBJECT_FMT.format(version=version, today=today)
    body = MAILTO_BODY_INTRO + report + MAILTO_BODY_OUTRO
    # urlencode subject and body; mailto uses %20 for spaces
    params = urllib.parse.urlencode(
        {"subject": subject, "body": body},
        quote_via=urllib.parse.quote,
    )
    return f"mailto:{SUPPORT_EMAIL}?{params}"


# ── HTML template ────────────────────────────────────────────────────


def render_dashboard(
    snapshot: SystemSnapshot,
    findings: list[dict],
    *,
    import_evernote_enabled: bool = False,
) -> str:
    """Render the diagnostic dashboard as HTML.

    ``import_evernote_enabled`` toggles the footer nav link to the
    Evernote import page (CM024 Block 3.4). The flag is read by the
    dashboard route handler so the dashboard renderer stays decoupled
    from ``import_evernote.is_feature_enabled``. Flag flips while a
    dashboard tab is open take effect on the next full refresh, not
    the auto-poll -- the auto-refresh JS only updates the dynamic
    panels, not the footer nav.
    """
    import_evernote_link = (
        DASHBOARD_IMPORT_EVERNOTE_LINK if import_evernote_enabled else ''
    )

    # Build service status cards
    service_cards = ""
    for svc in snapshot.services:
        color = {"healthy": "#5cb579", "unhealthy": "#d4a052", "unreachable": "#d96666"}.get(svc.status, "rgba(236,232,221,0.40)")
        icon = {"healthy": "&#10003;", "unhealthy": "&#9888;", "unreachable": "&#10007;"}.get(svc.status, "?")
        service_cards += f"""
        <div class="status-card">
            <div class="status-indicator" style="background:{color}">{icon}</div>
            <div class="status-info">
                <div class="status-name">{svc.name}</div>
                <div class="status-detail">{svc.status}{f' (HTTP {svc.status_code})' if svc.status_code else ''}</div>
            </div>
        </div>"""

    # Build container cards
    empty_containers_html = (
        f'<div class="status-card"><div class="status-info">'
        f'<div class="status-name">{DASHBOARD_NO_CONTAINERS}</div>'
        f'</div></div>'
    )
    meta_info_html = DASHBOARD_META_FMT.format(
        timestamp=snapshot.timestamp[:19],
        os_version=snapshot.os_version or DASHBOARD_META_OS_UNKNOWN,
        docker_version=snapshot.docker_version or DASHBOARD_META_DOCKER_NONE,
        ollama_version=snapshot.ollama_version or DASHBOARD_META_OLLAMA_NONE,
    )
    container_cards = ""
    for c in snapshot.docker_containers:
        color = {"running": "#5cb579", "exited": "#d96666", "paused": "#d4a052"}.get(c.state, "rgba(236,232,221,0.40)")
        container_cards += f"""
        <div class="status-card">
            <div class="status-indicator" style="background:{color}">&#9632;</div>
            <div class="status-info">
                <div class="status-name">{c.name}</div>
                <div class="status-detail">{c.state} &ndash; {c.status}</div>
            </div>
        </div>"""

    # Build model list
    model_items = ""
    for m in snapshot.ollama_models:
        size = f" ({m.size_gb:.1f} GB)" if m.size_gb else ""
        model_items += f"<li>{m.name}{size}</li>"
    if not model_items:
        model_items = f"<li class='empty'>{DASHBOARD_NO_MODELS}</li>"

    # Build disk usage
    disk_items = ""
    for d in snapshot.disk_usage:
        bar_color = "#5cb579" if d.percent_used < 80 else "#d4a052" if d.percent_used < 95 else "#d96666"
        disk_items += f"""
        <div class="disk-item">
            <div class="disk-label">{d.mount_point}</div>
            <div class="disk-bar-bg">
                <div class="disk-bar" style="width:{d.percent_used}%;background:{bar_color}"></div>
            </div>
            <div class="disk-detail">{d.free_gb:.0f} GB free of {d.total_gb:.0f} GB ({d.percent_used}%)</div>
        </div>"""

    # Security posture: read marker files written by each service at boot.
    # Empty string when no markers (e.g. on a brand-new install).
    posture_section = render_security_posture()

    # Observability posture: per-tick health markers from the
    # hourly LaunchAgents (email-ingest et al). Empty string when
    # no markers, e.g. on a brand-new install or when none of the
    # LaunchAgents have ticked yet.
    observability_section = render_observability_posture()

    # Consent registry (A7+A8): records of every tickbox the user
    # has been shown (Article 9 EU, WhatsApp risk, EU voice gate).
    # Empty string until first record is written. Amber when
    # bundled wording-hash drifts from stored hash (renewal needed).
    consent_section = render_consent_status()

    # iMessage TCC posture (task #278): install-time snapshot of
    # the macOS AppleEvents permission for Messages.app. Empty
    # string when the marker is absent (fresh install before
    # install.sh has run, or install with iMessage disabled). A
    # silent denial here is one of the most common ways a daily
    # brief never arrives, so surfacing it explicitly is part of
    # the productisation posture story.
    imessage_tcc_section = render_imessage_tcc_posture()

    # Build findings
    findings_html = ""
    for f in findings:
        sev_color = {"critical": "#d96666", "warning": "#d4a052", "info": "#5cb579"}.get(f["severity"], "rgba(236,232,221,0.40)")
        sev_icon = {"critical": "&#9888;", "warning": "&#9888;", "info": "&#10003;"}.get(f["severity"], "?")
        fix_html = ""
        if f.get("fix_command"):
            cmd_escaped = f['fix_command'].replace("'", "\\'").replace('"', '&quot;')
            fix_label = DASHBOARD_FIX_LABEL_FMT.format(risk=f.get('risk', 'low'))
            fix_html = f"""
            <div class="fix-box">
                <div class="fix-label">{fix_label}</div>
                <div class="fix-description">{f['fix']}</div>
                <div class="fix-command-wrapper">
                    <code class="fix-command">{f['fix_command']}</code>
                    <button class="copy-btn" onclick="copyCommand(this, '{cmd_escaped}')" title="Copy to clipboard">&#128203;</button>
                </div>
                <div class="fix-note">{DASHBOARD_FIX_NOTE}</div>
            </div>"""
        elif f.get("fix"):
            fix_html = f"""
            <div class="fix-box">
                <div class="fix-description">{f['fix']}</div>
            </div>"""

        findings_html += f"""
        <div class="finding" style="border-left:3px solid {sev_color}">
            <div class="finding-header">
                <span class="finding-icon" style="color:{sev_color}">{sev_icon}</span>
                <span class="finding-title">{f['title']}</span>
                <span class="finding-severity" style="background:{sev_color}">{f['severity']}</span>
            </div>
            <div class="finding-detail">{f['detail']}</div>
            {fix_html}
        </div>"""

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{DASHBOARD_TITLE_TAG}</title>
    <style>
        /* Ostler Doctor inline theme. Tokens mirror the marketing site
           (assets/ostler.css on os001) shifted to a dark-mode admin
           dashboard palette. Components: header, status-grid + status-card,
           findings + fix-box, disk + model lists, chat. */
        /* PRIVACY: Google Fonts @import removed -- a local privacy-first product must not beacon the customer IP+timestamp to googleapis.com on every dashboard open. System-ui / -apple-system fallbacks below render cleanly. TODO(v1.0.1 privacy): self-host Outfit/IBM Plex via @font-face if branded type is wanted; do NOT re-add the googleapis @import. */

        :root {{
            --ostler-ink: #0d0b08;
            --ostler-ink-deep: #07060a;
            --ostler-panel: #1a1612;
            --ostler-panel-elev: #221c16;
            --ostler-chassis: #ECE8DD;
            --ostler-accent: #C84545;
            --ostler-accent-hover: #D76060;
            --ostler-accent-warm: #E26A6A;
            --ostler-accent-glow: rgba(200, 69, 69, 0.18);
            --ostler-hairline-soft: rgba(236, 232, 221, 0.16);
            --ostler-hairline-faint: rgba(236, 232, 221, 0.08);
            --text: var(--ostler-chassis);
            --text-secondary: rgba(236, 232, 221, 0.74);
            --text-muted: rgba(236, 232, 221, 0.50);
            --text-faint: rgba(236, 232, 221, 0.32);
            --green: #5cb579;
            --red: #d96666;
            --yellow: #d4a052;
            --shadow-soft: 0 1px 2px rgba(0,0,0,0.40), 0 4px 12px rgba(0,0,0,0.28);
            --shadow-card: 0 1px 2px rgba(0,0,0,0.45), 0 8px 24px rgba(0,0,0,0.35);
            --font-display: 'Outfit', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-body: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-mono: 'IBM Plex Mono', 'SF Mono', Menlo, monospace;
        }}
        * {{ margin:0; padding:0; box-sizing:border-box; }}
        body {{
            font-family: var(--font-body);
            font-size: 15px;
            line-height: 1.5;
            background: var(--ostler-ink);
            color: var(--text);
            min-height: 100vh;
            padding: 2.5rem 1.75rem;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
        }}
        a {{ color: var(--ostler-accent); text-decoration: none; }}
        a:hover {{ color: var(--ostler-accent-hover); }}
        .container {{ max-width: 960px; margin: 0 auto; }}
        h1 {{
            font-family: var(--font-display);
            font-size: 1.7rem;
            font-weight: 600;
            letter-spacing: -0.02em;
            margin-bottom: 0.3rem;
            color: var(--text);
        }}
        .subtitle {{
            font-family: var(--font-mono);
            font-size: 0.78rem;
            letter-spacing: 0.04em;
            color: var(--text-muted);
            margin-bottom: 2rem;
        }}
        .header {{
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            margin-bottom: 2.2rem;
        }}
        .header-controls {{
            display: flex;
            align-items: center;
            gap: 0.65rem;
        }}
        .refresh-btn, .auto-refresh-btn {{
            background: var(--ostler-panel);
            color: var(--text-secondary);
            border: 1px solid var(--ostler-hairline-soft);
            padding: 0.55rem 1.1rem;
            border-radius: 999px;
            cursor: pointer;
            font-family: var(--font-display);
            font-weight: 500;
            font-size: 0.82rem;
            transition: border-color 0.18s, color 0.18s, background 0.18s, transform 0.18s, box-shadow 0.18s;
            display: inline-flex;
            align-items: center;
            gap: 6px;
        }}
        .refresh-btn:hover, .auto-refresh-btn:hover {{
            border-color: var(--ostler-accent);
            color: var(--text);
            background: var(--ostler-panel-elev);
            transform: translateY(-1px);
            box-shadow: var(--shadow-soft);
        }}
        .auto-refresh-btn.active {{
            background: var(--ostler-accent-glow);
            border-color: var(--ostler-accent);
            color: var(--ostler-accent-warm);
        }}
        .last-checked {{
            font-family: var(--font-mono);
            font-size: 0.72rem;
            letter-spacing: 0.02em;
            color: var(--text-faint);
            text-align: right;
            margin-top: 0.4rem;
        }}
        .section {{ margin-bottom: 2.2rem; }}
        .section-title {{
            font-family: var(--font-display);
            font-size: 0.72rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            color: var(--text-muted);
            margin-bottom: 0.85rem;
            font-weight: 500;
        }}
        .status-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
            gap: 0.65rem;
        }}
        .status-card {{
            background: var(--ostler-panel);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 12px;
            padding: 0.95rem 1.05rem;
            display: flex;
            align-items: center;
            gap: 0.85rem;
            box-shadow: var(--shadow-soft);
            transition: border-color 0.18s, transform 0.18s, box-shadow 0.18s;
        }}
        .status-card:hover {{
            border-color: var(--ostler-accent);
            transform: translateY(-1px);
            box-shadow: var(--shadow-card);
        }}
        .status-indicator {{
            width: 30px;
            height: 30px;
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 0.9rem;
            color: white;
            flex-shrink: 0;
            box-shadow: 0 0 10px rgba(0,0,0,0.20);
        }}
        .status-name {{
            font-family: var(--font-display);
            font-weight: 600;
            font-size: 0.9rem;
            letter-spacing: -0.005em;
        }}
        .status-detail {{
            font-family: var(--font-mono);
            font-size: 0.74rem;
            letter-spacing: 0.02em;
            color: var(--text-muted);
        }}
        .status-info {{ flex: 1; min-width: 0; }}
        .model-list {{
            list-style: none;
            display: flex;
            flex-wrap: wrap;
            gap: 0.5rem;
        }}
        .model-list li {{
            background: var(--ostler-panel-elev);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 999px;
            padding: 0.42rem 0.95rem;
            font-family: var(--font-mono);
            font-size: 0.78rem;
            letter-spacing: 0.01em;
            color: var(--text-secondary);
        }}
        .model-list .empty {{
            color: var(--text-faint);
            font-family: var(--font-body);
            font-style: italic;
            background: transparent;
            border: 1px dashed var(--ostler-hairline-faint);
        }}
        .disk-item {{ margin-bottom: 0.85rem; }}
        .disk-label {{
            font-family: var(--font-display);
            font-size: 0.85rem;
            font-weight: 600;
            margin-bottom: 0.3rem;
            color: var(--text);
        }}
        .disk-bar-bg {{
            background: var(--ostler-panel-elev);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 999px;
            height: 8px;
            overflow: hidden;
            margin-bottom: 0.3rem;
        }}
        .disk-bar {{ height: 100%; border-radius: 999px; transition: width 0.4s ease; }}
        .disk-detail {{
            font-family: var(--font-mono);
            font-size: 0.74rem;
            letter-spacing: 0.02em;
            color: var(--text-muted);
        }}
        .finding {{
            background: var(--ostler-panel);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 12px;
            padding: 1.05rem 1.15rem;
            margin-bottom: 0.8rem;
            box-shadow: var(--shadow-soft);
            transition: transform 0.18s, box-shadow 0.18s, border-color 0.18s;
        }}
        .finding:hover {{
            transform: translateY(-1px);
            box-shadow: var(--shadow-card);
            border-color: var(--ostler-hairline-soft);
        }}
        .finding-header {{
            display: flex;
            align-items: center;
            gap: 0.55rem;
            margin-bottom: 0.55rem;
        }}
        .finding-icon {{ font-size: 1.05rem; }}
        .finding-title {{
            font-family: var(--font-display);
            font-weight: 600;
            font-size: 0.94rem;
            flex: 1;
            color: var(--text);
            letter-spacing: -0.005em;
        }}
        .finding-severity {{
            font-family: var(--font-display);
            font-size: 0.62rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            padding: 0.18rem 0.6rem;
            border-radius: 999px;
            color: white;
            font-weight: 600;
        }}
        .finding-detail {{
            font-family: var(--font-body);
            font-size: 0.86rem;
            color: var(--text-secondary);
            margin-bottom: 0.85rem;
            line-height: 1.55;
        }}
        .fix-box {{
            background: var(--ostler-ink-deep);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 8px;
            padding: 0.85rem 1rem;
        }}
        .fix-label {{
            font-family: var(--font-display);
            font-size: 0.68rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            color: var(--text-muted);
            margin-bottom: 0.35rem;
            font-weight: 500;
        }}
        .fix-description {{
            font-family: var(--font-body);
            font-size: 0.86rem;
            margin-bottom: 0.55rem;
            color: var(--text);
        }}
        .fix-command-wrapper {{
            display: flex;
            align-items: stretch;
            gap: 0;
            margin-bottom: 0.35rem;
        }}
        .fix-command {{
            display: block;
            background: var(--ostler-ink);
            border: 1px solid var(--ostler-hairline-soft);
            border-right: none;
            border-radius: 6px 0 0 6px;
            padding: 0.55rem 0.85rem;
            font-family: var(--font-mono);
            font-size: 0.80rem;
            letter-spacing: 0.01em;
            color: var(--ostler-accent-warm);
            flex: 1;
            user-select: all;
            word-break: break-all;
        }}
        .copy-btn {{
            background: var(--ostler-panel-elev);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 0 6px 6px 0;
            padding: 0.55rem 0.7rem;
            cursor: pointer;
            font-size: 0.85rem;
            color: var(--text-muted);
            transition: background 0.18s, color 0.18s, border-color 0.18s;
            white-space: nowrap;
        }}
        .copy-btn:hover {{
            background: var(--ostler-accent-glow);
            color: var(--ostler-accent-warm);
            border-color: var(--ostler-accent);
        }}
        .copy-btn.copied {{
            background: rgba(92, 181, 121, 0.16);
            color: var(--green);
            border-color: var(--green);
        }}
        .fix-note {{
            font-family: var(--font-body);
            font-size: 0.72rem;
            color: var(--text-faint);
            font-style: italic;
            margin-top: 0.4rem;
        }}

        /* Chat interface */
        .chat-section {{
            margin-top: 2.5rem;
            border-top: 1px solid var(--ostler-hairline-faint);
            padding-top: 2rem;
        }}
        .chat-controls {{
            display: flex;
            gap: 0.5rem;
            margin-bottom: 0.85rem;
            align-items: center;
        }}
        .chat-controls label {{
            font-family: var(--font-display);
            font-size: 0.72rem;
            letter-spacing: 0.18em;
            text-transform: uppercase;
            color: var(--text-muted);
            font-weight: 500;
        }}
        .chat-controls select {{
            background: var(--ostler-panel);
            color: var(--text);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 6px;
            padding: 0.35rem 0.55rem;
            font-family: var(--font-body);
            font-size: 0.82rem;
        }}
        .chat-input-row {{ display: flex; gap: 0.5rem; }}
        .chat-input {{
            flex: 1;
            background: var(--ostler-panel);
            color: var(--text);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 999px;
            padding: 0.7rem 1rem;
            font-family: var(--font-body);
            font-size: 0.88rem;
            outline: none;
            transition: border-color 0.18s, box-shadow 0.18s;
        }}
        .chat-input:focus {{
            border-color: var(--ostler-accent);
            box-shadow: 0 0 0 3px var(--ostler-accent-glow);
        }}
        .chat-input::placeholder {{ color: var(--text-faint); }}
        .chat-send {{
            background: var(--ostler-accent);
            color: white;
            border: none;
            border-radius: 999px;
            padding: 0.7rem 1.5rem;
            font-family: var(--font-display);
            font-size: 0.85rem;
            cursor: pointer;
            font-weight: 500;
            transition: background 0.18s, transform 0.18s, box-shadow 0.18s;
        }}
        .chat-send:hover {{
            background: var(--ostler-accent-hover);
            transform: translateY(-1px);
            box-shadow: var(--shadow-soft);
        }}
        .chat-send:disabled {{
            background: var(--ostler-panel-elev);
            color: var(--text-muted);
            cursor: not-allowed;
            transform: none;
            box-shadow: none;
        }}
        .chat-messages {{ margin-top: 1rem; }}
        .chat-bubble {{
            border-radius: 12px;
            padding: 0.85rem 1.1rem;
            margin-bottom: 0.55rem;
            font-family: var(--font-body);
            font-size: 0.86rem;
            line-height: 1.55;
            max-width: 85%;
            white-space: pre-wrap;
            box-shadow: var(--shadow-soft);
        }}
        .chat-bubble.user {{
            background: var(--ostler-accent-glow);
            border: 1px solid var(--ostler-accent);
            color: var(--text);
            margin-left: auto;
            text-align: right;
        }}
        .chat-bubble.assistant {{
            background: var(--ostler-panel);
            border: 1px solid var(--ostler-hairline-faint);
            color: var(--text-secondary);
        }}
        .chat-bubble .chat-label {{
            font-family: var(--font-display);
            font-size: 0.65rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            color: var(--text-muted);
            margin-bottom: 0.3rem;
            font-weight: 500;
        }}
        .chat-thinking {{
            color: var(--text-muted);
            font-style: italic;
        }}

        .meta {{
            font-family: var(--font-mono);
            font-size: 0.72rem;
            letter-spacing: 0.04em;
            color: var(--text-faint);
            margin-top: 2.2rem;
            padding-top: 1.1rem;
            border-top: 1px solid var(--ostler-hairline-faint);
        }}
        .meta a {{
            color: var(--text-muted);
            text-decoration: none;
        }}
        .meta a:hover {{
            color: var(--ostler-accent-warm);
            text-decoration: underline;
        }}
        a:focus-visible,
        button:focus-visible {{
            outline: 2px solid var(--ostler-accent);
            outline-offset: 2px;
        }}
        @media (max-width: 720px) {{
            body {{ padding: 1.4rem 1rem; }}
            .status-grid {{ grid-template-columns: 1fr; }}
            .header {{ flex-direction: column; gap: 0.85rem; align-items: stretch; }}
            .chat-bubble {{ max-width: 95%; }}
            h1 {{ font-size: 1.4rem; }}
            .header-controls {{ flex-wrap: wrap; }}
        }}
        @media (max-width: 480px) {{
            .header-controls {{ width: 100%; }}
            .refresh-btn, .auto-refresh-btn {{ flex: 1; justify-content: center; }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1>{DASHBOARD_HEADING}</h1>
                <div class="subtitle">{DASHBOARD_SUBTITLE_FMT.format(hostname=snapshot.hostname or DASHBOARD_HOSTNAME_UNKNOWN)}</div>
            </div>
            <div>
                <div class="header-controls">
                    <button class="refresh-btn" onclick="manualRefresh()">{DASHBOARD_BTN_REFRESH}</button>
                    <button class="auto-refresh-btn active" id="autoRefreshBtn" onclick="toggleAutoRefresh()">{DASHBOARD_BTN_AUTO_ON}</button>
                    <button class="refresh-btn" id="emailReportBtn" onclick="sendByEmail()" title="{DASHBOARD_BTN_EMAIL_TITLE}">{DASHBOARD_BTN_EMAIL}</button>
                </div>
                <div class="last-checked" id="lastChecked">{DASHBOARD_LAST_CHECKED_JUST_NOW}</div>
            </div>
        </div>

        <div class="section" id="findingsSection">
            <div class="section-title">{DASHBOARD_SECTION_FINDINGS}</div>
            <div id="findingsContent">{findings_html}</div>
        </div>

        <div class="section" id="servicesSection">
            <div class="section-title">{DASHBOARD_SECTION_SERVICES}</div>
            <div class="status-grid" id="servicesContent">{service_cards}</div>
        </div>

        <div class="section" id="containersSection">
            <div class="section-title">{DASHBOARD_SECTION_CONTAINERS}</div>
            <div class="status-grid" id="containersContent">{container_cards if container_cards else empty_containers_html}</div>
        </div>

        {posture_section}

        {observability_section}

        {consent_section}

        {imessage_tcc_section}

        <div class="section">
            <div class="section-title">{DASHBOARD_SECTION_MODELS}</div>
            <ul class="model-list" id="modelsContent">{model_items}</ul>
        </div>

        <div class="section">
            <div class="section-title">{DASHBOARD_SECTION_DISK}</div>
            <div id="diskContent">{disk_items}</div>
        </div>

        <div class="chat-section">
            <div class="section-title">{DASHBOARD_SECTION_HELP}</div>
            <p style="color:#94a3b8; line-height:1.6; margin-bottom:1rem;">
                {DASHBOARD_HELP_PARAGRAPH_1}
            </p>
            <p style="color:#94a3b8; line-height:1.6; font-size:0.85rem;">
                {DASHBOARD_HELP_PARAGRAPH_2}
            </p>
        </div>

        <div class="meta" id="metaInfo">
            {meta_info_html}{import_evernote_link}{DASHBOARD_PAIR_IOS_LINK}{DASHBOARD_CONFIG_LINK}
        </div>
    </div>

    <script>
    (function() {{
        // --- Auto-refresh ---
        let autoRefresh = true;
        let lastCheckTime = Date.now();
        let refreshTimer = null;

        function updateLastChecked() {{
            const seconds = Math.round((Date.now() - lastCheckTime) / 1000);
            const el = document.getElementById('lastChecked');
            if (seconds < 5) el.textContent = 'Last checked: just now';
            else el.textContent = 'Last checked: ' + seconds + 's ago';
        }}

        setInterval(updateLastChecked, 1000);

        function scheduleRefresh() {{
            if (refreshTimer) clearTimeout(refreshTimer);
            if (!autoRefresh) return;
            refreshTimer = setTimeout(fetchStatus, 10000);
        }}

        function fetchStatus() {{
            fetch('/doctor/api/status')
                .then(r => r.json())
                .then(data => {{
                    lastCheckTime = Date.now();
                    updateDashboard(data);
                    scheduleRefresh();
                }})
                .catch(() => {{
                    scheduleRefresh();
                }});
        }}

        function updateDashboard(data) {{
            const snap = data.snapshot;
            const findings = data.findings;

            // Update findings
            let fhtml = '';
            findings.forEach(f => {{
                const sevColors = {{critical:'#d96666',warning:'#d4a052',info:'#5cb579'}};
                const sevIcons = {{critical:'&#9888;',warning:'&#9888;',info:'&#10003;'}};
                const sc = sevColors[f.severity]||'rgba(236,232,221,0.40)';
                const si = sevIcons[f.severity]||'?';
                let fixHtml = '';
                if (f.fix_command) {{
                    const escaped = f.fix_command.replace(/'/g, "\\\\'").replace(/"/g, '&quot;');
                    fixHtml = '<div class="fix-box">'
                        + '<div class="fix-label">Suggested fix (' + (f.risk||'low') + ' risk):</div>'
                        + '<div class="fix-description">' + (f.fix||'') + '</div>'
                        + '<div class="fix-command-wrapper">'
                        + '<code class="fix-command">' + f.fix_command + '</code>'
                        + '<button class="copy-btn" onclick="copyCommand(this, \\'' + escaped + '\\')" title="Copy to clipboard">&#128203;</button>'
                        + '</div>'
                        + '<div class="fix-note">Copy and paste this into Terminal. Ostler Doctor never runs commands for you.</div>'
                        + '</div>';
                }} else if (f.fix) {{
                    fixHtml = '<div class="fix-box"><div class="fix-description">' + f.fix + '</div></div>';
                }}
                fhtml += '<div class="finding" style="border-left:3px solid ' + sc + '">'
                    + '<div class="finding-header">'
                    + '<span class="finding-icon" style="color:' + sc + '">' + si + '</span>'
                    + '<span class="finding-title">' + f.title + '</span>'
                    + '<span class="finding-severity" style="background:' + sc + '">' + f.severity + '</span>'
                    + '</div>'
                    + '<div class="finding-detail">' + f.detail + '</div>'
                    + fixHtml + '</div>';
            }});
            document.getElementById('findingsContent').innerHTML = fhtml;

            // Update services
            let shtml = '';
            snap.services.forEach(s => {{
                const colors = {{healthy:'#5cb579',unhealthy:'#d4a052',unreachable:'#d96666'}};
                const icons = {{healthy:'&#10003;',unhealthy:'&#9888;',unreachable:'&#10007;'}};
                shtml += '<div class="status-card">'
                    + '<div class="status-indicator" style="background:' + (colors[s.status]||'rgba(236,232,221,0.40)') + '">' + (icons[s.status]||'?') + '</div>'
                    + '<div class="status-info"><div class="status-name">' + s.name + '</div>'
                    + '<div class="status-detail">' + s.status + (s.status_code ? ' (HTTP ' + s.status_code + ')' : '') + '</div></div></div>';
            }});
            document.getElementById('servicesContent').innerHTML = shtml;

            // Update containers
            let chtml = '';
            snap.containers.forEach(c => {{
                const colors = {{running:'#5cb579',exited:'#d96666',paused:'#d4a052'}};
                chtml += '<div class="status-card">'
                    + '<div class="status-indicator" style="background:' + (colors[c.state]||'rgba(236,232,221,0.40)') + '">&#9632;</div>'
                    + '<div class="status-info"><div class="status-name">' + c.name + '</div>'
                    + '<div class="status-detail">' + c.state + ' &ndash; ' + c.status + '</div></div></div>';
            }});
            if (!chtml) chtml = '<div class="status-card"><div class="status-info"><div class="status-name">No containers found</div></div></div>';
            document.getElementById('containersContent').innerHTML = chtml;

            // Update models
            let mhtml = '';
            snap.models.forEach(m => {{
                const size = m.size_gb ? ' (' + m.size_gb.toFixed(1) + ' GB)' : '';
                mhtml += '<li>' + m.name + size + '</li>';
            }});
            if (!mhtml) mhtml = "<li class='empty'>No models found</li>";
            document.getElementById('modelsContent').innerHTML = mhtml;

            // Update disk
            let dhtml = '';
            snap.disk.forEach(d => {{
                const bc = d.percent_used < 80 ? '#5cb579' : d.percent_used < 95 ? '#d4a052' : '#d96666';
                dhtml += '<div class="disk-item"><div class="disk-label">' + d.mount + '</div>'
                    + '<div class="disk-bar-bg"><div class="disk-bar" style="width:' + d.percent_used + '%;background:' + bc + '"></div></div>'
                    + '<div class="disk-detail">' + Math.round(d.free_gb) + ' GB free of ' + Math.round(d.total_gb) + ' GB (' + d.percent_used + '%)</div></div>';
            }});
            document.getElementById('diskContent').innerHTML = dhtml;

            // Update meta
            document.getElementById('metaInfo').innerHTML =
                'Snapshot taken: ' + snap.timestamp.substring(0,19) + 'Z &ndash; '
                + 'OS: ' + (snap.os_version||'unknown') + ' &ndash; '
                + 'Docker: ' + (snap.docker_version||'not detected') + ' &ndash; '
                + 'Ollama: ' + (snap.ollama_version||'not detected')
                + ' &ndash; <a href="/doctor/history">History</a>'
                + ' &ndash; <a href="/config">Settings</a>';
        }}

        window.manualRefresh = function() {{
            fetchStatus();
        }};

        window.toggleAutoRefresh = function() {{
            autoRefresh = !autoRefresh;
            const btn = document.getElementById('autoRefreshBtn');
            if (autoRefresh) {{
                btn.textContent = 'Auto: ON';
                btn.classList.add('active');
                scheduleRefresh();
            }} else {{
                btn.textContent = 'Auto: OFF';
                btn.classList.remove('active');
                if (refreshTimer) clearTimeout(refreshTimer);
            }}
        }};

        // Start auto-refresh
        scheduleRefresh();

        // --- Copy to clipboard ---
        window.copyCommand = function(btn, text) {{
            navigator.clipboard.writeText(text).then(function() {{
                btn.classList.add('copied');
                btn.innerHTML = '&#10003;';
                setTimeout(function() {{
                    btn.classList.remove('copied');
                    btn.innerHTML = '&#128203;';
                }}, 1500);
            }}).catch(function() {{
                // Fallback: select the code element
                const code = btn.previousElementSibling;
                if (code) {{
                    const range = document.createRange();
                    range.selectNodeContents(code);
                    const sel = window.getSelection();
                    sel.removeAllRanges();
                    sel.addRange(range);
                }}
            }});
        }};

        // --- Send by Email (local-only mailto) ---
        window.sendByEmail = function() {{
            const btn = document.getElementById('emailReportBtn');
            btn.disabled = true;
            btn.textContent = 'Preparing…';
            fetch('/doctor/api/email-report')
                .then(r => r.json())
                .then(data => {{
                    if (data && data.mailto) {{
                        // Open the user's default mail client with the
                        // diagnostic report pre-populated. Nothing is
                        // sent automatically – the user reviews and sends.
                        window.location.href = data.mailto;
                    }} else {{
                        alert('{DASHBOARD_ALERT_REPORT_FAIL}');
                    }}
                }})
                .catch(err => {{
                    alert('{DASHBOARD_ALERT_REPORT_ERROR_FMT}' + err);
                }})
                .finally(() => {{
                    btn.disabled = false;
                    btn.innerHTML = '&#9993; Send by Email';
                }});
        }};

        function escapeHtml(text) {{
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }}
    }})();
    </script>
</body>
</html>"""


def render_history(history_entries: list[dict]) -> str:
    """Render the snapshot history page."""
    if not history_entries:
        rows = f'<tr><td colspan="5" style="text-align:center;color:rgba(236,232,221,0.50);padding:2rem">{HISTORY_EMPTY}</td></tr>'
    else:
        rows = ""
        prev_services: dict[str, str] = {}
        for entry in reversed(list(history_entries)):
            snap = entry["snapshot"]
            ts = snap["timestamp"][:19] + "Z"

            # Service summary. Colours match the dashboard token palette
            # (--green / --yellow / --red) so a healthy/unhealthy mix
            # reads identically across both views.
            svc_parts = []
            for s in snap.get("services", []):
                name = s["name"]
                status = s["status"]
                prev = prev_services.get(name)
                color = {"healthy": "#5cb579", "unhealthy": "#d4a052", "unreachable": "#d96666"}.get(status, "rgba(236,232,221,0.50)")
                changed = ""
                if prev and prev != status:
                    changed = f' <span style="color:#d4a052;font-size:0.7rem">{HISTORY_WAS_FMT.format(prev=prev)}</span>'
                svc_parts.append(f'<span style="color:{color}">{name}: {status}</span>{changed}')
                prev_services[name] = status

            # Container summary
            containers = snap.get("containers", [])
            running = sum(1 for c in containers if c["state"] == "running")
            total = len(containers)

            # Findings summary
            findings = entry.get("findings", [])
            crit = sum(1 for f in findings if f.get("severity") == "critical")
            warn = sum(1 for f in findings if f.get("severity") == "warning")
            finding_parts = []
            if crit:
                finding_parts.append(f'<span style="color:#d96666">{HISTORY_CRITICAL_FMT.format(count=crit)}</span>')
            if warn:
                finding_parts.append(f'<span style="color:#d4a052">{HISTORY_WARNING_FMT.format(count=warn)}</span>')
            if not finding_parts:
                finding_parts.append(f'<span style="color:#5cb579">{HISTORY_ALL_CLEAR}</span>')

            rows += f"""<tr>
                <td>{ts}</td>
                <td>{", ".join(svc_parts)}</td>
                <td>{HISTORY_RUNNING_FMT.format(running=running, total=total)}</td>
                <td>{", ".join(finding_parts)}</td>
            </tr>"""

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{HISTORY_TITLE_TAG}</title>
    <style>
        /* PRIVACY: Google Fonts @import removed -- a local privacy-first product must not beacon the customer IP+timestamp to googleapis.com on every dashboard open. System-ui / -apple-system fallbacks below render cleanly. TODO(v1.0.1 privacy): self-host Outfit/IBM Plex via @font-face if branded type is wanted; do NOT re-add the googleapis @import. */
        :root {{
            --ostler-ink: #0d0b08;
            --ostler-panel: #1a1612;
            --ostler-panel-elev: #221c16;
            --ostler-chassis: #ECE8DD;
            --ostler-accent: #C84545;
            --ostler-accent-warm: #E26A6A;
            --ostler-hairline-soft: rgba(236, 232, 221, 0.16);
            --ostler-hairline-faint: rgba(236, 232, 221, 0.08);
            --text: var(--ostler-chassis);
            --text-muted: rgba(236, 232, 221, 0.50);
            --font-display: 'Outfit', system-ui, sans-serif;
            --font-body: 'IBM Plex Sans', system-ui, sans-serif;
            --font-mono: 'IBM Plex Mono', 'SF Mono', Menlo, monospace;
        }}
        * {{ margin:0; padding:0; box-sizing:border-box; }}
        body {{
            font-family: var(--font-body);
            background: var(--ostler-ink);
            color: var(--text);
            min-height: 100vh;
            padding: 2.5rem 1.75rem;
            -webkit-font-smoothing: antialiased;
        }}
        .container {{ max-width: 1040px; margin: 0 auto; }}
        h1 {{
            font-family: var(--font-display);
            font-size: 1.5rem;
            font-weight: 600;
            letter-spacing: -0.02em;
            margin-bottom: 0.35rem;
        }}
        .subtitle {{
            font-family: var(--font-mono);
            color: var(--text-muted);
            margin-bottom: 1.6rem;
            font-size: 0.78rem;
            letter-spacing: 0.04em;
        }}
        .subtitle a {{ color: var(--ostler-accent); text-decoration: none; }}
        .subtitle a:hover {{ color: var(--ostler-accent-warm); text-decoration: underline; }}
        table {{
            width: 100%;
            border-collapse: separate;
            border-spacing: 0;
            font-family: var(--font-body);
            font-size: 0.82rem;
            background: var(--ostler-panel);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 1px 2px rgba(0,0,0,0.40), 0 4px 12px rgba(0,0,0,0.28);
        }}
        th {{
            text-align: left;
            padding: 0.7rem 0.95rem;
            background: var(--ostler-ink);
            border-bottom: 1px solid var(--ostler-hairline-soft);
            color: var(--text-muted);
            font-family: var(--font-display);
            font-weight: 500;
            text-transform: uppercase;
            letter-spacing: 0.16em;
            font-size: 0.7rem;
        }}
        td {{
            padding: 0.6rem 0.95rem;
            border-bottom: 1px solid var(--ostler-hairline-faint);
            vertical-align: top;
            font-family: var(--font-mono);
            font-size: 0.78rem;
        }}
        tr:last-child td {{ border-bottom: none; }}
        tr:hover td {{ background: var(--ostler-panel-elev); }}
    </style>
</head>
<body>
    <div class="container">
        <h1>{HISTORY_HEADING}</h1>
        <div class="subtitle">{HISTORY_SUBTITLE_FMT.format(count=len(history_entries))}</div>
        <table>
            <thead>
                <tr>
                    <th>{HISTORY_COL_TIMESTAMP}</th>
                    <th>{HISTORY_COL_SERVICES}</th>
                    <th>{HISTORY_COL_CONTAINERS}</th>
                    <th>{HISTORY_COL_FINDINGS}</th>
                </tr>
            </thead>
            <tbody>{rows}</tbody>
        </table>
    </div>
</body>
</html>"""


# ── Endpoints ────────────────────────────────────────────────────────


@app.get("/doctor", response_class=HTMLResponse)
async def dashboard():
    """Serve the diagnostic dashboard or first-run wizard."""
    snapshot = collect_full_snapshot()

    # Show setup wizard on first run
    if is_first_run():
        steps = get_wizard_steps(snapshot)
        # If all steps complete, mark setup done and fall through to dashboard
        if all(s["status"] == "complete" for s in steps):
            mark_setup_complete()
        else:
            return HTMLResponse(render_wizard(snapshot, steps))

    # Normal dashboard
    # Combine inline rules with the comprehensive rules engine
    findings = run_local_diagnostics(snapshot)
    findings.extend(run_all_rules(snapshot))
    # Deduplicate by title
    seen = set()
    findings = [f for f in findings if f["title"] not in seen and not seen.add(f["title"])]
    _record_snapshot(snapshot, findings)
    # CM024 Block 3.4: surface the Evernote import nav link only when
    # the feature flag is on. Read here (not inside the renderer) so
    # render_dashboard stays decoupled from import_evernote.
    from import_evernote import is_feature_enabled as _evernote_flag
    return render_dashboard(
        snapshot, findings,
        import_evernote_enabled=_evernote_flag(),
    )


@app.get("/doctor/api/status", response_class=JSONResponse)
async def api_status():
    """Return raw system status as JSON (for programmatic access)."""
    snapshot = collect_full_snapshot()
    findings = run_local_diagnostics(snapshot)
    findings.extend(run_all_rules(snapshot))
    seen = set()
    findings = [f for f in findings if f["title"] not in seen and not seen.add(f["title"])]
    _record_snapshot(snapshot, findings)
    snap_dict = _snapshot_to_dict(snapshot)
    return {
        "snapshot": snap_dict,
        "findings": findings,
    }


@app.get("/doctor/api/email-report", response_class=JSONResponse)
async def api_email_report():
    """
    Generate a mailto: URL with the full diagnostic report pre-populated.

    The frontend opens this URL, which launches the user's mail client
    with a pre-filled subject and body. The user reviews the content
    and chooses whether to send. Nothing is sent automatically and
    nothing leaves the machine without the user's action.
    """
    snapshot = collect_full_snapshot()
    findings = run_all_rules(snapshot) + run_local_diagnostics(snapshot)
    seen = set()
    findings = [f for f in findings if f["title"] not in seen and not seen.add(f["title"])]
    report = _format_report(snapshot, findings)
    mailto = _build_mailto(report)
    return {"mailto": mailto, "report_preview": report}


@app.get("/doctor/history", response_class=HTMLResponse)
async def history_page():
    """Show the snapshot history page."""
    return render_history(list(_history))


@app.get("/doctor/api/history", response_class=JSONResponse)
async def api_history():
    """Return snapshot history as JSON."""
    return {"entries": list(_history)}


@app.get("/doctor/api/health")
async def health():
    return {"status": "healthy", "service": "ostler-doctor"}


@app.post("/api/v1/wiki/correct", response_class=JSONResponse)
async def api_wiki_correct(request: Request):
    """Record a wiki correction (#277).

    Sister endpoint to CM044 PR #26's read side. The inline pencil
    overlay, the Doctor "Corrections" tab, and the CM031 assistant
    chat tool all POST here. We validate, recompute the fact_hash
    server-side as defence-in-depth, then INSERT a fresh
    ``pwg:Correction`` triple into Oxigraph. CM044's compiler picks
    it up on the next rebuild and prefers the corrected value.

    See ``wiki_correct.py`` for the schema, the source/status
    enums, and the validation rules. This handler only owns the
    HTTP plumbing.
    """
    from wiki_correct import (
        ValidationError as _WikiCorrectError,
        validate_payload as _validate,
        write_correction as _write,
    )

    try:
        body = await request.json()
    except Exception as exc:
        return JSONResponse(
            {"error": f"invalid JSON: {exc}"}, status_code=400,
        )

    try:
        normalised = _validate(body)
    except _WikiCorrectError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)

    try:
        result = _write(normalised)
    except Exception as exc:
        # Oxigraph reachable-but-rejecting OR unreachable. Surface as
        # 502 -- caller should retry; the client (overlay or assistant
        # tool) renders the failure inline so the user knows their
        # edit didn't land.
        return JSONResponse(
            {"error": f"oxigraph write failed: {exc}"},
            status_code=502,
        )

    return result


@app.post("/api/v1/wiki/duplicates/decision", response_class=JSONResponse)
async def api_wiki_duplicates_decision(request: Request):
    """Record a duplicate-contact decision (#3 duplicates UX).

    The CM044 "Possible duplicate contacts" page renders Combine /
    Not-the-same buttons that POST here. We append the decision to
    ``duplicates.yaml`` in the corrections dir; the CM041 resolver enacts
    it on the next sweep (merge = forced union, distinct = permanent
    never-merge) and the page reads it back to stop re-nagging. Thin HTTP
    plumbing only -- schema + write live in ``duplicate_decision.py``.
    """
    from duplicate_decision import (
        ValidationError as _DupError,
        validate_payload as _validate,
        write_decision as _write,
    )

    try:
        body = await request.json()
    except Exception as exc:
        return JSONResponse({"error": f"invalid JSON: {exc}"}, status_code=400)

    try:
        normalised = _validate(body)
    except _DupError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)

    try:
        result = _write(normalised)
    except _DupError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)
    except Exception as exc:
        return JSONResponse(
            {"error": f"could not record decision: {exc}"}, status_code=500,
        )

    return result


@app.post("/api/v1/auth/chat-token", response_class=JSONResponse)
async def api_chat_token(request: Request):
    """Mint a fresh ZeroClaw bearer token for the iOS chat tab.

    Sister endpoint to CM031 PR #43's ``ChatTokenService``. The iOS
    Companion calls this once after pairing; we proxy through
    ZeroClaw's pairing-code flow (admin-authenticated initiate plus
    public code exchange) to mint a device-bearer token, then return
    it with the LAN-reachable chat gateway URL.

    See ``chat_token.py`` for the end-to-end logic, the admin-token
    seed convention, and the public-URL resolution rules. This
    handler only owns the HTTP plumbing.
    """
    from chat_token import (
        TokenIssueError as _ChatTokenError,
        issue_chat_token as _issue,
    )

    request_host = request.headers.get("host")
    try:
        result = _issue(request_host=request_host)
    except _ChatTokenError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)

    return result


@app.get("/api/v1/observability-posture", response_class=JSONResponse)
async def api_observability_posture():
    """Return every observability-posture marker keyed by service.

    The CM031 Companion app and any future external dashboard
    consume this endpoint instead of scraping the HTML tile. The
    payload is the literal output of
    `ostler_security.observability_posture.all_observability_postures()`,
    which is the same dict the on-disk markers contain. Empty dict
    when no service has reported yet.

    Versioned at /api/v1 so the response shape can evolve without
    breaking older clients -- once an external client ships,
    breaking-change must roll a /api/v2 instead of mutating this.
    """
    return all_observability_postures()


# ── CM019 reverse proxy (CM019 clean-house PR 8) ──────────────────
#
# Forwards iOS-initiated CM019 paths to the local gateway over
# loopback so iOS only ever talks to one auth boundary: the
# Doctor on :8089. The CM019 gateway is bound to 127.0.0.1 per
# design doc Section 4. Configurable via DOCTOR_PROXY_PATHS (env
# var, comma-separated) so future iOS paths land as a config
# change rather than a code change. See doctor/agent/proxy.py.

from proxy import register_proxy_routes

_registered_proxy_paths = register_proxy_routes(app)


def _config_section_order() -> tuple[str, ...]:
    """Section display order for the Configuration panel.

    Imported lazily from ``config_panel`` so the panel's renderer and
    its backend share one source of truth for section ordering.
    """
    from config_panel import SECTION_ORDER

    return SECTION_ORDER


# ── CM024 Evernote import (feature-flagged, launch-scope brief 2026-05-13) ──
#
# Four routes back the Doctor "Import Evernote" surface. All four
# 404 when ``features.evernote_import`` is off in
# ``~/.ostler/config/features.yaml`` -- the installer always deploys
# ``ostler-knowledge`` (CM051 PR #70's 3.13b section) but the
# customer-visible surface stays hidden until the operator flips
# the flag. Block 3.3 wires the routes + lockfile + state machine;
# Block 3.4 fills in the UI page body.


def _render_import_evernote_page(active_job_id=None) -> str:
    """Render the Evernote import page (CM024 Block 3.4).

    ``active_job_id`` is the output of
    ``import_evernote.current_running_job_id()``. When non-None the
    page boots straight into the polling-status panel so the operator
    who closed and reopened the tab mid-import reattaches without
    having to re-enter the path.

    Vanilla HTML + JS, no framework. Matches Doctor's chassis tokens
    (Outfit / Plex Sans / Plex Mono, ostler-ink palette) so it sits
    visually next to ``/doctor`` rather than feeling bolted on.

    Polling cadence per the launch-scope brief:
        - ``GET /status`` every 5 seconds
        - ``GET /tail``  every 10 seconds
    On a terminal status (succeeded / failed) both timers stop.
    """
    initial_job_id_js = json.dumps(active_job_id)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{EVERNOTE_TITLE_TAG}</title>
    <style>
        /* PRIVACY: Google Fonts @import removed -- a local privacy-first product must not beacon the customer IP+timestamp to googleapis.com on every dashboard open. System-ui / -apple-system fallbacks below render cleanly. TODO(v1.0.1 privacy): self-host Outfit/IBM Plex via @font-face if branded type is wanted; do NOT re-add the googleapis @import. */
        :root {{
            --ostler-ink: #0d0b08;
            --ostler-ink-deep: #07060a;
            --ostler-panel: #1a1612;
            --ostler-panel-elev: #221c16;
            --ostler-chassis: #ECE8DD;
            --ostler-accent: #C84545;
            --ostler-accent-hover: #D76060;
            --ostler-accent-warm: #E26A6A;
            --ostler-accent-glow: rgba(200, 69, 69, 0.18);
            --ostler-hairline-soft: rgba(236, 232, 221, 0.16);
            --ostler-hairline-faint: rgba(236, 232, 221, 0.08);
            --text: var(--ostler-chassis);
            --text-secondary: rgba(236, 232, 221, 0.74);
            --text-muted: rgba(236, 232, 221, 0.50);
            --text-faint: rgba(236, 232, 221, 0.32);
            --green: #5cb579;
            --yellow: #d4a052;
            --red: #d96666;
            --shadow-soft: 0 1px 2px rgba(0,0,0,0.40), 0 4px 12px rgba(0,0,0,0.28);
            --shadow-card: 0 1px 2px rgba(0,0,0,0.45), 0 8px 24px rgba(0,0,0,0.35);
            --font-display: 'Outfit', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-body: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-mono: 'IBM Plex Mono', 'SF Mono', Menlo, monospace;
        }}
        * {{ margin:0; padding:0; box-sizing:border-box; }}
        body {{
            font-family: var(--font-body);
            font-size: 15px;
            line-height: 1.5;
            background: var(--ostler-ink);
            color: var(--text);
            min-height: 100vh;
            padding: 2.5rem 1.75rem;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
        }}
        a {{ color: var(--ostler-accent); text-decoration: none; }}
        a:hover {{ color: var(--ostler-accent-hover); }}
        .container {{ max-width: 760px; margin: 0 auto; }}
        h1 {{
            font-family: var(--font-display);
            font-size: 1.7rem;
            font-weight: 600;
            letter-spacing: -0.02em;
            margin-bottom: 0.3rem;
        }}
        .subtitle {{
            font-family: var(--font-mono);
            font-size: 0.78rem;
            letter-spacing: 0.04em;
            color: var(--text-muted);
            margin-bottom: 2rem;
        }}
        .subtitle a {{ color: var(--text-muted); }}
        .subtitle a:hover {{ color: var(--ostler-accent-warm); text-decoration: underline; }}
        .section-title {{
            font-family: var(--font-display);
            font-size: 0.72rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            color: var(--text-muted);
            margin-bottom: 0.85rem;
            font-weight: 500;
        }}
        .panel {{
            background: var(--ostler-panel);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 12px;
            padding: 1.4rem 1.5rem;
            box-shadow: var(--shadow-soft);
            margin-bottom: 1.4rem;
        }}
        .panel p {{ color: var(--text-secondary); margin-bottom: 0.85rem; }}
        .help {{
            font-size: 0.82rem;
            color: var(--text-muted);
            margin-top: 0.55rem;
            line-height: 1.55;
        }}
        .help code {{
            font-family: var(--font-mono);
            font-size: 0.78rem;
            background: var(--ostler-ink-deep);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 4px;
            padding: 0.1rem 0.35rem;
            color: var(--ostler-accent-warm);
        }}
        label {{
            display: block;
            font-family: var(--font-display);
            font-size: 0.78rem;
            text-transform: uppercase;
            letter-spacing: 0.16em;
            color: var(--text-muted);
            margin-bottom: 0.45rem;
            font-weight: 500;
        }}
        input[type="text"] {{
            display: block;
            width: 100%;
            background: var(--ostler-ink-deep);
            color: var(--text);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 8px;
            padding: 0.75rem 0.95rem;
            font-family: var(--font-mono);
            font-size: 0.86rem;
            letter-spacing: 0.01em;
            outline: none;
            transition: border-color 0.18s, box-shadow 0.18s;
        }}
        input[type="text"]:focus {{
            border-color: var(--ostler-accent);
            box-shadow: 0 0 0 3px var(--ostler-accent-glow);
        }}
        input[type="text"]::placeholder {{ color: var(--text-faint); }}
        .button-row {{
            display: flex;
            gap: 0.6rem;
            align-items: center;
            margin-top: 1rem;
            flex-wrap: wrap;
        }}
        button.primary, button.secondary {{
            font-family: var(--font-display);
            font-weight: 500;
            font-size: 0.85rem;
            padding: 0.65rem 1.4rem;
            border-radius: 999px;
            cursor: pointer;
            border: 1px solid transparent;
            transition: background 0.18s, transform 0.18s, box-shadow 0.18s, border-color 0.18s, color 0.18s;
        }}
        button.primary {{
            background: var(--ostler-accent);
            color: white;
        }}
        button.primary:hover {{
            background: var(--ostler-accent-hover);
            transform: translateY(-1px);
            box-shadow: var(--shadow-soft);
        }}
        button.primary:disabled {{
            background: var(--ostler-panel-elev);
            color: var(--text-muted);
            cursor: not-allowed;
            transform: none;
            box-shadow: none;
        }}
        button.secondary {{
            background: var(--ostler-panel);
            color: var(--text-secondary);
            border-color: var(--ostler-hairline-soft);
        }}
        button.secondary:hover {{
            border-color: var(--ostler-accent);
            color: var(--text);
            background: var(--ostler-panel-elev);
            transform: translateY(-1px);
        }}
        .banner {{
            padding: 0.75rem 1rem;
            border-radius: 8px;
            font-size: 0.86rem;
            margin-bottom: 1.2rem;
            border-left: 3px solid var(--red);
            background: rgba(217, 102, 102, 0.10);
            color: var(--text);
            display: none;
        }}
        .banner.visible {{ display: block; }}
        .status-row {{
            display: flex;
            align-items: center;
            gap: 0.85rem;
            margin-bottom: 1rem;
            flex-wrap: wrap;
        }}
        .status-pill {{
            font-family: var(--font-display);
            font-size: 0.7rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            padding: 0.3rem 0.85rem;
            border-radius: 999px;
            font-weight: 600;
            color: white;
            background: var(--text-faint);
        }}
        .status-pill.running {{ background: var(--yellow); }}
        .status-pill.succeeded {{ background: var(--green); }}
        .status-pill.partial {{ background: #d4a052; }}
        .status-pill.failed {{ background: var(--red); }}
        .status-meta {{
            font-family: var(--font-mono);
            font-size: 0.76rem;
            letter-spacing: 0.02em;
            color: var(--text-muted);
        }}
        .log-pane {{
            background: var(--ostler-ink-deep);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 8px;
            padding: 0.85rem 1rem;
            font-family: var(--font-mono);
            font-size: 0.78rem;
            line-height: 1.5;
            color: var(--text-secondary);
            max-height: 360px;
            overflow-y: auto;
            white-space: pre-wrap;
            word-break: break-word;
        }}
        .log-pane.empty {{
            color: var(--text-faint);
            font-style: italic;
        }}
        .meta-bottom {{
            font-family: var(--font-mono);
            font-size: 0.72rem;
            letter-spacing: 0.04em;
            color: var(--text-faint);
            margin-top: 2rem;
            padding-top: 1.1rem;
            border-top: 1px solid var(--ostler-hairline-faint);
        }}
        button:focus-visible {{
            outline: 2px solid var(--ostler-accent);
            outline-offset: 2px;
        }}
        @media (max-width: 720px) {{
            body {{ padding: 1.4rem 1rem; }}
            h1 {{ font-size: 1.4rem; }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>{EVERNOTE_HEADING}</h1>
        <div class="subtitle">
            {EVERNOTE_SUBTITLE}
        </div>

        <div id="errorBanner" class="banner"></div>

        <div id="formPanel" class="panel" style="display:none">
            <div class="section-title">{EVERNOTE_SECTION_SOURCE}</div>
            <p>
                {EVERNOTE_INTRO_HTML}
            </p>
            <form id="importForm" autocomplete="off">
                <label for="enexPath">{EVERNOTE_LABEL_PATH}</label>
                <input type="text" id="enexPath" name="enex_path"
                    placeholder="{EVERNOTE_PLACEHOLDER_PATH}"
                    spellcheck="false" autocapitalize="off">
                <div class="help">
                    {EVERNOTE_HELP_TIP_HTML}
                </div>
                <div class="button-row">
                    <button type="submit" class="primary" id="submitBtn">{EVERNOTE_BTN_START}</button>
                </div>
            </form>
        </div>

        <div id="jobPanel" class="panel" style="display:none">
            <div class="section-title">{EVERNOTE_SECTION_STATUS}</div>
            <div class="status-row">
                <span class="status-pill" id="statusPill">{EVERNOTE_PILL_STARTING}</span>
                <span class="status-meta" id="statusMeta"></span>
            </div>
            <div class="section-title" style="margin-top:1.2rem">{EVERNOTE_SECTION_LOG_TAIL}</div>
            <div class="log-pane empty" id="logPane">{EVERNOTE_WAITING_FIRST_LOG}</div>
            <div class="button-row" id="resetRow" style="display:none">
                <button type="button" class="secondary" id="resetBtn">{EVERNOTE_BTN_IMPORT_ANOTHER}</button>
            </div>
        </div>

        <div class="meta-bottom">
            {EVERNOTE_META_FOOTER_HTML}
        </div>
    </div>

    <script>
    (function() {{
        const STATUS_POLL_MS = 5000;
        const TAIL_POLL_MS = 10000;
        const INITIAL_JOB_ID = {initial_job_id_js};

        const formPanel = document.getElementById('formPanel');
        const jobPanel = document.getElementById('jobPanel');
        const importForm = document.getElementById('importForm');
        const submitBtn = document.getElementById('submitBtn');
        const enexInput = document.getElementById('enexPath');
        const statusPill = document.getElementById('statusPill');
        const statusMeta = document.getElementById('statusMeta');
        const logPane = document.getElementById('logPane');
        const resetRow = document.getElementById('resetRow');
        const resetBtn = document.getElementById('resetBtn');
        const errorBanner = document.getElementById('errorBanner');

        let currentJobId = null;
        let statusTimer = null;
        let tailTimer = null;

        function showError(msg) {{
            errorBanner.textContent = msg;
            errorBanner.classList.add('visible');
        }}

        function clearError() {{
            errorBanner.classList.remove('visible');
            errorBanner.textContent = '';
        }}

        function showForm() {{
            formPanel.style.display = '';
            jobPanel.style.display = 'none';
            enexInput.value = '';
            enexInput.focus();
        }}

        function showJobPanel() {{
            formPanel.style.display = 'none';
            jobPanel.style.display = '';
        }}

        function renderStatus(state) {{
            const status = state.status || 'unknown';
            statusPill.textContent = status;
            statusPill.className = 'status-pill ' + status;

            const bits = [];
            if (state.job_id) bits.push('job ' + state.job_id);
            if (state.started_at) bits.push('started ' + state.started_at.substring(0, 19) + 'Z');
            if (state.completed_at) bits.push('finished ' + state.completed_at.substring(0, 19) + 'Z');
            if (state.exit_code !== null && state.exit_code !== undefined) {{
                bits.push('exit ' + state.exit_code);
            }}
            // A degraded ('partial') import carries a human-facing note
            // explaining what landed and what is pending; surface it.
            if (state.note) bits.push(state.note);
            statusMeta.textContent = bits.join(' \\u00b7 ');

            if (status === 'succeeded' || status === 'failed' || status === 'partial') {{
                resetRow.style.display = '';
                stopPolling();
                // One last tail fetch to make sure the final output is shown.
                fetchTail();
            }} else {{
                resetRow.style.display = 'none';
            }}
        }}

        function fetchStatus() {{
            if (!currentJobId) return;
            fetch('/api/v1/import/evernote/' + encodeURIComponent(currentJobId) + '/status')
                .then(function(r) {{
                    if (r.status === 404) {{
                        // Either feature flipped off mid-session, or the
                        // job_id has been reaped. Either way the page is
                        // out of sync; force a reload.
                        stopPolling();
                        showError('{EVERNOTE_ERROR_JOB_NOT_FOUND}');
                        return null;
                    }}
                    return r.json();
                }})
                .then(function(state) {{
                    if (state) renderStatus(state);
                }})
                .catch(function(err) {{
                    showError('{EVERNOTE_ERROR_STATUS_FAIL_PREFIX}' + err);
                }});
        }}

        function fetchTail() {{
            if (!currentJobId) return;
            fetch('/api/v1/import/evernote/' + encodeURIComponent(currentJobId) + '/tail')
                .then(function(r) {{
                    if (!r.ok) return null;
                    return r.text();
                }})
                .then(function(text) {{
                    if (text === null) return;
                    if (!text || text.trim() === '') {{
                        logPane.classList.add('empty');
                        logPane.textContent = 'Waiting for first log output\\u2026';
                    }} else {{
                        logPane.classList.remove('empty');
                        logPane.textContent = text;
                        // Auto-scroll to the bottom so the latest line is
                        // always visible without manual scrolling.
                        logPane.scrollTop = logPane.scrollHeight;
                    }}
                }})
                .catch(function(err) {{
                    // Don't surface tail failures as errors - the status
                    // pane is the source of truth.
                }});
        }}

        function startPolling() {{
            stopPolling();
            fetchStatus();
            fetchTail();
            statusTimer = setInterval(fetchStatus, STATUS_POLL_MS);
            tailTimer = setInterval(fetchTail, TAIL_POLL_MS);
        }}

        function stopPolling() {{
            if (statusTimer) {{ clearInterval(statusTimer); statusTimer = null; }}
            if (tailTimer) {{ clearInterval(tailTimer); tailTimer = null; }}
        }}

        function handleSubmit(event) {{
            event.preventDefault();
            clearError();
            const path = enexInput.value.trim();
            if (!path) {{
                showError('{EVERNOTE_ERROR_NO_PATH}');
                return;
            }}
            submitBtn.disabled = true;
            submitBtn.textContent = '{EVERNOTE_BTN_STARTING}';
            fetch('/api/v1/import/evernote', {{
                method: 'POST',
                headers: {{'Content-Type': 'application/json'}},
                body: JSON.stringify({{enex_path: path}}),
            }})
                .then(function(r) {{
                    return r.json().then(function(body) {{ return [r.status, body]; }});
                }})
                .then(function(pair) {{
                    const status = pair[0], body = pair[1];
                    if (status === 200 && body.job_id) {{
                        currentJobId = body.job_id;
                        showJobPanel();
                        startPolling();
                    }} else {{
                        showError(body.error || ('Import failed to start (HTTP ' + status + ')'));
                    }}
                }})
                .catch(function(err) {{
                    showError('{EVERNOTE_ERROR_NETWORK_PREFIX}' + err);
                }})
                .finally(function() {{
                    submitBtn.disabled = false;
                    submitBtn.textContent = '{EVERNOTE_BTN_START}';
                }});
        }}

        function handleReset() {{
            stopPolling();
            currentJobId = null;
            clearError();
            resetRow.style.display = 'none';
            logPane.classList.add('empty');
            logPane.textContent = 'Waiting for first log output\\u2026';
            statusPill.textContent = '{EVERNOTE_PILL_STARTING}';
            statusPill.className = 'status-pill';
            statusMeta.textContent = '';
            showForm();
        }}

        importForm.addEventListener('submit', handleSubmit);
        resetBtn.addEventListener('click', handleReset);

        if (INITIAL_JOB_ID) {{
            // Reattach to an in-flight job whose POST was issued from
            // an earlier tab. The server discovered the live lockfile
            // and rendered the job_id into the page; we go straight to
            // the polling state without showing the form.
            currentJobId = INITIAL_JOB_ID;
            showJobPanel();
            startPolling();
        }} else {{
            showForm();
        }}
    }})();
    </script>
</body>
</html>"""


@app.get("/import-evernote", response_class=HTMLResponse)
async def import_evernote_page():
    """Render the Evernote import page. 404 when the feature flag is off."""
    from import_evernote import current_running_job_id, is_feature_enabled

    if not is_feature_enabled():
        return JSONResponse(
            {"error": "feature_disabled"}, status_code=404,
        )
    return HTMLResponse(_render_import_evernote_page(
        active_job_id=current_running_job_id(),
    ))


@app.post("/api/v1/import/evernote", response_class=JSONResponse)
async def api_import_evernote_start(request: Request):
    """Start a new Evernote import job.

    Body: ``{"enex_path": "/path/to/export.enex"}``. On success returns
    ``{"job_id": "...", "status": "started"}`` with 200. Validation
    failures surface as 400 / 404 / 409 / 500 per
    ``import_evernote.EvernoteImportError``. Returns 404
    ``{"error": "feature_disabled"}`` when the flag is off.
    """
    from import_evernote import (
        EvernoteImportError as _Err,
        is_feature_enabled as _flag,
        start_import as _start,
        validate_enex_path as _validate,
    )

    if not _flag():
        return JSONResponse(
            {"error": "feature_disabled"}, status_code=404,
        )

    try:
        body = await request.json()
    except Exception as exc:
        return JSONResponse(
            {"error": f"invalid JSON: {exc}"}, status_code=400,
        )

    if not isinstance(body, dict):
        return JSONResponse(
            {"error": "body must be a JSON object"}, status_code=400,
        )

    try:
        enex_path = _validate(body.get("enex_path"))
        result = _start(enex_path)
    except _Err as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)

    return JSONResponse(result, status_code=200)


@app.get("/api/v1/import/evernote/{job_id}/status", response_class=JSONResponse)
async def api_import_evernote_status(job_id: str):
    """Return the state of an Evernote import job."""
    from import_evernote import (
        EvernoteImportError as _Err,
        is_feature_enabled as _flag,
        read_status as _status,
    )

    if not _flag():
        return JSONResponse(
            {"error": "feature_disabled"}, status_code=404,
        )

    try:
        return JSONResponse(_status(job_id), status_code=200)
    except _Err as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)


@app.get("/api/v1/import/evernote/{job_id}/tail", response_class=PlainTextResponse)
async def api_import_evernote_tail(job_id: str):
    """Return the last 100 lines of the job's import log as text/plain."""
    from import_evernote import (
        EvernoteImportError as _Err,
        is_feature_enabled as _flag,
        read_tail as _tail,
    )

    if not _flag():
        return JSONResponse(
            {"error": "feature_disabled"}, status_code=404,
        )

    try:
        return PlainTextResponse(_tail(job_id), status_code=200)
    except _Err as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)


# ── Pair iOS device panel (DFA-002) ──────────────────────────────────


def _render_pair_ios_page() -> str:
    """Render the Pair iOS device panel.

    Vanilla HTML + JS, no framework. Matches Doctor's chassis tokens
    (Outfit / Plex Sans / Plex Mono, ostler-ink palette) so it sits
    visually next to ``/doctor`` rather than feeling bolted on.

    The QR image is rendered server-side as inline SVG and embedded in
    the API JSON; the client just sets ``innerHTML``. No external
    JavaScript libraries are loaded.
    """
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{PAIR_IOS_TITLE_TAG}</title>
    <style>
        /* PRIVACY: Google Fonts @import removed -- a local privacy-first product must not beacon the customer IP+timestamp to googleapis.com on every dashboard open. System-ui / -apple-system fallbacks below render cleanly. TODO(v1.0.1 privacy): self-host Outfit/IBM Plex via @font-face if branded type is wanted; do NOT re-add the googleapis @import. */
        :root {{
            --ostler-ink: #0d0b08;
            --ostler-ink-deep: #07060a;
            --ostler-panel: #1a1612;
            --ostler-panel-elev: #221c16;
            --ostler-chassis: #ECE8DD;
            --ostler-accent: #C84545;
            --ostler-accent-hover: #D76060;
            --ostler-accent-warm: #E26A6A;
            --ostler-accent-glow: rgba(200, 69, 69, 0.18);
            --ostler-hairline-soft: rgba(236, 232, 221, 0.16);
            --ostler-hairline-faint: rgba(236, 232, 221, 0.08);
            --text: var(--ostler-chassis);
            --text-secondary: rgba(236, 232, 221, 0.74);
            --text-muted: rgba(236, 232, 221, 0.50);
            --text-faint: rgba(236, 232, 221, 0.32);
            --red: #d96666;
            --shadow-soft: 0 1px 2px rgba(0,0,0,0.40), 0 4px 12px rgba(0,0,0,0.28);
            --font-display: 'Outfit', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-body: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-mono: 'IBM Plex Mono', 'SF Mono', Menlo, monospace;
        }}
        * {{ margin:0; padding:0; box-sizing:border-box; }}
        body {{
            font-family: var(--font-body);
            font-size: 15px;
            line-height: 1.5;
            background: var(--ostler-ink);
            color: var(--text);
            min-height: 100vh;
            padding: 2.5rem 1.75rem;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
        }}
        a {{ color: var(--ostler-accent); text-decoration: none; }}
        a:hover {{ color: var(--ostler-accent-hover); }}
        .container {{ max-width: 600px; margin: 0 auto; }}
        h1 {{
            font-family: var(--font-display);
            font-size: 1.7rem;
            font-weight: 600;
            letter-spacing: -0.02em;
            margin-bottom: 0.3rem;
        }}
        .subtitle {{
            font-family: var(--font-mono);
            font-size: 0.78rem;
            letter-spacing: 0.04em;
            color: var(--text-muted);
            margin-bottom: 2rem;
        }}
        .subtitle a {{ color: var(--text-muted); }}
        .subtitle a:hover {{ color: var(--ostler-accent-warm); text-decoration: underline; }}
        .section-title {{
            font-family: var(--font-display);
            font-size: 0.72rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            color: var(--text-muted);
            margin-bottom: 0.85rem;
            font-weight: 500;
        }}
        .panel {{
            background: var(--ostler-panel);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 12px;
            padding: 1.4rem 1.5rem;
            box-shadow: var(--shadow-soft);
            margin-bottom: 1.4rem;
        }}
        .panel p {{ color: var(--text-secondary); margin-bottom: 0.85rem; }}
        .help {{
            font-size: 0.82rem;
            color: var(--text-muted);
            margin-top: 0.55rem;
            line-height: 1.55;
        }}
        .qr-wrap {{
            display: flex;
            justify-content: center;
            margin: 0.6rem 0 0.4rem;
        }}
        .qr-frame {{
            background: var(--ostler-chassis);
            border-radius: 12px;
            padding: 1rem;
            box-shadow: var(--shadow-soft);
        }}
        .qr-frame svg {{
            display: block;
            width: 240px;
            height: 240px;
        }}
        .hub-addr {{
            font-family: var(--font-mono);
            font-size: 0.92rem;
            letter-spacing: 0.04em;
            color: var(--text-secondary);
            background: var(--ostler-ink-deep);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 8px;
            padding: 0.55rem 0.85rem;
            text-align: center;
            margin: 1rem 0 0.4rem;
            user-select: all;
            -webkit-user-select: all;
        }}
        .hub-addr-label {{
            font-family: var(--font-display);
            font-size: 0.7rem;
            text-transform: uppercase;
            letter-spacing: 0.16em;
            color: var(--text-muted);
            text-align: center;
            margin-top: 0.85rem;
        }}
        .camera-hint {{
            font-size: 0.82rem;
            color: var(--text-muted);
            text-align: center;
            line-height: 1.5;
            margin-top: 0.85rem;
        }}
        .empty-state-title {{
            font-family: var(--font-display);
            font-size: 1.05rem;
            font-weight: 600;
            margin-bottom: 0.55rem;
            color: var(--text);
        }}
        .button-row {{
            display: flex;
            gap: 0.6rem;
            align-items: center;
            margin-top: 1.1rem;
            flex-wrap: wrap;
        }}
        button.secondary {{
            font-family: var(--font-display);
            font-weight: 500;
            font-size: 0.85rem;
            padding: 0.65rem 1.4rem;
            border-radius: 999px;
            cursor: pointer;
            background: var(--ostler-panel);
            color: var(--text-secondary);
            border: 1px solid var(--ostler-hairline-soft);
            transition: background 0.18s, transform 0.18s, box-shadow 0.18s, border-color 0.18s, color 0.18s;
        }}
        button.secondary:hover {{
            border-color: var(--ostler-accent);
            color: var(--text);
            background: var(--ostler-panel-elev);
            transform: translateY(-1px);
        }}
        button.secondary:disabled {{
            background: var(--ostler-panel);
            color: var(--text-muted);
            cursor: not-allowed;
            transform: none;
            border-color: var(--ostler-hairline-faint);
        }}
        button:focus-visible {{
            outline: 2px solid var(--ostler-accent);
            outline-offset: 2px;
        }}
        .banner {{
            padding: 0.75rem 1rem;
            border-radius: 8px;
            font-size: 0.86rem;
            margin-bottom: 1.2rem;
            border-left: 3px solid var(--red);
            background: rgba(217, 102, 102, 0.10);
            color: var(--text);
            display: none;
        }}
        .banner.visible {{ display: block; }}
        .network-notice {{
            padding: 0.7rem 1rem;
            border-radius: 8px;
            font-size: 0.82rem;
            margin-bottom: 1.4rem;
            border-left: 3px solid #e0a437;
            background: rgba(224, 164, 55, 0.10);
            color: var(--text-secondary);
            line-height: 1.5;
        }}
        .meta-bottom {{
            font-family: var(--font-mono);
            font-size: 0.72rem;
            letter-spacing: 0.04em;
            color: var(--text-faint);
            margin-top: 2rem;
            padding-top: 1.1rem;
            border-top: 1px solid var(--ostler-hairline-faint);
            line-height: 1.55;
        }}
        @media (max-width: 720px) {{
            body {{ padding: 1.4rem 1rem; }}
            h1 {{ font-size: 1.4rem; }}
            .qr-frame svg {{ width: 200px; height: 200px; }}
            .hub-addr {{ font-size: 0.82rem; }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>{PAIR_IOS_HEADING}</h1>
        <div class="subtitle">
            {PAIR_IOS_SUBTITLE}
        </div>

        <div class="network-notice">{PAIR_IOS_NETWORK_BANNER_HTML}</div>

        <div id="errorBanner" class="banner"></div>

        <div id="codePanel" class="panel" style="display:none">
            <div class="section-title">{PAIR_IOS_SECTION_CODE}</div>
            <p>{PAIR_IOS_INTRO_HTML}</p>
            <div class="qr-wrap">
                <div class="qr-frame" id="qrFrame"></div>
            </div>
            <div class="camera-hint">{PAIR_IOS_CAMERA_HINT_HTML}</div>
            <div class="hub-addr-label">{PAIR_IOS_HUB_ADDR_LABEL}</div>
            <div class="hub-addr" id="hubAddr"></div>
            <div class="button-row">
                <button type="button" class="secondary" id="regenerateBtn">{PAIR_IOS_BTN_REGENERATE}</button>
            </div>
        </div>

        <div id="emptyPanel" class="panel" style="display:none">
            <div class="empty-state-title" id="emptyTitle"></div>
            <p id="emptyDetail"></p>
            <div class="button-row" id="emptyButtonRow" style="display:none">
                <button type="button" class="secondary" id="regenerateBtnEmpty">{PAIR_IOS_BTN_REGENERATE}</button>
            </div>
        </div>

        <div class="meta-bottom">
            {PAIR_IOS_META_FOOTER_HTML}
        </div>
    </div>

    <script>
    (function() {{
        const STATUS_POLL_MS = 15000;

        const codePanel = document.getElementById('codePanel');
        const emptyPanel = document.getElementById('emptyPanel');
        const qrFrame = document.getElementById('qrFrame');
        const hubAddrEl = document.getElementById('hubAddr');
        const emptyTitle = document.getElementById('emptyTitle');
        const emptyDetail = document.getElementById('emptyDetail');
        const emptyButtonRow = document.getElementById('emptyButtonRow');
        const regenerateBtn = document.getElementById('regenerateBtn');
        const regenerateBtnEmpty = document.getElementById('regenerateBtnEmpty');
        const errorBanner = document.getElementById('errorBanner');

        function showError(msg) {{
            errorBanner.textContent = msg;
            errorBanner.classList.add('visible');
        }}

        function clearError() {{
            errorBanner.classList.remove('visible');
            errorBanner.textContent = '';
        }}

        function showCode(state) {{
            emptyPanel.style.display = 'none';
            codePanel.style.display = '';
            qrFrame.innerHTML = state.qr_svg || '';
            hubAddrEl.textContent = state.hub_addr || '';
        }}

        function showEmpty(title, detail, withRegenerate) {{
            codePanel.style.display = 'none';
            emptyPanel.style.display = '';
            emptyTitle.innerHTML = title;
            emptyDetail.innerHTML = detail;
            emptyButtonRow.style.display = withRegenerate ? '' : 'none';
        }}

        function renderState(state) {{
            if (state.available && state.qr_svg) {{
                showCode(state);
                return;
            }}
            switch (state.error_kind) {{
                case 'pairing_disabled':
                    showEmpty(
                        '{PAIR_IOS_DISABLED_TITLE}',
                        '{PAIR_IOS_DISABLED_DETAIL}',
                        false
                    );
                    break;
                case 'no_code_active':
                    showEmpty(
                        '{PAIR_IOS_NO_CODE_TITLE}',
                        '{PAIR_IOS_NO_CODE_DETAIL}',
                        true
                    );
                    break;
                case 'qr_render_failed':
                    showEmpty(
                        '{PAIR_IOS_QR_RENDER_TITLE}',
                        '{PAIR_IOS_QR_RENDER_DETAIL}',
                        true
                    );
                    break;
                case 'gateway_envelope_invalid':
                    showEmpty(
                        '{PAIR_IOS_ENVELOPE_INVALID_TITLE}',
                        '{PAIR_IOS_ENVELOPE_INVALID_DETAIL}',
                        true
                    );
                    break;
                default:
                    // gateway_down / timeout / unreachable / http_error /
                    // malformed -- all surface the same friendly "Hub not
                    // ready yet" empty state.
                    showEmpty(
                        '{PAIR_IOS_EMPTY_TITLE}',
                        '{PAIR_IOS_EMPTY_DETAIL}',
                        false
                    );
            }}
        }}

        function fetchStatus() {{
            fetch('/api/v1/pair/status')
                .then(function(r) {{ return r.json(); }})
                .then(function(state) {{
                    clearError();
                    renderState(state);
                }})
                .catch(function(err) {{
                    showError('{PAIR_IOS_ERROR_NETWORK_PREFIX}' + err);
                }});
        }}

        function regenerate(btn) {{
            const originalLabel = btn.textContent;
            btn.disabled = true;
            btn.textContent = '{PAIR_IOS_BTN_REGENERATING}';
            fetch('/api/v1/pair/regenerate', {{method: 'POST'}})
                .then(function(r) {{ return r.json(); }})
                .then(function(state) {{
                    clearError();
                    renderState(state);
                }})
                .catch(function(err) {{
                    showError('{PAIR_IOS_ERROR_REGENERATE_PREFIX}' + err);
                }})
                .finally(function() {{
                    btn.disabled = false;
                    btn.textContent = originalLabel;
                }});
        }}

        regenerateBtn.addEventListener('click', function() {{ regenerate(regenerateBtn); }});
        regenerateBtnEmpty.addEventListener('click', function() {{ regenerate(regenerateBtnEmpty); }});

        fetchStatus();
        setInterval(fetchStatus, STATUS_POLL_MS);
    }})();
    </script>
</body>
</html>"""


@app.get("/pair-ios", response_class=HTMLResponse)
async def pair_ios_page():
    """Render the Pair iOS device panel (DFA-002)."""
    return HTMLResponse(_render_pair_ios_page())


@app.get("/api/v1/pair/status", response_class=JSONResponse)
async def api_pair_status():
    """Return the current pair code, QR SVG, and any error state."""
    from pair_status import fetch_pair_status
    return JSONResponse(fetch_pair_status().to_dict(), status_code=200)


@app.post("/api/v1/pair/regenerate", response_class=JSONResponse)
async def api_pair_regenerate(request: Request):
    """Rotate the pair code via the gateway and return the new shape.

    Cross-origin POSTs from a malicious local browser tab can DOS the
    pair code (rotate it under the customer's feet) even though the
    same-origin policy blocks the attacker from reading the new code.
    Modern browsers set ``Sec-Fetch-Site`` automatically; reject
    anything that is not ``same-origin`` or ``none`` (the latter
    covers direct navigation and bookmarks). Older browsers do not
    send the header; in that case the request is allowed through and
    the same-origin policy remains the defence-in-depth.
    """
    sec_fetch_site = request.headers.get("sec-fetch-site")
    if sec_fetch_site is not None and sec_fetch_site not in ("same-origin", "none"):
        return JSONResponse(
            {"error": "Cross-site request refused"},
            status_code=403,
        )
    from pair_status import fetch_pair_status
    return JSONResponse(
        fetch_pair_status(fresh=True).to_dict(), status_code=200,
    )


# ── Configuration panel (backlog #261) ───────────────────────────────
#
# A view-and-edit surface for the customer-safe Ostler settings file at
# ``~/.ostler/config/config.yaml``. Read-first: it always renders the
# current config; a small strict whitelist of fields (channel toggles,
# model, schedule times, privacy default) can be edited and written
# back. Secrets are never rendered -- secret-looking keys show
# "set"/"not set" only. See ``config_panel.py`` for the schema, the
# whitelist, validation, and the atomic write.


def _render_config_page() -> str:
    """Render the Doctor Configuration panel.

    Vanilla HTML + JS, no framework. Matches Doctor's chassis tokens
    (Outfit / Plex Sans / Plex Mono, ostler-ink palette) so it sits
    visually next to ``/doctor`` and ``/pair-ios``.

    The form is built client-side from the ``/api/v1/config`` view
    model, so the whitelist and current values live in one place
    (``config_panel.py``) and the page stays in sync automatically.
    """
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{CONFIG_TITLE_TAG}</title>
    <style>
        /* PRIVACY: Google Fonts @import removed -- a local privacy-first product must not beacon the customer IP+timestamp to googleapis.com on every dashboard open. System-ui / -apple-system fallbacks below render cleanly. TODO(v1.0.1 privacy): self-host Outfit/IBM Plex via @font-face if branded type is wanted; do NOT re-add the googleapis @import. */
        :root {{
            --ostler-ink: #0d0b08;
            --ostler-ink-deep: #07060a;
            --ostler-panel: #1a1612;
            --ostler-panel-elev: #221c16;
            --ostler-chassis: #ECE8DD;
            --ostler-accent: #C84545;
            --ostler-accent-hover: #D76060;
            --ostler-accent-warm: #E26A6A;
            --ostler-hairline-soft: rgba(236, 232, 221, 0.16);
            --ostler-hairline-faint: rgba(236, 232, 221, 0.08);
            --text: var(--ostler-chassis);
            --text-secondary: rgba(236, 232, 221, 0.74);
            --text-muted: rgba(236, 232, 221, 0.50);
            --text-faint: rgba(236, 232, 221, 0.32);
            --green: #5cb579;
            --red: #d96666;
            --shadow-soft: 0 1px 2px rgba(0,0,0,0.40), 0 4px 12px rgba(0,0,0,0.28);
            --font-display: 'Outfit', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-body: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            --font-mono: 'IBM Plex Mono', 'SF Mono', Menlo, monospace;
        }}
        * {{ margin:0; padding:0; box-sizing:border-box; }}
        body {{
            font-family: var(--font-body);
            font-size: 15px;
            line-height: 1.5;
            background: var(--ostler-ink);
            color: var(--text);
            min-height: 100vh;
            padding: 2.5rem 1.75rem;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
        }}
        a {{ color: var(--ostler-accent); text-decoration: none; }}
        a:hover {{ color: var(--ostler-accent-hover); }}
        .container {{ max-width: 640px; margin: 0 auto; }}
        h1 {{
            font-family: var(--font-display);
            font-size: 1.7rem;
            font-weight: 600;
            letter-spacing: -0.02em;
            margin-bottom: 0.3rem;
        }}
        .subtitle {{
            font-family: var(--font-mono);
            font-size: 0.78rem;
            letter-spacing: 0.04em;
            color: var(--text-muted);
            margin-bottom: 2rem;
        }}
        .subtitle a {{ color: var(--text-muted); }}
        .subtitle a:hover {{ color: var(--ostler-accent-warm); text-decoration: underline; }}
        .section-title {{
            font-family: var(--font-display);
            font-size: 0.72rem;
            text-transform: uppercase;
            letter-spacing: 0.18em;
            color: var(--text-muted);
            margin-bottom: 0.85rem;
            font-weight: 500;
        }}
        .panel {{
            background: var(--ostler-panel);
            border: 1px solid var(--ostler-hairline-faint);
            border-radius: 12px;
            padding: 1.4rem 1.5rem;
            box-shadow: var(--shadow-soft);
            margin-bottom: 1.4rem;
        }}
        .panel p {{ color: var(--text-secondary); margin-bottom: 0.85rem; }}
        .field {{
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 1rem;
            padding: 0.85rem 0;
            border-top: 1px solid var(--ostler-hairline-faint);
        }}
        .field:first-of-type {{ border-top: none; padding-top: 0.2rem; }}
        .field-text {{ flex: 1 1 auto; min-width: 0; }}
        .field-label {{
            font-family: var(--font-display);
            font-weight: 500;
            font-size: 0.95rem;
            color: var(--text);
        }}
        .field-help {{
            font-size: 0.8rem;
            color: var(--text-muted);
            margin-top: 0.2rem;
            line-height: 1.5;
        }}
        .field-control {{ flex: 0 0 auto; padding-top: 0.1rem; }}
        select {{
            font-family: var(--font-body);
            font-size: 0.88rem;
            color: var(--text);
            background: var(--ostler-ink-deep);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 8px;
            padding: 0.45rem 0.7rem;
            min-width: 9rem;
        }}
        input[type="time"] {{
            font-family: var(--font-mono);
            font-size: 0.88rem;
            color: var(--text);
            background: var(--ostler-ink-deep);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 8px;
            padding: 0.4rem 0.6rem;
            color-scheme: dark;
        }}
        select:focus, input:focus {{
            outline: none;
            border-color: var(--ostler-accent);
        }}
        /* Toggle switch */
        .toggle {{
            position: relative;
            display: inline-block;
            width: 44px;
            height: 26px;
        }}
        .toggle input {{ opacity: 0; width: 0; height: 0; }}
        .toggle .slider {{
            position: absolute;
            cursor: pointer;
            inset: 0;
            background: var(--ostler-ink-deep);
            border: 1px solid var(--ostler-hairline-soft);
            border-radius: 999px;
            transition: background 0.18s, border-color 0.18s;
        }}
        .toggle .slider::before {{
            content: "";
            position: absolute;
            height: 18px;
            width: 18px;
            left: 3px;
            top: 3px;
            background: var(--text-secondary);
            border-radius: 50%;
            transition: transform 0.18s, background 0.18s;
        }}
        .toggle input:checked + .slider {{
            background: var(--ostler-accent);
            border-color: var(--ostler-accent);
        }}
        .toggle input:checked + .slider::before {{
            transform: translateX(18px);
            background: var(--ostler-chassis);
        }}
        .toggle input:focus-visible + .slider {{
            outline: 2px solid var(--ostler-accent);
            outline-offset: 2px;
        }}
        .readonly-row {{
            display: flex;
            align-items: baseline;
            justify-content: space-between;
            gap: 1rem;
            padding: 0.5rem 0;
            border-top: 1px solid var(--ostler-hairline-faint);
            font-size: 0.86rem;
        }}
        .readonly-row:first-of-type {{ border-top: none; }}
        .readonly-key {{
            font-family: var(--font-mono);
            color: var(--text-secondary);
            word-break: break-all;
        }}
        .readonly-val {{
            font-family: var(--font-mono);
            color: var(--text-muted);
            text-align: right;
        }}
        .badge {{
            font-family: var(--font-display);
            font-size: 0.68rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            padding: 0.15rem 0.5rem;
            border-radius: 999px;
            border: 1px solid var(--ostler-hairline-soft);
            color: var(--text-muted);
        }}
        .badge.set {{ color: var(--green); border-color: rgba(92,181,121,0.4); }}
        .badge.secret {{ color: var(--text-faint); }}
        .button-row {{
            display: flex;
            gap: 0.6rem;
            align-items: center;
            margin-top: 1.1rem;
            flex-wrap: wrap;
        }}
        button.primary {{
            font-family: var(--font-display);
            font-weight: 500;
            font-size: 0.85rem;
            padding: 0.65rem 1.5rem;
            border-radius: 999px;
            cursor: pointer;
            background: var(--ostler-accent);
            color: var(--ostler-chassis);
            border: 1px solid var(--ostler-accent);
            transition: background 0.18s, transform 0.18s, box-shadow 0.18s;
        }}
        button.primary:hover {{
            background: var(--ostler-accent-hover);
            transform: translateY(-1px);
        }}
        button.primary:disabled {{
            background: var(--ostler-panel);
            color: var(--text-muted);
            border-color: var(--ostler-hairline-faint);
            cursor: not-allowed;
            transform: none;
        }}
        button:focus-visible {{
            outline: 2px solid var(--ostler-accent);
            outline-offset: 2px;
        }}
        .config-path {{
            font-family: var(--font-mono);
            font-size: 0.78rem;
            color: var(--text-faint);
        }}
        .banner {{
            padding: 0.75rem 1rem;
            border-radius: 8px;
            font-size: 0.86rem;
            margin-bottom: 1.2rem;
            border-left: 3px solid var(--red);
            background: rgba(217, 102, 102, 0.10);
            color: var(--text);
            display: none;
        }}
        .banner.visible {{ display: block; }}
        .banner.ok {{
            border-left-color: var(--green);
            background: rgba(92, 181, 121, 0.10);
        }}
        .empty {{ color: var(--text-muted); font-size: 0.86rem; }}
        .meta-bottom {{
            font-family: var(--font-mono);
            font-size: 0.72rem;
            letter-spacing: 0.04em;
            color: var(--text-faint);
            margin-top: 2rem;
            padding-top: 1.1rem;
            border-top: 1px solid var(--ostler-hairline-faint);
            line-height: 1.55;
        }}
        @media (max-width: 720px) {{
            body {{ padding: 1.4rem 1rem; }}
            h1 {{ font-size: 1.4rem; }}
            .field {{ flex-direction: column; }}
            .field-control {{ align-self: flex-start; }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>{CONFIG_HEADING}</h1>
        <div class="subtitle">
            {CONFIG_SUBTITLE}
        </div>

        <div id="statusBanner" class="banner"></div>

        <div class="panel" id="processingPanel">
            <div class="section-title">Processing</div>
            <p id="pauseState" style="margin-bottom:0.9rem">Loading&hellip;</p>
            <div class="button-row" id="pauseButtons" style="flex-wrap:wrap;gap:0.5rem">
                <button type="button" id="pauseHour">Pause 1 hour</button>
                <button type="button" id="pauseTonight">Pause until tonight</button>
                <button type="button" id="pauseIndef">Pause until I resume</button>
                <button type="button" class="primary" id="resumeBtn" style="display:none">Resume now</button>
            </div>
            <p id="governorState" style="margin-top:1rem;color:var(--text-muted);font-size:0.86rem"></p>
        </div>

        <div id="editPanels"></div>

        <div id="readonlyPanel" class="panel" style="display:none">
            <div class="section-title">{CONFIG_SECTION_READONLY}</div>
            <p>{CONFIG_READONLY_INTRO}</p>
            <div id="readonlyRows"></div>
        </div>

        <div class="button-row">
            <button type="button" class="primary" id="saveBtn">{CONFIG_BTN_SAVE}</button>
            <span class="config-path" id="configPath"></span>
        </div>

        <div class="meta-bottom">
            {CONFIG_META_FOOTER}
        </div>
    </div>

    <script>
    (function() {{
        const editPanels = document.getElementById('editPanels');
        const readonlyPanel = document.getElementById('readonlyPanel');
        const readonlyRows = document.getElementById('readonlyRows');
        const saveBtn = document.getElementById('saveBtn');
        const statusBanner = document.getElementById('statusBanner');
        const configPathEl = document.getElementById('configPath');

        const SECTION_ORDER = {json.dumps(list(_config_section_order()))};

        function showStatus(msg, ok) {{
            statusBanner.textContent = msg;
            statusBanner.className = 'banner visible' + (ok ? ' ok' : '');
        }}
        function clearStatus() {{
            statusBanner.className = 'banner';
            statusBanner.textContent = '';
        }}

        function esc(s) {{
            const d = document.createElement('div');
            d.textContent = s == null ? '' : String(s);
            return d.innerHTML;
        }}

        function controlFor(field) {{
            const id = 'cfg_' + field.key;
            if (field.kind === 'bool') {{
                const checked = field.value === true ? ' checked' : '';
                return '<label class="toggle"><input type="checkbox" id="' + id +
                    '" data-key="' + esc(field.key) + '" data-kind="bool"' + checked +
                    '><span class="slider"></span></label>';
            }}
            if (field.kind === 'enum') {{
                let opts = '';
                if (field.value == null) {{
                    opts += '<option value="" selected>{CONFIG_OPT_UNSET}</option>';
                }}
                field.choices.forEach(function(c) {{
                    const sel = (c === field.value) ? ' selected' : '';
                    opts += '<option value="' + esc(c) + '"' + sel + '>' + esc(c) + '</option>';
                }});
                return '<select id="' + id + '" data-key="' + esc(field.key) +
                    '" data-kind="enum">' + opts + '</select>';
            }}
            if (field.kind === 'time') {{
                const v = field.value == null ? '' : esc(field.value);
                return '<input type="time" id="' + id + '" data-key="' + esc(field.key) +
                    '" data-kind="time" value="' + v + '">';
            }}
            return '';
        }}

        function renderEdit(view) {{
            editPanels.innerHTML = '';
            const bySection = {{}};
            view.editable.forEach(function(f) {{
                (bySection[f.section] = bySection[f.section] || []).push(f);
            }});
            SECTION_ORDER.forEach(function(section) {{
                const fields = bySection[section];
                if (!fields || !fields.length) return;
                let rows = '';
                fields.forEach(function(f) {{
                    rows += '<div class="field"><div class="field-text">' +
                        '<div class="field-label">' + esc(f.label) + '</div>' +
                        '<div class="field-help">' + esc(f.help) + '</div></div>' +
                        '<div class="field-control">' + controlFor(f) + '</div></div>';
                }});
                editPanels.insertAdjacentHTML('beforeend',
                    '<div class="panel"><div class="section-title">' + esc(section) +
                    '</div>' + rows + '</div>');
            }});
        }}

        function renderReadonly(view) {{
            if (!view.read_only || !view.read_only.length) {{
                readonlyPanel.style.display = 'none';
                return;
            }}
            readonlyPanel.style.display = '';
            let rows = '';
            view.read_only.forEach(function(r) {{
                let right;
                if (r.is_secret) {{
                    const cls = r.is_set ? 'badge set secret' : 'badge secret';
                    right = '<span class="' + cls + '">' +
                        (r.is_set ? '{CONFIG_SECRET_SET}' : '{CONFIG_SECRET_UNSET}') + '</span>';
                }} else {{
                    right = '<span class="readonly-val">' + esc(r.value) + '</span>';
                }}
                rows += '<div class="readonly-row"><span class="readonly-key">' +
                    esc(r.key) + '</span>' + right + '</div>';
            }});
            readonlyRows.innerHTML = rows;
        }}

        function render(view) {{
            renderEdit(view);
            renderReadonly(view);
            configPathEl.textContent = view.config_path || '';
        }}

        function load() {{
            fetch('/api/v1/config')
                .then(function(r) {{ return r.json(); }})
                .then(function(view) {{
                    if (view.error) {{ showStatus(view.error, false); return; }}
                    clearStatus();
                    render(view);
                }})
                .catch(function(err) {{
                    showStatus('{CONFIG_ERR_LOAD_PREFIX}' + err, false);
                }});
        }}

        function collectUpdates() {{
            const updates = {{}};
            const controls = editPanels.querySelectorAll('[data-key]');
            controls.forEach(function(el) {{
                const key = el.getAttribute('data-key');
                const kind = el.getAttribute('data-kind');
                if (kind === 'bool') {{
                    updates[key] = el.checked;
                }} else {{
                    const v = el.value;
                    if (v !== '') updates[key] = v;
                }}
            }});
            return updates;
        }}

        function save() {{
            const updates = collectUpdates();
            const label = saveBtn.textContent;
            saveBtn.disabled = true;
            saveBtn.textContent = '{CONFIG_BTN_SAVING}';
            fetch('/api/v1/config', {{
                method: 'POST',
                headers: {{'Content-Type': 'application/json'}},
                body: JSON.stringify(updates)
            }})
                .then(function(r) {{ return r.json().then(function(b) {{ return {{ok: r.ok, body: b}}; }}); }})
                .then(function(res) {{
                    if (!res.ok) {{
                        showStatus(res.body.error || '{CONFIG_ERR_SAVE_GENERIC}', false);
                        return;
                    }}
                    render(res.body);
                    showStatus('{CONFIG_SAVED}', true);
                }})
                .catch(function(err) {{
                    showStatus('{CONFIG_ERR_SAVE_PREFIX}' + err, false);
                }})
                .finally(function() {{
                    saveBtn.disabled = false;
                    saveBtn.textContent = label;
                }});
        }}

        // --- Pause + governor controls (resource throttle) ----------
        const pauseStateEl = document.getElementById('pauseState');
        const governorStateEl = document.getElementById('governorState');
        const resumeBtn = document.getElementById('resumeBtn');
        const pauseHourBtn = document.getElementById('pauseHour');
        const pauseTonightBtn = document.getElementById('pauseTonight');
        const pauseIndefBtn = document.getElementById('pauseIndef');

        function renderPause(state) {{
            const paused = state && state.paused;
            resumeBtn.style.display = paused ? '' : 'none';
            pauseHourBtn.style.display = paused ? 'none' : '';
            pauseTonightBtn.style.display = paused ? 'none' : '';
            pauseIndefBtn.style.display = paused ? 'none' : '';
            if (!paused) {{
                pauseStateEl.textContent =
                    'Background processing is running. Pause it any time.';
                return;
            }}
            if (state.indefinite) {{
                pauseStateEl.textContent =
                    'Paused until you resume. Live chat is unaffected.';
            }} else {{
                pauseStateEl.textContent =
                    'Paused until ' + (state.expiry_human || 'later') +
                    '. Live chat is unaffected.';
            }}
        }}

        function loadPause() {{
            fetch('/api/v1/pause')
                .then(function(r) {{ return r.json(); }})
                .then(function(s) {{ if (!s.error) renderPause(s); }})
                .catch(function() {{}});
        }}

        function doPause(scope) {{
            fetch('/api/v1/pause', {{
                method: 'POST',
                headers: {{'Content-Type': 'application/json'}},
                body: JSON.stringify({{scope: scope}})
            }})
                .then(function(r) {{ return r.json(); }})
                .then(function(s) {{
                    if (s.error) {{ showStatus(s.error, false); return; }}
                    renderPause(s);
                    showStatus('Background processing paused.', true);
                }})
                .catch(function(err) {{ showStatus('Pause failed: ' + err, false); }});
        }}

        function doResume() {{
            fetch('/api/v1/resume', {{method: 'POST'}})
                .then(function(r) {{ return r.json(); }})
                .then(function(s) {{
                    if (s.error) {{ showStatus(s.error, false); return; }}
                    renderPause(s);
                    showStatus('Background processing resumed.', true);
                }})
                .catch(function(err) {{ showStatus('Resume failed: ' + err, false); }});
        }}

        pauseHourBtn.addEventListener('click', function() {{ doPause('hour'); }});
        pauseTonightBtn.addEventListener('click', function() {{ doPause('tonight'); }});
        pauseIndefBtn.addEventListener('click', function() {{ doPause('indefinite'); }});
        resumeBtn.addEventListener('click', doResume);

        function loadGovernor() {{
            fetch('/api/v1/governor-status')
                .then(function(r) {{ return r.json(); }})
                .then(function(g) {{
                    if (!g || g.error) {{ governorStateEl.textContent = ''; return; }}
                    if (!g.enabled) {{
                        governorStateEl.textContent =
                            'Auto ease-off is OFF. Background work runs regardless of load.';
                        return;
                    }}
                    let msg = 'Hardware tier: ' + (g.tier || 'unknown') + '. ';
                    msg += g.deferring
                        ? 'Easing off now (your Mac is busy).'
                        : 'Catching up (load is below the ceiling).';
                    governorStateEl.textContent = msg;
                }})
                .catch(function() {{ governorStateEl.textContent = ''; }});
        }}

        saveBtn.addEventListener('click', save);
        load();
        loadPause();
        loadGovernor();
    }})();
    </script>
</body>
</html>"""


@app.get("/config", response_class=HTMLResponse)
async def config_page():
    """Render the Doctor Configuration panel (backlog #261)."""
    return HTMLResponse(_render_config_page())


@app.get("/api/v1/config", response_class=JSONResponse)
async def api_config_get():
    """Return the current config view model.

    Secrets are never included as values: secret-looking keys are
    reported presence-only (set / not set). See ``config_panel.py``.
    """
    from config_panel import ConfigError as _ConfigError, read_config_view

    try:
        return JSONResponse(read_config_view(), status_code=200)
    except _ConfigError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)


@app.post("/api/v1/config", response_class=JSONResponse)
async def api_config_post(request: Request):
    """Validate + persist a whitelist of safe config edits.

    Same cross-site guard as the pair-regenerate route: reject any POST
    whose ``Sec-Fetch-Site`` is present and not same-origin, so a
    malicious local tab cannot mutate the customer's config under them.
    Only whitelisted, non-secret fields are writable; everything else is
    rejected by ``config_panel.write_config``.
    """
    sec_fetch_site = request.headers.get("sec-fetch-site")
    if sec_fetch_site is not None and sec_fetch_site not in ("same-origin", "none"):
        return JSONResponse(
            {"error": "Cross-site request refused"},
            status_code=403,
        )

    from config_panel import ConfigError as _ConfigError, write_config

    try:
        body = await request.json()
    except Exception as exc:
        return JSONResponse(
            {"error": f"invalid JSON: {exc}"}, status_code=400,
        )

    try:
        view = write_config(body)
    except _ConfigError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)

    return JSONResponse(view, status_code=200)


# ── Pause control + governor status (resource throttle) ──────────────
#
# Pause stops all BACKGROUND processing (the five tick wrappers + the
# wiki recompile) via a sentinel file the wrappers honour. Live chat and
# the assistant daemon's foreground turns are never paused. Governor
# status surfaces the existing adaptive resource governor's live tier +
# whether it is currently deferring. See ``pause_control.py``.


@app.get("/api/v1/pause", response_class=JSONResponse)
async def api_pause_get():
    """Return the current pause state (self-heals an expired sentinel)."""
    from pause_control import PauseError as _PauseError, read_state

    try:
        return JSONResponse(read_state(), status_code=200)
    except _PauseError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)


@app.post("/api/v1/pause", response_class=JSONResponse)
async def api_pause_post(request: Request):
    """Pause background processing for a scope (hour / tonight / indefinite)."""
    sec_fetch_site = request.headers.get("sec-fetch-site")
    if sec_fetch_site is not None and sec_fetch_site not in ("same-origin", "none"):
        return JSONResponse(
            {"error": "Cross-site request refused"}, status_code=403,
        )

    from pause_control import PauseError as _PauseError, write_pause

    try:
        body = await request.json()
    except Exception as exc:
        return JSONResponse({"error": f"invalid JSON: {exc}"}, status_code=400)

    scope = body.get("scope") if isinstance(body, dict) else None
    if not scope:
        return JSONResponse({"error": "scope is required"}, status_code=400)

    try:
        return JSONResponse(write_pause(scope), status_code=200)
    except _PauseError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)


@app.post("/api/v1/resume", response_class=JSONResponse)
async def api_resume_post(request: Request):
    """Resume background processing (delete the pause sentinel)."""
    sec_fetch_site = request.headers.get("sec-fetch-site")
    if sec_fetch_site is not None and sec_fetch_site not in ("same-origin", "none"):
        return JSONResponse(
            {"error": "Cross-site request refused"}, status_code=403,
        )

    from pause_control import PauseError as _PauseError, clear_pause

    try:
        return JSONResponse(clear_pause(), status_code=200)
    except _PauseError as exc:
        return JSONResponse({"error": exc.detail}, status_code=exc.status)


@app.get("/api/v1/governor-status", response_class=JSONResponse)
async def api_governor_status():
    """Report the adaptive governor's live tier + whether it is deferring.

    Best-effort: shells the resource-tier lib that the wrappers source.
    Any failure degrades to a minimal "unknown" payload so the panel
    never errors.
    """
    import subprocess

    # Governor on/off comes from the customer's config (defaults ON).
    enabled = True
    try:
        from config_panel import _load_raw  # type: ignore

        raw = _load_raw()
        if raw.get("governor_enabled") is False:
            enabled = False
    except Exception:
        pass

    lib = os.environ.get(
        "OSTLER_RESOURCE_TIER_LIB",
        str(Path.home() / ".ostler" / "lib" / "ostler-resource-tier.sh"),
    )
    tier = None
    deferring = None
    if os.path.isfile(lib):
        script = (
            f'. "{lib}"; ostler_resource_tier_detect; '
            'printf "%s\\n" "$OSTLER_TIER"; '
            'if ostler_resource_tier_should_defer_nonessential; '
            'then echo defer; else echo run; fi'
        )
        try:
            out = subprocess.run(
                ["bash", "-c", script],
                capture_output=True, text=True, timeout=5,
            )
            lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
            if lines:
                tier = lines[0]
            if len(lines) > 1:
                deferring = lines[1] == "defer"
        except Exception:
            pass

    return JSONResponse(
        {"enabled": enabled, "tier": tier, "deferring": deferring},
        status_code=200,
    )


# ── Main ─────────────────────────────────────────────────────────────


if __name__ == "__main__":
    import uvicorn
    # DOCTOR_PORT is the canonical name; DIAGNOSTIC_PORT kept for backwards
    # compatibility with existing launchd plists during the rename.
    port = int(os.getenv("DOCTOR_PORT", os.getenv("DIAGNOSTIC_PORT", "8089")))
    print(CONSOLE_RUNNING_FMT.format(port=port))
    uvicorn.run(app, host="127.0.0.1", port=port)
