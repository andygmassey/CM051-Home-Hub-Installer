#!/usr/bin/env python3
"""telemetry.py -- what the box spent to answer, for the memory-tier comparison.

Every number here is either MEASURED or printed as NOT INSTRUMENTED. A source
that did not answer is never read as zero: "0 bytes" and "could not look" look
identical in a log, so a missing reading is a string, not a number.

  physical_ram_gb()        physical RAM (macOS hw.memsize, Linux MemTotal)
  tier_label(ram_gb)       the installer's RAM tiers (install.sh:6471, lib/ostler-model-fit.sh)
  model_facts(get, model)  name, quantisation, parameter size, on-disk bytes, from Ollama /api/tags
  LiveTelemetry(get, model) samples Ollama /api/ps (resident model bytes) and the ollama
                           processes (RSS, CPU time) every SAMPLE_S seconds during a run
  parse_cputime(text)      ps cputime ([dd-][hh:]mm:ss[.cc]) -> seconds
  median(values)           None-safe median

Reads only: the Ollama HTTP API and `ps`. Nothing calls an ollama binary by
name (check_no_bare_ollama.py).
"""
import os
import re
import statistics
import subprocess
import threading
import time

SAMPLE_S = 2.0
NI = "NOT INSTRUMENTED"


def physical_ram_gb():
    """Whole GB of physical RAM, or None if this host cannot say."""
    try:
        out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip().isdigit():
            return int(out.stdout.strip()) // (1 << 30)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for ln in f:
                if ln.startswith("MemTotal:"):
                    return int(ln.split()[1]) // (1 << 20)
    except (OSError, ValueError):
        pass
    return None


def tier_label(ram_gb):
    """The RAM tiers the installer and the model picker actually use.
    <16: below the install floor (install.sh:6472 aborts). 16-23: gemma4:e2b.
    24-47: qwen3.5:9b. 48+: qwen3.5:9b (the 35b row is withheld, v1.0.121)."""
    if ram_gb is None:
        return "unknown"
    if ram_gb < 16:
        return "<16 (below install floor)"
    if ram_gb < 24:
        return "16-23"
    if ram_gb < 48:
        return "24-47"
    return "48+"


def parse_cputime(text):
    """ps cputime: [dd-][hh:]mm:ss[.cc] -> seconds. Raises ValueError on anything else."""
    m = re.match(r"^\s*(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)\s*$", text or "")
    if not m:
        raise ValueError("unparseable cputime %r" % text)
    days, hours, mins, secs = m.groups()
    return ((int(days or 0) * 24 + int(hours or 0)) * 60 + int(mins)) * 60 + float(secs)


def median(values):
    vals = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(vals) if vals else None


def model_facts(get, model):
    """get(path) -> (status, parsed-json). Returns the facts of one model from /api/tags."""
    code, body = get("/api/tags")
    facts = {"model": model, "quant": NI, "parameter_size": NI, "disk_bytes": NI}
    if code != 200:
        facts["note"] = "ollama /api/tags answered %s" % code
        return facts
    for m in (body or {}).get("models") or []:
        if m.get("name") == model or m.get("model") == model:
            det = m.get("details") or {}
            facts["quant"] = det.get("quantization_level") or NI
            facts["parameter_size"] = det.get("parameter_size") or NI
            if isinstance(m.get("size"), int):
                facts["disk_bytes"] = m["size"]
            return facts
    facts["note"] = "model not in /api/tags"
    return facts


def ps_ollama():
    """-> {pid: (rss_bytes, cpu_seconds)} for processes whose executable is ollama.
    A ps failure returns None, never {}."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,rss=,time=,comm="], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    procs = {}
    for ln in out.stdout.splitlines():
        parts = ln.split(None, 3)
        if len(parts) < 4 or os.path.basename(parts[3].strip()) != "ollama":
            continue
        try:
            procs[int(parts[0])] = (int(parts[1]) * 1024, parse_cputime(parts[2]))
        except ValueError:
            continue
    return procs


class LiveTelemetry:
    """Samples during a run. start() / stop() bracket it; stop() returns the summary."""

    def __init__(self, get, model):
        self.get = get
        self.model = model
        self.samples = []
        self._stop = threading.Event()
        self._thread = None
        self.wall0 = None

    def _sample(self):
        code, body = self.get("/api/ps")
        if code == 200 and isinstance(body, dict):
            model_bytes = sum(m.get("size", 0) for m in body.get("models") or []
                              if m.get("name") == self.model or m.get("model") == self.model)
            model_bytes = model_bytes if isinstance(model_bytes, int) else None
        else:
            model_bytes = None
        return {"t": time.time(), "model_bytes": model_bytes, "procs": ps_ollama()}

    def _loop(self):
        while not self._stop.is_set():
            self.samples.append(self._sample())
            self._stop.wait(SAMPLE_S)

    def start(self):
        self.wall0 = time.time()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=SAMPLE_S * 3)
        wall = time.time() - (self.wall0 or time.time())
        return summarise(self.samples, wall, self.model)


def summarise(samples, wall_s, model):
    """Pure: samples -> the telemetry dict. Tested on canned samples in the self-test."""
    out = {"samples": len(samples), "wall_s": round(wall_s, 1), "model": model}
    mb = [s["model_bytes"] for s in samples if s.get("model_bytes") is not None]
    if not mb:
        out.update(peak_model_bytes=NI, steady_model_bytes=NI, model_note="no /api/ps reading in this run")
    else:
        half = mb[len(mb) // 2:] or mb
        out.update(peak_model_bytes=max(mb), steady_model_bytes=statistics.median(half))
    rss = [sum(r for r, _c in s["procs"].values()) for s in samples if s.get("procs") is not None]
    if not rss:
        out.update(peak_rss_bytes=NI, steady_rss_bytes=NI, cpu_seconds=NI, cpu_pct_avg=NI,
                   proc_note="ps could not list ollama processes")
        return out
    half = rss[len(rss) // 2:] or rss
    out.update(peak_rss_bytes=max(rss), steady_rss_bytes=statistics.median(half))
    # CPU: per pid, last reading minus first reading it was seen with. A pid first seen
    # mid-run counts from its first sample, so this is a floor, and the README says so.
    first, last = {}, {}
    for s in samples:
        for pid, (_r, cpu) in (s.get("procs") or {}).items():
            first.setdefault(pid, cpu)
            last[pid] = cpu
    cpu_s = sum(max(0.0, last[p] - first[p]) for p in last)
    out.update(cpu_seconds=round(cpu_s, 2),
               cpu_pct_avg=round(100.0 * cpu_s / wall_s, 1) if wall_s > 0 else NI)
    return out
