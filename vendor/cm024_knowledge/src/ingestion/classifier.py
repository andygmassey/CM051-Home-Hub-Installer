"""
Privacy Classifier - Assign compartment levels to notes.

Uses heuristics first, then LLM classification for ambiguous cases.
Compartment levels match CM019:
  L0 = public
  L1 = friends
  L2 = personal (default)
  L3 = sensitive
  L4 = secret

Usage:
    classifier = PrivacyClassifier()
    level = classifier.classify(note)
"""

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

from .enex_parser import ParsedNote

logger = logging.getLogger(__name__)


# Compartment level names
COMPARTMENT_NAMES = {
    0: "public",
    1: "friends",
    2: "personal",
    3: "sensitive",
    4: "secret",
}


@dataclass
class ClassificationResult:
    """Result of privacy classification."""

    level: int
    confidence: float  # 0.0 - 1.0
    reason: str
    method: str  # "heuristic", "llm", "default"


# Heuristic patterns for classification
# Format: (pattern, level, confidence, reason)
TITLE_PATTERNS: List[Tuple[re.Pattern, int, float, str]] = [
    # L4 - Secret
    (re.compile(r'\b(password|credential|secret|api.?key|private.?key)\b', re.I), 4, 0.95, "Contains sensitive credentials indicator"),
    (re.compile(r'\b(bank.*account|credit.*card|social.*security)\b', re.I), 4, 0.9, "Financial account information"),

    # L3 - Sensitive
    (re.compile(r'\b(health|medical|doctor|diagnosis|prescription|therapy)\b', re.I), 3, 0.85, "Health/medical content"),
    (re.compile(r'\b(salary|compensation|income|net.*worth|tax.*return)\b', re.I), 3, 0.85, "Financial/compensation information"),
    (re.compile(r'\b(legal|lawsuit|attorney|lawyer|contract)\b', re.I), 3, 0.7, "Legal content"),

    # L1 - Friends (personal but shareable)
    (re.compile(r'\b(trip|vacation|travel|itinerary)\b', re.I), 1, 0.6, "Travel content"),
    (re.compile(r'\b(recipe|cooking|restaurant)\b', re.I), 1, 0.5, "Food/dining content"),
    (re.compile(r'\b(movie|book|review|recommendation)\b', re.I), 1, 0.5, "Entertainment content"),

    # L0 - Public
    (re.compile(r'\b(article|news|blog|tutorial|guide|how.?to)\b', re.I), 0, 0.6, "Educational/reference content"),
]

CONTENT_PATTERNS: List[Tuple[re.Pattern, int, float, str]] = [
    # L4 - Secret (content patterns)
    (re.compile(r'(?:password|passwd|pwd)\s*[:=]\s*\S+', re.I), 4, 0.98, "Contains password"),
    (re.compile(r'(?:api.?key|secret.?key|access.?token)\s*[:=]\s*\S+', re.I), 4, 0.98, "Contains API key or token"),
    (re.compile(r'-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----', re.I), 4, 0.99, "Contains private key"),
    (re.compile(r'\b[A-Za-z0-9]{32,}\b'), 4, 0.6, "May contain API key (long alphanumeric)"),

    # L3 - Sensitive
    (re.compile(r'\b\d{3}[-.\s]?\d{2}[-.\s]?\d{4}\b'), 3, 0.8, "Contains SSN-like number"),
    (re.compile(r'\b\d{4}[-.\s]?\d{4}[-.\s]?\d{4}[-.\s]?\d{4}\b'), 3, 0.85, "Contains credit card-like number"),
    (re.compile(r'(?:diagnos|symptom|medication|prescription)', re.I), 3, 0.75, "Medical terminology"),
]

TAG_PATTERNS: Dict[str, Tuple[int, float, str]] = {
    # Exact tag matches (case-insensitive)
    "password": (4, 0.95, "Tagged as password"),
    "passwords": (4, 0.95, "Tagged as passwords"),
    "credentials": (4, 0.95, "Tagged as credentials"),
    "secret": (4, 0.9, "Tagged as secret"),
    "private": (3, 0.8, "Tagged as private"),
    "health": (3, 0.85, "Tagged as health"),
    "medical": (3, 0.85, "Tagged as medical"),
    "financial": (3, 0.8, "Tagged as financial"),
    "work": (2, 0.6, "Tagged as work"),
    "personal": (2, 0.5, "Tagged as personal"),
    "public": (0, 0.7, "Tagged as public"),
    "shared": (1, 0.6, "Tagged as shared"),
    "reference": (0, 0.6, "Tagged as reference"),
    "article": (0, 0.5, "Tagged as article"),
}


class PrivacyClassifier:
    """
    Classify notes into privacy compartment levels.

    Uses a multi-stage approach:
    1. Check for explicit tag overrides
    2. Apply title heuristics
    3. Apply content heuristics
    4. Optionally use LLM for ambiguous cases
    5. Fall back to default level
    """

    def __init__(
        self,
        default_level: int = 2,
        use_llm: bool = False,
        llm_provider: str = "ollama",
        llm_model: str = "qwen2.5:14b-instruct",
        ollama_host: str = "http://localhost:11434",
    ):
        """
        Initialize the classifier.

        Args:
            default_level: Default compartment level (0-4)
            use_llm: Whether to use LLM for ambiguous cases
            llm_provider: LLM provider ("ollama" or "openai")
            llm_model: Model name for LLM classification
            ollama_host: Ollama server URL (e.g., "http://localhost:11434")
        """
        self.default_level = default_level
        self.use_llm = use_llm
        self.llm_provider = llm_provider
        self.llm_model = llm_model
        self.ollama_host = ollama_host

        self._stats = {
            'classified': 0,
            'by_tag': 0,
            'by_title': 0,
            'by_content': 0,
            'by_llm': 0,
            'by_default': 0,
        }

        # LLM client (lazy initialization)
        self._llm_client = None

    def classify(self, note: ParsedNote) -> ClassificationResult:
        """
        Classify a note's privacy level.

        Args:
            note: ParsedNote to classify

        Returns:
            ClassificationResult with level, confidence, and reason
        """
        self._stats['classified'] += 1

        # Stage 1: Check tags
        result = self._classify_by_tags(note.tags)
        if result:
            self._stats['by_tag'] += 1
            return result

        # Stage 2: Check title
        result = self._classify_by_title(note.title)
        if result and result.confidence > 0.7:
            self._stats['by_title'] += 1
            return result

        # Stage 3: Check content
        result = self._classify_by_content(note.content)
        if result and result.confidence > 0.7:
            self._stats['by_content'] += 1
            return result

        # Stage 4: LLM classification (if enabled and ambiguous)
        if self.use_llm:
            result = self._classify_by_llm(note)
            if result:
                self._stats['by_llm'] += 1
                return result

        # Stage 5: Default
        self._stats['by_default'] += 1
        return ClassificationResult(
            level=self.default_level,
            confidence=0.5,
            reason="No specific indicators found",
            method="default",
        )

    def _classify_by_tags(self, tags: List[str]) -> Optional[ClassificationResult]:
        """Check tags for privacy level indicators."""
        if not tags:
            return None

        best_result = None
        best_confidence = 0.0

        for tag in tags:
            tag_lower = tag.lower().strip()

            if tag_lower in TAG_PATTERNS:
                level, confidence, reason = TAG_PATTERNS[tag_lower]
                if confidence > best_confidence:
                    best_confidence = confidence
                    best_result = ClassificationResult(
                        level=level,
                        confidence=confidence,
                        reason=reason,
                        method="heuristic_tag",
                    )

        return best_result

    def _classify_by_title(self, title: str) -> Optional[ClassificationResult]:
        """Check title for privacy level indicators."""
        if not title:
            return None

        best_result = None
        best_confidence = 0.0

        for pattern, level, confidence, reason in TITLE_PATTERNS:
            if pattern.search(title):
                if confidence > best_confidence:
                    best_confidence = confidence
                    best_result = ClassificationResult(
                        level=level,
                        confidence=confidence,
                        reason=reason,
                        method="heuristic_title",
                    )

        return best_result

    def _classify_by_content(self, content: str) -> Optional[ClassificationResult]:
        """Check content for privacy level indicators."""
        if not content:
            return None

        # Only check first 5000 chars for performance
        content_sample = content[:5000]

        best_result = None
        best_confidence = 0.0

        for pattern, level, confidence, reason in CONTENT_PATTERNS:
            if pattern.search(content_sample):
                if confidence > best_confidence:
                    best_confidence = confidence
                    best_result = ClassificationResult(
                        level=level,
                        confidence=confidence,
                        reason=reason,
                        method="heuristic_content",
                    )

        return best_result

    def _classify_by_llm(self, note: ParsedNote) -> Optional[ClassificationResult]:
        """Use LLM to classify ambiguous notes."""
        try:
            if self.llm_provider == "ollama":
                return self._classify_with_ollama(note)
            elif self.llm_provider == "openai":
                return self._classify_with_openai(note)
            else:
                logger.warning(f"Unknown LLM provider: {self.llm_provider}")
                return None
        except Exception as e:
            logger.warning(f"LLM classification failed: {e}")
            return None

    def _classify_with_ollama(self, note: ParsedNote) -> Optional[ClassificationResult]:
        """Classify using Ollama model (local or remote)."""
        import json
        try:
            import httpx
        except ImportError:
            logger.warning("httpx package not installed, trying requests")
            try:
                import requests
                httpx = None
            except ImportError:
                logger.warning("Neither httpx nor requests installed")
                return None

        prompt = self._build_classification_prompt(note)

        url = f"{self.ollama_host}/api/generate"
        payload = {
            "model": self.llm_model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": 0.1},
        }

        try:
            if httpx:
                with httpx.Client(timeout=60.0) as client:
                    response = client.post(url, json=payload)
                    response.raise_for_status()
                    data = response.json()
            else:
                response = requests.post(url, json=payload, timeout=60)
                response.raise_for_status()
                data = response.json()

            return self._parse_llm_response(data.get('response', ''))

        except Exception as e:
            logger.warning(f"Ollama API call failed: {e}")
            return None

    def _classify_with_openai(self, note: ParsedNote) -> Optional[ClassificationResult]:
        """Classify using OpenAI API."""
        # Not implemented - would require API key setup
        logger.warning("OpenAI classification not implemented")
        return None

    def _build_classification_prompt(self, note: ParsedNote) -> str:
        """Build prompt for LLM classification."""
        # Truncate content for prompt
        content_preview = note.content[:1000] if note.content else ""

        return f"""Classify this note's privacy level based on its content.

Privacy Levels:
0 = PUBLIC: Safe to share with anyone (articles, tutorials, public info)
1 = FRIENDS: Personal but shareable with close contacts (travel, hobbies)
2 = PERSONAL: Private to self (work notes, personal thoughts)
3 = SENSITIVE: Extra protection needed (health, finances, legal)
4 = SECRET: Maximum protection (passwords, credentials, highly private)

Note Title: {note.title}
Tags: {', '.join(note.tags) if note.tags else 'none'}

Content Preview:
{content_preview}

Respond with ONLY a JSON object:
{{"level": <0-4>, "reason": "<brief reason>"}}"""

    def _parse_llm_response(self, response: str) -> Optional[ClassificationResult]:
        """Parse LLM response to extract classification."""
        import json

        try:
            # Try to extract JSON from response
            json_match = re.search(r'\{[^}]+\}', response)
            if not json_match:
                return None

            data = json.loads(json_match.group())
            level = int(data.get('level', self.default_level))
            reason = data.get('reason', 'LLM classification')

            # Validate level
            if not 0 <= level <= 4:
                level = self.default_level

            return ClassificationResult(
                level=level,
                confidence=0.7,  # LLM confidence
                reason=reason,
                method="llm",
            )

        except (json.JSONDecodeError, ValueError, KeyError) as e:
            logger.debug(f"Failed to parse LLM response: {e}")
            return None

    def classify_batch(
        self,
        notes: List[ParsedNote],
    ) -> List[Tuple[ParsedNote, ClassificationResult]]:
        """
        Classify multiple notes.

        Args:
            notes: List of ParsedNote objects

        Returns:
            List of (note, result) tuples
        """
        results = []
        for note in notes:
            result = self.classify(note)
            results.append((note, result))
        return results

    @property
    def stats(self) -> dict:
        """Get classification statistics."""
        return self._stats.copy()

    def reset_stats(self):
        """Reset statistics."""
        self._stats = {
            'classified': 0,
            'by_tag': 0,
            'by_title': 0,
            'by_content': 0,
            'by_llm': 0,
            'by_default': 0,
        }


def classify_note(
    note: ParsedNote,
    use_llm: bool = False,
) -> int:
    """
    Convenience function to classify a single note.

    Args:
        note: ParsedNote to classify
        use_llm: Whether to use LLM for ambiguous cases

    Returns:
        Compartment level (0-4)
    """
    classifier = PrivacyClassifier(use_llm=use_llm)
    result = classifier.classify(note)
    return result.level


if __name__ == "__main__":
    # Test the classifier
    import sys
    from .enex_parser import sample_notes

    if len(sys.argv) < 2:
        print("Usage: python -m src.ingestion.classifier <file.enex> [--llm]")
        sys.exit(1)

    file_path = sys.argv[1]
    use_llm = "--llm" in sys.argv

    logging.basicConfig(level=logging.INFO)

    print(f"Classifying notes from: {file_path}")
    print(f"LLM enabled: {use_llm}")
    print()

    notes = sample_notes(file_path, 10)
    classifier = PrivacyClassifier(use_llm=use_llm)

    for note in notes:
        result = classifier.classify(note)
        print(f"Title: {note.title[:60]}...")
        print(f"  Level: L{result.level} ({COMPARTMENT_NAMES[result.level]})")
        print(f"  Confidence: {result.confidence:.0%}")
        print(f"  Reason: {result.reason}")
        print(f"  Method: {result.method}")
        print()

    print(f"\nStats: {classifier.stats}")
