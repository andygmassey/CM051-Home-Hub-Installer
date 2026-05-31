"""Base parser interface."""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, Dict, Any, AsyncIterator
from pathlib import Path
import uuid


@dataclass
class ParsedPreference:
    """A parsed preference ready for ingestion."""

    # Core fields
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    subject: str = ""
    preference_type: str = "Like"  # Like, Dislike, Love, Hate, Neutral
    strength: float = 0.5  # -1.0 to +1.0 (negative=dislike, positive=like)
    compartment_level: int = 2  # Default to L2 (Trusted)

    # Metadata
    source: str = ""  # e.g., "google_takeout", "spotify", "csv"
    source_id: Optional[str] = None  # Original ID from source
    category: Optional[str] = None  # e.g., "music", "food", "movie"
    context: Optional[str] = None  # e.g., "at_home", "working"

    # Temporal
    created_at: datetime = field(default_factory=datetime.utcnow)
    observed_at: Optional[datetime] = None  # When the preference was observed

    # Size classification
    size: str = "Medium"  # Micro, Small, Medium, Large, Macro

    # Additional data
    extra: Dict[str, Any] = field(default_factory=dict)

    # Text for embedding
    embedding_text: str = ""

    def __post_init__(self):
        """Generate embedding text if not provided."""
        if not self.embedding_text:
            parts = [self.preference_type, self.subject]
            if self.category:
                parts.append(f"category:{self.category}")
            if self.context:
                parts.append(f"context:{self.context}")
            self.embedding_text = " ".join(parts)

    def to_turtle(self, user_id: str) -> str:
        """Convert to RDF Turtle format."""
        pref_uri = f"pwg:pref_{self.id}"
        compartment_uri = self._compartment_uri()

        # Determine preference class
        pref_class = f"pwg:{self.preference_type}Preference"
        if self.preference_type in ("Like", "Love"):
            pref_class = "pwg:LikePreference"
        elif self.preference_type in ("Dislike", "Hate"):
            pref_class = "pwg:DislikePreference"
        else:
            pref_class = "pwg:NeutralPreference"

        # Build turtle
        lines = [
            f'{pref_uri} a {pref_class} ;',
            f'    pwg:subject "{self._escape(self.subject)}" ;',
            f'    pwg:preferenceStrength {self.strength} ;',
            f'    pwg:belongsToCompartment {compartment_uri} ;',
            f'    pwg:hasSize pwg:{self.size}Size ;',
            f'    pwg:createdAt "{self.created_at.isoformat()}"^^xsd:dateTime ;',
            f'    pwg:belongsToUser pwg:user_{self._sanitize_iri(user_id)} ;',
            f'    pwg:dataSource "{self._escape(self.source)}" ;',
        ]

        if self.category:
            lines.append(f'    pwg:category "{self._escape(self.category)}" ;')

        if self.context:
            lines.append(f'    pwg:hasContext pwg:context_{self._sanitize_iri(self.context)} ;')

        if self.observed_at:
            lines.append(f'    pwg:observedAt "{self.observed_at.isoformat()}"^^xsd:dateTime ;')

        if self.source_id:
            lines.append(f'    pwg:sourceId "{self._escape(self.source_id)}" ;')

        # Close the turtle block
        lines[-1] = lines[-1].rstrip(' ;') + ' .'

        return '\n'.join(lines)

    def _compartment_uri(self) -> str:
        """Get compartment URI based on level."""
        names = {
            0: "L0Personal",
            1: "L1Family",
            2: "L2Trusted",
            3: "L3Community",
            4: "L4Public",
            5: "L5Commercial",
            6: "L6Broadcast"
        }
        return f"pwg:{names.get(self.compartment_level, 'L2Trusted')}"

    def _escape(self, text: str) -> str:
        """Escape string for Turtle."""
        return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

    def _sanitize_iri(self, text: str) -> str:
        """Sanitize string for use in RDF prefixed names (IRIs)."""
        import re
        # Replace @ and other invalid IRI characters with underscores
        sanitized = re.sub(r'[^a-zA-Z0-9_-]', '_', text)
        return sanitized

    def to_payload(self, user_id: str) -> Dict[str, Any]:
        """Convert to Qdrant payload."""
        payload = {
            "preference_id": self.id,
            "user_id": user_id,
            "subject": self.subject,
            "preference_type": self.preference_type,
            "strength": self.strength,
            "compartment_level": self.compartment_level,
            "source": self.source,
            "category": self.category,
            "context": self.context,
            "size": self.size,
            "created_at": self.created_at.isoformat(),
            "observed_at": self.observed_at.isoformat() if self.observed_at else None
        }
        # Include extra metadata (frequency, source_count, etc.)
        if self.extra:
            payload["extra"] = self.extra
        return payload


class BaseParser(ABC):
    """Abstract base class for data source parsers."""

    source_name: str = "unknown"

    @abstractmethod
    async def parse(self, file_path: Path, **kwargs) -> AsyncIterator[ParsedPreference]:
        """
        Parse a file and yield preferences.

        Args:
            file_path: Path to the file to parse
            **kwargs: Additional parser-specific options

        Yields:
            ParsedPreference objects
        """
        pass

    @abstractmethod
    def can_parse(self, file_path: Path) -> bool:
        """
        Check if this parser can handle the given file.

        Args:
            file_path: Path to check

        Returns:
            True if this parser can handle the file
        """
        pass

    def classify_strength(self, value: Any, bipolar: bool = True) -> float:
        """
        Convert various strength indicators to a numeric strength value.

        V2 Model: Uses bipolar scale (-1.0 to +1.0) by default.
        - Positive = like, negative = dislike, 0 = neutral
        - Ratings (1-5, 1-10) map to the full bipolar range

        Args:
            value: The value to classify (number, string keyword, rating)
            bipolar: If True, use -1 to +1 scale. If False, use 0 to 1 (legacy).

        Returns:
            Strength value in the appropriate range
        """
        if isinstance(value, (int, float)):
            if value > 1 or value < -1:
                # Assume it's a rating out of 5 or 10
                if abs(value) <= 5:
                    # 1-5 rating: 1=-0.5, 2=-0.25, 3=0, 4=+0.25, 5=+0.5 (bipolar)
                    # Then parsers apply their own base strength multiplier
                    if bipolar:
                        return (value - 3) / 4.0  # Maps 1-5 to -0.5 to +0.5
                    else:
                        return value / 5.0
                elif abs(value) <= 10:
                    # 1-10 rating: 1=-0.45, 5=0, 10=+0.45 (bipolar)
                    if bipolar:
                        return (value - 5.5) / 10.0  # Maps 1-10 to -0.45 to +0.45
                    else:
                        return value / 10.0
                else:
                    # Percentage or large number
                    if bipolar:
                        return min(0.95, max(-0.95, (value - 50) / 50.0))
                    else:
                        return min(1.0, value / 100.0)
            return float(value)

        if isinstance(value, str):
            # First try to parse as a number
            try:
                num_value = float(value)
                return self.classify_strength(num_value, bipolar=bipolar)
            except ValueError:
                pass

            # Fall back to keyword mapping (bipolar scale)
            value_lower = value.lower()
            if bipolar:
                mapping = {
                    "love": 0.50,        # Strong positive
                    "like": 0.25,        # Positive
                    "neutral": 0.0,      # Neutral
                    "dislike": -0.25,    # Negative
                    "hate": -0.50,       # Strong negative
                    "yes": 0.30,         # Mild positive
                    "no": -0.30,         # Mild negative
                    "true": 0.25,
                    "false": -0.25,
                    "up": 0.35,          # Thumbs up
                    "down": -0.35,       # Thumbs down
                }
            else:
                # Legacy 0-1 mapping
                mapping = {
                    "love": 1.0,
                    "like": 0.75,
                    "neutral": 0.5,
                    "dislike": 0.25,
                    "hate": 0.0,
                    "yes": 0.8,
                    "no": 0.2,
                    "true": 0.8,
                    "false": 0.2
                }
            return mapping.get(value_lower, 0.0 if bipolar else 0.5)

        return 0.0 if bipolar else 0.5

    def classify_size(self, subject: str, category: Optional[str] = None) -> str:
        """Classify preference size based on subject specificity."""
        # Very specific (e.g., "Song X by Artist Y") = Micro
        # Specific (e.g., "Artist Y") = Small
        # Medium (e.g., "Rock music") = Medium
        # Broad (e.g., "Music") = Large
        # Very broad (e.g., "Entertainment") = Macro

        words = subject.split()
        if len(words) >= 5:
            return "Micro"
        elif len(words) >= 3:
            return "Small"
        elif len(words) >= 2:
            return "Medium"
        elif category:
            return "Large"
        else:
            return "Macro"
