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

import logging
import os
import re
import time
from typing import Any

from banner_copy import EMPTY_MAIL_NUDGE, backfill_progress

from diagnostic_copy import (
    INGEST_EMPTY_DETAIL_FMT,
    INGEST_EMPTY_FIX,
    INGEST_EMPTY_FIX_COMMAND,
    INGEST_NO_INPUT_TITLE_FMT,
    INGEST_NO_INPUT_DETAIL_FMT,
    INGEST_NO_INPUT_DETAIL_NO_APP_FMT,
    INGEST_NO_INPUT_DETAIL_NO_EXPORT_FMT,
    INGEST_NO_INPUT_FIX,
    INGEST_NO_INPUT_FIX_COMMAND,
    INGEST_EMPTY_TITLE_FMT,
    INGEST_KILLED_DETAIL_FMT,
    INGEST_KILLED_FIX,
    INGEST_KILLED_FIX_COMMAND,
    INGEST_KILLED_TITLE_FMT,
    RULE_CRASHED_TITLE_FMT,
    RULE_CRASHED_DETAIL_FMT,
    RULE_CRASHED_FIX,
    RULE_CRASHED_FIX_COMMAND,
    SCHEDULED_AGENT_FAILING_TITLE_FMT,
    SCHEDULED_AGENT_FAILING_DETAIL_FMT,
    SCHEDULED_AGENT_FAILING_FIX,
    SCHEDULED_AGENT_FAILING_FIX_COMMAND_FMT,
    SCHEDULED_AGENT_NEVER_RAN_TITLE_FMT,
    SCHEDULED_AGENT_NEVER_RAN_DETAIL_FMT,
    SCHEDULED_AGENT_NEVER_RAN_FIX,
    SCHEDULED_AGENT_NOT_LOADED_TITLE_FMT,
    SCHEDULED_AGENT_NOT_LOADED_DETAIL_FMT,
    SCHEDULED_AGENT_NOT_LOADED_FIX,
    SCHEDULED_AGENT_NOT_LOADED_FIX_COMMAND_FMT,
    SCHEDULED_AGENT_UNKNOWN_TITLE_FMT,
    SCHEDULED_AGENT_UNKNOWN_DETAIL_FMT,
    SCHEDULED_AGENT_UNKNOWN_FIX,
    SCHEDULED_AGENT_UNKNOWN_FIX_COMMAND_FMT,
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
    CONTAINER_ENGINE_UNREACHABLE_TITLE,
    CONTAINER_ENGINE_UNREACHABLE_DETAIL_FMT,
    CONTAINER_ENGINE_UNREACHABLE_FIX,
    CONTAINER_ENGINE_UNREACHABLE_FIX_COMMAND,
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
    IMESSAGE_CAPTURE_STALLED_DETAIL,
    IMESSAGE_CAPTURE_STALLED_FIX,
    IMESSAGE_CAPTURE_STALLED_FIX_COMMAND,
    IMESSAGE_CAPTURE_STALLED_TITLE,
    CONVO_DISPATCH_FAILING_TITLE,
    CONVO_DISPATCH_FAILING_DETAIL,
    CONVO_DISPATCH_FAILING_FIX,
    CONVO_DISPATCH_FAILING_FIX_COMMAND,
    IMESSAGE_FDA_DETAIL,
    IMESSAGE_FDA_FIX,
    IMESSAGE_FDA_FIX_COMMAND,
    IMESSAGE_FDA_RESTART_HINT,
    IMESSAGE_FDA_TITLE,
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
    LAST_UPGRADE_FAILED_DETAIL,
    LAST_UPGRADE_FAILED_FIX,
    LAST_UPGRADE_FAILED_TITLE,
    LAST_UPGRADE_ROLLED_BACK_DETAIL_FMT,
    LAST_UPGRADE_ROLLED_BACK_FIX,
    LAST_UPGRADE_ROLLED_BACK_TITLE,
    LAST_UPGRADE_SUCCESS_DETAIL_FMT,
    LAST_UPGRADE_SUCCESS_DETAIL_NO_TIME,
    LAST_UPGRADE_SUCCESS_TITLE_FMT,
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
    WIKI_CONTAINER_STOPPED_DETAIL_FMT,
    WIKI_CONTAINER_STOPPED_FIX,
    WIKI_CONTAINER_STOPPED_FIX_COMMAND_FMT,
    WIKI_CONTAINER_STOPPED_TITLE,
    WIKI_ENGINE_DOWN_DETAIL,
    WIKI_ENGINE_DOWN_FIX,
    WIKI_ENGINE_DOWN_FIX_COMMAND,
    WIKI_ENGINE_DOWN_TITLE,
    WIKI_REFRESH_STALLED_DETAIL_FMT,
    WIKI_REFRESH_STALLED_FIX,
    WIKI_REFRESH_STALLED_FIX_COMMAND,
    WIKI_REFRESH_STALLED_TITLE,
    WIKI_UNHEALTHY_DETAIL_FMT,
    WIKI_UNHEALTHY_FIX,
    WIKI_UNHEALTHY_FIX_COMMAND_FMT,
    WIKI_UNHEALTHY_TITLE_FMT,
    WIKI_UNREACHABLE_DETAIL_FMT,
    WIKI_UNREACHABLE_FIX,
    WIKI_UNREACHABLE_FIX_COMMAND,
    WIKI_UNREACHABLE_TITLE,
)
from status_collector import (
    WIKI_URL,
    detect_ostler_prefix,
    is_native_deployment,
    is_ostler_container,
)

log = logging.getLogger(__name__)


def check_first_install(snapshot: Any) -> list[dict]:
    """Detect common first-install problems."""
    findings = []

    # "Docker Desktop not installed" critical.
    #
    # Suppressed on the productised native build. NOTE: native here does
    # NOT mean "no Docker" -- the data tier (Qdrant/Oxigraph/Redis) runs
    # in containers via Colima even on the native build. This rule is
    # suppressed because its fix-command is *Docker-Desktop-specific*
    # (Colima needs no Docker Desktop install), so it is a false-RED
    # there and would lead the support-email report. A genuine data-tier
    # outage is already covered by the per-service unreachable rules, so
    # nothing is lost by dropping this Docker-Desktop check. The legacy
    # Docker-Desktop dev deploy opts back in via OSTLER_DEPLOY_MODE=docker.
    # See is_native_deployment().
    if (
        not is_native_deployment()
        and snapshot.docker_version is None
        and not snapshot.docker_containers
    ):
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
    """Detect container-level issues.

    THE FIRST ARM IS NOT ABOUT A CONTAINER. It is about the absence of a
    container LIST, which the three per-container arms below cannot
    express: each loops `snapshot.docker_containers`, so an empty list
    runs zero bodies and contributes zero findings, exactly like a
    healthy stack.

    Measured on the Mini 2026-08-20 after a power cycle: Colima was down,
    `docker ps` failed, and the six stores were gone. Every per-container
    arm stayed silent because there was nothing to loop over. Absence is
    not health, and a zero denominator is not a clean result.
    """
    findings = []

    # docker_error is set ONLY when the engine could not be queried. It is
    # not the same as an empty list on a reachable engine, which is a
    # legitimate state on a box whose stack has not started yet, and which
    # deliberately does NOT fire here.
    docker_error = getattr(snapshot, "docker_error", None)
    if docker_error:
        findings.append({
            "severity": "critical",
            "title": CONTAINER_ENGINE_UNREACHABLE_TITLE,
            "detail": CONTAINER_ENGINE_UNREACHABLE_DETAIL_FMT.format(
                error=docker_error
            ),
            "fix": CONTAINER_ENGINE_UNREACHABLE_FIX,
            "fix_command": CONTAINER_ENGINE_UNREACHABLE_FIX_COMMAND,
            "risk": "low",
            "category": "runtime",
        })

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


def check_wiki_health(snapshot: Any) -> list[dict]:
    """The wiki must announce its own death.

    🔴 v1.0.42 UPGRADE WALK, 2026-08-23. The wiki was dead for about a day
    and NOTHING said so. No alert, no card, no banner. It was found only
    because someone was asked to open the URL. Before this rule, the whole
    doctor package's only mention of port 8044 was a comment.

    This is not a duplicate of the generic SERVICE_UNREACHABLE finding that
    web_ui.run_local_diagnostics emits for every unreachable service. That
    one exists and now covers the wiki too, because "wiki" was added to
    collect_service_health. But its fix command is
    `docker restart <prefix><name>`, which is the WRONG INSTRUCTION here in
    the most common case: the wiki is a container behind a Linux VM, so the
    usual reason it is unreachable is that the VM is stopped, and
    restarting a container inside a stopped VM does nothing at all. A fix
    command that cannot work is worse than none, because the customer tries
    it, sees it fail, and stops trusting the page.

    So this rule names the layer that is actually broken:

      engine down + wiki down  -> ONE finding about the engine
      engine up  + container   -> a finding naming the container
                    stopped
      engine up  + no container-> the generic unreachable finding, with a
                    visible               fix that starts the runtime first

    An exited-cleanly container is the case nothing else catches:
    check_container_health deliberately ignores `Exited (0)` because a
    stopped container is a legitimate state for most services. For the
    wiki it is not -- it is the customer's front door.
    """
    findings = []

    # The refresh tick's own streak, read FIRST and independently of the
    # port probe: a wiki that still serves yesterday's pages is a different
    # fault from one that does not answer, and both can be true at once.
    stall = _wiki_recompile_stall()
    if stall is not None:
        ticks, hours = stall
        findings.append({
            "severity": "critical" if hours >= 6 else "warning",
            "title": WIKI_REFRESH_STALLED_TITLE,
            "detail": WIKI_REFRESH_STALLED_DETAIL_FMT.format(
                ticks=ticks, hours=hours
            ),
            "fix": WIKI_REFRESH_STALLED_FIX,
            "fix_command": WIKI_REFRESH_STALLED_FIX_COMMAND,
            "risk": "low",
            "category": "runtime",
        })

    wiki_svc = next((s for s in snapshot.services if s.name == "wiki"), None)
    if not wiki_svc:
        # No probe result at all. Silence here is correct: an older
        # snapshot without the wiki row must not fabricate a verdict about
        # a service it never looked at.
        return findings

    if wiki_svc.status == "healthy":
        return findings

    # Is the engine itself reachable? docker_error is set ONLY when the
    # engine could not be queried.
    engine_down = bool(getattr(snapshot, "docker_error", None))

    if wiki_svc.status == "unhealthy":
        findings.append({
            "severity": "warning",
            "title": WIKI_UNHEALTHY_TITLE_FMT.format(
                status_code=wiki_svc.status_code
            ),
            "detail": WIKI_UNHEALTHY_DETAIL_FMT.format(
                url=WIKI_URL, status_code=wiki_svc.status_code
            ),
            "fix": WIKI_UNHEALTHY_FIX,
            "fix_command": WIKI_UNHEALTHY_FIX_COMMAND_FMT.format(
                name=_wiki_container_name(snapshot)
            ),
            "risk": "low",
            "category": "runtime",
        })
        return findings

    # status == "unreachable" from here down.
    if engine_down:
        findings.append({
            "severity": "critical",
            "title": WIKI_ENGINE_DOWN_TITLE,
            "detail": WIKI_ENGINE_DOWN_DETAIL,
            "fix": WIKI_ENGINE_DOWN_FIX,
            "fix_command": WIKI_ENGINE_DOWN_FIX_COMMAND,
            "risk": "low",
            "category": "runtime",
        })
        return findings

    stopped = _stopped_wiki_container(snapshot)
    if stopped is not None:
        findings.append({
            "severity": "critical",
            "title": WIKI_CONTAINER_STOPPED_TITLE,
            "detail": WIKI_CONTAINER_STOPPED_DETAIL_FMT.format(
                name=stopped.name, state=stopped.state
            ),
            "fix": WIKI_CONTAINER_STOPPED_FIX,
            "fix_command": WIKI_CONTAINER_STOPPED_FIX_COMMAND_FMT.format(
                name=stopped.name
            ),
            "risk": "low",
            "category": "runtime",
        })
        return findings

    findings.append({
        "severity": "critical",
        "title": WIKI_UNREACHABLE_TITLE,
        "detail": WIKI_UNREACHABLE_DETAIL_FMT.format(url=WIKI_URL),
        "fix": WIKI_UNREACHABLE_FIX,
        "fix_command": WIKI_UNREACHABLE_FIX_COMMAND,
        "risk": "low",
        "category": "runtime",
    })
    return findings


_WIKI_STALL_MIN_TICKS = 3   # 10-minute StartInterval, so ~30 minutes


def _wiki_recompile_stall():
    """(consecutive_ticks, hours) when the refresh tick has been a no-op.

    wiki-recompile-tick.sh exits 0 when the container runtime is not ready,
    deliberately: flipping that to non-zero would put a red launchd record
    on every ordinary reboot, and a gate that is always red stops being read
    just as surely as one that is always green. The cost was that a
    transient and a PERMANENT outage looked identical -- green, forever.

    The tick now counts its consecutive no-ops into a state file. This reads
    it. Returns None below the threshold so a single reboot tick says
    nothing, and never raises: an unreadable or malformed file means we do
    not know, and "we do not know" must not be rendered as "all is well" OR
    as an alarm.
    """
    import json
    from datetime import datetime, timezone
    from pathlib import Path

    base = os.environ.get("OSTLER_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".ostler", "state",
    )
    path = Path(base) / "wiki-recompile" / "runtime-unready.json"
    try:
        if not path.exists():
            return None
        data = json.loads(path.read_text())
        ticks = int(data.get("consecutive", 0))
        if ticks < _WIKI_STALL_MIN_TICKS:
            return None
        first = data.get("first_seen")
        hours = 0
        if first:
            started = datetime.fromisoformat(first.replace("Z", "+00:00"))
            hours = int(
                (datetime.now(tz=timezone.utc) - started).total_seconds() // 3600
            )
        return ticks, hours
    except Exception:
        log.debug("wiki recompile stall marker unreadable", exc_info=True)
        return None


def _wiki_container_name(snapshot: Any) -> str:
    """Best-effort name of the wiki container, for a fix command.

    Falls back to the canonical productised name rather than to an empty
    string: a fix command with a hole in it is not a fix command.
    """
    for c in getattr(snapshot, "docker_containers", None) or []:
        if "wiki-site" in c.name:
            return c.name
    return f"{detect_ostler_prefix(snapshot)}wiki-site"


def _stopped_wiki_container(snapshot: Any):
    """The wiki container, if the engine can see it and it is not running.

    Returns None when the engine sees no such container at all -- which is
    a different fact from "it is stopped" and gets different copy.
    """
    for c in getattr(snapshot, "docker_containers", None) or []:
        if "wiki-site" in c.name and c.state != "running":
            return c
    return None


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


def _imessage_chat_db_path() -> str:
    """Returns the canonical ~/Library/Messages/chat.db path.

    Pulled to its own helper so tests can monkeypatch HOME without
    touching the rule body.
    """
    import os

    return os.path.join(
        os.path.expanduser("~"),
        "Library",
        "Messages",
        "chat.db",
    )


def _imessage_chat_db_readable() -> bool:
    """True if SOMETHING in this Doctor process can open chat.db.

    Used purely as a "FDA is granted on this machine" liveness probe
    for the auto-dismiss path in :func:`check_imessage_fda`. The
    file exists on every macOS install; failing to open it is the
    signal the user has not yet granted Full Disk Access for the
    binary doing the probing.

    We use ``sqlite3.connect`` rather than ``os.access`` because
    macOS reports the path as readable from a stat() perspective
    even when TCC denies the actual open -- we have to attempt the
    real SQLite open to get the truthful answer.

    Any failure (missing file, permission denied, OSError on the
    sqlite extension import) is treated as "not readable" -- safer
    to keep the card visible than to wrongly auto-dismiss.
    """
    import sqlite3

    path = _imessage_chat_db_path()
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2.0)
    except sqlite3.Error:
        return False
    except OSError:
        return False
    try:
        # A minimal read confirms the open succeeded; the chat.db
        # ``message`` table always exists once Messages has run once,
        # but we only care that the open + a no-op SELECT round-trip
        # without raising the OperationalError that TCC denial throws.
        conn.execute("SELECT 1").fetchone()
        return True
    except sqlite3.Error:
        return False
    finally:
        try:
            conn.close()
        except sqlite3.Error:
            pass


def check_imessage_fda(snapshot: Any) -> list[dict]:
    """CX-60 Doctor card: ostler-assistant daemon needs FDA for
    ~/Library/Messages/chat.db.

    Renders a warning-severity card when ALL of:

    1. The installer recorded ``imessage_chat_db_fda_needed=True`` in
       pipeline_signals.json (the install-time probe found the
       daemon could not open chat.db once the LaunchAgent loaded).
    2. A live re-probe from this Doctor process *also* cannot open
       chat.db. This is the auto-dismiss path: as soon as either
       the customer's Doctor process or the assistant binary gains
       FDA and the customer re-runs Doctor, the card disappears.

    A missing key on the snapshot (``None``) means the install ran
    before CX-60 shipped -- we stay quiet rather than firing a
    false-positive card on legacy installs.

    Customer copy lives in ``diagnostic_copy.py`` per Rule 0.9.
    The fix-command opens System Settings -> Privacy & Security ->
    Full Disk Access via the x-apple.systempreferences URL scheme.
    The follow-up ``IMESSAGE_FDA_RESTART_HINT`` is appended to the
    detail so the user sees the launchctl restart command alongside.
    """
    findings: list[dict] = []

    signals = getattr(snapshot, "pipeline_signals", None)
    if signals is None:
        return findings

    needs = getattr(signals, "imessage_chat_db_fda_needed", None)
    if needs is not True:
        # None (legacy install, no probe yet) or False (probe said
        # the daemon was already healthy). Either way: no card.
        return findings

    # Live auto-dismiss: if Doctor's own process can open chat.db,
    # FDA has been granted at least to one binary on this Mac. The
    # daemon may still need its own grant (TCC is per-binary), but
    # at that point the install-time probe is stale -- prefer the
    # live signal so the card does not linger.
    if _imessage_chat_db_readable():
        return findings

    detail = "{body}\n\n{restart}".format(
        body=IMESSAGE_FDA_DETAIL,
        restart=IMESSAGE_FDA_RESTART_HINT,
    )
    findings.append({
        "severity": "warning",
        "title": IMESSAGE_FDA_TITLE,
        "detail": detail,
        "fix": IMESSAGE_FDA_FIX,
        "fix_command": IMESSAGE_FDA_FIX_COMMAND,
        "risk": "low",
        "category": "installation",
    })
    return findings


# ── (B-lite) upgrade audit-trail row ─────────────────────────────────


def _ostler_preferences_path() -> str:
    """Returns the canonical ~/.ostler/preferences.json path.

    Pulled to its own helper so tests can monkeypatch HOME without
    touching the rule body (mirrors :func:`_imessage_chat_db_path`).
    """
    import os

    return os.path.join(
        os.path.expanduser("~"),
        ".ostler",
        "preferences.json",
    )


def _format_upgrade_applied(timestamp: str | None) -> str | None:
    """Format an ISO 8601 upgrade timestamp as ``%Y-%m-%d %H:%M``.

    Returns ``None`` when the value is missing or unparseable, so the
    rule omits the applied-time clause rather than surfacing a raw
    string with a "T"/"Z" in it. Mirrors :func:`_format_backfill_month`.
    """
    if not timestamp:
        return None
    from datetime import datetime as _dt
    raw = timestamp.strip()
    # Tolerate the trailing 'Z' zulu shape the Hub writer emits;
    # fromisoformat accepts it from 3.11 but the doctor image targets
    # 3.10+ so we normalise defensively.
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = _dt.fromisoformat(raw)
    except (TypeError, ValueError):
        return None
    return parsed.strftime("%Y-%m-%d %H:%M")


def check_last_upgrade(snapshot: Any) -> list[dict]:
    """(B-lite) upgrade audit-trail Doctor row.

    Reads the durable, reboot-surviving upgrade result the Hub records
    at ``~/.ostler/preferences.json`` and surfaces exactly one row
    describing how the last Ostler update went.

    This rule is READ-ONLY: the Hub (Rust) owns writes to
    preferences.json. Doctor never creates, modifies, or repairs the
    file -- a malformed file is left byte-for-byte untouched.

    Quiet-on-legacy posture (mirrors :func:`check_imessage_fda`): a
    missing file, malformed JSON, or a missing / ``None`` /
    non-object ``last_upgrade_result`` all mean "this install has no
    upgrade audit trail yet" and return no findings rather than
    firing a false row. An unknown ``status`` value is likewise not
    guessed.

    Customer copy lives in ``diagnostic_copy.py`` per Rule 0.9.
    """
    import json

    findings: list[dict] = []

    path = _ostler_preferences_path()
    try:
        with open(path, encoding="utf-8") as fh:
            prefs = json.load(fh)
    except OSError:
        # Missing file (FileNotFoundError is an OSError) or unreadable:
        # legacy install with no audit trail. Stay quiet.
        return findings
    except ValueError:
        # Malformed JSON (JSONDecodeError / UnicodeDecodeError both
        # subclass ValueError). Stay quiet, never crash, never rewrite.
        return findings

    if not isinstance(prefs, dict):
        return findings

    result = prefs.get("last_upgrade_result")
    if not isinstance(result, dict):
        # Missing key, explicit null, or a non-object value: no trail.
        return findings

    status = result.get("status")
    version = result.get("version")
    applied = _format_upgrade_applied(result.get("timestamp"))

    if status == "success":
        if applied:
            detail = LAST_UPGRADE_SUCCESS_DETAIL_FMT.format(applied=applied)
        else:
            detail = LAST_UPGRADE_SUCCESS_DETAIL_NO_TIME
        findings.append({
            "severity": "info",
            "title": LAST_UPGRADE_SUCCESS_TITLE_FMT.format(version=version),
            "detail": detail,
            "fix": None,
            "fix_command": None,
            "risk": "low",
            "category": "upgrade",
        })
    elif status == "failed":
        findings.append({
            "severity": "warning",
            "title": LAST_UPGRADE_FAILED_TITLE,
            "detail": LAST_UPGRADE_FAILED_DETAIL,
            "fix": LAST_UPGRADE_FAILED_FIX,
            "fix_command": None,
            "risk": "low",
            "category": "upgrade",
        })
    elif status == "rolled-back":
        findings.append({
            "severity": "warning",
            "title": LAST_UPGRADE_ROLLED_BACK_TITLE,
            "detail": LAST_UPGRADE_ROLLED_BACK_DETAIL_FMT.format(version=version),
            "fix": LAST_UPGRADE_ROLLED_BACK_FIX,
            "fix_command": None,
            "risk": "low",
            "category": "upgrade",
        })
    # Unknown status value: do not guess. Return no findings.

    return findings


# Runtime signature the iMessage capture bundle logs on every tick while it
# cannot open ~/Library/Messages/chat.db (Full Disk Access not yet granted).
# Matched as two tokens rather than one literal so incidental whitespace /
# path suffix variations in the traceback line still match.
_IMESSAGE_SQLITE_CRASH_TOKENS = (
    "sqlite3.OperationalError",
    "unable to open database file",
)
# Cap how much of the (potentially long-lived, appended-to) error log we read.
_IMESSAGE_ERR_TAIL_BYTES = 65536


def _imessage_bundle_err_path() -> "Any":
    """Path to the iMessage capture bundle's stderr log.

    Honours ``OSTLER_LOGS_DIR`` then ``OSTLER_DIR`` (the installer sets
    ``OSTLER_DIR=~/.ostler`` and points launchd logs at ``${OSTLER_DIR}/logs``),
    falling back to ``~/.ostler/logs/imessage-bundle.err``. Mirrors
    ``web_ui._ostler_logs_dir`` so the resolution stays in lockstep, and lets
    tests point it at a fixture via ``OSTLER_LOGS_DIR`` without touching HOME.
    """
    import os
    from pathlib import Path

    override = os.environ.get("OSTLER_LOGS_DIR")
    if override:
        base = Path(override)
    else:
        ostler_dir = os.environ.get("OSTLER_DIR")
        base = Path(ostler_dir) / "logs" if ostler_dir else (
            Path.home() / ".ostler" / "logs"
        )
    return base / "imessage-bundle.err"


def _imessage_capture_crash_logged() -> bool:
    """True if the iMessage capture stderr log shows the pre-FDA SQLite crash.

    Reads only the tail of the file (the log is appended to on every tick, so
    it can grow) and looks for the ``sqlite3.OperationalError: unable to open
    database file`` signature. Any read failure (missing file on a fresh box,
    permission error) is treated as "no crash observed" so the rule stays
    quiet rather than firing a false positive.
    """
    path = _imessage_bundle_err_path()
    try:
        if not path.is_file():
            return False
        with open(path, "rb") as fh:
            try:
                fh.seek(-_IMESSAGE_ERR_TAIL_BYTES, 2)
            except OSError:
                # File shorter than the tail window: read from the start.
                fh.seek(0)
            tail = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return False
    return all(token in tail for token in _IMESSAGE_SQLITE_CRASH_TOKENS)


def check_imessage_capture_stalled(snapshot: Any) -> list[dict]:
    """#172 Doctor card: the iMessage capture bundle is crash-looping on
    SQLite because Full Disk Access has not been granted yet.

    Distinct from :func:`check_imessage_fda` (which fires on the install-time
    probe signal): this rule reads the RUNTIME evidence. Before FDA is granted
    every capture tick logs
    ``sqlite3.OperationalError: unable to open database file`` to
    ``~/.ostler/logs/imessage-bundle.err``. The capture is silently stalled --
    no messages are being read -- so we surface an actionable card.

    Fires when BOTH:

    1. The crash signature is present in the log tail, AND
    2. A live re-probe from this Doctor process *also* cannot open chat.db.

    The live re-probe is the auto-dismiss path (shared with
    :func:`check_imessage_fda`): the crash lines linger in the appended log
    after FDA is finally granted, so without the re-probe the card would never
    clear. Once FDA is granted and Messages is readable, the card disappears.

    Customer copy lives in ``diagnostic_copy.py`` per Rule 0.9. The fix-command
    opens System Settings -> Privacy & Security -> Full Disk Access.
    """
    findings: list[dict] = []

    if not _imessage_capture_crash_logged():
        return findings

    # Live auto-dismiss: if this Doctor process can now open chat.db, FDA has
    # been granted on this Mac and the logged crashes are stale history.
    if _imessage_chat_db_readable():
        return findings

    findings.append({
        "severity": "warning",
        "title": IMESSAGE_CAPTURE_STALLED_TITLE,
        "detail": IMESSAGE_CAPTURE_STALLED_DETAIL,
        "fix": IMESSAGE_CAPTURE_STALLED_FIX,
        "fix_command": IMESSAGE_CAPTURE_STALLED_FIX_COMMAND,
        "risk": "low",
        "category": "installation",
    })
    return findings


# ── Rule registry ────────────────────────────────────────────────────


# Dispatch failures are logged as a non-zero return code from the CM048
# conversation processor. Counted over the log TAIL only: the log is appended
# to forever, so counting the whole file would keep surfacing failures the
# customer already dealt with weeks ago.
_DISPATCH_FAIL_TOKENS = ("rc=1", "sessions_failed")


def _dispatch_failure_count() -> int:
    """How many dispatch failures appear in the tail of the bundle error log.

    Same read posture as :func:`_imessage_capture_crash_logged` -- tail only,
    and any read failure counts as zero so a missing log on a fresh box cannot
    manufacture a warning.
    """
    path = _imessage_bundle_err_path()
    try:
        if not path.is_file():
            return 0
        with open(path, "rb") as fh:
            try:
                fh.seek(-_IMESSAGE_ERR_TAIL_BYTES, 2)
            except OSError:
                fh.seek(0)
            tail = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return 0
    return sum(
        1 for line in tail.splitlines()
        if any(tok in line for tok in _DISPATCH_FAIL_TOKENS)
    )


def check_conversation_dispatch_failures(snapshot: Any) -> list[dict]:
    """Surface conversations that were READ but failed to be processed.

    WHY THIS RULE EXISTS (2026-08-08 box-walk of .208)
    Doctor's status endpoint reported "Everything looks healthy. Nice one."
    at 16:49 while ``imessage-bundle.err`` was 37KB and carried a fresh rc=1
    from 16:43. Doctor was not wrong about what it checked -- it checked this
    log for the pre-FDA SQLite crash signature and for nothing else. There was
    no rule for FAILURE, only for SILENCE.

    That distinction is the whole defect. A crash-looping bundle is caught by
    :func:`check_imessage_capture_stalled`. A bundle that ticks forever while
    every dispatch fails looks identical to a healthy one from the outside:
    the process is running, the log is growing, messages are being read. The
    conversations are simply dropped on the floor.

    Second-in-class after #208 (Doctor reporting a device as paired when it
    was not). A product that reports green over a red state twice is not
    trusted a third time, so this rule errs towards saying something.

    Deliberately a WARNING, not an error: the ingest as a whole is working and
    the customer's other data is unaffected. It is a "some of your things did
    not make it" message, which is what actually happened.
    """
    findings: list[dict] = []

    n = _dispatch_failure_count()
    if n <= 0:
        return findings

    findings.append({
        "severity": "warning",
        "title": CONVO_DISPATCH_FAILING_TITLE,
        "detail": CONVO_DISPATCH_FAILING_DETAIL.format(
            n=n,
            noun="conversation" if n == 1 else "conversations",
            have="has" if n == 1 else "have",
        ),
        "fix": CONVO_DISPATCH_FAILING_FIX,
        "fix_command": CONVO_DISPATCH_FAILING_FIX_COMMAND,
        "risk": "low",
        "category": "installation",
    })
    return findings



_NON_COUNT_KEYS = frozenset({"rc", "exit", "status", "code"})


def _payload_is_all_zero(payload: str) -> bool:
    """True when every numeric field in a marker payload is zero.

    Payloads look like ``sent=0``, ``people_added=353``, ``written=0`` or
    ``status=no_data``. A marker with NO numeric field at all returns False:
    absence of a number is not evidence of zero, and guessing would
    manufacture findings on sources that simply do not report counts.
    """
    if "no_data" in payload:
        return True
    # (key, value) pairs, so the KEY can be excluded. `rc=0` is a RETURN CODE
    # meaning success, not a count of zero items. Scanning values blindly
    # flagged `status=run rc=0` as an empty import and would have
    # manufactured a finding on every healthy source that reports its rc.
    pairs = re.findall(r"(\w+)\s*=\s*(\d+)", payload)
    counts = [v for k, v in pairs if k.lower() not in _NON_COUNT_KEYS]
    return bool(counts) and all(v == "0" for v in counts)


# The hydrate marker vocabulary, MEASURED on CM051 origin/main install.sh
# rather than assumed (HR015 #580). Exactly three statuses reach a
# ~/.ostler/state/hydrate/<source>.done file:
#
#   ok        _hydrate_sentinel_record, non-zero payload
#   no_data   _hydrate_sentinel_record_no_data, and _hydrate_sentinel_record
#             when the payload is all zeros
#   error     _hydrate_sentinel_record_error, carries an rc
#
# Three other status strings appear in install.sh (no_app, denied,
# error_empty_result) and NONE of them is written to a hydrate marker: two
# are inside comments describing the old call shape, one is a gui_emit. That
# was checked rather than eyeballed, because a first pass counting
# `status=[a-z_]+` across the file found all six and would have had this
# rule handling statuses it can never see.
#
# no_app and no_export_json are REASONS, carried in `detail`, not statuses.
HYDRATE_STATUS_NO_INPUT = "no_data"
HYDRATE_STATUSES_HEALTHY = frozenset({"ok", HYDRATE_STATUS_NO_INPUT})


def check_hydrate_ingest(snapshot: Any) -> list[dict]:
    """Surface ingest sources that were killed, or that imported nothing.

    THE DEFECT THIS EXISTS FOR. install.sh writes one marker per source under
    ~/.ostler/state/hydrate/. Nothing in the vendored Doctor read them:
    `grep -rl hydrate` over vendor/doctor/agent returned 0 files, against
    controls qdrant=15 and pipeline_signals=6. On the v1.0.36 box two sources
    had been killed by the 90s watchdog:

        browsing   status=error  rc=124  sent=0,skipped=0
        people     status=error  rc=124  sent=0

    and the panel said "Everything looks healthy. Nice one." People search and
    browsing had ingested nothing and no surface anywhere said so.

    THREE ARMS, deliberately different severities.

    1. status is a FAILURE status. The source was killed. warning.
    2. status == no_data. The source RAN and found no input. INFO.
    3. status == ok but the payload is all zeros. INFO, because an empty
       source is often legitimate. The point is only that "succeeded" and
       "did nothing" must not render identically -- the zero-denominator
       problem.

    ARM 1 TESTS FOR FAILURE, NOT FOR NOT-SUCCESS (HR015 #580). It used to
    read `m.status != "ok"`, which is not the same predicate and was wrong
    on a healthy box. install.sh writes exactly three hydrate statuses,
    measured on CM051 origin/main rather than assumed:

        ok        the source imported something
        no_data   the source RAN and THE INPUT WAS NOT THERE
        error     the source failed, with an rc

    `no_data` is written by _hydrate_sentinel_record_no_data, whose own
    comment calls the condition transient and explicitly not a failure, and
    by _hydrate_sentinel_record when a payload is all zeros. Treating it as
    a kill produced four warnings on a clean box -- no WhatsApp installed,
    an FDA export not yet landed -- each claiming an import "stopped before
    it completed" when it had run fine. Four confident false statements is
    worse than the silence this rule replaced, because silence does not
    send anyone looking for a fault that is not there.

    WHY A SET AND NOT `== "error"`. A status this rule has never seen must
    not be silently absorbed into the healthy path: that is how the original
    defect would recur in the other direction. Anything not recognised as a
    success or a no-input outcome is treated as a failure, so a new status
    added upstream surfaces loudly rather than vanishing.
    """
    findings = []
    for m in getattr(snapshot, "hydrate_markers", None) or []:
        source = (m.source or "").replace("_", " ") or "An import"
        if m.status == HYDRATE_STATUS_NO_INPUT:
            reason = (m.detail or "").strip()
            if reason == "no_app":
                detail = INGEST_NO_INPUT_DETAIL_NO_APP_FMT.format(source=source)
            elif reason == "no_export_json":
                detail = INGEST_NO_INPUT_DETAIL_NO_EXPORT_FMT.format(source=source)
            else:
                detail = INGEST_NO_INPUT_DETAIL_FMT.format(source=source)
            findings.append({
                "severity": "info",
                "title": INGEST_NO_INPUT_TITLE_FMT.format(source=source),
                "detail": detail,
                "fix": INGEST_NO_INPUT_FIX,
                "fix_command": INGEST_NO_INPUT_FIX_COMMAND,
                "risk": "low",
                "category": "ingest",
            })
        elif m.status and m.status not in HYDRATE_STATUSES_HEALTHY:
            timed_out = m.rc in (124, 137)
            findings.append({
                "severity": "warning",
                "title": INGEST_KILLED_TITLE_FMT.format(source=source),
                "detail": INGEST_KILLED_DETAIL_FMT.format(
                    source=source,
                    timeout_clause=(
                        " because it ran out of time" if timed_out else ""
                    ),
                ),
                "fix": INGEST_KILLED_FIX,
                "fix_command": INGEST_KILLED_FIX_COMMAND,
                "risk": "low",
                "category": "ingest",
            })
        elif m.status == "ok" and _payload_is_all_zero(m.payload):
            findings.append({
                "severity": "info",
                "title": INGEST_EMPTY_TITLE_FMT.format(source=source),
                "detail": INGEST_EMPTY_DETAIL_FMT.format(
                    source=source, payload=m.payload or "no counts recorded",
                ),
                "fix": INGEST_EMPTY_FIX,
                "fix_command": INGEST_EMPTY_FIX_COMMAND,
                "risk": "low",
                "category": "ingest",
            })
    return findings


# ===========================================================================
# check_scheduled_agents -- MAKE A DYING AGENT LOUD. (#595 layer 2)
#
# WHAT WENT WRONG, MEASURED, ON .228 / v1.0.38.
#
# com.ostler.fda-rerun is the ONLY recurring ingest for six sources
# (contacts, calendar, iMessage, WhatsApp, browsing, notes). It exited 1 on
# every hourly tick for days. The graph froze completely. Nothing surfaced
# it, while the product went on saying "still loading in the background".
#
# The missing module was the proximate cause and is fixed (#939/#942/#945).
# THE REAL DEFECT IS THE SILENCE, and this rule is the fix for that.
#
# WHY THERE IS NO TICK WRAPPER TO INSTRUMENT, AND WHY THAT IS FINE.
#
# Measured, not assumed: fda-rerun is a "daemon-only feed"
# (tests/tick_pair_map.tsv) whose plist runs the Rust binary directly --
#   ProgramArguments = OstlerAssistant.app/.../ostler-assistant run-source
# -- with no shell wrapper anywhere in CM051, and CM051 cannot rebuild that
# binary. So there is nothing of ours to add exit-status recording to.
#
# There does not need to be. LAUNCHD ALREADY RECORDS IT. `launchctl print`
# reports `runs = N` and `last exit code = ...` for every job it manages.
# Before this rule, NOTHING in the shipping product read either field:
#
#     $ grep -rIn -i "lastexit" . --exclude-dir=.git   ->  0 hits
#     $ grep -rIn "launchctl" . --exclude-dir=.git     ->  348 hits (control)
#
# The one place in the repo that reads a last exit status is a box-walk QA
# probe that never reaches a customer. The knowledge existed; the wiring did
# not. This rule is that wiring, and it costs install.sh nothing -- the
# Doctor already runs every rule in ALL_RULES on every status poll.
#
# THE THREE STATES, AND WHY THEY ARE SEPARATE BRANCHES.
#
# "Never ran" and "ran and succeeded" MUST NOT print the same. That exact
# conflation is #810, and the gate that inherited it wrote `${ec:-0}` --
# defaulting an unloaded label's empty string to a clean exit 0 -- and went
# GREEN on a box where the bundle was not installed at all. So:
#
#   healthy      last exit code = 0            -> NO finding (silence is
#                                                 correct only here)
#   failing      last exit code = N, N != 0    -> critical, with the streak
#   never_ran    runs = 0 past its window      -> warning, its own copy
#   not_loaded   launchctl has no such job     -> critical
#   in_flight    runs > 0, "(never exited)"    -> no finding; it is running
#   unknown      we could not parse an answer  -> warning, CANNOT-RUN
#
# There is no `or 0` and no `.get(..., 0)` anywhere in the parse. A field we
# could not read becomes `unknown`, never `healthy`.
#
# COUNTING CONSECUTIVE FAILURES. launchd reports the LAST exit code, not a
# streak, so the streak is accumulated here against `runs`. Any observation
# of exit 0 resets it. The Doctor dashboard polls /doctor/api/status every
# 10s against hourly ticks, so in practice every tick's outcome is seen.
# ===========================================================================

# label -> (feeds, log basename, expected interval seconds)
# The recurring agents whose death freezes ingest. fda-rerun is first
# because it is the one that actually died and it carries six sources.
_SCHEDULED_AGENTS = (
    (
        "com.ostler.fda-rerun",
        "contacts, calendar, iMessage, WhatsApp, browsing and notes",
        "fda-rerun",
        3600,
    ),
    ("com.ostler.contact-resync", "your contacts", "contact-resync", 1800),
    ("com.ostler.enrich", "people and organisation detail", "enrich", 1800),
    ("com.ostler.export-scan", "exports you have dropped in", "export-scan", 14400),
    ("com.ostler.aiconv-resume", "AI chat transcripts", "aiconv-resume", 3600),
)

# How many consecutive failed ticks before the card goes critical. One bad
# tick can be a transient (a locked DB, a sleeping Mac). Two consecutive is a
# pattern, and on the .228 box it was hundreds.
_SCHEDULED_AGENT_CRITICAL_AFTER = 2

# Multiplier on the expected interval before "runs = 0" is worth reporting.
# A job legitimately shows runs = 0 in the minutes after install; it does not
# legitimately show runs = 0 two full windows later. Matches the 2x posture
# used by dashboard_components.STALE_INTERVAL_MULTIPLIER.
_SCHEDULED_AGENT_NEVER_RAN_AFTER = 2

_LAUNCHD_RUNS_RE = re.compile(r"^\s*runs\s*=\s*(\d+)\s*$", re.MULTILINE)
_LAUNCHD_EXIT_RE = re.compile(r"^\s*last exit code\s*=\s*(.+?)\s*$", re.MULTILINE)


def _scheduled_agent_state_dir():
    """Where the per-label streak state lives.

    Findings themselves are computed per HTTP request and never persisted,
    so the streak has to be. Honours OSTLER_STATE_DIR for tests.
    """
    from pathlib import Path
    base = os.environ.get("OSTLER_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".ostler", "state",
    )
    return Path(base) / "launchd_tick_posture"


def _launchctl_print(label: str) -> "tuple[int, str]":
    """Ask launchd about one job. Returns (rc, combined output).

    rc 127 is reserved for "there is no launchctl here", which is a
    CANNOT-RUN and not a verdict about the job.
    """
    import subprocess
    try:
        proc = subprocess.run(
            ["launchctl", "print", f"gui/{os.getuid()}/{label}"],
            capture_output=True, text=True, timeout=10,
        )
    except FileNotFoundError:
        return 127, "launchctl not found"
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, f"{type(exc).__name__}: {exc}"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _parse_launchd_job(rc: int, out: str) -> dict:
    """Turn `launchctl print` output into a state, with no lossy defaults.

    Deliberately returns `unknown` rather than assuming success whenever a
    field is absent or unparseable. See the #810 note above.
    """
    if rc == 127:
        return {"state": "unknown", "why": out.strip()[:200] or "launchctl unavailable"}
    if rc != 0:
        # launchctl exits non-zero when the label is not registered at all.
        return {"state": "not_loaded", "why": f"launchctl print exited {rc}"}

    runs_m = _LAUNCHD_RUNS_RE.search(out)
    exit_m = _LAUNCHD_EXIT_RE.search(out)
    if runs_m is None:
        return {"state": "unknown", "why": "launchd reported no run count"}
    if exit_m is None:
        # MEASURED, not hypothetical: a job the OS killed reports
        # `last exit reason = JETSAM_REASON_...` and NO `last exit code` at
        # all (com.apple.progressd on the dev Mac, 2026-08-22). We genuinely
        # do not know whether that was a fault, so the state stays unknown --
        # but the reason is carried through rather than thrown away, because
        # "could not tell" with a reason is actionable and "could not tell"
        # on its own is just a shrug.
        reason_m = re.search(
            r"^\s*last exit reason\s*=\s*(.+?)\s*$", out, re.MULTILINE,
        )
        if reason_m:
            return {
                "state": "unknown",
                "why": f"launchd reported no exit code, only "
                       f"'{reason_m.group(1)}' (the job was terminated, not "
                       f"exited)",
            }
        return {"state": "unknown", "why": "launchd reported no last exit code"}

    runs = int(runs_m.group(1))
    exit_raw = exit_m.group(1).strip()

    if runs == 0:
        return {"state": "never_ran", "runs": 0, "why": exit_raw}
    if not exit_raw.lstrip("-").isdigit():
        # "(never exited)" with runs > 0 means the first run is still going.
        return {"state": "in_flight", "runs": runs, "why": exit_raw}

    code = int(exit_raw)
    state = "healthy" if code == 0 else "failing"
    return {"state": state, "runs": runs, "last_exit": code}


def _scheduled_agent_observe(label: str, now=None, obs=None) -> dict:
    """Observe one label and fold it into its persisted streak.

    `obs` is injectable so the tests can drive every branch without a real
    launchd. Never raises: the Doctor must keep rendering.
    """
    import json
    from datetime import datetime, timezone

    now = now or datetime.now(tz=timezone.utc)
    now_iso = now.isoformat()

    if obs is None:
        obs = _parse_launchd_job(*_launchctl_print(label))
    obs = dict(obs)
    obs["label"] = label

    path = _scheduled_agent_state_dir() / f"{label}.json"
    prev = {}
    try:
        if path.is_file():
            prev = json.loads(path.read_text()) or {}
    except (OSError, ValueError):
        prev = {}

    obs["first_observed_at"] = prev.get("first_observed_at") or now_iso
    obs["observed_at"] = now_iso

    if obs["state"] == "failing":
        if prev.get("state") == "failing" and prev.get("failing_since"):
            obs["failing_since"] = prev["failing_since"]
            start = prev.get("runs_at_failing_start")
            obs["runs_at_failing_start"] = (
                start if isinstance(start, int) else obs.get("runs")
            )
        else:
            obs["failing_since"] = now_iso
            obs["runs_at_failing_start"] = obs.get("runs")
        start = obs.get("runs_at_failing_start")
        runs = obs.get("runs")
        if isinstance(start, int) and isinstance(runs, int):
            obs["failed_ticks"] = max(1, runs - start + 1)
        else:
            obs["failed_ticks"] = 1
    else:
        obs["failing_since"] = None
        obs["runs_at_failing_start"] = None
        obs["failed_ticks"] = 0

    # Write only when something changed. The dashboard polls every 10s; the
    # timestamps alone would otherwise rewrite five files 8,640 times a day.
    changed = any(
        prev.get(k) != obs.get(k)
        for k in ("state", "runs", "last_exit", "failing_since")
    ) or not prev
    if changed:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(obs, indent=2, sort_keys=True) + "\n")
            tmp.replace(path)
        except OSError as exc:
            log.warning("could not persist tick posture for %s: %s", label, exc)
    else:
        obs["failing_since"] = prev.get("failing_since")
        obs["first_observed_at"] = prev.get("first_observed_at") or obs["first_observed_at"]

    return obs


def _age_seconds(iso_ts, now) -> "float | None":
    from datetime import datetime, timezone
    if not iso_ts:
        return None
    try:
        ts = datetime.fromisoformat(iso_ts)
    except (TypeError, ValueError):
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return (now - ts).total_seconds()


def _humanise_every(seconds: int) -> str:
    if seconds % 3600 == 0 and seconds >= 3600:
        h = seconds // 3600
        return "hourly" if h == 1 else f"every {h} hours"
    return f"every {max(1, seconds // 60)} minutes"


def check_scheduled_agents(snapshot: Any) -> list[dict]:
    """Surface recurring agents that are failing, have never run, or are gone.

    Emits NOTHING when a job is healthy -- a card per healthy agent would be
    noise, and the whole point is that the abnormal states stop being silent.
    Every finding carries machine-readable `agent_state` / `agent_label` so a
    test can assert the verdict rather than the prose (copy is reworded
    freely in diagnostic_copy.py; a test pinned to a sentence goes
    green-while-blind the day someone improves it).
    """
    from datetime import datetime, timezone

    findings: list[dict] = []
    now = datetime.now(tz=timezone.utc)

    for label, feeds, logname, interval_s in _SCHEDULED_AGENTS:
        obs = _scheduled_agent_observe(label, now=now)
        state = obs.get("state")

        if state in ("healthy", "in_flight"):
            continue

        if state == "failing":
            ticks = obs.get("failed_ticks") or 1
            severity = (
                "critical" if ticks >= _SCHEDULED_AGENT_CRITICAL_AFTER
                else "warning"
            )
            since = _format_upgrade_applied(obs.get("failing_since")) or "recently"
            findings.append({
                "severity": severity,
                "title": SCHEDULED_AGENT_FAILING_TITLE_FMT.format(feeds=feeds),
                "detail": SCHEDULED_AGENT_FAILING_DETAIL_FMT.format(
                    label=label, feeds=feeds, since=since, ticks=ticks,
                    code=obs.get("last_exit"),
                ),
                "fix": SCHEDULED_AGENT_FAILING_FIX,
                "fix_command": SCHEDULED_AGENT_FAILING_FIX_COMMAND_FMT.format(
                    logname=logname, label=label,
                ),
                "risk": "low",
                "category": "ingest",
                "agent_state": "failing",
                "agent_label": label,
                "agent_failed_ticks": ticks,
            })

        elif state == "never_ran":
            # Only once it is genuinely overdue. A fresh install legitimately
            # shows runs = 0, and crying wolf in the first hour would train
            # the customer to ignore the one card that matters.
            age = _age_seconds(obs.get("first_observed_at"), now)
            if age is None or age < interval_s * _SCHEDULED_AGENT_NEVER_RAN_AFTER:
                continue
            since = _format_upgrade_applied(obs.get("first_observed_at")) or "install"
            findings.append({
                "severity": "warning",
                "title": SCHEDULED_AGENT_NEVER_RAN_TITLE_FMT.format(feeds=feeds),
                "detail": SCHEDULED_AGENT_NEVER_RAN_DETAIL_FMT.format(
                    label=label, feeds=feeds, since=since,
                    every=_humanise_every(interval_s),
                ),
                "fix": SCHEDULED_AGENT_NEVER_RAN_FIX,
                "fix_command": SCHEDULED_AGENT_FAILING_FIX_COMMAND_FMT.format(
                    logname=logname, label=label,
                ),
                "risk": "low",
                "category": "ingest",
                "agent_state": "never_ran",
                "agent_label": label,
            })

        elif state == "not_loaded":
            findings.append({
                "severity": "critical",
                "title": SCHEDULED_AGENT_NOT_LOADED_TITLE_FMT.format(feeds=feeds),
                "detail": SCHEDULED_AGENT_NOT_LOADED_DETAIL_FMT.format(
                    label=label, feeds=feeds,
                ),
                "fix": SCHEDULED_AGENT_NOT_LOADED_FIX,
                "fix_command": SCHEDULED_AGENT_NOT_LOADED_FIX_COMMAND_FMT.format(
                    label=label,
                ),
                "risk": "low",
                "category": "ingest",
                "agent_state": "not_loaded",
                "agent_label": label,
            })

        else:
            findings.append({
                "severity": "warning",
                "title": SCHEDULED_AGENT_UNKNOWN_TITLE_FMT.format(feeds=feeds),
                "detail": SCHEDULED_AGENT_UNKNOWN_DETAIL_FMT.format(
                    label=label, why=obs.get("why") or "no reason given",
                ),
                "fix": SCHEDULED_AGENT_UNKNOWN_FIX,
                "fix_command": SCHEDULED_AGENT_UNKNOWN_FIX_COMMAND_FMT.format(
                    label=label,
                ),
                "risk": "low",
                "category": "ingest",
                "agent_state": "unknown",
                "agent_label": label,
            })

    return findings


ALL_RULES = [
    check_scheduled_agents,
    check_hydrate_ingest,
    check_first_install,
    check_container_health,
    check_qdrant_health,
    check_oxigraph_health,
    check_wiki_health,
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
    check_imessage_fda,
    check_last_upgrade,
    check_imessage_capture_stalled,
    check_conversation_dispatch_failures,
]


def run_all_rules(snapshot: Any) -> list[dict]:
    """Run all diagnostic rules and return combined findings."""
    findings = []
    for rule in ALL_RULES:
        try:
            findings.extend(rule(snapshot))
        except Exception as exc:
            # A RULE THAT CRASHED IS NOT A RULE THAT PASSED, AND THE PANEL
            # MUST NOT BE ABLE TO SAY OTHERWISE.
            #
            # This used to be `pass`. The comment said individual rule
            # failures should not crash diagnostics, which is correct, and
            # then it threw the failure away, which is not the same thing.
            # Three rules had been raising AttributeError on EVERY install
            # since they were written, because they read snapshot fields no
            # collector ever set. One of them is check_memory_pressure,
            # severity CRITICAL above 90%. On the v1.0.36 box
            # /api/v1/box-status reported 91% used at the same moment this
            # panel rendered "Everything looks healthy. Nice one."
            #
            # Silence made a broken rule and a healthy machine produce
            # identical output. So the failure becomes a finding. It is
            # deliberately a warning rather than a critical: we do not know
            # what the rule would have said, and inventing a severity we
            # cannot justify would be a different kind of lie. What we DO
            # know, and now state, is that the check did not run.
            rule_name = getattr(rule, "__name__", repr(rule))
            log.warning(
                "diagnostic rule %s raised %s: %s",
                rule_name, type(exc).__name__, exc,
            )
            findings.append({
                "severity": "warning",
                "title": RULE_CRASHED_TITLE_FMT.format(rule=rule_name),
                "detail": RULE_CRASHED_DETAIL_FMT.format(
                    rule=rule_name,
                    error_type=type(exc).__name__,
                ),
                "fix": RULE_CRASHED_FIX,
                "fix_command": RULE_CRASHED_FIX_COMMAND,
                "risk": "low",
                "category": "diagnostics",
            })

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
