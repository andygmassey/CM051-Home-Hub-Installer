"""Local-model arm of cuisine enrichment: offline, always allowed.

Asks the owner's own on-Mac model (the install's tier model, read from
settings.yaml, never a bigger one) which cuisine a restaurant serves, given
its name, area and any dishes. The answer must normalise to a word in the
shared vocabulary or it is discarded: a free-text reply is never stored.

Nothing here leaves the machine: the endpoint is localhost Ollama. An
unreachable model returns None (no evidence), never an error.
"""

from __future__ import annotations

import json
import os
import re
import urllib.request
from pathlib import Path
from typing import Callable, Iterable, Optional

try:  # package import (production) or flat import (tests put derive on sys.path)
    from .cuisine_vocab import VENUE_LABELS, labels, normalise_cuisine, parents
except ImportError:  # pragma: no cover
    from cuisine_vocab import VENUE_LABELS, labels, normalise_cuisine, parents

OLLAMA_URL = "http://127.0.0.1:11434"
# Cuisine labels the model may answer with (venue types are not a guess it can make).
# Top-level cuisines only: a name rarely tells a model Sichuan from Hunan, so it is
# never asked to guess a region.
_ASKABLE = [c for c in labels() if c not in VENUE_LABELS and c not in parents()]
GenerateFn = Callable[[str], Optional[str]]


def tier_model() -> str:
    """The install's enrichment model: env override, else settings.yaml, else gemma4:e2b."""
    env = os.environ.get("OSTLER_FOOD_CUISINE_MODEL")
    if env:
        return env
    settings = Path(os.environ.get("OSTLER_DIR") or Path.home() / ".ostler") / "settings.yaml"
    try:
        m = re.search(r"^ollama_enrich_model:\s*(\S+)", settings.read_text(), re.M)
        if m:
            return m.group(1).strip("\"'")
    except OSError:
        pass
    return "gemma4:e2b"


def ollama_generate(model: Optional[str] = None, base: str = OLLAMA_URL, timeout: float = 20.0) -> GenerateFn:
    """A generate function bound to local Ollama. Returns None on any failure."""
    name = model or tier_model()

    def _gen(prompt: str) -> Optional[str]:
        body = json.dumps({"model": name, "prompt": prompt, "stream": False, "think": False,
                           "options": {"temperature": 0, "num_predict": 12}}).encode()
        req = urllib.request.Request(base + "/api/generate", body, {"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return (json.load(r).get("response") or "").strip()
        except Exception:
            return None

    return _gen


def prompt_for(name: str, area: str = "", dishes: Iterable[str] = ()) -> str:
    bits = [f"Restaurant: {name}"]
    if area:
        bits.append(f"Area: {area}")
    ds = [d for d in dishes if d][:6]
    if ds:
        bits.append("Dishes ordered: " + "; ".join(ds))
    return (
        "You label restaurants with ONE cuisine from this list: " + ", ".join(_ASKABLE) + ".\n"
        "Answer only when the name itself, the dishes, or a well-known restaurant makes the cuisine clear. "
        "If the name is just a surname, a place, a person, a pun or a generic word, answer unknown. "
        "A wrong label is worse than unknown.\n\n"
        "Restaurant: Bella Napoli Pizzeria\nAnswer: italian\n"
        "Restaurant: The Corner House\nAnswer: unknown\n"
        "Restaurant: Jade Garden\nAnswer: unknown\n"
        "Restaurant: Wong Kei Roast Goose\nAnswer: chinese\n"
        "Restaurant: Smith and Daughters\nAnswer: unknown\n\n"
        + "\n".join(bits) + "\nAnswer:"
    )


def infer_with_local_model(name: str, area: str = "", dishes: Iterable[str] = (),
                           generate: Optional[GenerateFn] = None) -> Optional[str]:
    """Canonical cuisine from the local model, or None (unknown, unreachable, off-list)."""
    gen = generate or ollama_generate()
    reply = gen(prompt_for(name, area, dishes))
    if not reply:
        return None
    first = reply.strip().splitlines()[0].strip(" .\"'*")
    got = normalise_cuisine(first)
    return got if got in _ASKABLE else None
