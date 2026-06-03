"""
Ostler Doctor – Diagnostic Rules Engine

Comprehensive set of diagnostic rules that run locally without any
cloud LLM. These cover the most common failure modes beta testers
will encounter during install and daily use.

Each rule is a function that takes a SystemSnapshot and returns
a list of findings (or empty list if the rule passes).

Rules are organised by category:
- Installation checks (first-time setup issues)
- Runtime checks (ongoing health)
- Performance checks (degradation)
- Configuration checks (misconfig)
- Upgrade checks (version advisories)
"""

from __future__ import annotations

import time
from typing import Any

from banner_copy import EMPTY_MAIL_NUDGE, backfill_progress
from diagnostic_copy import (
    ALL_UNREACHABLE_DETAIL,
    ALL_UNREACHABLE_FIX,
    ALL_UNREACHABLE_FIX_COMMAND,
    ALL_UNREACHABLE_TITLE,
    CANNOT_REACH_DETAIL_FMT,
    CANNOT_REACH_FIX_COMMAND_FMT,
    CANNOT_REACH_FIX_FMT,
    CANNOT_REACH_TITLE_FMT,
    CONTAINERS_NOT_CREATED_DETAIL,
    CONTAINERS_NOT_CREATED_FIX,
    CONTAINERS_NOT_CREATED_FIX_COMMAND,
    CONTAINERS_NOT_CREATED_TITLE,
    CONTAINER_CRASHED_DETAIL_FMT,
    CONTAINER_CRASHED_FIX,
    CONTAINER_CRASHED_FIX_COMMAND_FMT,
    CONTAINER_CRASHED_TITLE_FMT,
    CONTAINER_NEVER_STARTED_DETAIL,
    CONTAINER_NEVER_STARTED_FIX,
    CONTAINER_NEVER_STARTED_FIX_COMMAND_FMT,
    CONTAINER_NEVER_STARTED_TITLE_FMT,
    CONTAINER_RESTARTING_DETAIL_FMT,
    CONTAINER_RESTARTING_FIX,
    CONTAINER_RESTARTING_FIX_COMMAND_FMT,
    CONTAINER_RESTARTING_TITLE_FMT,
    CRITICAL_DISK_DETAIL,
    CRITICAL_DISK_FIX,
    CRITICAL_DISK_FIX_COMMAND,
    CRITICAL_DISK_TITLE_FMT,
    CRITICAL_MEMORY_DETAIL_FMT,
    CRITICAL_MEMORY_FIX,
    CRITICAL_MEMORY_FIX_COMMAND,
    CRITICAL_MEMORY_TITLE_FMT,
    DOCKER_NOT_INSTALLED_DETAIL,
    DOCKER_NOT_INSTALLED_FIX,
    DOCKER_NOT_INSTALLED_FIX_COMMAND,
    DOCKER_NOT_INSTALLED_TITLE,
    GATEWAY_BAD_GATEWAY_DETAIL,
    GATEWAY_BAD_GATEWAY_FIX,
    GATEWAY_BAD_GATEWAY_FIX_COMMAND,
    GATEWAY_BAD_GATEWAY_TITLE_FMT,
    GATEWAY_UNREACHABLE_DETAIL,
    GATEWAY_UNREACHABLE_FIX,
    GATEWAY_UNREACHABLE_FIX_COMMAND,
    GATEWAY_UNREACHABLE_TITLE,
    HIGH_CPU_DETAIL,
    HIGH_CPU_FIX,
    HIGH_CPU_FIX_COMMAND_FMT,
    HIGH_CPU_TITLE_FMT,
    HIGH_MEMORY_DETAIL_FMT,
    HIGH_MEMORY_FIX,
    HIGH_MEMORY_FIX_COMMAND,
    HIGH_MEMORY_TITLE_FMT,
    HIGH_MEM_CONTAINER_DETAIL,
    HIGH_MEM_CONTAINER_FIX,
    HIGH_MEM_CONTAINER_FIX_COMMAND_FMT,
    HIGH_MEM_CONTAINER_TITLE_FMT,
    IMPORT_BLOCKED_EMBED_DETAIL,
    IMPORT_BLOCKED_EMBED_FIX,
    IMPORT_BLOCKED_EMBED_FIX_COMMAND,
    IMPORT_BLOCKED_EMBED_TITLE,
    IMPORT_BLOCKED_SERVICES_DETAIL_FMT,
    IMPORT_BLOCKED_SERVICES_FIX,
    IMPORT_BLOCKED_SERVICES_FIX_COMMAND,
    IMPORT_BLOCKED_SERVICES_TITLE_FMT,
    IMPORT_READY_DETAIL,
    IMPORT_READY_FIX_COMMAND,
    IMPORT_READY_TITLE,
    LOW_RAM_DETAIL,
    LOW_RAM_TITLE_FMT,
    MANY_MODELS_DETAIL,
    MANY_MODELS_FIX,
    MANY_MODELS_FIX_COMMAND,
    MANY_MODELS_TITLE_FMT,
    MODEL_TOO_LARGE_DETAIL_FMT,
    MODEL_TOO_LARGE_FIX,
    MODEL_TOO_LARGE_FIX_COMMAND_FMT,
    MODEL_TOO_LARGE_TITLE_FMT,
    NO_CHAT_MODEL_DETAIL,
    NO_CHAT_MODEL_FIX,
    NO_CHAT_MODEL_FIX_COMMAND,
    NO_CHAT_MODEL_TITLE,
    NO_EMBED_MODEL_DETAIL,
    NO_EMBED_MODEL_FIX,
    NO_EMBED_MODEL_FIX_COMMAND,
    NO_EMBED_MODEL_TITLE,
    NO_INTER_SERVICE_DETAIL,
    NO_INTER_SERVICE_FIX,
    NO_INTER_SERVICE_FIX_COMMAND,
    NO_INTER_SERVICE_TITLE,
    NO_OLLAMA_MODELS_DETAIL,
    NO_OLLAMA_MODELS_FIX,
    NO_OLLAMA_MODELS_FIX_COMMAND,
    NO_OLLAMA_MODELS_TITLE,
    OLLAMA_NOT_INSTALLED_DETAIL,
    OLLAMA_NOT_INSTALLED_FIX,
    OLLAMA_NOT_INSTALLED_FIX_COMMAND,
    OLLAMA_NOT_INSTALLED_TITLE,
    OLLAMA_OLD_DETAIL,
    OLLAMA_OLD_FIX,
    OLLAMA_OLD_FIX_COMMAND,
    OLLAMA_OLD_TITLE_FMT,
    OXIGRAPH_INTERNAL_ERROR_DETAIL,
    OXIGRAPH_INTERNAL_ERROR_FIX,
    OXIGRAPH_INTERNAL_ERROR_FIX_COMMAND_FMT,
    OXIGRAPH_INTERNAL_ERROR_TITLE,
    QDRANT_OVERLOADED_DETAIL,
    QDRANT_OVERLOADED_FIX,
    QDRANT_OVERLOADED_FIX_COMMAND_FMT,
    QDRANT_OVERLOADED_TITLE,
    REDIS_UNREACHABLE_DETAIL,
    REDIS_UNREACHABLE_FIX,
    REDIS_UNREACHABLE_FIX_COMMAND_FMT,
    REDIS_UNREACHABLE_TITLE,
    STALE_IMPORT_DETAIL,
    STALE_IMPORT_FIX,
    STALE_IMPORT_FIX_COMMAND,
    STALE_IMPORT_TITLE_FMT,
)
from status_collector import (
    detect_ostler_prefix,
    is_ostler_container,
)


def check_first_install(snapshot: Any) -> list[dict]:
    """Detect common first-install problems."""
    findings = []

    # No Docker at all
    if snapshot.docker_version is None and not snapshot.docker_containers:
        findings.append({
            "severity": "critical",
            "title": DOCKER_NOT_INSTALLED_TITLE,
            "detail": DOCKER_NOT_INSTALLED_DETAIL,
            "fix": DOCKER_NOT_INSTALLED_FIX,
            "fix_command": DOCKER_NOT_INSTALLED_FIX_COMMAND,
            "risk": "low",
            "category": "installation",
        })

    # Docker installed but no Ostler containers (never ran docker compose)
    if snapshot.docker_version and not any(
        is_ostler_container(c) for c in snapshot.docker_containers
    ):
        findings.append({
            "severity": "warning",
            "title": CONTAINERS_NOT_CREATED_TITLE,
            "detail": CONTAINERS_NOT_CREATED_DETAIL,
            "fix": CONTAINERS_NOT_CREATED_FIX,
            "fix_command": CONTAINERS_NOT_CREATED_FIX_COMMAND,
            "risk": "low",
            "category": "installation",
        })

    # Ollama not installed
    if snapshot.ollama_version is None and not snapshot.ollama_models:
        findings.append({
            "severity": "critical",
            "title": OLLAMA_NOT_INSTALLED_TITLE,
            "detail": OLLAMA_NOT_INSTALLED_DETAIL,
            "fix": OLLAMA_NOT_INSTALLED_FIX,
            "fix_command": OLLAMA_NOT_INSTALLED_FIX_COMMAND,
            "risk": "low",
            "category": "installation",
        })

    # No .env file (config missing)
    # We can't check files directly, but we can infer from missing services
    all_unreachable = all(s.status == "unreachable" for s in snapshot.services)
    if all_unreachable and snapshot.docker_containers:
        findings.append({
            "severity": "warning",
            "title": ALL_UNREACHABLE_TITLE,
            "detail": ALL_UNREACHABLE_DETAIL,
            "fix": ALL_UNREACHABLE_FIX,
            "fix_command": ALL_UNREACHABLE_FIX_COMMAND,
            "risk": "low",
            "category": "installation",
        })

    return findings


def check_container_health(snapshot: Any) -> list[dict]:
    """Detect container-level issues."""
    findings = []

    for c in snapshot.docker_containers:
        # Container restarting (crash loop)
        if "Restarting" in c.status:
            findings.append({
                "severity": "critical",
                "title": CONTAINER_RESTARTING_TITLE_FMT.format(name=c.name),
                "detail": CONTAINER_RESTARTING_DETAIL_FMT.format(status=c.status),
                "fix": CONTAINER_RESTARTING_FIX,
                "fix_command": CONTAINER_RESTARTING_FIX_COMMAND_FMT.format(name=c.name),
                "risk": "low",
                "category": "runtime",
            })

        # Container created but never started
        if c.state == "created":
            findings.append({
                "severity": "warning",
                "title": CONTAINER_NEVER_STARTED_TITLE_FMT.format(name=c.name),
                "detail": CONTAINER_NEVER_STARTED_DETAIL,
                "fix": CONTAINER_NEVER_STARTED_FIX,
                "fix_command": CONTAINER_NEVER_STARTED_FIX_COMMAND_FMT.format(name=c.name),
                "risk": "low",
                "category": "runtime",
            })

        # Container exited with non-zero exit code
        if c.state == "exited" and "Exited (0)" not in c.status:
            findings.append({
                "severity": "critical",
                "title": CONTAINER_CRASHED_TITLE_FMT.format(name=c.name),
                "detail": CONTAINER_CRASHED_DETAIL_FMT.format(status=c.status),
                "fix": CONTAINER_CRASHED_FIX,
                "fix_command": CONTAINER_CRASHED_FIX_COMMAND_FMT.format(name=c.name),
                "risk": "low",
                "category": "runtime",
            })

    return findings


def check_qdrant_health(snapshot: Any) -> list[dict]:
    """Qdrant-specific checks."""
    findings = []
    prefix = detect_ostler_prefix(snapshot)

    qdrant_svc = next((s for s in snapshot.services if s.name == "qdrant"), None)
    if not qdrant_svc:
        return findings

    if qdrant_svc.status == "healthy" and qdrant_svc.status_code == 200:
        # Qdrant is healthy – check for common issues
        pass

    if qdrant_svc.status_code == 503:
        findings.append({
            "severity": "critical",
            "title": QDRANT_OVERLOADED_TITLE,
            "detail": QDRANT_OVERLOADED_DETAIL,
            "fix": QDRANT_OVERLOADED_FIX,
            "fix_command": QDRANT_OVERLOADED_FIX_COMMAND_FMT.format(prefix=prefix),
            "risk": "low",
            "category": "runtime",
        })

    return findings


def check_oxigraph_health(snapshot: Any) -> list[dict]:
    """Oxigraph-specific checks."""
    findings = []
    prefix = detect_ostler_prefix(snapshot)

    oxigraph_svc = next((s for s in snapshot.services if s.name == "oxigraph"), None)
    if not oxigraph_svc:
        return findings

    if oxigraph_svc.status_code == 500:
        findings.append({
            "severity": "critical",
            "title": OXIGRAPH_INTERNAL_ERROR_TITLE,
            "detail": OXIGRAPH_INTERNAL_ERROR_DETAIL,
            "fix": OXIGRAPH_INTERNAL_ERROR_FIX,
            "fix_command": OXIGRAPH_INTERNAL_ERROR_FIX_COMMAND_FMT.format(prefix=prefix),
            "risk": "low",
            "category": "runtime",
        })

    return findings


def check_import_readiness(snapshot: Any) -> list[dict]:
    """Check whether the system is ready to run the import pipeline."""
    findings = []

    required_services = {"qdrant", "oxigraph", "ollama"}
    healthy_services = {s.name for s in snapshot.services if s.status == "healthy"}
    missing = required_services - healthy_services

    has_embed_model = any(
        "nomic-embed" in m.name for m in snapshot.ollama_models
    )

    if missing:
        missing_str = ", ".join(missing)
        findings.append({
            "severity": "warning",
            "title": IMPORT_BLOCKED_SERVICES_TITLE_FMT.format(missing=missing_str),
            "detail": IMPORT_BLOCKED_SERVICES_DETAIL_FMT.format(missing=missing_str),
            "fix": IMPORT_BLOCKED_SERVICES_FIX,
            "fix_command": IMPORT_BLOCKED_SERVICES_FIX_COMMAND,
            "risk": "low",
            "category": "configuration",
        })
    elif not has_embed_model:
        findings.append({
            "severity": "warning",
            "title": IMPORT_BLOCKED_EMBED_TITLE,
            "detail": IMPORT_BLOCKED_EMBED_DETAIL,
            "fix": IMPORT_BLOCKED_EMBED_FIX,
            "fix_command": IMPORT_BLOCKED_EMBED_FIX_COMMAND,
            "risk": "low",
            "category": "configuration",
        })
    elif not missing and has_embed_model:
        findings.append({
            "severity": "info",
            "title": IMPORT_READY_TITLE,
            "detail": IMPORT_READY_DETAIL,
            "fix": None,
            "fix_command": IMPORT_READY_FIX_COMMAND,
            "risk": "low",
            "category": "configuration",
        })

    return findings


def check_performance(snapshot: Any) -> list[dict]:
    """Detect performance degradation patterns."""
    findings = []

    # High disk usage on root
    root_disk = next(
        (d for d in snapshot.disk_usage if d.mount_point == "/"),
        None,
    )
    if root_disk and root_disk.free_gb < 10:
        findings.append({
            "severity": "critical",
            "title": CRITICAL_DISK_TITLE_FMT.format(free_gb=root_disk.free_gb),
            "detail": CRITICAL_DISK_DETAIL,
            "fix": CRITICAL_DISK_FIX,
            "fix_command": CRITICAL_DISK_FIX_COMMAND,
            "risk": "medium",
            "category": "performance",
        })

    # Many Ollama models wasting space
    if len(snapshot.ollama_models) > 8:
        total_gb = sum(m.size_gb or 0 for m in snapshot.ollama_models)
        findings.append({
            "severity": "info",
            "title": MANY_MODELS_TITLE_FMT.format(
                count=len(snapshot.ollama_models),
                total_gb=total_gb,
            ),
            "detail": MANY_MODELS_DETAIL,
            "fix": MANY_MODELS_FIX,
            "fix_command": MANY_MODELS_FIX_COMMAND,
            "risk": "low",
            "category": "performance",
        })

    return findings


def check_network_isolation(snapshot: Any) -> list[dict]:
    """Verify services can reach each other."""
    findings = []

    # If all network checks fail, likely a Docker networking issue
    if snapshot.network_checks and all(not c.reachable for c in snapshot.network_checks):
        findings.append({
            "severity": "critical",
            "title": NO_INTER_SERVICE_TITLE,
            "detail": NO_INTER_SERVICE_DETAIL,
            "fix": NO_INTER_SERVICE_FIX,
            "fix_command": NO_INTER_SERVICE_FIX_COMMAND,
            "risk": "medium",
            "category": "runtime",
        })
    elif snapshot.network_checks:
        # Partial failures
        failed = [c for c in snapshot.network_checks if not c.reachable]
        if failed and len(failed) < len(snapshot.network_checks):
            for check in failed:
                findings.append({
                    "severity": "warning",
                    "title": CANNOT_REACH_TITLE_FMT.format(
                        source=check.source, target=check.target,
                    ),
                    "detail": CANNOT_REACH_DETAIL_FMT.format(
                        source=check.source, target=check.target,
                    ),
                    "fix": CANNOT_REACH_FIX_FMT.format(target=check.target),
                    "fix_command": CANNOT_REACH_FIX_COMMAND_FMT.format(target=check.target),
                    "risk": "low",
                    "category": "runtime",
                })

    return findings


def check_ollama_models(snapshot: Any) -> list[dict]:
    """Check Ollama model configuration for common issues."""
    findings = []

    if not snapshot.ollama_models:
        findings.append({
            "severity": "critical",
            "title": NO_OLLAMA_MODELS_TITLE,
            "detail": NO_OLLAMA_MODELS_DETAIL,
            "fix": NO_OLLAMA_MODELS_FIX,
            "fix_command": NO_OLLAMA_MODELS_FIX_COMMAND,
            "risk": "low",
            "category": "installation",
        })
        return findings

    # Check for embedding model specifically
    has_embed = any("nomic-embed" in m.name or "embed" in m.name for m in snapshot.ollama_models)
    if not has_embed:
        findings.append({
            "severity": "critical",
            "title": NO_EMBED_MODEL_TITLE,
            "detail": NO_EMBED_MODEL_DETAIL,
            "fix": NO_EMBED_MODEL_FIX,
            "fix_command": NO_EMBED_MODEL_FIX_COMMAND,
            "risk": "low",
            "category": "configuration",
        })

    # Check for a chat model (at least one non-embed model)
    chat_models = [m for m in snapshot.ollama_models if "embed" not in m.name]
    if not chat_models:
        findings.append({
            "severity": "warning",
            "title": NO_CHAT_MODEL_TITLE,
            "detail": NO_CHAT_MODEL_DETAIL,
            "fix": NO_CHAT_MODEL_FIX,
            "fix_command": NO_CHAT_MODEL_FIX_COMMAND,
            "risk": "low",
            "category": "configuration",
        })

    # Check for models too large for available RAM
    if snapshot.ram_total_gb and chat_models:
        for m in chat_models:
            if m.size_gb and m.size_gb > snapshot.ram_total_gb * 0.7:
                findings.append({
                    "severity": "warning",
                    "title": MODEL_TOO_LARGE_TITLE_FMT.format(name=m.name),
                    "detail": MODEL_TOO_LARGE_DETAIL_FMT.format(
                        size_gb=m.size_gb,
                        ram_total_gb=snapshot.ram_total_gb,
                    ),
                    "fix": MODEL_TOO_LARGE_FIX,
                    "fix_command": MODEL_TOO_LARGE_FIX_COMMAND_FMT.format(name=m.name),
                    "risk": "low",
                    "category": "performance",
                })

    return findings


def check_redis_health(snapshot: Any) -> list[dict]:
    """Redis-specific checks (message bus for conversation processing).

    The container is now Valkey (BSD-3-Clause LF fork) but the service
    name and Python client interface are still Redis-compatible. The
    service identifier in the snapshot stays as "redis" for backwards
    compat.
    """
    findings = []
    prefix = detect_ostler_prefix(snapshot)

    redis_svc = next((s for s in snapshot.services if s.name == "redis"), None)
    if not redis_svc:
        return findings

    if redis_svc.status == "unreachable":
        findings.append({
            "severity": "critical",
            "title": REDIS_UNREACHABLE_TITLE,
            "detail": REDIS_UNREACHABLE_DETAIL,
            "fix": REDIS_UNREACHABLE_FIX,
            "fix_command": REDIS_UNREACHABLE_FIX_COMMAND_FMT.format(prefix=prefix),
            "risk": "low",
            "category": "runtime",
        })

    return findings


def check_gateway_health(snapshot: Any) -> list[dict]:
    """PWG Gateway checks (the main API)."""
    findings = []

    gw_svc = next(
        (s for s in snapshot.services if s.name in ("gateway", "pwg-gateway")),
        None,
    )
    if not gw_svc:
        return findings

    if gw_svc.status_code == 502 or gw_svc.status_code == 504:
        findings.append({
            "severity": "critical",
            "title": GATEWAY_BAD_GATEWAY_TITLE_FMT.format(status_code=gw_svc.status_code),
            "detail": GATEWAY_BAD_GATEWAY_DETAIL,
            "fix": GATEWAY_BAD_GATEWAY_FIX,
            "fix_command": GATEWAY_BAD_GATEWAY_FIX_COMMAND,
            "risk": "low",
            "category": "runtime",
        })

    if gw_svc.status == "unreachable":
        findings.append({
            "severity": "critical",
            "title": GATEWAY_UNREACHABLE_TITLE,
            "detail": GATEWAY_UNREACHABLE_DETAIL,
            "fix": GATEWAY_UNREACHABLE_FIX,
            "fix_command": GATEWAY_UNREACHABLE_FIX_COMMAND,
            "risk": "low",
            "category": "runtime",
        })

    return findings


def check_memory_pressure(snapshot: Any) -> list[dict]:
    """Detect memory pressure on the Mac."""
    findings = []

    if snapshot.ram_total_gb and snapshot.ram_available_gb is not None:
        used_pct = (1 - snapshot.ram_available_gb / snapshot.ram_total_gb) * 100
        if used_pct > 90:
            findings.append({
                "severity": "critical",
                "title": CRITICAL_MEMORY_TITLE_FMT.format(used_pct=used_pct),
                "detail": CRITICAL_MEMORY_DETAIL_FMT.format(
                    avail_gb=snapshot.ram_available_gb,
                    total_gb=snapshot.ram_total_gb,
                ),
                "fix": CRITICAL_MEMORY_FIX,
                "fix_command": CRITICAL_MEMORY_FIX_COMMAND,
                "risk": "low",
                "category": "performance",
            })
        elif used_pct > 75:
            findings.append({
                "severity": "warning",
                "title": HIGH_MEMORY_TITLE_FMT.format(used_pct=used_pct),
                "detail": HIGH_MEMORY_DETAIL_FMT.format(
                    avail_gb=snapshot.ram_available_gb,
                    total_gb=snapshot.ram_total_gb,
                ),
                "fix": HIGH_MEMORY_FIX,
                "fix_command": HIGH_MEMORY_FIX_COMMAND,
                "risk": "low",
                "category": "performance",
            })

    if snapshot.ram_total_gb and snapshot.ram_total_gb < 16:
        findings.append({
            "severity": "warning",
            "title": LOW_RAM_TITLE_FMT.format(ram_total_gb=snapshot.ram_total_gb),
            "detail": LOW_RAM_DETAIL,
            "fix": None,
            "fix_command": None,
            "risk": "low",
            "category": "performance",
        })

    return findings


def check_gdpr_export_age(snapshot: Any) -> list[dict]:
    """Warn if GDPR exports might be stale."""
    findings = []

    if snapshot.last_import_date and snapshot.current_date:
        days_since = (snapshot.current_date - snapshot.last_import_date).days
        if days_since > 90:
            findings.append({
                "severity": "info",
                "title": STALE_IMPORT_TITLE_FMT.format(days=days_since),
                "detail": STALE_IMPORT_DETAIL,
                "fix": STALE_IMPORT_FIX,
                "fix_command": STALE_IMPORT_FIX_COMMAND,
                "risk": "low",
                "category": "configuration",
            })

    return findings


def check_docker_resources(snapshot: Any) -> list[dict]:
    """Check Docker Desktop resource allocation."""
    findings = []

    # Docker containers using excessive CPU or memory
    for c in snapshot.docker_containers:
        if hasattr(c, 'cpu_percent') and c.cpu_percent and c.cpu_percent > 80:
            findings.append({
                "severity": "warning",
                "title": HIGH_CPU_TITLE_FMT.format(
                    name=c.name, cpu_percent=c.cpu_percent,
                ),
                "detail": HIGH_CPU_DETAIL,
                "fix": HIGH_CPU_FIX,
                "fix_command": HIGH_CPU_FIX_COMMAND_FMT.format(name=c.name),
                "risk": "low",
                "category": "performance",
            })

        if hasattr(c, 'mem_mb') and c.mem_mb and c.mem_mb > 4000:
            findings.append({
                "severity": "warning",
                "title": HIGH_MEM_CONTAINER_TITLE_FMT.format(
                    name=c.name, mem_mb=c.mem_mb,
                ),
                "detail": HIGH_MEM_CONTAINER_DETAIL,
                "fix": HIGH_MEM_CONTAINER_FIX,
                "fix_command": HIGH_MEM_CONTAINER_FIX_COMMAND_FMT.format(name=c.name),
                "risk": "low",
                "category": "performance",
            })

    return findings


def check_service_versions(snapshot: Any) -> list[dict]:
    """Advisory checks for known version issues."""
    findings = []

    # Ollama version check
    if snapshot.ollama_version:
        try:
            parts = snapshot.ollama_version.split(".")
            major, minor = int(parts[0]), int(parts[1])
            if major == 0 and minor < 6:
                findings.append({
                    "severity": "info",
                    "title": OLLAMA_OLD_TITLE_FMT.format(version=snapshot.ollama_version),
                    "detail": OLLAMA_OLD_DETAIL,
                    "fix": OLLAMA_OLD_FIX,
                    "fix_command": OLLAMA_OLD_FIX_COMMAND,
                    "risk": "low",
                    "category": "configuration",
                })
        except (ValueError, IndexError):
            pass

    return findings


# ── #259 Mail content detection ──────────────────────────────────────


# Wait window between install completion and the empty-mail banner
# firing. Findings doc 2026-05-17 recommends 24h to give the customer
# a working day to set Mail up themselves before Doctor nudges.
MAIL_BANNER_DELAY_SECONDS = 24 * 60 * 60


def check_mail_content(snapshot: Any) -> list[dict]:
    """Empty-Mail nudge banner.

    Fires when:
    1. The CM051 installer recorded ``mail_has_fetched=False`` at
       install time (no ``InboxCache`` plist under ``~/Library/Mail``
       -- proxy for "Mail.app has never pulled mail").
    2. At least 24h have passed since install completion. Gives the
       customer time to add accounts themselves before nudging.

    Customer-facing copy follows the Apple-Restraint voice per
    PRODUCTISATION_CHECKLIST.md Rule 0.8: observational, not
    punitive, no exclamation marks.
    """
    findings: list[dict] = []
    signals = getattr(snapshot, "pipeline_signals", None)
    if signals is None:
        return findings
    if signals.mail_has_fetched is not False:
        # None = no install-time probe yet; True = Mail had fetched
        # mail at install. Neither fires the banner.
        return findings
    if signals.install_completed_ts is None:
        return findings
    elapsed = time.time() - signals.install_completed_ts
    if elapsed < MAIL_BANNER_DELAY_SECONDS:
        return findings

    findings.append({
        "severity": "info",
        **EMPTY_MAIL_NUDGE,
        "risk": "low",
        "category": "installation",
    })
    return findings


# ── #260 Mail backfill progress ──────────────────────────────────────


def _format_backfill_month(iso_ts: str | None) -> str | None:
    """Convert an ISO 8601 timestamp into a human "March 2022" label.

    Returns ``None`` if the value cannot be parsed -- the rule then
    skips rendering rather than surfacing a half-formed banner.

    We use ``datetime.fromisoformat`` which accepts the ISO output of
    ``apple_mail_mbox``'s ``save_checkpoint``. A bad format gets
    coerced to ``None`` rather than crashing the diagnostic.
    """
    if not iso_ts:
        return None
    from datetime import datetime as _dt
    raw = iso_ts.strip()
    # Tolerate the trailing 'Z' shape some sources emit -- fromisoformat
    # accepts it from Python 3.11 onward, but the doctor image targets
    # 3.10+ so we strip defensively.
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = _dt.fromisoformat(raw)
    except (TypeError, ValueError):
        return None
    return parsed.strftime("%B %Y")


def check_backfill_progress(snapshot: Any) -> list[dict]:
    """Backfill-progress info-banner (#260).

    Fires when:
    1. The first non-empty ingest has happened (``first_ingest_complete_ts``
       set by mark_first_ingest in the tick).
    2. ``backfill_complete`` is still false -- the progressive sweep
       is still walking backwards through the .emlx tree.
    3. We have an ``oldest_processed`` we can render as a "currently
       at <month year>" landmark.

    Skip rendering if any of those preconditions fail; the empty-Mail
    banner (#259) or the ingest-not-running case is handled elsewhere.

    Customer-facing copy follows the Apple-Restraint voice per
    PRODUCTISATION_CHECKLIST.md Rule 0.8: observational, not
    punitive, no exclamation marks. Customer copy needs Andy sign-off
    pre-merge.
    """
    findings: list[dict] = []

    pipeline = getattr(snapshot, "pipeline_signals", None)
    if pipeline is None:
        return findings
    if pipeline.first_ingest_complete_ts is None:
        # Ingest has not produced anything yet -- the empty-Mail banner
        # (#259) is the right surface in this state, not this one.
        return findings

    checkpoint = getattr(snapshot, "backfill_checkpoint", None)
    if checkpoint is None:
        return findings
    if checkpoint.backfill_complete:
        # Backfill done; nothing to nudge about. A separate one-time
        # "backfill complete" notification would land here but is
        # gated on the ZeroClaw deliver_announcement smoke; see PR
        # description for the deferral note.
        return findings

    month = _format_backfill_month(checkpoint.oldest_processed)
    if month is None:
        # No usable landmark; better to stay quiet than render a
        # half-formed banner.
        return findings

    findings.append({
        "severity": "info",
        **backfill_progress(month),
        "fix": None,
        "fix_command": None,
        "risk": "low",
        "category": "installation",
    })
    return findings


# ── Rule registry ────────────────────────────────────────────────────


ALL_RULES = [
    check_first_install,
    check_container_health,
    check_qdrant_health,
    check_oxigraph_health,
    check_redis_health,
    check_gateway_health,
    check_import_readiness,
    check_performance,
    check_memory_pressure,
    check_ollama_models,
    check_docker_resources,
    check_network_isolation,
    check_gdpr_export_age,
    check_service_versions,
    check_mail_content,
    check_backfill_progress,
]


def run_all_rules(snapshot: Any) -> list[dict]:
    """Run all diagnostic rules and return combined findings."""
    findings = []
    for rule in ALL_RULES:
        try:
            findings.extend(rule(snapshot))
        except Exception:
            pass  # Individual rule failures should not crash diagnostics

    # Deduplicate by title
    seen_titles = set()
    deduped = []
    for f in findings:
        if f["title"] not in seen_titles:
            seen_titles.add(f["title"])
            deduped.append(f)

    # Sort: critical first, then warning, then info
    severity_order = {"critical": 0, "warning": 1, "info": 2}
    deduped.sort(key=lambda f: severity_order.get(f.get("severity", "info"), 3))

    return deduped
