"""Page summaries for ordinary browsing, and "Save to Knowledge" (Lane 6).

Why this file exists
--------------------
``api_safari_ingest`` used to store only url, title, domain and timestamp,
so a browsing entry meant nothing beyond a bare URL. The extensions now send
an optional readable ``text`` with a visit that passes a worth-it filter. This
module turns that text into a SHORT summary plus topic tags and key entities
with the local model, and writes the result back onto the stored visit.

Design rules, each enforced by tests in ``tests/test_browsing_enrich.py``:

* The raw page text is DROPPED after summarising. Only summary, tags and
  entities survive. The text is held in a spool file (0600) only until the
  worker has handled it, and a failed or aged job is deleted, never kept.
* The worker is background work. It yields to a foreground chat turn through
  the user-active lease the daemon refreshes (``~/.ostler/run/ollama-user-
  active``, same contract as CM024 and CM048), it is rate limited, and the
  queue is bounded. Save-to-Knowledge jobs (an explicit user action) go
  ahead of browsing jobs but obey the same lease.
* No network fetch of page content, ever. Only the Hub's own loopback Qdrant
  and Ollama are called, with the same urllib style as ``_embed_text``.
* Pure stdlib, so it ships beside ``ical-server.py`` like ``subscription_gate``.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

# ── Caps ────────────────────────────────────────────────────────────
TEXT_CAP_CHARS = 20 * 1024            # ordinary visit text
KNOWLEDGE_TEXT_CAP_CHARS = 200 * 1024  # explicit Save to Knowledge
# Only this much of the text is shown to the model: a 16 GB machine runs an
# 8192 (or 4096 on the floor tier) context for enrichment, see
# OSTLER_ENRICH_NUM_CTX in CM051 install.sh.
PROMPT_CHARS_VISIT = 8000
PROMPT_CHARS_KNOWLEDGE = 14000
MAX_TAGS_USER = 20
MAX_TAG_CHARS = 40
MAX_NOTE_CHARS = 2000

# Privacy level for Save to Knowledge items. Every Knowledge source (Evernote,
# Apple Notes, Obsidian, Notion) writes compartment_level 2 by default and the
# Doctor importers cap embedding at 2 (OSTLER_KNOWLEDGE_MAX_COMPARTMENT_LEVEL
# default 2): level 3 is withheld from the searchable collection, so 2 is the
# strictest level that is still rendered by the wiki Knowledge wing.
KNOWLEDGE_COMPARTMENT_LEVEL = 2
KNOWLEDGE_COLLECTION = os.environ.get("WIKI_KNOWLEDGE_COLLECTION", "evernote_knowledge")
KNOWLEDGE_SOURCE = "web_clip"
KNOWLEDGE_NOTEBOOK = "Saved web pages"


# ── Explicit, editable text skip list ───────────────────────────────
# Pages matching this list still get their VISIT stored, but no page text is
# captured or summarised. The same default list ships in the extensions
# (contract/hub_contract.json is the shared copy). The customer edits the
# Hub side in USER_SKIPLIST_PATH, one entry per line.
DEFAULT_TEXT_SKIPLIST: Dict[str, Any] = {
    "host_substrings": [
        "bank", "paypal", "stripe.com", "wise.com", "revolut", "monzo",
        "barclays", "hsbc", "natwest", "lloyds", "santander", "halifax",
        "nationwide", "amex", "americanexpress", "mastercard", "visa.com",
        "coinbase", "binance", "kraken.com", "nhs.uk", "patient",
        "healthgrades", "webmd", "mayoclinic", "pharmacy", "doctolib",
        "zocdoc", "medical", "clinic", "hospital", "therapy", "psychology",
        "mentalhealth", "mail.google.com", "outlook.live.com",
        "outlook.office.com", "mail.yahoo.com", "mail.proton.me",
        "icloud.com", "accounts.google.com", "appleid.apple.com",
        "login.microsoftonline",
    ],
    "path_patterns": [
        "login", "log-in", "signin", "sign-in", "signup", "sign-up", "auth",
        "oauth", "password", "checkout", "cart", "basket", "payment",
        "billing", "account", "settings", "search", "results",
    ],
    "query_params": ["q", "query", "search", "s"],
    "hosts_exact_or_suffix": ["localhost", "127.0.0.1", "::1"],
    "host_patterns": ["intranet", "internal", "corp", ".local", ".lan"],
    "private_ip_prefixes": (
        ["10.", "192.168."] + ["172.%d." % n for n in range(16, 32)]
    ),
}

USER_SKIPLIST_PATH = os.environ.get(
    "OSTLER_BROWSING_SKIPLIST_PATH",
    os.path.expanduser("~/.ostler/config/browsing_text_skiplist.txt"),
)


def load_user_skiplist(path: Optional[str] = None) -> List[str]:
    """Customer-editable extras: one lowercase host substring per line,
    ``#`` starts a comment. A missing or unreadable file is an empty list
    (the defaults still apply)."""
    try:
        with open(path or USER_SKIPLIST_PATH, "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except Exception:
        return []
    out = []
    for line in lines:
        line = line.split("#", 1)[0].strip().lower()
        if line:
            out.append(line)
    return out


def text_skip_reason(url: str, user_extra: Optional[List[str]] = None) -> str:
    """Return a short reason string when page text must NOT be captured for
    ``url``, or an empty string when it may be."""
    from urllib.parse import urlparse, parse_qs
    try:
        parsed = urlparse(url or "")
    except Exception:
        return "unparseable_url"
    scheme = (parsed.scheme or "").lower()
    if scheme not in ("http", "https"):
        return "non_web_scheme"
    host = (parsed.hostname or "").lower()
    if not host:
        return "no_host"
    d = DEFAULT_TEXT_SKIPLIST
    for h in d["hosts_exact_or_suffix"]:
        if host == h or host.endswith("." + h):
            return "local_host"
    if any(host.startswith(p) for p in d["private_ip_prefixes"]):
        return "private_ip"
    if any(p in host for p in d["host_patterns"]):
        return "intranet"
    if any(s in host for s in d["host_substrings"]):
        return "sensitive_host"
    extra = load_user_skiplist() if user_extra is None else user_extra
    if any(s and s in host for s in extra):
        return "user_skiplist"
    path = (parsed.path or "").lower()
    segs = [s for s in re.split(r"[/_.\-]", path) if s]
    for pat in d["path_patterns"]:
        if "-" in pat:
            if pat in path:
                return "path_" + pat
        elif pat in segs:
            return "path_" + pat
    query = parse_qs(parsed.query or "")
    if any(q in query for q in d["query_params"]):
        return "search_results"
    return ""


def clamp_text(text: Any, cap: int) -> str:
    if not isinstance(text, str):
        return ""
    return text[:cap]


# ── User-active lease (yield to chat) ───────────────────────────────
# Same contract as CM024 ostler_knowledge/ollama_user_active.py and CM048
# src/ollama_user_active.py: the daemon writes epoch-millis "active until"
# on every foreground chat turn. Missing or garbage means idle.
USER_ACTIVE_LEASE = os.environ.get(
    "OSTLER_USER_ACTIVE_LEASE", "~/.ostler/run/ollama-user-active"
)


def user_active(now_ms: Optional[int] = None, lease_path: Optional[str] = None) -> bool:
    try:
        raw = Path(lease_path or USER_ACTIVE_LEASE).expanduser().read_text(
            encoding="utf-8"
        ).strip()
        until = int(raw)
    except Exception:
        return False
    now = int(time.time() * 1000) if now_ms is None else now_ms
    return now < until


# ── Local model (Ollama on loopback) ────────────────────────────────
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")


class ModelUnavailable(Exception):
    """The summary model cannot be used. ``reason`` is the stored,
    customer-visible code. Never retried: the same call fails the same way."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _ostler_env_file() -> str:
    return os.environ.get("OSTLER_ENV_FILE") or os.path.expanduser("~/.ostler/.env")


def _model_from_env_file() -> str:
    """AI_MODEL from the compose ``~/.ostler/.env``. install.sh writes the
    model it actually pulled there (CM051 install.sh:15087-15091), and the
    wiki compiler reads it from the same file (install.sh:19885). The
    ical-server launchd job has no AI_MODEL in its own environment, so this
    file is the one place on an installed Hub that names the pulled model."""
    try:
        with open(_ostler_env_file(), encoding="utf-8") as fh:
            val = ""
            for line in fh:
                if line.startswith("AI_MODEL="):
                    val = line.split("=", 1)[1].strip().strip("\"'").strip()
            return val
    except OSError:
        return ""


def summary_model() -> Optional[str]:
    """The model the installer pulled, or None. OSTLER_BROWSING_MODEL
    overrides for browsing only; then AI_MODEL from the environment; then
    AI_MODEL from ``~/.ostler/.env``. There is NO built-in default: a name
    the installer did not pull fails every summary silently (measured on
    macmini16-walk 2026-10-07, qwen3.5:9b absent, gemma4:e2b present)."""
    return (os.environ.get("OSTLER_BROWSING_MODEL")
            or os.environ.get("AI_MODEL")
            or _model_from_env_file()
            or None)


def _num_ctx() -> int:
    # install.sh sets OSTLER_ENRICH_NUM_CTX per resource tier (4096 floor,
    # 8192 low, empty on high). Browsing summaries never need more than 8192.
    try:
        n = int(os.environ.get("OSTLER_ENRICH_NUM_CTX") or 0)
    except ValueError:
        n = 0
    return n if n > 0 else 8192


def ollama_generate(prompt: str, *, timeout: float = 120.0) -> str:
    """POST /api/generate on the loopback Ollama, same urllib style as the
    Hub's ``_embed_text``. qwen3 gets no native JSON mode (it degenerates to
    ``{}``), so JSON is requested in the prompt and recovered by
    ``extract_json``."""
    model = summary_model()
    if not model:
        print("[browsing-enrich] ERROR no summary model configured: AI_MODEL is "
              f"not in the environment or in {_ostler_env_file()}. Summaries "
              "will be marked failed (no_model_configured).", file=sys.stderr, flush=True)
        raise ModelUnavailable("no_model_configured")
    body = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "think": False,
        "options": {"temperature": 0.2, "num_ctx": _num_ctx(), "num_predict": 700},
    }
    if not model.lower().startswith("qwen3"):
        body["format"] = "json"
    req = urllib.request.Request(
        OLLAMA_URL.rstrip("/") + "/api/generate",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read()).get("response", "")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            print(f"[browsing-enrich] ERROR summary model {model!r} is not installed "
                  "in Ollama (HTTP 404). Summaries will be marked failed "
                  "(model_not_installed). Run `ollama list` and check AI_MODEL in "
                  f"{_ostler_env_file()}.", file=sys.stderr, flush=True)
            raise ModelUnavailable("model_not_installed") from exc
        raise


def extract_json(raw: str) -> Optional[dict]:
    if not raw:
        return None
    try:
        obj = json.loads(raw)
        return obj if isinstance(obj, dict) else None
    except Exception:
        pass
    m = re.search(r"\{.*\}", raw, re.DOTALL)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


_JSON_RULES = (
    "Reply with ONLY a JSON object, no prose, no code fence. "
    "Use the page's own language."
)


def visit_prompt(title: str, url: str, text: str) -> str:
    return (
        "You summarise a web page the user read, so a personal assistant can "
        "recall it later. " + _JSON_RULES + "\n"
        'Keys: "summary" (1 to 2 sentences, plain, no marketing words), '
        '"tags" (3 to 6 lowercase topic tags), '
        '"entities" (up to 8 key people, organisations, places or products named).\n\n'
        f"Title: {title}\nURL: {url}\n\nPage text:\n{text[:PROMPT_CHARS_VISIT]}"
    )


def knowledge_prompt(title: str, url: str, text: str, user_tags: List[str], note: str) -> str:
    return (
        "You write a Knowledge entry for a page the user chose to save. "
        + _JSON_RULES + "\n"
        'Keys: "summary" (a short paragraph of 3 to 5 sentences), '
        '"key_points" (3 to 7 short bullet strings), '
        '"tags" (3 to 8 lowercase subject tags), '
        '"entities" (up to 12 people, organisations, places or products named).\n\n'
        f"Title: {title}\nURL: {url}\n"
        f"The user's own tags: {', '.join(user_tags) or 'none'}\n"
        f"The user's own note: {note or 'none'}\n\nPage text:\n{text[:PROMPT_CHARS_KNOWLEDGE]}"
    )


def _clean_list(value: Any, limit: int, maxlen: int = MAX_TAG_CHARS, lower: bool = False) -> List[str]:
    out: List[str] = []
    if isinstance(value, str):
        value = [v for v in re.split(r"[,\n]", value)]
    if not isinstance(value, list):
        return out
    seen = set()
    for item in value:
        if not isinstance(item, str):
            continue
        s = re.sub(r"\s+", " ", item).strip().strip("#").strip()
        if lower:
            s = s.lower()
        s = s[:maxlen]
        if s and s.lower() not in seen:
            seen.add(s.lower())
            out.append(s)
        if len(out) >= limit:
            break
    return out


def normalise_visit_result(obj: Optional[dict]) -> Optional[dict]:
    """Model output -> stored shape, or None when the model gave nothing
    usable (a failed summary must not be stored as a real one)."""
    if not obj:
        return None
    summary = re.sub(r"\s+", " ", str(obj.get("summary") or "")).strip()[:500]
    if not summary:
        return None
    return {
        "summary": summary,
        "tags": _clean_list(obj.get("tags"), 6, lower=True),
        "entities": _clean_list(obj.get("entities"), 8, maxlen=80),
    }


def normalise_knowledge_result(obj: Optional[dict]) -> Optional[dict]:
    if not obj:
        return None
    summary = re.sub(r"\s+", " ", str(obj.get("summary") or "")).strip()[:1500]
    if not summary:
        return None
    return {
        "summary": summary,
        "key_points": _clean_list(obj.get("key_points"), 7, maxlen=300),
        "tags": _clean_list(obj.get("tags"), 8, lower=True),
        "entities": _clean_list(obj.get("entities"), 12, maxlen=80),
    }


def clean_user_tags(tags: Any) -> List[str]:
    return _clean_list(tags, MAX_TAGS_USER, lower=False)


def clean_note(note: Any) -> str:
    return note.strip()[:MAX_NOTE_CHARS] if isinstance(note, str) else ""


# ── Knowledge item (same collection and shape as the Evernote, Notes,
#    Obsidian and Notion importers; CM044 knowledge_pages.py renders it) ──
def knowledge_id(url: str, timestamp: str) -> str:
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"knowledge|web_clip|{url}|{timestamp}"))


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s[:60] or "page"


def render_knowledge_markdown(title: str, url: str, result: Optional[dict],
                              user_tags: List[str], note: str) -> str:
    parts: List[str] = []
    if result:
        parts.append("## Summary\n\n" + result["summary"])
        if result["key_points"]:
            parts.append("## Key points\n\n" + "\n".join("- " + p for p in result["key_points"]))
        if result["entities"]:
            parts.append("## Mentioned\n\n" + ", ".join(result["entities"]))
    if note:
        parts.append("## My note\n\n" + note)
    parts.append("## Source\n\n" + url)
    return "\n\n".join(parts)


def build_knowledge_point(*, url: str, title: str, timestamp: str, device: str,
                          visit_id: str, result: Optional[dict],
                          user_tags: List[str], note: str,
                          failure_reason: str = "") -> dict:
    """Return the Qdrant payload (no vector) for a Saved web page.

    Field names are the union the real writers and the real reader use:
    cm024 ``QdrantStore.upsert`` (note_id, evernote_guid, chunk_index, title,
    content, tags, compartment_level, importance_score, source_url, created,
    updated, content_hash) and CM044 ``_assemble_note`` (rel_path, notebook,
    source, author). User tags come first and are always preserved."""
    kid = knowledge_id(url, timestamp)
    model_tags = result["tags"] if result else []
    tags: List[str] = []
    seen = set()
    for t in list(user_tags) + list(model_tags):
        if t.lower() not in seen:
            seen.add(t.lower())
            tags.append(t)
    content = render_knowledge_markdown(title, url, result, user_tags, note)
    return {
        "note_id": kid,
        "evernote_guid": kid,
        "rel_path": f"web/{_slug(title)}-{kid[:8]}",
        "chunk_index": 0,
        "title": title or url,
        "content": content,
        "tags": tags,
        "user_tags": list(user_tags),
        "notebook": KNOWLEDGE_NOTEBOOK,
        "source": KNOWLEDGE_SOURCE,
        "author": "",
        "source_url": url,
        "created": timestamp,
        "updated": timestamp,
        "compartment_level": KNOWLEDGE_COMPARTMENT_LEVEL,
        "importance_score": 1.0,
        "content_hash": hashlib.sha256(content.encode("utf-8")).hexdigest(),
        "entities": result["entities"] if result else [],
        "user_note": note,
        "visit_id": visit_id,
        "device": device,
        "summarised": bool(result),
        "summary_status": "done" if result else "failed",
        "summary_error": "" if result else (failure_reason or "no_summary"),
    }


# ── Loopback Qdrant helpers (collection-agnostic) ───────────────────
def _q(base: str, path: str, method: str = "GET", body: Any = None, timeout: float = 15.0):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base.rstrip("/") + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def qdrant_get_payload(base: str, collection: str, point_id: str) -> Optional[dict]:
    """The stored payload of a point, or None when it is absent or Qdrant
    cannot be reached (fail open: callers then write normally)."""
    try:
        res = _q(base, f"/collections/{collection}/points/{point_id}")
        return (res.get("result") or {}).get("payload") or None
    except Exception:
        return None


def qdrant_set_payload(base: str, collection: str, point_id: str, payload: dict) -> bool:
    try:
        _q(base, f"/collections/{collection}/points/payload?wait=true", "POST",
           {"payload": payload, "points": [point_id]}, timeout=30.0)
        return True
    except Exception:
        return False


def qdrant_update_vector(base: str, collection: str, point_id: str, vector: List[float]) -> bool:
    try:
        _q(base, f"/collections/{collection}/points/vectors?wait=true", "PUT",
           {"points": [{"id": point_id, "vector": vector}]}, timeout=30.0)
        return True
    except Exception:
        return False


def qdrant_ensure_collection(base: str, collection: str, size: int) -> None:
    try:
        _q(base, f"/collections/{collection}", timeout=5.0)
        return
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            raise
    _q(base, f"/collections/{collection}", "PUT",
       {"vectors": {"size": size, "distance": "Cosine"}})


def qdrant_upsert(base: str, collection: str, point_id: str, vector: List[float], payload: dict) -> bool:
    try:
        _q(base, f"/collections/{collection}/points?wait=true", "PUT",
           {"points": [{"id": point_id, "vector": vector, "payload": payload}]}, timeout=30.0)
        return True
    except Exception:
        return False


# ── Queue and worker ────────────────────────────────────────────────
KIND_VISIT = "visit"
KIND_KNOWLEDGE = "knowledge"

SPOOL_DIR = os.environ.get(
    "OSTLER_BROWSING_QUEUE_DIR", os.path.expanduser("~/.ostler/state/browsing_queue")
)
MAX_QUEUE = int(os.environ.get("OSTLER_BROWSING_QUEUE_MAX", "100"))
MIN_INTERVAL_S = float(os.environ.get("OSTLER_BROWSING_SUMMARY_INTERVAL_S", "20"))
MAX_ATTEMPTS = 3
MAX_JOB_AGE_S = 24 * 3600
MAX_YIELD_S = 120.0  # never wait longer than this on the lease per job


class EnrichQueue:
    """Spool-backed, bounded, rate-limited summary queue.

    ``summarise(job) -> dict | None`` and ``store(job, result) -> bool`` are
    injected so the logic is testable with no model and no Qdrant. A job's
    raw ``text`` lives only in its spool file and in memory until handled;
    ``store`` never receives it.
    """

    def __init__(self, spool_dir: str, summarise: Callable[[dict], Optional[dict]],
                 store: Callable[[dict, Optional[dict]], bool], *,
                 min_interval_s: float = MIN_INTERVAL_S, max_queue: int = MAX_QUEUE,
                 is_user_active: Callable[[], bool] = user_active,
                 sleep: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.time):
        self.dir = Path(spool_dir)
        self.summarise = summarise
        self.store = store
        self.min_interval_s = min_interval_s
        self.max_queue = max_queue
        self.is_user_active = is_user_active
        self._sleep = sleep
        self._clock = clock
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._last_call = 0.0
        self.yielded = 0  # count of lease waits, for tests and the Doctor

    # -- spool -------------------------------------------------------
    def _path(self, job_id: str) -> Path:
        return self.dir / (re.sub(r"[^A-Za-z0-9_.-]", "_", job_id) + ".json")

    def _jobs(self) -> List[dict]:
        out = []
        try:
            names = sorted(self.dir.glob("*.json"))
        except Exception:
            return out
        for p in names:
            try:
                out.append(json.loads(p.read_text(encoding="utf-8")))
            except Exception:
                try:
                    p.unlink()
                except Exception:
                    pass
        return out

    def depth(self) -> int:
        with self._lock:
            return len(self._jobs())

    def enqueue(self, job: dict) -> bool:
        """Persist ``job`` ({id, kind, text, ...}). Returns False when the
        bounded queue dropped it (a browsing job is dropped, never a
        knowledge job)."""
        job = dict(job)
        job.setdefault("kind", KIND_VISIT)
        job["queued_at"] = self._clock()
        job["attempts"] = 0
        with self._lock:
            self.dir.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(self.dir, 0o700)
            except Exception:
                pass
            existing = self._jobs()
            visit_jobs = [j for j in existing if j.get("kind") == KIND_VISIT]
            if job["kind"] == KIND_VISIT and len(visit_jobs) >= self.max_queue:
                return False
            if len(existing) >= self.max_queue and job["kind"] == KIND_KNOWLEDGE and visit_jobs:
                oldest = min(visit_jobs, key=lambda j: j.get("queued_at", 0))
                self._drop(oldest["id"])
            p = self._path(job["id"])
            fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(job, fh)
        self._wake.set()
        return True

    def _drop(self, job_id: str) -> None:
        try:
            self._path(job_id).unlink()
        except Exception:
            pass

    def _next(self) -> Optional[dict]:
        jobs = self._jobs()
        if not jobs:
            return None
        # Explicit user saves first, then oldest first.
        jobs.sort(key=lambda j: (0 if j.get("kind") == KIND_KNOWLEDGE else 1, j.get("queued_at", 0)))
        return jobs[0]

    # -- worker ------------------------------------------------------
    def _yield_to_chat(self) -> None:
        waited = 0.0
        while self.is_user_active() and waited < MAX_YIELD_S:
            self.yielded += 1
            self._sleep(0.5)
            waited += 0.5

    def run_once(self) -> bool:
        """Handle at most one job. Returns True when a job was handled."""
        with self._lock:
            job = self._next()
        if job is None:
            return False
        jid = job["id"]
        if self._clock() - job.get("queued_at", 0) > MAX_JOB_AGE_S:
            self._drop(jid)
            self.store(job_without_text(job), None)
            return True
        self._yield_to_chat()
        gap = self.min_interval_s - (self._clock() - self._last_call)
        if gap > 0:
            self._sleep(gap)
        self._last_call = self._clock()
        result = None
        unusable = ""
        try:
            result = self.summarise(job)
        except ModelUnavailable as exc:
            unusable = exc.reason
            job["failure_reason"] = unusable
        except Exception:
            result = None
        if result is None and not unusable and job.get("attempts", 0) + 1 < MAX_ATTEMPTS:
            job["attempts"] = job.get("attempts", 0) + 1
            with self._lock:
                p = self._path(jid)
                fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    json.dump(job, fh)
            return True
        # Final: success, or out of attempts. Either way the raw text goes.
        self._drop(jid)
        try:
            self.store(job_without_text(job), result)
        except Exception:
            pass
        return True

    def start(self) -> None:
        with self._lock:
            if self._thread and self._thread.is_alive():
                return
            self._thread = threading.Thread(target=self._loop, name="browsing-enrich", daemon=True)
            self._thread.start()

    def _loop(self) -> None:
        while True:
            try:
                handled = self.run_once()
            except Exception:
                handled = False
            if not handled:
                self._wake.wait(timeout=30.0)
                self._wake.clear()


def job_without_text(job: dict) -> dict:
    return {k: v for k, v in job.items() if k != "text"}
