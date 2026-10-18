"""Text vectorizer via the local Ollama embedder.

VENDORED SWAP (CM051, 2026-05-31): the upstream CM019 vectorizer used
``sentence_transformers`` (all-MiniLM-L6-v2, 384-dim), which drags in
torch + transformers + sklearn + nltk (~2.5GB). On the single-Mac install
there is already a local Ollama serving ``nomic-embed-text`` (768-dim) that
the rest of the stack uses (people / safari_history / conversations), so
this thin HTTP client reuses that ONE embedding space and ships no torch.

768-dim is required: the wiki reads the ``preferences`` Qdrant collection
which is pre-created at 768, and a 384-dim MiniLM vector would dim-mismatch
and fail to upsert. Same ``/api/embed`` batching as
ostler_fda.pwg_ingest._ollama_embed_batch.

Interface is unchanged from upstream (embed / embed_batch / similarity /
dimension + singleton + module-level ``vectorizer``) so pipeline.py needs no
edits.

USAGE JOURNAL (CM051, #2472): every ``/api/embed`` call here is the customer's
own preference-export ingest, i.e. ``purpose="ingesting"``. CM019 has no
Ollama call upstream at all (it embeds via sentence-transformers), so there is
no source-repo fix to graft -- this wiring can only exist here, vendor-side,
alongside the HTTP-client swap above.

ROLLED UP, NOT PER-CALL (walk-defect review, 2026-10-02): the first cut
here wrote one journal row per ACTUAL HTTP response. Measured on a live
walk: this vectorizer alone wrote 1,099 journal rows from a single ingest
run, a meaningful share of total journal volume with no rotation and no
cache on the Bursar's monthly-summary reader. Switched to the same
60-second ``RollingUsageRecorder`` already used by cm024_knowledge's
embedder (CM051 #2472 volume review) for consistency and the same
size reduction: real measured tokens summed into one row per window,
never estimated.
"""

import logging
import math
from datetime import datetime, timezone
from typing import List, Optional

import httpx

from .config import settings
from ._vendor.ostler_usage_journal import RollingUsageRecorder, tokens_from_ollama

logger = logging.getLogger(__name__)

# Identifies THIS ingest RUN, never the person. One id per process.
_USAGE_SESSION_ID = "cm019-ingest-" + datetime.now(timezone.utc).strftime(
    "%Y-%m-%dT%H:%M:%SZ"
)


class Vectorizer:
    """Generate embeddings via the local Ollama ``/api/embed`` endpoint."""

    _instance: Optional["Vectorizer"] = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self):
        # Stateless HTTP client config; nothing to load (no local model).
        self._url = settings.ollama_url.rstrip("/")
        self._model = settings.embedding_model
        self._dim = settings.embedding_dim
        self._batch = settings.batch_size
        # __init__ reruns every time Vectorizer() is called even though
        # __new__ returns the same singleton -- safe here because the only
        # call site is the module-level `vectorizer = Vectorizer()` below,
        # not a per-call constructor invocation (checked: grep finds no
        # other `Vectorizer()` call anywhere in this package).
        self._usage_recorder = RollingUsageRecorder(
            model=self._model,
            purpose="ingesting",
            session_id=_USAGE_SESSION_ID,
        )

    def embed(self, text: str) -> List[float]:
        """Embed a single text. Empty text returns a zero vector."""
        if not text or not text.strip():
            return [0.0] * self._dim
        return self.embed_batch([text])[0]

    def embed_batch(self, texts: List[str]) -> List[List[float]]:
        """Embed many texts, returning one vector per input in order.

        Empty inputs map to zero vectors. A batch/HTTP failure pads the
        affected slots with zero vectors so callers keep index alignment
        (the Qdrant loader drops zero/empty vectors at upsert time);
        ingestion never aborts on an embedder hiccup.
        """
        if not texts:
            return []

        # Track non-empty inputs so empties become zero vectors.
        idx_map: List[int] = []
        payload_texts: List[str] = []
        for i, t in enumerate(texts):
            if t and t.strip():
                idx_map.append(i)
                payload_texts.append(t)

        embedded: List[List[float]] = []
        transport = httpx.HTTPTransport(proxy=None)
        with httpx.Client(timeout=120.0, transport=transport) as client:
            for start in range(0, len(payload_texts), self._batch):
                chunk = payload_texts[start : start + self._batch]
                try:
                    resp = client.post(
                        f"{self._url}/api/embed",
                        json={"model": self._model, "input": chunk},
                    )
                    resp.raise_for_status()
                    data = resp.json()
                    try:
                        prompt, completion = tokens_from_ollama(
                            data if isinstance(data, dict) else {}
                        )
                        # Never drop a call (Andy's product rule, 2026-10-02:
                        # "I'd rather Bursar overcounted, than undercounted").
                        # When Ollama reports no prompt_eval_count at all,
                        # fall back to a chars/4 estimate of the text this
                        # chunk actually submitted, rather than losing the
                        # call to the panel entirely.
                        estimated_prompt = max(1, sum(len(t) for t in chunk) // 4)
                        self._usage_recorder.add(
                            prompt, completion, estimated_input_tokens=estimated_prompt
                        )
                    except Exception as usage_exc:  # pragma: no cover - defensive
                        logger.warning(
                            "usage journal write skipped (%s): %s",
                            type(usage_exc).__name__,
                            usage_exc,
                        )
                    vecs = data.get("embeddings")
                    if vecs is None or len(vecs) != len(chunk):
                        logger.warning(
                            "Ollama returned %s vectors for %d inputs; "
                            "zero-padding chunk",
                            "None" if vecs is None else len(vecs), len(chunk),
                        )
                        vecs = [[0.0] * self._dim for _ in chunk]
                    embedded.extend(vecs)
                except Exception as exc:
                    logger.warning(
                        "Ollama embed batch failed (start=%d, size=%d): %s",
                        start, len(chunk), type(exc).__name__,
                    )
                    embedded.extend([[0.0] * self._dim for _ in chunk])

        # Reassemble full-length result with zero vectors for empties.
        result: List[List[float]] = [[0.0] * self._dim for _ in texts]
        for slot, vec in zip(idx_map, embedded):
            result[slot] = vec
        return result

    def similarity(self, text1: str, text2: str) -> float:
        """Cosine similarity between two texts (pure-python, no numpy)."""
        a = self.embed(text1)
        b = self.embed(text2)
        dot = sum(x * y for x, y in zip(a, b))
        na = math.sqrt(sum(x * x for x in a))
        nb = math.sqrt(sum(y * y for y in b))
        if na == 0 or nb == 0:
            return 0.0
        return float(dot / (na * nb))

    @property
    def dimension(self) -> int:
        return self._dim


# Global vectorizer instance (preserves upstream import contract).
vectorizer = Vectorizer()
