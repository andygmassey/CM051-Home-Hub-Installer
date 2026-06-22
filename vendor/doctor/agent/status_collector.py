"""
Ostler Doctor – Local Status Collector

Collects safe diagnostic information from the local PWG installation.
This module ONLY gathers system-level data: service health, versions,
disk usage, container states, and network connectivity.

SECURITY: This module MUST NOT collect or expose:
- Knowledge graph data (Qdrant vectors, Oxigraph triples)
- Conversation content (Redis stream messages)
- Contact names, email content, calendar events
- File contents from user directories
- Environment variable values
- Docker container logs (may contain PII)
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import httpx

# ---------------------------------------------------------------------------
# Configuration – service endpoints (all localhost by default)
# ---------------------------------------------------------------------------

QDRANT_URL = os.getenv("QDRANT_URL", "http://localhost:6333")
OXIGRAPH_URL = os.getenv("OXIGRAPH_URL", "http://localhost:7878")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")
GATEWAY_URL = os.getenv("GATEWAY_URL", "http://localhost:8000")

HTTP_TIMEOUT = 5.0  # seconds


# ---------------------------------------------------------------------------
# Data classes for diagnostic info
# ---------------------------------------------------------------------------


@dataclass
class DockerContainerInfo:
    name: str
    image: str
    state: str
    status: str
    uptime_seconds: int | None = None


# Container-name prefixes Ostler accepts. The canonical productised prefix
# is `ostler-` (per CM051 install.sh). `pwg-` is from the dev / single-mac
# compose files in CM019 / CM043, retained so an Andy-style dev deployment
# is recognised by the doctor.
OSTLER_CONTAINER_PREFIXES = ("ostler-", "pwg-")
EXPECTED_OSTLER_SERVICES = ("qdrant", "oxigraph", "redis")


def is_ostler_container(c: "DockerContainerInfo") -> bool:
    """True if this container looks like an Ostler-managed service.

    Match on name prefix; falls back to image substring for resilience
    (a renamed container should still be detected as Ostler if its
    image is one of the bundled ones).
    """
    if any(c.name.startswith(p) for p in OSTLER_CONTAINER_PREFIXES):
        return True
    img = (c.image or "").lower()
    return any(
        sig in img
        for sig in ("qdrant", "oxigraph", "valkey", "redis:")
    )


def detect_ostler_prefix(snapshot: "SystemSnapshot") -> str:
    """Infer which container-name prefix this deployment uses by
    looking at its running containers. Defaults to the productised
    prefix when no Ostler containers are running yet."""
    for c in snapshot.docker_containers:
        for p in OSTLER_CONTAINER_PREFIXES:
            if c.name.startswith(p):
                return p
    return "ostler-"


# Architecture signal. The productised Ostler build is single-machine
# native (launchd, native processes -- NOT a second Docker *host*);
# HR015 locked this directive 2026-05-09. NOTE: "native" does NOT mean
# "no Docker" -- the data tier (Qdrant/Oxigraph/Redis) runs in
# containers via Colima even on the native build. The legacy gamingrig
# dev deploy runs the same services under Docker Desktop. The two builds
# want different Doctor diagnostics: the native build needs no Docker
# *Desktop* install (Colima provides the runtime), so the
# "Docker Desktop not installed / not running" rules are false-RED
# criticals there and must be suppressed -- a real data-tier outage is
# already covered by the per-service unreachable rules. The legacy
# Docker-Desktop deploy opts back into those rules by exporting
# ``OSTLER_DEPLOY_MODE=docker`` (set on the dev compose). The productised
# default is native, so the customer never sees a spurious Docker-Desktop
# critical lead the support-email report.
def is_native_deployment() -> bool:
    """True on the productised single-machine native build.

    Reads ``OSTLER_DEPLOY_MODE``. Anything other than the explicit
    legacy value ``docker`` (case-insensitive) resolves to native --
    the productised default -- so a fresh customer install with the
    env var unset gets the native (Docker-rule-suppressed) posture.
    """
    return os.environ.get("OSTLER_DEPLOY_MODE", "native").strip().lower() != "docker"


@dataclass
class OllamaModelInfo:
    name: str
    size_gb: float | None = None
    quantisation: str | None = None


@dataclass
class DiskUsageInfo:
    mount_point: str
    total_gb: float
    used_gb: float
    free_gb: float
    percent_used: float


@dataclass
class ServiceHealthInfo:
    name: str
    status: str  # healthy, unhealthy, unreachable
    status_code: int | None = None
    version: str | None = None


@dataclass
class NetworkCheckInfo:
    source: str
    target: str
    reachable: bool
    latency_ms: float | None = None


@dataclass
class PipelineSignalsInfo:
    """Install-time + first-run probe results written by the CM051
    installer and the email-ingest tick.

    Persisted at ``~/.ostler/state/pipeline_signals.json``. Single
    file is the shared substrate for #259 (was Mail detected at
    install?) and #260 (has the email backfill reached completion?).
    Keys are intentionally additive; a missing key resolves to
    ``None`` so future probe-types do not break old Doctor builds.
    """

    # #259 install-time Mail probe
    mail_accounts_found: int | None = None
    mail_has_fetched: bool | None = None
    # Epoch seconds, set by the installer on successful completion.
    install_completed_ts: int | None = None
    # #260 first-ingest sentinel, set by email-ingest-tick.sh on the
    # first non-empty ingest. Used by the 48h "extend history" timer.
    first_ingest_complete_ts: int | None = None


@dataclass
class BackfillCheckpointInfo:
    """Snapshot of the email-ingest backfill checkpoint (#260).

    Mirrors the load-bearing subset of
    ``ostler_fda.apple_mail_mbox.Checkpoint`` so the Doctor agent can
    render backfill progress without importing the package. The
    checkpoint file is owned by the email-ingest LaunchAgent; Doctor
    is read-only.

    Datetime fields stay as strings here because the doctor agent
    runs inside a slim container that imports as little as it can
    get away with; consumers parse on demand.

    Persisted at
    ``~/.ostler/state/apple_mail_mbox_checkpoint.json`` (also the
    default referenced from the email-ingest tick).
    """

    newest_processed: str | None = None   # ISO 8601
    oldest_processed: str | None = None   # ISO 8601
    backfill_complete: bool = False
    last_run_at: str | None = None        # ISO 8601
    last_emit_count: int = 0


@dataclass
class SystemSnapshot:
    timestamp: str = ""
    hostname: str | None = None
    os_version: str | None = None
    docker_containers: list[DockerContainerInfo] = field(default_factory=list)
    ollama_models: list[OllamaModelInfo] = field(default_factory=list)
    ollama_version: str | None = None
    disk_usage: list[DiskUsageInfo] = field(default_factory=list)
    services: list[ServiceHealthInfo] = field(default_factory=list)
    network_checks: list[NetworkCheckInfo] = field(default_factory=list)
    pwg_version: str | None = None
    docker_version: str | None = None
    pipeline_signals: PipelineSignalsInfo | None = None
    backfill_checkpoint: BackfillCheckpointInfo | None = None


# ---------------------------------------------------------------------------
# Collector functions – each gathers one category of safe data
# ---------------------------------------------------------------------------


def _docker_bin() -> str:
    """Resolve the docker executable.

    The Doctor runs as a launchd LaunchAgent, whose PATH does not include
    Homebrew's /opt/homebrew/bin (nor /usr/local/bin on Intel). A bare
    "docker" lookup therefore raises FileNotFoundError, so every
    Docker-derived signal (version, containers) reads as absent even when
    Docker is installed and running. On the native single-machine install
    this strands the first-run wizard on Step 1 forever. Resolve an
    absolute path so Docker is detected regardless of the launchd PATH.
    """
    found = shutil.which("docker")
    if found:
        return found
    for candidate in (
        "/opt/homebrew/bin/docker",
        "/usr/local/bin/docker",
        "/usr/bin/docker",
    ):
        if os.path.exists(candidate):
            return candidate
    # Fall back to the bare name so behaviour is unchanged when docker is
    # genuinely absent (FileNotFoundError handled by the callers).
    return "docker"


def collect_docker_containers() -> tuple[list[DockerContainerInfo], str | None]:
    """
    Get Docker container names, images, and states.
    Does NOT collect logs (may contain PII).
    """
    try:
        result = subprocess.run(
            [
                _docker_bin(), "ps", "-a",
                "--format", "{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return [], f"docker ps failed: exit code {result.returncode}"

        containers = []
        for line in result.stdout.strip().split("\n"):
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) >= 4:
                containers.append(DockerContainerInfo(
                    name=parts[0],
                    image=parts[1],
                    state=parts[2],
                    status=parts[3],
                ))
        return containers, None
    except FileNotFoundError:
        return [], "Docker not installed"
    except subprocess.TimeoutExpired:
        return [], "docker ps timed out"


def collect_docker_version() -> str | None:
    """Get Docker version string."""
    try:
        result = subprocess.run(
            [_docker_bin(), "version", "--format", "{{.Server.Version}}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def collect_ollama_models() -> tuple[list[OllamaModelInfo], str | None, str | None]:
    """
    Get Ollama model list and version.
    Only collects model names and sizes – no inference data.
    """
    models = []
    version = None

    try:
        client = httpx.Client(timeout=HTTP_TIMEOUT)

        # Version
        try:
            resp = client.get(f"{OLLAMA_URL}/api/version")
            if resp.status_code == 200:
                version = resp.json().get("version")
        except httpx.RequestError:
            pass

        # Models
        try:
            resp = client.get(f"{OLLAMA_URL}/api/tags")
            if resp.status_code == 200:
                for model in resp.json().get("models", []):
                    size_bytes = model.get("size", 0)
                    size_gb = round(size_bytes / (1024**3), 2) if size_bytes else None

                    # Extract quantisation from name if present
                    name = model.get("name", "unknown")
                    quant = None
                    for q in ("Q4_K_M", "Q4_0", "Q5_K_M", "Q8_0", "F16", "Q4", "Q5", "Q8"):
                        if q.lower() in name.lower():
                            quant = q
                            break

                    models.append(OllamaModelInfo(
                        name=name,
                        size_gb=size_gb,
                        quantisation=quant,
                    ))
            return models, version, None
        except httpx.RequestError as e:
            return models, version, f"Ollama unreachable: {e}"
    finally:
        pass

    return models, version, None


def collect_disk_usage() -> list[DiskUsageInfo]:
    """
    Get disk usage for key mount points.
    Reports percentages only – no file listings, no path contents.
    """
    mount_points = ["/", "/data"]
    # Also check common PWG data locations
    extra = ["/var/lib/docker", "/home"]
    mount_points.extend(extra)

    results = []
    seen = set()

    for mp in mount_points:
        if not os.path.exists(mp):
            continue
        try:
            usage = shutil.disk_usage(mp)
            # Deduplicate by device (same filesystem)
            key = (usage.total, usage.used)
            if key in seen:
                continue
            seen.add(key)

            total = usage.total
            if total == 0:
                continue
            results.append(DiskUsageInfo(
                mount_point=mp,
                total_gb=round(total / (1024**3), 2),
                used_gb=round(usage.used / (1024**3), 2),
                free_gb=round(usage.free / (1024**3), 2),
                percent_used=round((usage.used / total) * 100, 1),
            ))
        except OSError:
            continue

    return results


def collect_service_health() -> list[ServiceHealthInfo]:
    """
    Check health of PWG services via their HTTP endpoints.
    Only records status codes – does NOT query data endpoints.
    """
    services = [
        ("qdrant", QDRANT_URL, "/healthz"),
        ("oxigraph", OXIGRAPH_URL, "/"),
        ("redis", None, None),  # special case: TCP check
        ("ollama", OLLAMA_URL, "/"),
        ("gateway", GATEWAY_URL, "/health"),
    ]

    results = []
    client = httpx.Client(timeout=HTTP_TIMEOUT)

    for name, base_url, path in services:
        if name == "redis":
            # Redis: simple TCP connectivity check (no data query)
            results.append(_check_redis())
            continue

        try:
            resp = client.get(f"{base_url}{path}")
            results.append(ServiceHealthInfo(
                name=name,
                status="healthy" if resp.status_code < 400 else "unhealthy",
                status_code=resp.status_code,
            ))
        except httpx.RequestError:
            results.append(ServiceHealthInfo(
                name=name,
                status="unreachable",
                status_code=None,
            ))

    return results


def _check_redis() -> ServiceHealthInfo:
    """Check Redis connectivity via TCP. Does NOT read any keys."""
    import socket

    # Parse host/port from REDIS_URL
    url = REDIS_URL.replace("redis://", "")
    host, _, port_str = url.partition(":")
    port = int(port_str) if port_str else 6379

    try:
        sock = socket.create_connection((host, port), timeout=3)
        # Send PING, expect PONG (standard Redis health check, no data access)
        sock.sendall(b"PING\r\n")
        response = sock.recv(64).decode()
        sock.close()
        is_healthy = "PONG" in response
        return ServiceHealthInfo(
            name="redis",
            status="healthy" if is_healthy else "unhealthy",
            status_code=200 if is_healthy else 500,
        )
    except (OSError, TimeoutError):
        return ServiceHealthInfo(
            name="redis",
            status="unreachable",
            status_code=None,
        )


def collect_network_checks() -> list[NetworkCheckInfo]:
    """
    Check whether key services can reach each other.
    Only checks TCP connectivity – no data is transferred.
    """
    import socket

    checks = [
        ("gateway", "qdrant", "localhost", 6333),
        ("gateway", "oxigraph", "localhost", 7878),
        ("gateway", "redis", "localhost", 6379),
        ("gateway", "ollama", "localhost", 11434),
    ]

    results = []
    for source, target, host, port in checks:
        start = time.monotonic()
        try:
            sock = socket.create_connection((host, port), timeout=3)
            sock.close()
            latency = round((time.monotonic() - start) * 1000, 1)
            results.append(NetworkCheckInfo(
                source=source,
                target=target,
                reachable=True,
                latency_ms=latency,
            ))
        except (OSError, TimeoutError):
            results.append(NetworkCheckInfo(
                source=source,
                target=target,
                reachable=False,
                latency_ms=None,
            ))

    return results


def collect_os_info() -> tuple[str | None, str | None]:
    """Get hostname (used for the local dashboard subtitle only) and OS version.
    Hostname is NOT sent in the email-report body – see _format_report in web_ui.py.
    """
    import platform

    hostname = platform.node()
    # Strip domain from FQDN if present
    hostname = hostname.split(".")[0] if hostname else None

    os_version = f"{platform.system()} {platform.release()}"
    return hostname, os_version


# ---------------------------------------------------------------------------
# Main collector – assembles a full snapshot
# ---------------------------------------------------------------------------


def _pipeline_signals_path() -> Path:
    """Where the installer + ticks write probe results.

    Overridable for tests via ``OSTLER_STATE_DIR``. Customer install
    leaves the default ``~/.ostler/state/`` path.
    """
    base = os.environ.get("OSTLER_STATE_DIR")
    if base:
        return Path(base) / "pipeline_signals.json"
    return Path.home() / ".ostler" / "state" / "pipeline_signals.json"


def collect_pipeline_signals() -> PipelineSignalsInfo | None:
    """Read ``pipeline_signals.json`` (#259 + #260 shared sidecar).

    Missing file is not an error -- it just means no install-time
    probes have run yet (e.g. a customer running Doctor before the
    installer completed). Returns ``None`` so diagnostic rules can
    skip cleanly.

    Unknown keys in the file are ignored. Missing keys resolve to
    ``None`` on the dataclass field. The file is owned by the
    installer + the email-ingest tick; Doctor is read-only.
    """
    path = _pipeline_signals_path()
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        # Corrupt or unreadable -- treat as absent rather than
        # raising. The installer rewrites on the next run.
        return None
    if not isinstance(data, dict):
        return None
    return PipelineSignalsInfo(
        mail_accounts_found=_safe_int(data.get("mail_accounts_found")),
        mail_has_fetched=_safe_bool(data.get("mail_has_fetched")),
        install_completed_ts=_safe_int(data.get("install_completed_ts")),
        first_ingest_complete_ts=_safe_int(
            data.get("first_ingest_complete_ts"),
        ),
    )


def _backfill_checkpoint_path() -> Path:
    """Where the email-ingest tick writes its progressive-backfill state.

    Overridable for tests via ``OSTLER_STATE_DIR``. Matches the path
    used by ``ostler_fda.apple_mail_mbox.default_checkpoint_path``.
    """
    base = os.environ.get("OSTLER_STATE_DIR")
    if base:
        return Path(base) / "apple_mail_mbox_checkpoint.json"
    return Path.home() / ".ostler" / "state" / "apple_mail_mbox_checkpoint.json"


def collect_backfill_checkpoint() -> BackfillCheckpointInfo | None:
    """Read the email-ingest backfill checkpoint (#260).

    Missing file means the first tick has not yet run -- return
    ``None`` so diagnostic rules can decide whether to render a
    "pipeline not started" state separately.

    Forward-compatible with the v1 checkpoint schema (which carried
    only ``last_emitted_received_at``): if ``newest_processed`` is
    absent we fall back to the v1 field so an upgraded Doctor reading
    a pre-upgrade checkpoint still surfaces real data.
    """
    path = _backfill_checkpoint_path()
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    newest = data.get("newest_processed") or data.get("last_emitted_received_at")
    return BackfillCheckpointInfo(
        newest_processed=_safe_iso_string(newest),
        oldest_processed=_safe_iso_string(data.get("oldest_processed")),
        backfill_complete=bool(data.get("backfill_complete", False)),
        last_run_at=_safe_iso_string(data.get("last_run_at")),
        last_emit_count=_safe_int(data.get("last_emit_count")) or 0,
    )


def _safe_iso_string(value) -> str | None:
    """Return ``value`` if it is a non-empty string, else ``None``.

    No format validation -- we just pass through whatever the writer
    set so the rule layer can parse on demand. Empty string + None
    both collapse to None for the cleaner ``getattr(..., "...")``
    pattern in rules.
    """
    if isinstance(value, str) and value.strip():
        return value
    return None


def _safe_int(value) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _safe_bool(value) -> bool | None:
    if isinstance(value, bool):
        return value
    if value is None:
        return None
    # Accept JSON-style "true" / "false" strings the installer might
    # emit via shell-side jq.
    if isinstance(value, str):
        v = value.strip().lower()
        if v in ("true", "1", "yes"):
            return True
        if v in ("false", "0", "no"):
            return False
    return None


def collect_pwg_version() -> str | None:
    """Return the deployed Ostler version from the release manifest.

    Reads ``~/.ostler/ostler-release.json`` (WORKSTREAM C / C2). Returns
    the ``ostler_version`` string, or ``None`` when no manifest is on
    disk (fresh install before install.sh has emitted one) or it is
    unreadable. Backwards-tolerant + never raises -- a missing manifest
    leaves ``pwg_version`` unset and the version surface degrades to
    "unknown" rather than 500-ing the dashboard.

    Imported function-locally to avoid a hard import dependency at
    module load: Doctor must keep rendering even in a minimal venv.
    """
    try:
        from release_manifest import read_release_manifest

        manifest = read_release_manifest()
    except Exception:  # noqa: BLE001 -- Doctor must never crash on a reader
        return None
    if not manifest:
        return None
    version = manifest.get("ostler_version")
    if not version or version == "unknown":
        return None
    return version


def collect_full_snapshot() -> SystemSnapshot:
    """
    Collect a complete safe diagnostic snapshot.

    This is the main entry point. Returns a SystemSnapshot containing
    only safe, non-personal diagnostic data.
    """
    hostname, os_version = collect_os_info()
    containers, _docker_err = collect_docker_containers()
    docker_version = collect_docker_version()
    models, ollama_version, _ollama_err = collect_ollama_models()
    disk = collect_disk_usage()
    services = collect_service_health()
    network = collect_network_checks()
    pipeline_signals = collect_pipeline_signals()
    backfill_checkpoint = collect_backfill_checkpoint()
    pwg_version = collect_pwg_version()

    return SystemSnapshot(
        timestamp=datetime.now(timezone.utc).isoformat(),
        hostname=hostname,
        os_version=os_version,
        docker_containers=containers,
        ollama_models=models,
        ollama_version=ollama_version,
        disk_usage=disk,
        services=services,
        network_checks=network,
        pwg_version=pwg_version,
        docker_version=docker_version,
        pipeline_signals=pipeline_signals,
        backfill_checkpoint=backfill_checkpoint,
    )
