"""Tier-model stage for stated preferences: the model decides POLARITY only.

The deterministic parser (``stated.py``) is strict by design: it needs a
first-person subject next to a cue ("I hate coffee"). Real messages are looser
("lol hate coffee", "so good, love the Sichuan place"). This stage recovers
some of those, and nothing else changes:

- ORDER. The reader's ``filtered_lines()`` runs FIRST. Every privacy filter (L3,
  minors, deceased/suppressed, not-the-owner, assistant sends, quotes and
  forwards) has already removed a line before this module can see it. The model
  never sees a filtered line.
- PREFILTER. A line goes to the model only if it carries a sentiment word AND a
  vocabulary term in the same line, and the deterministic parser did not already
  settle that term.
- THE MODEL DECIDES POLARITY ONLY. The candidates (dimension, value) come from
  the vocabulary, not from the model; its answer is constrained JSON
  ``{dim, value, polarity}`` and any item that is not one of the candidates, or
  has a polarity other than like/dislike, is dropped and COUNTED.
- TIER MODEL ONLY, loopback Ollama, temperature 0. The caller names the model;
  this module never picks a bigger one.
- RESOURCES. A per-tick cap on model calls (default 200), a per-line timeout,
  a wait for the user-active lease before every request (never preempting chat),
  and an abort after repeated timeouts. The wrapper that runs this takes the
  shared ingest slot and the resource-tier defer, so chat and the brief never
  queue behind it.
- NO TEXT. Verdicts are stored as ``salted-hash(conversation, time, line) ->
  [{dimension, value, polarity}]``. The salt is random per install. No line, no
  message id, no conversation id is stored.
- CANCEL-SAFE. The verdict cache is written atomically in a ``finally``, the
  in-flight counter is reset in a ``finally``, so a cancel while a line is queued
  or in flight leaks nothing and the next tick resumes from the cache.

The once-per-conversation-per-month rule still applies to model hits: they join
the same cell as deterministic hits in ``StatedTranscriptReader.read``.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import time
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

from .stated import MEDIUM, Stance, StatedMapper, _norm_text
from .stated_messages import OwnerLine

MODEL_STRENGTH = MEDIUM
DEFAULT_CAP = 200
DEFAULT_LINE_TIMEOUT = 20.0
MAX_TIMEOUTS_PER_TICK = 3
MAX_LINE_CHARS = 600

# Wider than the deterministic cue set on purpose: this only nominates a line
# for the model, which still has to say LIKE or DISLIKE.
SENTIMENT = re.compile(
    r"\b(?:hate[sd]?|hating|can't stand|cannot stand|can't bear|not a fan|no fan|not really a fan|"
    r"not keen|not into|love[sd]?|loving|adore[sd]?|obsessed|favou?rite|prefer\w*|never again|"
    r"crave|craving|craves|allergic|sick of|dislike[sd]?|detest\w*|despise\w*|can't get enough|"
    r"addicted|so good|the best|disgusting|gross|yuck|yum)\b"
)


class StageCancelled(BaseException):
    """Raised by a signal handler (or a test) to cancel the stage mid-flight."""


def prefilter(mapper: StatedMapper, text: str) -> List[Tuple[str, str]]:
    """Candidate (dimension, value) pairs: sentiment word AND a vocab term, and
    not already settled by the deterministic parser. Empty = do not call."""
    t = _norm_text(text)
    if len(t) > MAX_LINE_CHARS or not SENTIMENT.search(t):
        return []
    terms = {(d, c) for _s, _e, d, c in mapper._terms_in(t)}
    done = {(s.dimension, s.value) for s in mapper.parse_message(text)}
    return sorted(terms - done)


class VerdictCache:
    """salted-hash(line) -> [{dimension, value, polarity}]. No text, no ids."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.salt = ""
        self.verdicts: Dict[str, List[dict]] = {}
        if self.path.is_file():
            try:
                doc = json.loads(self.path.read_text())
                self.salt = str(doc.get("salt", ""))
                self.verdicts = {k: v for k, v in doc.get("verdicts", {}).items() if isinstance(v, list)}
            except (OSError, ValueError):
                self.salt, self.verdicts = "", {}      # unreadable cache: start over, never guess
        if not self.salt:
            self.salt = secrets.token_hex(16)

    def key(self, ol: OwnerLine) -> str:
        raw = f"{self.salt}|{ol.conv}|{ol.when.isoformat() if ol.when else ''}|{ol.text}"
        return hashlib.sha256(raw.encode()).hexdigest()[:24]

    def has(self, ol: OwnerLine) -> bool:
        return self.key(ol) in self.verdicts

    def put(self, ol: OwnerLine, items: List[dict]) -> None:
        self.verdicts[self.key(ol)] = items

    def stances_for(self, ol: OwnerLine) -> List[Stance]:
        out = []
        for it in self.verdicts.get(self.key(ol), []):
            sign = -1.0 if it["polarity"] == "dislike" else 1.0
            out.append(Stance(it["dimension"], it["value"], sign * MODEL_STRENGTH, "model"))
        return out

    def save(self) -> None:
        """Atomic: a cancel mid-write leaves the previous file, never half of one."""
        tmp = self.path.with_name(self.path.name + ".tmp")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps({"schema": 1, "salt": self.salt, "verdicts": self.verdicts}, sort_keys=True))
        os.replace(tmp, self.path)


def validate(answer: object, candidates: Sequence[Tuple[str, str]], stats: Counter) -> List[dict]:
    """Keep only {dim, value, polarity} items that are a candidate with a real
    polarity. Everything else is dropped and counted."""
    if not isinstance(answer, dict) or not isinstance(answer.get("items"), list):
        stats["dropped_shape"] += 1
        return []
    allowed = set(candidates)
    out = []
    for it in answer["items"]:
        if not isinstance(it, dict) or set(it) - {"dim", "value", "polarity"}:
            stats["dropped_shape"] += 1
            continue
        key = (it.get("dim"), it.get("value"))
        pol = it.get("polarity")
        if key not in allowed:
            stats["dropped_not_a_candidate"] += 1
        elif pol == "none":
            stats["model_none"] += 1
        elif pol not in ("like", "dislike"):
            stats["dropped_polarity"] += 1
        else:
            out.append({"dimension": key[0], "value": key[1], "polarity": pol})
    return out


PROMPT = (
    "Below is ONE message that a person SENT. For each candidate item, decide "
    "whether the SENDER states THEIR OWN like or dislike of it. Answer 'none' "
    "for questions, requests, wishes, jokes, plans, other people's tastes, "
    "descriptions, or anything that is not the sender's own stated taste.\n"
    "Candidates: %s\nMessage: %s"
)


class OllamaPolarityModel:
    """Loopback Ollama, temperature 0, schema-constrained output. Tier model only."""

    def __init__(self, model: str, url: str = "http://127.0.0.1:11434", timeout: float = DEFAULT_LINE_TIMEOUT):
        self.model, self.url, self.timeout = model, url, timeout

    @staticmethod
    def _num_ctx() -> int:
        raw = os.environ.get("OSTLER_ENRICH_NUM_CTX", "").strip()
        try:
            v = int(raw)
            return v if v >= 2048 else 32768
        except ValueError:
            return 32768

    def __call__(self, text: str, candidates: Sequence[Tuple[str, str]]) -> object:
        schema = {
            "type": "object",
            "properties": {"items": {"type": "array", "items": {
                "type": "object",
                "properties": {
                    "dim": {"type": "string", "enum": sorted({d for d, _ in candidates})},
                    "value": {"type": "string", "enum": sorted({v for _, v in candidates})},
                    "polarity": {"type": "string", "enum": ["like", "dislike", "none"]},
                },
                "required": ["dim", "value", "polarity"],
            }}},
            "required": ["items"],
        }
        body = json.dumps({
            "model": self.model, "stream": False, "format": schema,
            "options": {"temperature": 0, "num_ctx": self._num_ctx()},
            "prompt": PROMPT % ("; ".join(f"{d} = {v}" for d, v in candidates), text),
        }).encode()
        req = urllib.request.Request(self.url + "/api/generate", data=body,
                                     headers={"Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=self.timeout) as r:
            return json.loads(json.load(r).get("response", ""))


def wait_until_user_idle(max_wait: float = 30.0, poll: float = 0.5, path: Optional[Path] = None) -> bool:
    """True when the user is NOT chatting. Same contract as ollama_user_active:
    ``~/.ostler/run/ollama-user-active`` holds an epoch-millis 'active until'; a
    missing or garbage file is idle. False = still active after ``max_wait``."""
    lease = Path(path or os.environ.get("OSTLER_USER_ACTIVE_LEASE", "~/.ostler/run/ollama-user-active")).expanduser()
    waited = 0.0
    while True:
        try:
            until = int(lease.read_text().strip())
        except (OSError, ValueError):
            return True
        if time.time() * 1000.0 >= until:
            return True
        if waited >= max_wait:
            return False
        time.sleep(poll)
        waited += poll


@dataclass
class StageResult:
    stats: Counter = field(default_factory=Counter)
    in_flight: int = 0


def run_stage(
    reader,                                  # a StatedTranscriptReader (its filters run first)
    model: Callable[[str, Sequence[Tuple[str, str]]], object],
    cache: VerdictCache,
    cap: int = DEFAULT_CAP,
    wait_idle: Callable[[], bool] = wait_until_user_idle,
    result: Optional[StageResult] = None,
) -> StageResult:
    """One tick: nominate, call the model for up to ``cap`` new lines, cache verdicts."""
    res = result or StageResult()
    st = res.stats
    timeouts = 0
    try:
        for ol in reader.filtered_lines():
            cands = prefilter(reader.mapper, ol.text)
            if not cands:
                continue
            st["prefilter_hits"] += 1
            if cache.has(ol):
                st["cached"] += 1
                continue
            if st["model_calls"] >= cap:
                st["deferred_over_cap"] += 1
                continue
            if not wait_idle():
                st["stopped_user_active"] += 1
                break
            res.in_flight += 1
            try:
                st["model_calls"] += 1
                answer = model(ol.text, cands)
            except (TimeoutError, OSError) as exc:     # urllib's URLError/timeouts are OSErrors
                st["model_errors"] += 1
                timeouts += 1
                if timeouts >= MAX_TIMEOUTS_PER_TICK:
                    st["aborted_unhealthy_model"] += 1
                    break
                continue                                # not cached: retried next tick
            except ValueError:                          # unparseable JSON
                st["dropped_shape"] += 1
                cache.put(ol, [])
                continue
            finally:
                res.in_flight -= 1
            kept = validate(answer, cands, st)
            cache.put(ol, kept)
            st["verdict_hits" if kept else "verdict_empty"] += 1
            st["hits_like"] += sum(1 for k in kept if k["polarity"] == "like")
            st["hits_dislike"] += sum(1 for k in kept if k["polarity"] == "dislike")
    finally:
        cache.save()
    return res


def main(argv=None) -> int:
    import argparse
    import signal
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "common"))   # services/common: `strength`
    from .config import build_readers
    from .readers import HttpStoreGateway
    from .stated_messages import StatedTranscriptReader

    ap = argparse.ArgumentParser(description="One tick of the stated-preference tier-model stage.")
    ap.add_argument("--model", required=True, help="the TIER model tag; never pass a bigger one")
    ap.add_argument("--cap", type=int, default=int(os.environ.get("OSTLER_STATED_MODEL_CAP", DEFAULT_CAP)))
    ap.add_argument("--timeout", type=float, default=DEFAULT_LINE_TIMEOUT)
    ap.add_argument("--cache", type=Path, default=Path(os.environ.get("OSTLER_DIR") or Path.home() / ".ostler")
                    / "workspace" / "stated_model_verdicts.json")
    ap.add_argument("--oxigraph-url", default=os.environ.get("OXIGRAPH_URL", "http://localhost:7878"))
    args = ap.parse_args(argv)

    def _cancel(signum, frame):
        raise StageCancelled()

    signal.signal(signal.SIGTERM, _cancel)
    gateway = HttpStoreGateway(oxigraph_url=args.oxigraph_url)
    reader = next(r for r in build_readers(gateway) if isinstance(r, StatedTranscriptReader))
    res = run_stage(reader, OllamaPolarityModel(args.model, timeout=args.timeout),
                    VerdictCache(args.cache), cap=args.cap)
    print(json.dumps({**res.stats, **reader.stats}, sort_keys=True))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
