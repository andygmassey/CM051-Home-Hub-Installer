"""Thin Ollama client for CM048 pipeline calls.

Targets the configured Ollama URL by default. Honours priority hints for
the future hub-wide scheduler (today, priority is a no-op label
carried through to logs; when the scheduler service exists it will
read these).

Includes robust JSON extraction from Ollama responses (strips
<think> blocks, finds first JSON object/array even when model adds
extra prose).
"""
from __future__ import annotations

import json
import logging
import re
import time
from dataclasses import dataclass
from typing import Any

import httpx


logger = logging.getLogger(__name__)


@dataclass
class OllamaCallResult:
    raw_response: str
    parsed_json: Any | None
    duration_seconds: float
    model: str
    prompt_chars: int


class OllamaClient:
    def __init__(
        self,
        base_url: str = "http://localhost:11434",
        default_timeout_seconds: float = 600.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.default_timeout = default_timeout_seconds

    def generate(
        self,
        model: str,
        prompt: str,
        *,
        system: str | None = None,
        temperature: float = 0.2,
        think: bool = False,
        stream: bool = False,
        timeout: float | None = None,
        priority: str = "medium",
        format_json: bool = False,
    ) -> OllamaCallResult:
        """Call /api/generate and return raw response text."""
        t0 = time.time()
        url = f"{self.base_url}/api/generate"
        # Always pin a large context window + generation budget. Without
        # num_ctx, Ollama silently truncates long transcripts to its small
        # default window, degenerating extraction output to a bare `{}`
        # (same class as the daemon's one-token #118 bug). num_predict=-1
        # means "generate until done".
        options = {"temperature": temperature, "num_ctx": 32768, "num_predict": -1}
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": stream,
            "think": think,
            "options": options,
        }
        if system:
            payload["system"] = system
        # qwen3.x degenerates to empty/`{}` output under native JSON mode
        # (`format: "json"`). It relies instead on the prompt instruction +
        # the robust `_extract_json` extractor below, so only request native
        # JSON mode for non-qwen3 models.
        if format_json and not model.lower().startswith("qwen3"):
            payload["format"] = "json"
        logger.info(
            "ollama.generate model=%s priority=%s prompt_chars=%d",
            model,
            priority,
            len(prompt),
        )
        # Yield to the user before starting a new request. This pipeline is a
        # background enrichment job; while the user is actively chatting the
        # daemon refreshes a lease file and we wait so their foreground chat
        # keeps the Ollama slots. Crash-safe: a missing/stale lease returns
        # immediately, and the helper's max_wait caps the yield.
        try:
            from .ollama_user_active import wait_until_user_idle
            wait_until_user_idle()
        except Exception as exc:  # pragma: no cover - defensive
            logger.debug("user-active lease check skipped: %s", exc)
        # Bypass any HTTP proxy for LAN Ollama calls
        transport = httpx.HTTPTransport(proxy=None)
        with httpx.Client(timeout=timeout or self.default_timeout, transport=transport) as client:
            resp = client.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        raw = data.get("response", "")
        duration = time.time() - t0
        logger.info(
            "ollama.generate done model=%s duration=%.1fs response_chars=%d",
            model,
            duration,
            len(raw),
        )
        return OllamaCallResult(
            raw_response=raw,
            parsed_json=None,
            duration_seconds=duration,
            model=model,
            prompt_chars=len(prompt),
        )

    def generate_json(
        self,
        model: str,
        prompt: str,
        *,
        expect: str = "object",  # "object" | "array"
        schema_hint: str = "",
        temperature: float = 0.2,
        timeout: float | None = None,
        priority: str = "medium",
    ) -> OllamaCallResult:
        """Call /api/generate with format=json and extract the response.

        Uses Ollama's native JSON mode (`format: "json"`) to force the
        model to output valid JSON. Also appends a reminder to the prompt
        so the model knows it must produce JSON only.

        Args:
            schema_hint: optional JSON example showing the expected
                structure. Appended to the suffix to guide the model.
        """
        # Append JSON reminder to the prompt to reinforce format
        schema_block = f"\n\nExample of expected output structure:\n{schema_hint}" if schema_hint else ""
        json_suffix = (
            "\n\n---\n\n"
            "CRITICAL: You MUST respond with ONLY a valid JSON "
            f"{'object (curly braces)' if expect == 'object' else 'array (square brackets)'}. "
            "No markdown, no prose, no code fences, no explanation. "
            f"Just the raw JSON.{schema_block}"
        )
        result = self.generate(
            model,
            prompt + json_suffix,
            temperature=temperature,
            timeout=timeout,
            priority=priority,
            format_json=True,
        )
        result.parsed_json = _extract_json(result.raw_response, expect=expect)
        if result.parsed_json is None:
            logger.warning(
                "ollama.generate_json failed to extract JSON (expected=%s, model=%s). First 300 chars of response: %r",
                expect,
                model,
                result.raw_response[:300],
            )
        return result

    def embed(
        self,
        text: str,
        model: str = "nomic-embed-text",
        timeout: float = 60.0,
    ) -> list[float]:
        url = f"{self.base_url}/api/embed"
        payload = {"model": model, "input": text}
        transport = httpx.HTTPTransport(proxy=None)
        with httpx.Client(timeout=timeout, transport=transport) as client:
            resp = client.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        embs = data.get("embeddings") or [data.get("embedding")]
        return embs[0]


def _extract_json(raw: str, *, expect: str) -> Any | None:
    """Strip <think> blocks then find the first valid JSON of the expected shape.

    When expect="array" but the model returns a single object, wraps
    it in a list. This is a common local-model behaviour — the model
    produces one item instead of an array of one.
    """
    cleaned = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL)

    # Try the expected shape first
    if expect == "array":
        match = re.search(r"\[[\s\S]*\]", cleaned)
    else:
        match = re.search(r"\{[\s\S]*\}", cleaned)

    parsed = _try_parse(match)
    if parsed is not None:
        return parsed

    # Fallback: expected array but got object — wrap it
    if expect == "array":
        obj_match = re.search(r"\{[\s\S]*\}", cleaned)
        obj = _try_parse(obj_match)
        if isinstance(obj, dict):
            logger.info("Expected array but got single object — wrapping in list")
            return [obj]

    return None


def _try_parse(match: re.Match | None) -> Any | None:
    """Try to parse a regex match as JSON, with progressive trim fallback."""
    if not match:
        return None
    try:
        return json.loads(match.group(0))
    except json.JSONDecodeError:
        candidate = match.group(0)
        for i in range(len(candidate), 0, -1):
            try:
                return json.loads(candidate[:i])
            except json.JSONDecodeError:
                continue
        return None
