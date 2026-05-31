"""Base client with rate limiting, retry logic, and caching."""

import asyncio
import hashlib
import json
import logging
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, Dict, Optional, TypeVar, Generic

import httpx
from aiolimiter import AsyncLimiter

from ..config import settings

logger = logging.getLogger(__name__)

T = TypeVar("T")


@dataclass
class CacheEntry:
    """A cached API response."""
    data: Any
    timestamp: float
    ttl_seconds: float

    def is_expired(self) -> bool:
        return time.time() - self.timestamp > self.ttl_seconds


class InMemoryCache:
    """Simple in-memory cache with TTL."""

    def __init__(self, ttl_days: int = 30):
        self._cache: Dict[str, CacheEntry] = {}
        self._ttl_seconds = ttl_days * 24 * 60 * 60

    def _make_key(self, prefix: str, query: str) -> str:
        """Create a cache key from prefix and query."""
        query_hash = hashlib.md5(query.encode()).hexdigest()
        return f"{prefix}:{query_hash}"

    def get(self, prefix: str, query: str) -> Optional[Any]:
        """Get cached value if exists and not expired."""
        key = self._make_key(prefix, query)
        entry = self._cache.get(key)

        if entry is None:
            return None

        if entry.is_expired():
            del self._cache[key]
            return None

        return entry.data

    def set(self, prefix: str, query: str, data: Any) -> None:
        """Cache a value."""
        key = self._make_key(prefix, query)
        self._cache[key] = CacheEntry(
            data=data,
            timestamp=time.time(),
            ttl_seconds=self._ttl_seconds
        )

    def clear(self) -> None:
        """Clear the cache."""
        self._cache.clear()

    def stats(self) -> Dict[str, int]:
        """Get cache statistics."""
        total = len(self._cache)
        expired = sum(1 for e in self._cache.values() if e.is_expired())
        return {"total": total, "expired": expired, "active": total - expired}


class BaseClient(ABC, Generic[T]):
    """
    Base class for API clients with rate limiting, retry logic, and caching.

    Features:
    - Async HTTP requests with httpx
    - Rate limiting per API requirements
    - Exponential backoff retry on failures
    - In-memory caching to avoid re-fetching
    - Proper error handling and logging
    """

    # Override in subclasses
    BASE_URL: str = ""
    CACHE_PREFIX: str = "base"

    def __init__(
        self,
        rate_limit: float = 1.0,  # Requests per second
        max_retries: int = 3,
        timeout: float = 30.0,
        cache: Optional[InMemoryCache] = None,
    ):
        """
        Initialize the client.

        Args:
            rate_limit: Maximum requests per second
            max_retries: Maximum retry attempts on failure
            timeout: Request timeout in seconds
            cache: Optional shared cache instance
        """
        # AsyncLimiter(max_rate, time_period) - rate_limit is requests per second
        # For rate_limit < 1, we need to adjust: e.g., 0.5 req/s = 1 req per 2 seconds
        if rate_limit >= 1:
            self.rate_limiter = AsyncLimiter(rate_limit, 1.0)
        else:
            # Convert to "1 request per X seconds"
            self.rate_limiter = AsyncLimiter(1, 1.0 / rate_limit)
        self.max_retries = max_retries
        self.timeout = timeout
        self.cache = cache or InMemoryCache(ttl_days=settings.cache_ttl_days)

        # Statistics
        self._request_count = 0
        self._cache_hits = 0
        self._cache_misses = 0
        self._errors = 0

        # Persistent HTTP client (created lazily)
        self._http_client: Optional[httpx.AsyncClient] = None

    def _get_headers(self) -> Dict[str, str]:
        """Get HTTP headers for requests. Override in subclasses."""
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }

    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create the persistent HTTP client."""
        if self._http_client is None or self._http_client.is_closed:
            self._http_client = httpx.AsyncClient(
                timeout=self.timeout,
                headers=self._get_headers(),
            )
        return self._http_client

    async def close(self) -> None:
        """Close the HTTP client and release resources."""
        if self._http_client is not None and not self._http_client.is_closed:
            await self._http_client.aclose()
            self._http_client = None

    async def _make_request(
        self,
        method: str,
        url: str,
        params: Optional[Dict[str, Any]] = None,
        json_data: Optional[Dict[str, Any]] = None,
    ) -> Optional[Dict[str, Any]]:
        """
        Make an HTTP request with rate limiting and retry logic.

        Args:
            method: HTTP method (GET, POST, etc.)
            url: Full URL to request
            params: Query parameters
            json_data: JSON body for POST requests

        Returns:
            Response JSON or None on failure
        """
        last_error = None

        for attempt in range(self.max_retries):
            try:
                # Wait for rate limiter
                async with self.rate_limiter:
                    client = await self._get_client()
                    self._request_count += 1

                    response = await client.request(
                        method=method,
                        url=url,
                        params=params,
                        json=json_data,
                        headers=self._get_headers(),
                    )

                    # Handle rate limiting
                    if response.status_code == 429:
                        retry_after = int(response.headers.get("Retry-After", 5))
                        logger.warning(
                            f"Rate limited, waiting {retry_after}s "
                            f"(attempt {attempt + 1}/{self.max_retries})"
                        )
                        await asyncio.sleep(retry_after)
                        continue

                    # Handle server errors with retry
                    if response.status_code >= 500:
                        delay = min(
                            settings.retry_base_delay * (2 ** attempt),
                            settings.retry_max_delay
                        )
                        logger.warning(
                            f"Server error {response.status_code}, "
                            f"retrying in {delay}s (attempt {attempt + 1}/{self.max_retries})"
                        )
                        await asyncio.sleep(delay)
                        continue

                    # Handle not found (valid response, just no results)
                    if response.status_code == 404:
                        logger.debug(f"Not found: {url}")
                        return None

                    # Handle other client errors
                    if response.status_code >= 400:
                        logger.error(
                            f"Client error {response.status_code}: {response.text}"
                        )
                        self._errors += 1
                        return None

                    # Success
                    return response.json()

            except httpx.TimeoutException:
                delay = min(
                    settings.retry_base_delay * (2 ** attempt),
                    settings.retry_max_delay
                )
                logger.warning(
                    f"Request timeout, retrying in {delay}s "
                    f"(attempt {attempt + 1}/{self.max_retries})"
                )
                last_error = "timeout"
                await asyncio.sleep(delay)

            except httpx.RequestError as e:
                delay = min(
                    settings.retry_base_delay * (2 ** attempt),
                    settings.retry_max_delay
                )
                # Get detailed error info - type and repr for better debugging
                error_type = type(e).__name__
                error_detail = repr(e) if not str(e) else str(e)
                logger.warning(
                    f"Request error ({error_type}): {error_detail}, retrying in {delay}s "
                    f"(attempt {attempt + 1}/{self.max_retries})"
                )
                last_error = f"{error_type}: {error_detail}"
                await asyncio.sleep(delay)

            except json.JSONDecodeError as e:
                logger.error(f"Invalid JSON response: {e}")
                self._errors += 1
                return None

        # All retries exhausted
        logger.error(f"All {self.max_retries} retries exhausted. Last error: {last_error}")
        self._errors += 1
        return None

    async def _get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        use_cache: bool = True,
        cache_key: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        """
        Make a GET request with caching.

        Args:
            endpoint: API endpoint (appended to BASE_URL)
            params: Query parameters
            use_cache: Whether to check/update cache
            cache_key: Custom cache key (default: endpoint + params)

        Returns:
            Response JSON or None
        """
        url = f"{self.BASE_URL}{endpoint}"

        # Build cache key
        if cache_key is None:
            cache_key = f"{endpoint}:{json.dumps(params or {}, sort_keys=True)}"

        # Check cache
        if use_cache:
            cached = self.cache.get(self.CACHE_PREFIX, cache_key)
            if cached is not None:
                self._cache_hits += 1
                logger.debug(f"Cache hit for {self.CACHE_PREFIX}:{cache_key[:50]}")
                return cached

        self._cache_misses += 1

        # Make request
        result = await self._make_request("GET", url, params=params)

        # Cache successful responses
        if result is not None and use_cache:
            self.cache.set(self.CACHE_PREFIX, cache_key, result)

        return result

    @abstractmethod
    async def search(self, query: str) -> Optional[T]:
        """
        Search for an item by query string.

        Args:
            query: Search query (title, artist name, etc.)

        Returns:
            Typed result or None if not found
        """
        pass

    @abstractmethod
    async def get_details(self, item_id: str) -> Optional[T]:
        """
        Get detailed information for an item by ID.

        Args:
            item_id: External API ID

        Returns:
            Typed result or None if not found
        """
        pass

    def get_stats(self) -> Dict[str, int]:
        """Get client statistics."""
        return {
            "requests": self._request_count,
            "cache_hits": self._cache_hits,
            "cache_misses": self._cache_misses,
            "errors": self._errors,
            "hit_rate": (
                self._cache_hits / max(1, self._cache_hits + self._cache_misses)
            ),
        }

    async def close(self) -> None:
        """Cleanup resources."""
        # In-memory cache doesn't need cleanup
        pass
