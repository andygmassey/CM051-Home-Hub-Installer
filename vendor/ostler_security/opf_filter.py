"""OpenAI Privacy Filter (OPF) wrapper for Ostler.

Phase 1 implementation – task #163. Loads ``openai/privacy-filter``
(1.5B total / 50M active MoE, 128k context, BIOES token classifier
over eight private categories) lazily on first use, and exposes a
small ``detect`` / ``redact`` API for Ostler's sanitisation paths.

Runtime layer is **onnxruntime + tokenizers**. We deliberately avoid
``transformers`` and ``torch`` here – the OPF tokeniser config
declares ``tokenizer_class="TokenizersBackend"`` which is a
``transformers`` v5 symbol not yet on PyPI, and torch + transformers
add ~4 GB to the installer footprint. Loading the ONNX export
directly with ``onnxruntime`` (~50 MB wheel) and the HF Rust
``tokenizers`` binding (~5 MB) gives identical numerical behaviour
without either of those costs.

Source: https://openai.com/index/introducing-openai-privacy-filter/
Released: 2026-04-21
Licence: Apache 2.0 (see ``THIRD_PARTY_NOTICES.md`` for attribution)
Model: 1.5B total / 50M active parameters (MoE), 128k context
Benchmark: F1 96% on PII-Masking-300k

OPF runs as a local pre-flight scrub for sensitive payloads before
they leave the device. It sits *in front of* the scalar-allowlist
payload viewer – OPF does model-based redaction, the viewer provides
the visible audit trail and second-layer belt-and-braces check.

Usage::

    from ostler_security.opf_filter import OPFFilter

    opf = OPFFilter()
    scrubbed = opf.redact("Email jane.doe@example.com tomorrow")
    # -> "Email [REDACTED] tomorrow"

    spans = opf.detect("Email jane.doe@example.com tomorrow")
    # -> [Span(start=6, end=26, category="private_email", score=0.99)]

See also:
    - ``OPF_INTEGRATION_SCOPING.md`` at the project root for full scope
    - ``ostler_security/payload_viewer.py`` for the second-layer check
    - Task #163 for the tracking issue
"""
from __future__ import annotations

import json
import logging
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


# ── Module-level constants ───────────────────────────────────────────

# Pinned upstream model id and revision. Pinning the revision is a
# supply-chain-safety requirement for productisation – any change to
# the upstream weights must come via a deliberate code change here,
# not a silent rollover. Once the CDN mirror is live this constant is
# the source of truth that the mirror script syncs against.
OPF_HF_MODEL_ID: str = "openai/privacy-filter"
OPF_HF_REVISION: str = "7ffa9a043d54d1be65afb281eddf0ffbe629385b"

# Files we pull down from the Hub. The model itself is sharded across
# ``model.onnx`` plus three ``.onnx_data`` external-data files; ORT
# resolves the shards by name when they sit alongside the main ONNX
# file in the same directory, which ``hf_hub_download`` guarantees by
# default (snapshot layout). ``config.json`` carries the BIOES label
# vocabulary – the ONNX graph itself is unlabelled.
_OPF_ONNX_MAIN: str = "onnx/model.onnx"
_OPF_ONNX_SHARDS: tuple[str, ...] = (
    "onnx/model.onnx_data",
    "onnx/model.onnx_data_1",
    "onnx/model.onnx_data_2",
)
_OPF_TOKENIZER_FILE: str = "tokenizer.json"
_OPF_CONFIG_FILE: str = "config.json"

# Apple Silicon is the primary target. CoreML hands the work to the
# Neural Engine / GPU when the graph is supported, falling back
# transparently to CPU within ORT for unsupported ops. ``providers``
# is a priority list – ORT tries them in order. We never request the
# CUDA provider: Ostler is Apple-Silicon-first.
_OPF_DEFAULT_PROVIDERS: tuple[str, ...] = (
    "CoreMLExecutionProvider",
    "CPUExecutionProvider",
)

# OPF's native taxonomy – do not reorder, downstream code may rely on
# stable ordering for display. Ostler-specific categories (e.g.
# "contact_in_graph") are a future extension, not a v1 concern.
OPF_CATEGORIES: tuple[str, ...] = (
    "private_person",
    "private_address",
    "private_email",
    "private_phone",
    "private_url",
    "private_date",
    "account_number",
    "secret",
)

# Category-aware placeholders for redact(categorised=True). Default
# placeholder remains [REDACTED] when categorised=False so existing
# callers keep their behaviour. Categorised mode is the right default
# for the payload-viewer UI – users debug "[EMAIL]" much faster than
# "[REDACTED]".
OPF_CATEGORY_PLACEHOLDERS: dict[str, str] = {
    "private_person": "[PERSON]",
    "private_address": "[ADDRESS]",
    "private_email": "[EMAIL]",
    "private_phone": "[PHONE]",
    "private_url": "[URL]",
    "private_date": "[DATE]",
    "account_number": "[ACCOUNT]",
    "secret": "[SECRET]",
}

# Placeholder identifier until we pin a specific weights hash on the
# CDN mirror. Format: ``opf-<size>-<release-date>``.
OPF_MODEL_VERSION: str = "opf-1.5b-2026-04-21"

# Reported F1 on the PII-Masking-300k benchmark per the release note.
OPF_BENCHMARK_F1: float = 0.96


# ── Public API ───────────────────────────────────────────────────────


@dataclass(frozen=True)
class Span:
    """A single detected PII span.

    ``start`` and ``end`` are character offsets into the input string,
    half-open (``text[start:end]`` slices out the span). ``category``
    is one of :data:`OPF_CATEGORIES`. ``score`` is the model's
    confidence in the range ``[0.0, 1.0]``.

    Deliberately minimal. We do not expose raw logits at v1 – no
    current Ostler caller needs calibration, and adding fields you
    cannot remove is the painful direction. If a future caller needs
    raw logits, add Span2 or extend with a defaulted optional field.
    """

    start: int
    end: int
    category: str
    score: float


class OPFFilter:
    """Local PII detector + redactor backed by OpenAI's Privacy Filter.

    The class is intentionally minimal – a single entry point for
    Ostler's sanitisation paths (Doctor payloads, cloud-LLM routing,
    optional third-party redaction in CM042 transcripts).

    Model loading is lazy: the first call to :meth:`detect` or
    :meth:`redact` triggers the download (if not cached) and load.
    Subsequent calls reuse the in-process model. The load is guarded
    by a :class:`threading.Lock` so concurrent callers do not
    double-load.
    """

    def __init__(
        self,
        model_path: Optional[Path] = None,
        device: str = "auto",
        providers: Optional[tuple[str, ...]] = None,
    ) -> None:
        """Record wrapper configuration.

        Parameters
        ----------
        model_path:
            Directory containing the pinned OPF weights laid out the
            way ``hf_hub_download`` lays them out (i.e. ``model.onnx``
            + shards under an ``onnx/`` subdirectory, ``tokenizer.json``
            and ``config.json`` at the root). ``None`` (the default)
            uses ``huggingface_hub`` to fetch + cache the pinned
            revision on first use – the right behaviour for the
            installer flow.
        device:
            ``"auto"`` (default), ``"coreml"``, or ``"cpu"``. Kept as a
            string for backwards compatibility with the previous
            torch-based wrapper; ``"mps"`` and ``"cuda"`` are accepted
            but treated as ``"auto"`` (we let ORT pick the right
            execution provider). Use ``providers`` for fine-grained
            control.
        providers:
            ORT execution-provider priority list. ``None`` (default)
            uses :data:`_OPF_DEFAULT_PROVIDERS` – CoreML first, CPU
            fallback. Pass an explicit list to force a specific
            provider for testing or debugging.
        """
        self.model_path: Optional[Path] = model_path
        self.device: str = device
        # Custom provider list overrides the device hint. We resolve
        # the effective list at load time so ``describe()`` can report
        # what was actually used.
        self._configured_providers: Optional[tuple[str, ...]] = providers
        self._session: Any = None  # onnxruntime.InferenceSession
        self._tokenizer: Any = None  # tokenizers.Tokenizer
        self._resolved_providers: Optional[tuple[str, ...]] = None
        self._id2label: dict[int, str] = {}
        self._load_lock = threading.Lock()

    # ── Lazy load ────────────────────────────────────────────────────

    def _resolve_providers(self) -> tuple[str, ...]:
        """Pick the ORT execution-provider priority list.

        Honours ``providers=`` from the constructor when given.
        Otherwise maps the legacy ``device=`` hint:

        - ``"cpu"`` -> CPU only.
        - ``"coreml"`` -> CoreML only (no CPU fallback; useful for
          benchmarking the accelerator path in isolation).
        - everything else (``"auto"``, ``"mps"``, ``"cuda"``) -> the
          default CoreML-then-CPU priority.

        We never request the CUDA provider – Ostler is Apple-Silicon
        first; the few Linux-on-Gaming-PC code paths that touch OPF
        run CPU-only and the wrapper's job is to be predictable on
        the laptop.
        """
        if self._configured_providers is not None:
            return tuple(self._configured_providers)

        if self.device == "cpu":
            return ("CPUExecutionProvider",)
        if self.device == "coreml":
            return ("CoreMLExecutionProvider",)
        return _OPF_DEFAULT_PROVIDERS

    def _resolve_assets(self) -> tuple[str, str, str]:
        """Resolve on-disk paths for the ONNX model, tokenizer, config.

        Returns ``(model_path, tokenizer_path, config_path)``. When
        ``self.model_path`` is set we treat it as the snapshot
        directory (HF layout). Otherwise we lazy-download via
        ``huggingface_hub`` at the pinned revision and rely on the HF
        cache for subsequent runs.
        """
        if self.model_path is not None:
            root = Path(self.model_path)
            return (
                str(root / _OPF_ONNX_MAIN),
                str(root / _OPF_TOKENIZER_FILE),
                str(root / _OPF_CONFIG_FILE),
            )

        # Lazy import – constructing an OPFFilter must not require the
        # huggingface_hub dependency. Only the actual download path
        # needs it.
        from huggingface_hub import hf_hub_download  # type: ignore[import-not-found]

        def _fetch(filename: str) -> str:
            return hf_hub_download(
                repo_id=OPF_HF_MODEL_ID,
                filename=filename,
                revision=OPF_HF_REVISION,
            )

        # Pull every shard so they sit next to model.onnx in the cache
        # snapshot directory; ORT looks for them by relative name when
        # the graph references external data.
        for shard in _OPF_ONNX_SHARDS:
            _fetch(shard)
        model_path = _fetch(_OPF_ONNX_MAIN)
        tokenizer_path = _fetch(_OPF_TOKENIZER_FILE)
        config_path = _fetch(_OPF_CONFIG_FILE)
        return model_path, tokenizer_path, config_path

    def _ensure_loaded(self) -> None:
        """Download (if needed) and load the OPF ONNX session + tokeniser.

        Idempotent and thread-safe. The first caller pays the cold
        load cost; subsequent callers fast-path on the already-loaded
        session.
        """
        if self._session is not None:
            return

        with self._load_lock:
            # Double-checked locking – another thread may have won the
            # race while we were waiting for the lock.
            if self._session is not None:
                return

            import onnxruntime as ort  # type: ignore[import-not-found]
            from tokenizers import Tokenizer  # type: ignore[import-not-found]

            model_path, tokenizer_path, config_path = self._resolve_assets()
            requested_providers = self._resolve_providers()

            logger.info(
                "Loading OPF tokeniser from %s", tokenizer_path,
            )
            tokenizer = Tokenizer.from_file(tokenizer_path)

            logger.info(
                "Loading OPF ONNX session from %s with providers=%s",
                model_path, requested_providers,
            )
            try:
                session = ort.InferenceSession(
                    model_path, providers=list(requested_providers),
                )
            except Exception as exc:
                # If a non-CPU provider in the request fails (CoreML
                # not built into ORT, x86_64 box, or – as observed on
                # macOS Sequoia 15.x – CoreML failing to follow the
                # symlinked HF snapshot layout for external-data
                # shards), retry CPU-only rather than crash. Only
                # re-raise if the request was already CPU-only, since
                # there's no further fallback in that case.
                non_cpu = [
                    p for p in requested_providers
                    if p != "CPUExecutionProvider"
                ]
                if not non_cpu:
                    raise
                logger.warning(
                    "Could not load ORT session with providers=%s "
                    "(%s); falling back to CPU only",
                    requested_providers, exc,
                )
                session = ort.InferenceSession(
                    model_path, providers=["CPUExecutionProvider"],
                )

            with open(config_path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            id2label_raw = cfg.get("id2label", {})
            id2label = {int(k): str(v) for k, v in id2label_raw.items()}

            self._tokenizer = tokenizer
            self._session = session
            self._resolved_providers = tuple(session.get_providers())
            self._id2label = id2label
            logger.info(
                "OPF model loaded with providers=%s, %d labels",
                self._resolved_providers, len(self._id2label),
            )

    # ── Detection ────────────────────────────────────────────────────

    def detect(self, text: str) -> list[Span]:
        """Return every PII span the model identifies in *text*.

        Spans are returned in ascending ``start`` order. Sub-word
        tokens that share a category are merged into a single span.
        Empty input returns an empty list without loading the model –
        callers can use :meth:`detect` as a cheap no-op probe.
        """
        if not text:
            return []

        self._ensure_loaded()
        assert self._session is not None and self._tokenizer is not None

        # Lazy import – numpy is a hard runtime requirement for ORT
        # inference but not for module import.
        import numpy as np  # type: ignore[import-not-found]

        encoding = self._tokenizer.encode(text)
        # ``offsets`` is a list of (start, end) char-offset tuples. HF
        # Rust tokenizers report (0, 0) for special tokens (BOS/EOS),
        # which the BIOES decoder skips.
        offsets = [list(o) for o in encoding.offsets]
        input_ids = np.array([encoding.ids], dtype=np.int64)
        attention_mask = np.array([encoding.attention_mask], dtype=np.int64)

        # Build the feed dict from the session's declared inputs. OPF's
        # ONNX export uses ``input_ids`` + ``attention_mask`` but we
        # tolerate alternative naming (e.g. ``token_type_ids`` if a
        # future revision adds it) by only sending what the session
        # asks for.
        input_names = {i.name for i in self._session.get_inputs()}
        feed: dict[str, Any] = {}
        if "input_ids" in input_names:
            feed["input_ids"] = input_ids
        if "attention_mask" in input_names:
            feed["attention_mask"] = attention_mask
        # ``token_type_ids`` is required by some exports; if so, send
        # zeros (single-segment input).
        if "token_type_ids" in input_names:
            feed["token_type_ids"] = np.zeros_like(input_ids)

        # First (and only) output is the logits tensor of shape
        # (1, seq_len, num_labels). Some exports name it ``logits``,
        # others ``last_hidden_state`` or just leave it unnamed – we
        # take the first output positionally to be robust.
        outputs = self._session.run(None, feed)
        logits = outputs[0]  # shape (1, seq_len, num_labels)

        # Softmax over the label axis. Numerically-stable form: subtract
        # max before exp.
        logits_2d = logits[0]  # (seq_len, num_labels)
        shifted = logits_2d - logits_2d.max(axis=-1, keepdims=True)
        exp = np.exp(shifted)
        probs = exp / exp.sum(axis=-1, keepdims=True)

        pred_ids = probs.argmax(axis=-1).tolist()
        pred_scores = probs.max(axis=-1).tolist()

        return _decode_bioes(
            offsets=offsets,
            label_ids=pred_ids,
            label_scores=pred_scores,
            id2label=self._id2label,
        )

    # ── Redaction ────────────────────────────────────────────────────

    def redact(
        self,
        text: str,
        placeholder: str = "[REDACTED]",
        categorised: bool = False,
    ) -> str:
        """Replace every detected span with *placeholder*.

        Default behaviour (``categorised=False``) replaces every span
        with the same string – matches Ostler's existing audit-log
        convention.

        With ``categorised=True``, each span is replaced with its
        category-specific placeholder from
        :data:`OPF_CATEGORY_PLACEHOLDERS` (``[EMAIL]``, ``[PHONE]``,
        etc). Recommended for the payload-viewer UI, where labelled
        placeholders make redactions debuggable. The ``placeholder``
        argument is used as the fallback for unknown categories in
        categorised mode.
        """
        if not text:
            return text

        spans = self.detect(text)
        if not spans:
            return text

        # Replace right-to-left so earlier offsets stay valid. The
        # detector already returns ascending order, so reverse it.
        result = text
        for span in sorted(spans, key=lambda s: s.start, reverse=True):
            # Clamp span boundaries past surrounding whitespace. The
            # ONNX model sometimes predicts span boundaries that
            # include the preceding or trailing space; we want the
            # redacted output to preserve whitespace around the
            # placeholder so the surrounding text reads cleanly.
            start = span.start
            end = span.end
            while start < end and text[start].isspace():
                start += 1
            while end > start and text[end - 1].isspace():
                end -= 1
            if start >= end:
                # Span is entirely whitespace – nothing to redact.
                continue

            if categorised:
                replacement = OPF_CATEGORY_PLACEHOLDERS.get(
                    span.category, placeholder,
                )
            else:
                replacement = placeholder
            result = result[:start] + replacement + result[end:]
        return result

    # ── Metadata ─────────────────────────────────────────────────────

    def describe(self) -> dict:
        """Return static metadata about the wrapper and model.

        Safe to call on an un-initialised wrapper – this is what the
        UI uses to show "OPF available but not loaded" / model
        version strings / attribution in the About panel.
        """
        return {
            "model_version": OPF_MODEL_VERSION,
            "hf_model_id": OPF_HF_MODEL_ID,
            "hf_revision": OPF_HF_REVISION,
            "categories": list(OPF_CATEGORIES),
            "benchmark_f1": OPF_BENCHMARK_F1,
            "benchmark_name": "PII-Masking-300k",
            "licence": "Apache-2.0",
            "source_url": (
                "https://openai.com/index/introducing-openai-privacy-filter/"
            ),
            "total_parameters": "1.5B",
            "active_parameters": "50M",
            "context_window": 131072,
            "released": "2026-04-21",
            "model_path": (
                str(self.model_path) if self.model_path is not None else None
            ),
            "device": self.device,
            "runtime": "onnxruntime",
            "configured_providers": (
                list(self._configured_providers)
                if self._configured_providers is not None else None
            ),
            "resolved_providers": (
                list(self._resolved_providers)
                if self._resolved_providers is not None else None
            ),
            "loaded": self._session is not None,
        }


# ── BIOES decoding ───────────────────────────────────────────────────


def _decode_bioes(
    offsets: list[list[int]],
    label_ids: list[int],
    label_scores: list[float],
    id2label: dict[int, str],
) -> list[Span]:
    """Decode per-token BIOES predictions into character-offset spans.

    Greedy scheme that tolerates noisy boundaries: any non-O label
    opens or extends a span of its category, and category changes (or
    O tags) close the current span. Sub-word tokens with the same
    category therefore merge into one Span. Span score is the mean of
    the contributing tokens' predicted-class probabilities.

    Tokens with offset (0, 0) are special tokens (BOS/EOS/PAD) and
    are skipped. Open spans are flushed at end-of-input.
    """
    spans: list[Span] = []
    current_category: Optional[str] = None
    current_start: int = -1
    current_end: int = -1
    current_scores: list[float] = []

    def _flush() -> None:
        nonlocal current_category, current_start, current_end, current_scores
        if current_category is not None and current_end > current_start:
            score = (
                sum(current_scores) / len(current_scores)
                if current_scores else 0.0
            )
            spans.append(
                Span(
                    start=current_start,
                    end=current_end,
                    category=current_category,
                    score=float(score),
                )
            )
        current_category = None
        current_start = -1
        current_end = -1
        current_scores = []

    for offset, label_id, score in zip(offsets, label_ids, label_scores):
        start, end = offset[0], offset[1]
        # Special tokens (BOS/EOS/PAD) are reported as (0, 0) by HF
        # fast tokenisers. Skip them so they don't extend or break
        # spans.
        if start == 0 and end == 0:
            continue

        label = id2label.get(int(label_id), "O")
        if label == "O":
            _flush()
            continue

        # BIOES tags are encoded as "<prefix>-<category>" – split on
        # the first dash to recover the category. A malformed label
        # (no dash) is treated as O defensively.
        if "-" not in label:
            _flush()
            continue
        _, category = label.split("-", 1)

        if category != current_category:
            _flush()
            current_category = category
            current_start = start
            current_end = end
            current_scores = [float(score)]
        else:
            # Same category as previous token – extend the current
            # span. Use the maximum end seen so far so out-of-order
            # tokenisers (none expected, but defensive) still produce
            # sane ranges.
            current_end = max(current_end, end)
            current_scores.append(float(score))

    _flush()
    spans.sort(key=lambda s: s.start)
    return spans
