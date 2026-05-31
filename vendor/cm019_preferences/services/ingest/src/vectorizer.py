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
"""

import logging
import math
from typing import List, Optional

import httpx

from .config import settings

logger = logging.getLogger(__name__)


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
                    vecs = resp.json().get("embeddings")
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
