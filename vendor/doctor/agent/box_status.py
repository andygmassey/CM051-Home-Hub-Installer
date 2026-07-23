"""Box-status aggregator - the single live "how hard is the Mac working" read.

Backs ``GET /api/v1/box-status`` (Governor page + header status chip). This is
the *surface* over the throttle/governor engine that already exists; this module
adds only the two readings nothing exposed before - a load-per-core number and a
load-attribution-by-owner breakdown - and rolls together the pieces that already
exist (pause state, governor tier, memory, resident model).

Design constraints (see ``docs/SPEC_governor_status_indicator.md`` in
``ostler-assistant``):

* **Fail-soft, never 500.** Every probe degrades its own field to ``None`` (or a
  documented idle default) on any error. A failing probe must not break the 7 s
  poll.
* **Stdlib only.** No httpx/3rd-party import here, so the aggregator is runnable
  and function-verifiable with a bare ``python3`` (no venv) and adds no new
  dependency to the cut-sensitive Doctor.
* **Honest attribution.** The "whose load is it?" breakdown is an *instantaneous
  CPU% snapshot* (``top -l 2``), **not** the 1-minute loadavg - you cannot
  attribute the run-queue of loadavg to a process. The load meter is loadavg;
  the breakdown is CPU%. They are related, not identical, and the percentages do
  not sum to the loadavg. Ostler's own share (incl. the whole Docker VM) is
  shown even when small; we err toward over-counting *our* share, never hiding
  it.
* **No PII.** Output is process *names* and friendly labels only - never argv,
  never file paths, never usernames.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.request
from typing import Any, Optional

# Ollama endpoint - same env var the rest of the Doctor uses.
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")

# ── Load (primary - drives the chip colour) ─────────────────────────────────


def probe_load() -> Optional[dict[str, Any]]:
    """1-minute loadavg normalised by core count.

    ``load_per_core = loadavg_1min / cpu_cores`` - exactly the self-DOS signal
    (~47 on a ~10-core box ≈ 4.7× per core). ``1.0`` ≈ cores fully committed.
    The "busy" reference is ``OSTLER_LOADAVG_CEILING`` where the resource-tier
    lib exposes it, so the read matches the governor's own defer decision.
    """
    try:
        one, five, fifteen = os.getloadavg()
        cores = os.cpu_count() or 1
        try:
            ceiling = float(os.environ.get("OSTLER_LOADAVG_CEILING", "1.5"))
        except (TypeError, ValueError):
            ceiling = 1.5
        return {
            "per_core": round(one / cores, 2),
            "loadavg_1m": round(one, 2),
            "loadavg_5m": round(five, 2),
            "loadavg_15m": round(fifteen, 2),
            "cores": cores,
            "ceiling": ceiling,
        }
    except OSError:
        return None


# ── Memory ──────────────────────────────────────────────────────────────────


def _total_ram_bytes() -> Optional[int]:
    try:
        out = subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
        return int(out) if out else None
    except Exception:
        return None


def probe_memory() -> Optional[dict[str, Any]]:
    """Used / total RAM via ``hw.memsize`` + ``vm_stat`` (macOS, stdlib only).

    "Used" excludes the purgeable/free pages; we treat (active + wired +
    compressed) as committed and the rest as available. This is the same
    notion macOS Activity Monitor calls "Memory Used" closely enough for a
    comfort read; it is not a forensic figure and is not presented as one.
    """
    total = _total_ram_bytes()
    if not total:
        return None
    try:
        out = subprocess.run(
            ["vm_stat"], capture_output=True, text=True, timeout=3
        ).stdout
    except Exception:
        return None

    # Page size from the header line: "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
    page = 4096
    m = re.search(r"page size of (\d+) bytes", out)
    if m:
        page = int(m.group(1))

    def pages(label: str) -> int:
        mm = re.search(rf"{re.escape(label)}:\s+(\d+)\.", out)
        return int(mm.group(1)) if mm else 0

    active = pages("Pages active")
    wired = pages("Pages wired down")
    compressed = pages("Pages occupied by compressor")
    used_bytes = (active + wired + compressed) * page
    used_bytes = min(used_bytes, total)
    return {
        "used_pct": round(used_bytes / total * 100),
        "used_gb": round(used_bytes / 1024 ** 3, 1),
        "total_gb": round(total / 1024 ** 3, 1),
    }


# ── LLM (resident model memory share) ───────────────────────────────────────


def probe_llm() -> dict[str, Any]:
    """Resident-model VRAM as a share of system RAM ("memory held by the model").

    From Ollama ``GET /api/ps``. No model resident → ``0% (idle)``. We do **not**
    invent a GPU-compute % - Ollama doesn't expose instantaneous utilisation, so
    that would be faked. Always returns a dict (idle on any failure), never None.
    """
    idle = {"pct": 0, "resident": False, "model": None, "vram_gb": 0.0,
            "keep_alive": None}
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/ps")
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return idle

    models = data.get("models") or []
    if not models:
        return idle
    total = _total_ram_bytes()
    vram = sum(int(m.get("size_vram", 0) or 0) for m in models)
    pct = round(vram / total * 100) if total else None
    first = models[0]
    return {
        "pct": pct,
        "resident": True,
        "model": first.get("name"),
        "vram_gb": round(vram / 1024 ** 3, 1),
        "keep_alive": first.get("expires_at"),
    }


# ── Load attribution (I-2) - whose load is it? ──────────────────────────────
#
# CPU% snapshot, NOT loadavg. Bucket the top CPU contributors by OWNER into
# Ostler / macOS system / other apps so the user does not blame Ostler for
# macOS's own first-run housekeeping.

# A process is "Ostler" iff its command matches one of these basenames OR (when
# we can see argv) its argv contains an Ostler path/wrapper hint.
_OSTLER_NAMES = {
    "ostler-assistant", "zeroclaw-gateway", "ollama", "ollama-runner",
    "uvicorn", "web_ui",
    "com.docker.backend", "com.docker.virtualization", "com.docker.hyperkit",
    "qemu-system-aarch64", "vpnkit",
}
# Precise argv hints ONLY - every Ostler wrapper/pipeline runs out of
# ``~/.ostler/``; the Doctor runs as ``doctor.agent.web_ui``. Deliberately NOT
# a bare "ostler" substring: that would mis-claim e.g. a developer's `rustc`
# compiling the ostler-assistant crate, or any path that merely contains the
# word. On a customer box the product processes always carry one of these.
_OSTLER_ARGV_HINTS = ("/.ostler/", "-bundle-tick", "wiki-recompile-tick",
                      "doctor.agent.web_ui")

# macOS first-run housekeeping → the "macOS system" bucket.
_MACOS_NAMES = {
    # Spotlight
    "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync",
    "corespotlightd", "spotlightknowledged",
    # Mail / Messages / on-device indexing & analysis
    "Mail", "mailindexd", "IMDPersistenceAgent", "imagent", "suggestd",
    "knowledgeconstructiond", "knowledge-agent", "mediaanalysisd",
    "photoanalysisd", "photolibraryd", "parsecd", "proactived",
    # iCloud sync / restore
    "cloudd", "bird", "fileproviderd", "apsd", "nsurlsessiond", "cloudphotod",
    "CardDAVPlugin", "accountsd", "akd",
    # generic system housekeeping
    "kernel_task", "WindowServer", "backupd", "syspolicyd", "coreduetd",
}

# Friendly, plain-English labels for the page (basename → human phrase).
_LABELS = {
    "mds": "Spotlight indexing", "mds_stores": "Spotlight indexing",
    "mdworker": "Spotlight indexing", "mdworker_shared": "Spotlight indexing",
    "corespotlightd": "Spotlight indexing",
    "cloudd": "iCloud sync", "bird": "iCloud restore",
    "cloudphotod": "iCloud Photos", "fileproviderd": "iCloud files",
    "nsurlsessiond": "iCloud transfer", "apsd": "Apple push",
    "Mail": "Mail indexing", "mailindexd": "Mail indexing",
    "photoanalysisd": "Photos analysis", "mediaanalysisd": "Media analysis",
    "photolibraryd": "Photos library", "knowledgeconstructiond": "On-device learning",
    "kernel_task": "macOS thermal/system", "WindowServer": "macOS graphics",
    "backupd": "Time Machine",
    "ollama": "Ostler model", "ollama-runner": "Ostler model",
    "ostler-assistant": "Ostler assistant", "zeroclaw-gateway": "Ostler assistant",
    "uvicorn": "Ostler Doctor", "web_ui": "Ostler Doctor",
    "com.docker.backend": "Ostler databases", "com.docker.virtualization": "Ostler databases",
    "com.docker.hyperkit": "Ostler databases", "qemu-system-aarch64": "Ostler databases",
}


def _basename(command: str) -> str:
    """Process basename from an argv string (executable leaf, no PII kept).

    Takes argv's first whitespace-delimited token (the executable path), strips
    any trailing ``/`` and returns the leaf. ``/usr/.../mds_stores -a`` →
    ``mds_stores``; ``claude --flag`` → ``claude``.
    """
    command = command.strip()
    if not command:
        return command
    first = command.split(" ", 1)[0].rstrip("/")
    leaf = first.rsplit("/", 1)[-1]
    return leaf or first


def _categorise(name: str, argv: str, user: str) -> str:
    low_argv = argv.lower()
    if name in _OSTLER_NAMES or any(h in low_argv for h in _OSTLER_ARGV_HINTS):
        return "ostler"
    if name in _MACOS_NAMES or user == "root" or user.startswith("_"):
        return "macos"
    return "other"


# Match `top -l` per-process rows: PID  %CPU  COMMAND...  (COMMAND may have spaces)
_TOP_ROW = re.compile(r"^\s*(\d+)\s+([\d.]+)\s+(.+?)\s*$")


def _ps_user_map() -> dict[int, tuple[str, str]]:
    """pid → (user, argv) via a single `ps` call.

    The authoritative process name is the basename of argv's first token -
    ``top -stats command`` sometimes reports a thread/version artifact instead
    of the real command (e.g. ``2.1.193`` for ``claude``). ``argv`` is used for
    ownership + Ostler-path detection and to derive the name; it is **never**
    returned to the client (only the basename leaks out).
    """
    out_map: dict[int, tuple[str, str]] = {}
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,user=,command="],
            capture_output=True, text=True, timeout=4,
        ).stdout
    except Exception:
        return out_map
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        user = parts[1]
        argv = parts[2] if len(parts) > 2 else ""
        out_map[pid] = (user, argv)
    return out_map


def _parse_top_second_sample(out: str) -> list[tuple[int, float, str]]:
    """Return [(pid, cpu, command)] from the SECOND sample block of `top -l 2`.

    The first sample is a since-boot average that over-counts long-lived
    daemons; only the second sample is a true interval reading. Sample blocks
    are delimited by the "Processes:" header line that `top` reprints per
    sample.
    """
    blocks: list[list[str]] = []
    current: list[str] = []
    for line in out.splitlines():
        if line.startswith("Processes:"):
            if current:
                blocks.append(current)
            current = []
        current.append(line)
    if current:
        blocks.append(current)
    if not blocks:
        return []
    block = blocks[-1]  # second (last) sample
    rows: list[tuple[int, float, str]] = []
    for line in block:
        m = _TOP_ROW.match(line)
        if not m:
            continue
        try:
            pid = int(m.group(1))
            cpu = float(m.group(2))
        except ValueError:
            continue
        rows.append((pid, cpu, m.group(3)))
    return rows


def probe_attribution() -> Optional[dict[str, Any]]:
    """Top CPU contributors bucketed by owner. ``None`` if the probe fails."""
    try:
        out = subprocess.run(
            ["top", "-l", "2", "-n", "16", "-stats", "pid,cpu,command",
             "-o", "cpu"],
            capture_output=True, text=True, timeout=6,
        ).stdout
    except Exception:
        return None

    rows = _parse_top_second_sample(out)
    if not rows:
        return None

    users = _ps_user_map()
    cats = {"ostler": 0.0, "macos": 0.0, "other": 0.0}
    contributors: list[dict[str, Any]] = []
    for pid, cpu, command in rows:
        if cpu <= 0:
            continue
        user, argv = users.get(pid, ("", ""))
        # Authoritative name = basename of argv (top's COMMAND column can mangle
        # it); fall back to top's column only when ps has no argv for the pid.
        name = _basename(argv) if argv else _basename(command)
        cat = _categorise(name, argv, user)
        cats[cat] += cpu
        contributors.append({
            "name": name,
            "category": cat,
            "cpu": round(cpu),
            "label": _LABELS.get(name, name),
        })

    if not contributors:
        return None

    # Roll up duplicate basenames (e.g. several mdworker_shared) for the page.
    rolled: dict[str, dict[str, Any]] = {}
    for c in contributors:
        key = c["name"]
        if key in rolled:
            rolled[key]["cpu"] += c["cpu"]
        else:
            rolled[key] = dict(c)
    top = sorted(rolled.values(), key=lambda c: c["cpu"], reverse=True)[:6]

    ostler_pct = round(cats["ostler"])
    macos_pct = round(cats["macos"])
    if macos_pct >= ostler_pct:
        explanation = (
            "Your Mac is finishing macOS's own setup - indexing files and "
            "restoring iCloud after the install. That's normal and eases off "
            f"over the next few hours. Ostler itself is using ~{ostler_pct}%."
        )
    else:
        explanation = (
            f"Ostler is doing background catch-up - using ~{ostler_pct}% of "
            "the Mac right now. It eases off as it settles, and you can pause "
            "it any time below."
        )

    return {
        "basis": "cpu",
        "note": "CPU% snapshot (top -l 2), not loadavg; does not sum to the load meter.",
        "categories": {k: round(v) for k, v in cats.items()},
        "top": top,
        "explanation": explanation,
    }


# ── Settling / running (reuse existing signals, fail-soft) ──────────────────


def probe_settling() -> Optional[dict[str, Any]]:
    """Best-effort settle-progress from the pipeline-signals substrate.

    The richer per-phase hydration feed is owned elsewhere; here we degrade to
    a coarse complete/incomplete read from the first-ingest sentinel so the
    page can say "still settling" without fabricating a percentage. Returns
    ``None`` when we genuinely cannot tell.
    """
    try:
        from status_collector import collect_pipeline_signals  # type: ignore

        sig = collect_pipeline_signals()
    except Exception:
        return None
    if sig is None:
        return None
    complete = bool(getattr(sig, "first_ingest_complete_ts", None))
    return {
        "complete": complete,
        "progress": None,      # no honest fine-grained % available here
        "eta_minutes": None,
        "phase": None,
    }


# ── Top-level aggregator ────────────────────────────────────────────────────


def _governor() -> dict[str, Any]:
    """Re-read the live governor tier the same way the governor-status route
    does, fail-soft to a minimal unknown payload."""
    enabled = True
    try:
        from config_panel import _load_raw  # type: ignore

        if _load_raw().get("governor_enabled") is False:
            enabled = False
    except Exception:
        pass

    import os.path as _osp
    from pathlib import Path

    lib = os.environ.get(
        "OSTLER_RESOURCE_TIER_LIB",
        str(Path.home() / ".ostler" / "lib" / "ostler-resource-tier.sh"),
    )
    tier = None
    deferring = None
    if _osp.isfile(lib):
        script = (
            f'. "{lib}"; ostler_resource_tier_detect; '
            'printf "%s\\n" "$OSTLER_TIER"; '
            'if ostler_resource_tier_should_defer_nonessential; '
            'then echo defer; else echo run; fi'
        )
        try:
            res = subprocess.run(
                ["bash", "-c", script], capture_output=True, text=True, timeout=5
            )
            lines = [ln.strip() for ln in res.stdout.splitlines() if ln.strip()]
            if lines:
                tier = lines[0]
            if len(lines) > 1:
                deferring = lines[1] == "defer"
        except Exception:
            pass
    return {"enabled": enabled, "tier": tier, "deferring": deferring}


def _pause() -> dict[str, Any]:
    try:
        from pause_control import read_state  # type: ignore

        return read_state()
    except Exception:
        return {"paused": False, "expiry": None, "indefinite": False,
                "expiry_human": ""}


def _derive_state(load: Optional[dict], memory: Optional[dict],
                  llm: dict, paused: bool) -> str:
    """Worst-of-inputs band. ``unknown`` when we have no load *and* no memory."""
    if paused:
        return "paused"
    if load is None and memory is None:
        return "unknown"
    overloaded = False
    busy = False
    if load is not None:
        per_core = load["per_core"]
        ceiling = load.get("ceiling") or 1.5
        if per_core >= ceiling or per_core >= 1.5:
            overloaded = True
        elif per_core >= 0.7:
            busy = True
    if memory is not None:
        if memory["used_pct"] > 90:
            overloaded = True
        elif memory["used_pct"] >= 75:
            busy = True
    if isinstance(llm.get("pct"), (int, float)) and llm["pct"] >= 90:
        overloaded = True
    if overloaded:
        return "overloaded"
    if busy:
        return "busy"
    return "comfortable"


def _running(governor: dict, settling: Optional[dict]) -> list[str]:
    """Best-effort list of what's working right now (plain English). Empty when
    nothing is known to be running or work is paused/deferred."""
    running: list[str] = []
    if settling is not None and not settling.get("complete"):
        running.append("first-run catch-up")
    if governor.get("deferring"):
        # Deferring means the governor is holding non-essential work back.
        return running
    return running


def box_status() -> dict[str, Any]:
    """Assemble the full box-status payload. Never raises; every field
    degrades independently to ``None`` / idle on failure."""
    load = probe_load()
    memory = probe_memory()
    llm = probe_llm()
    attribution = probe_attribution()
    governor = _governor()
    pause = _pause()
    settling = probe_settling()
    paused = bool(pause.get("paused"))

    state = _derive_state(load, memory, llm, paused)
    return {
        "state": state,
        "load": load,
        "memory": memory,
        "llm": llm,
        "governor": governor,
        "pause": {
            "paused": paused,
            "expiry_human": pause.get("expiry_human", ""),
            "indefinite": bool(pause.get("indefinite")),
        },
        "settling": settling,
        "running": _running(governor, settling),
        "attribution": attribution,
    }


if __name__ == "__main__":  # function-verification entrypoint
    print(json.dumps(box_status(), indent=2))
