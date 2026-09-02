"""
Embedder - Generate vector embeddings for text chunks.

Supports both local (Ollama) and cloud (OpenAI) embedding providers.

Usage:
    embedder = Embedder(provider="ollama", model="nomic-embed-text")
    vectors = await embedder.embed_batch(texts)
"""

import asyncio
import logging
from dataclasses import dataclass
from typing import List, Optional, Union

logger = logging.getLogger(__name__)


@dataclass
class EmbeddingResult:
    """Result of embedding a text."""

    text: str
    vector: List[float]
    model: str
    dimensions: int


class Embedder:
    """
    Generate embeddings using local or cloud providers.

    Supports:
    - Ollama (local): nomic-embed-text, all-minilm, mxbai-embed-large
    - OpenAI (cloud): text-embedding-3-small, text-embedding-3-large
    """

    # Model configurations
    MODEL_CONFIGS = {
        # Ollama models
        "nomic-embed-text": {"provider": "ollama", "dimensions": 768},
        "all-minilm": {"provider": "ollama", "dimensions": 384},
        "mxbai-embed-large": {"provider": "ollama", "dimensions": 1024},
        # OpenAI models
        "text-embedding-3-small": {"provider": "openai", "dimensions": 1536},
        "text-embedding-3-large": {"provider": "openai", "dimensions": 3072},
        "text-embedding-ada-002": {"provider": "openai", "dimensions": 1536},
    }

    def __init__(
        self,
        provider: str = "ollama",
        model: str = "nomic-embed-text",
        batch_size: int = 32,
        ollama_host: str = "http://localhost:11434",
        openai_api_key: Optional[str] = None,
    ):
        """
        Initialize the embedder.

        Args:
            provider: "ollama" or "openai"
            model: Model name
            batch_size: Batch size for API calls
            ollama_host: Ollama server URL
            openai_api_key: OpenAI API key (if using OpenAI)
        """
        self.provider = provider
        self.model = model
        self.batch_size = batch_size
        self.ollama_host = ollama_host
        self.openai_api_key = openai_api_key

        # Get dimensions from config or use default
        config = self.MODEL_CONFIGS.get(model, {})
        self.dimensions = config.get("dimensions", 768)

        self._stats = {
            'texts_embedded': 0,
            'batches_processed': 0,
            'errors': 0,
        }

        # Validate configuration
        if provider == "openai" and not openai_api_key:
            logger.warning("OpenAI provider selected but no API key provided")

    async def embed(self, text: str) -> Optional[List[float]]:
        """
        Embed a single text.

        Args:
            text: Text to embed

        Returns:
            Vector embedding or None on error
        """
        results = await self.embed_batch([text])
        return results[0] if results else None

    async def embed_batch(self, texts: List[str]) -> List[Optional[List[float]]]:
        """
        Embed multiple texts.

        Args:
            texts: List of texts to embed

        Returns:
            List of vector embeddings (None for failed texts)
        """
        if not texts:
            return []

        results = []

        # Process in batches
        for i in range(0, len(texts), self.batch_size):
            batch = texts[i:i + self.batch_size]

            try:
                if self.provider == "ollama":
                    batch_results = await self._embed_ollama(batch)
                elif self.provider == "openai":
                    batch_results = await self._embed_openai(batch)
                else:
                    logger.error(f"Unknown provider: {self.provider}")
                    batch_results = [None] * len(batch)

                results.extend(batch_results)
                self._stats['batches_processed'] += 1

            except Exception as e:
                logger.error(f"Batch embedding error: {e}")
                results.extend([None] * len(batch))
                self._stats['errors'] += 1

        self._stats['texts_embedded'] += len([r for r in results if r is not None])

        return results

    async def _embed_ollama(self, texts: List[str]) -> List[Optional[List[float]]]:
        """Embed using Ollama."""
        try:
            import httpx
        except ImportError:
            logger.error("httpx not installed - required for Ollama")
            return [None] * len(texts)

        results = []
        url = f"{self.ollama_host}/api/embed"

        async with httpx.AsyncClient(timeout=60.0) as client:
            for text in texts:
                try:
                    response = await client.post(
                        url,
                        json={"model": self.model, "input": text}
                    )
                    response.raise_for_status()
                    data = response.json()
                    # Ollama returns {"embeddings": [[...]]} for single input
                    embeddings = data.get("embeddings", [])
                    results.append(embeddings[0] if embeddings else None)
                except Exception as e:
                    logger.warning(f"Ollama embedding error: {e}")
                    results.append(None)

        return results

    async def _embed_openai(self, texts: List[str]) -> List[Optional[List[float]]]:
        """Embed using OpenAI API."""
        if not self.openai_api_key:
            logger.error("OpenAI API key not configured")
            return [None] * len(texts)

        try:
            import httpx
        except ImportError:
            logger.error("httpx not installed - required for OpenAI")
            return [None] * len(texts)

        url = "https://api.openai.com/v1/embeddings"
        headers = {
            "Authorization": f"Bearer {self.openai_api_key}",
            "Content-Type": "application/json",
        }

        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    url,
                    headers=headers,
                    json={
                        "model": self.model,
                        "input": texts,
                    }
                )
                response.raise_for_status()
                data = response.json()

                # Sort by index to maintain order
                embeddings = sorted(data["data"], key=lambda x: x["index"])
                return [e["embedding"] for e in embeddings]

        except Exception as e:
            logger.error(f"OpenAI embedding error: {e}")
            return [None] * len(texts)

    def embed_sync(self, text: str) -> Optional[List[float]]:
        """Synchronous wrapper for embed."""
        return asyncio.run(self.embed(text))

    def embed_batch_sync(self, texts: List[str]) -> List[Optional[List[float]]]:
        """Synchronous wrapper for embed_batch."""
        return asyncio.run(self.embed_batch(texts))

    @property
    def stats(self) -> dict:
        """Get embedding statistics."""
        return self._stats.copy()


class SentenceTransformerEmbedder:
    """
    Alternative embedder using sentence-transformers library.

    Faster for local batch processing, runs entirely on CPU/GPU.
    """

    def __init__(
        self,
        model: str = "all-MiniLM-L6-v2",
        batch_size: int = 32,
        device: str = "cpu",  # or "cuda", "mps"
    ):
        """
        Initialize sentence-transformers embedder.

        Args:
            model: Model name from sentence-transformers
            batch_size: Batch size for encoding
            device: Device to run on
        """
        self.model_name = model
        self.batch_size = batch_size
        self.device = device
        self._model = None

    def _load_model(self):
        """Lazy load the model."""
        if self._model is None:
            try:
                from sentence_transformers import SentenceTransformer
                self._model = SentenceTransformer(self.model_name, device=self.device)
                logger.info(f"Loaded model: {self.model_name}")
            except ImportError:
                raise ImportError("sentence-transformers not installed")
        return self._model

    def embed_batch(self, texts: List[str]) -> List[List[float]]:
        """
        Embed multiple texts.

        Args:
            texts: List of texts

        Returns:
            List of embeddings
        """
        model = self._load_model()
        embeddings = model.encode(
            texts,
            batch_size=self.batch_size,
            show_progress_bar=False,
            convert_to_numpy=True,
        )
        return [e.tolist() for e in embeddings]

    def embed(self, text: str) -> List[float]:
        """Embed single text."""
        return self.embed_batch([text])[0]

    @property
    def dimensions(self) -> int:
        """Get embedding dimensions."""
        model = self._load_model()
        return model.get_sentence_embedding_dimension()


def get_embedder(
    provider: str = "ollama",
    model: str = "nomic-embed-text",
    **kwargs
) -> Union[Embedder, SentenceTransformerEmbedder]:
    """
    Factory function to get an embedder.

    Args:
        provider: "ollama", "openai", or "sentence-transformers"
        model: Model name
        **kwargs: Additional arguments for the embedder

    Returns:
        Embedder instance
    """
    if provider == "sentence-transformers":
        return SentenceTransformerEmbedder(model=model, **kwargs)
    else:
        return Embedder(provider=provider, model=model, **kwargs)


if __name__ == "__main__":
    # Test the embedder
    import asyncio

    async def test():
        print("Testing Ollama embedder...")

        embedder = Embedder(provider="ollama", model="nomic-embed-text")

        texts = [
            "The quick brown fox jumps over the lazy dog.",
            "Machine learning is transforming how we process data.",
            "Evernote is a note-taking application.",
        ]

        print(f"Embedding {len(texts)} texts...")
        vectors = await embedder.embed_batch(texts)

        for i, (text, vector) in enumerate(zip(texts, vectors)):
            if vector:
                print(f"\nText {i + 1}: {text[:50]}...")
                print(f"  Dimensions: {len(vector)}")
                print(f"  First 5 values: {vector[:5]}")
            else:
                print(f"\nText {i + 1}: FAILED")

        print(f"\nStats: {embedder.stats}")

    asyncio.run(test())
