"""
Email Summarizer - Extracts knowledge from email threads using LLM.

Uses Ollama (local LLM) to summarize email threads and extract:
- Topics discussed
- Decisions made
- Advice given/received
- Life events mentioned
- Key entities (people, places, organizations)

Usage:
    summarizer = EmailSummarizer(ollama_host="http://localhost:11434")
    knowledge = await summarizer.summarize_thread(thread)
"""

import json
import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional

import httpx

from .thread_aggregator import EmailThread

logger = logging.getLogger(__name__)


# Prompt template for thread summarization
SUMMARIZE_PROMPT = """Analyze this email thread and extract knowledge. Be concise and factual.

Thread Subject: {subject}
Participants: {participants}
Date Range: {start_date} to {end_date}
Email Count: {count}

--- Thread Content ---
{content}
---

Extract the following as JSON:
{{
  "topics": ["list of main topics discussed"],
  "summary": "2-3 sentence summary of the thread",
  "decisions": ["any decisions made, or empty list if none"],
  "advice": ["any advice given/received, or empty list if none"],
  "events": ["any life events mentioned (moves, births, projects, etc.), or empty list if none"],
  "entities": {{
    "people": ["names of people mentioned"],
    "places": ["locations mentioned"],
    "organizations": ["companies/orgs mentioned"]
  }},
  "privacy_level": 3, 4, or 5 based on sensitivity (3=safe, 4=personal, 5=sensitive/health/financial)
}}

Return ONLY valid JSON, no other text."""


@dataclass
class ThreadKnowledge:
    """Extracted knowledge from an email thread."""

    thread_id: str
    subject: str
    participants: List[str]
    date_range_start: Optional[datetime]
    date_range_end: Optional[datetime]
    message_count: int

    # Extracted by LLM
    topics: List[str] = field(default_factory=list)
    summary: str = ""
    decisions: List[str] = field(default_factory=list)
    advice: List[str] = field(default_factory=list)
    events: List[str] = field(default_factory=list)
    entities_people: List[str] = field(default_factory=list)
    entities_places: List[str] = field(default_factory=list)
    entities_organizations: List[str] = field(default_factory=list)
    privacy_level: int = 4

    # Metadata
    extraction_model: str = ""
    extracted_at: Optional[datetime] = None
    extraction_error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "thread_id": self.thread_id,
            "subject": self.subject,
            "participants": self.participants,
            "date_range_start": self.date_range_start.isoformat() if self.date_range_start else None,
            "date_range_end": self.date_range_end.isoformat() if self.date_range_end else None,
            "message_count": self.message_count,
            "topics": self.topics,
            "summary": self.summary,
            "decisions": self.decisions,
            "advice": self.advice,
            "events": self.events,
            "entities": {
                "people": self.entities_people,
                "places": self.entities_places,
                "organizations": self.entities_organizations,
            },
            "privacy_level": self.privacy_level,
            "extraction_model": self.extraction_model,
            "extracted_at": self.extracted_at.isoformat() if self.extracted_at else None,
            "extraction_error": self.extraction_error,
        }

    def get_text_for_embedding(self) -> str:
        """Get text representation for embedding."""
        parts = [
            f"Subject: {self.subject}",
            f"Summary: {self.summary}",
        ]

        if self.topics:
            parts.append(f"Topics: {', '.join(self.topics)}")

        if self.decisions:
            parts.append(f"Decisions: {'; '.join(self.decisions)}")

        if self.advice:
            parts.append(f"Advice: {'; '.join(self.advice)}")

        if self.events:
            parts.append(f"Events: {'; '.join(self.events)}")

        return "\n".join(parts)


class EmailSummarizer:
    """
    Summarizes email threads using LLM to extract knowledge.

    Supports multiple backends:
    - Ollama (local, private)
    - Gemini (fast, cheap API)
    """

    def __init__(
        self,
        ollama_host: str = "http://localhost:11434",
        model: str = "qwen2.5:14b-instruct",
        timeout: float = 120.0,
        provider: str = "ollama",  # "ollama" or "gemini"
        gemini_api_key: Optional[str] = None,
    ):
        """
        Initialize summarizer.

        Args:
            ollama_host: Ollama server URL (for ollama provider)
            model: Model to use for summarization
            timeout: Request timeout in seconds
            provider: "ollama" or "gemini"
            gemini_api_key: API key for Gemini (required if provider="gemini")
        """
        self.ollama_host = ollama_host.rstrip('/')
        self.model = model
        self.timeout = timeout
        self.provider = provider
        self.gemini_api_key = gemini_api_key

        if provider == "gemini" and not gemini_api_key:
            raise ValueError("gemini_api_key required when provider='gemini'")

        self._stats = {
            "threads_processed": 0,
            "successful": 0,
            "failed": 0,
            "total_tokens": 0,
        }

    async def summarize_thread(
        self,
        thread: EmailThread,
        max_content_length: int = 8000,
    ) -> ThreadKnowledge:
        """
        Summarize an email thread and extract knowledge.

        Args:
            thread: EmailThread to summarize
            max_content_length: Maximum content length to send to LLM

        Returns:
            ThreadKnowledge with extracted information
        """
        self._stats["threads_processed"] += 1

        # Create knowledge object
        knowledge = ThreadKnowledge(
            thread_id=thread.thread_id,
            subject=thread.subject,
            participants=thread.participants,
            date_range_start=thread.date_range_start,
            date_range_end=thread.date_range_end,
            message_count=thread.message_count,
            extraction_model=self.model,
            extracted_at=datetime.now(),
        )

        # Build prompt
        content = thread.get_thread_content()
        if len(content) > max_content_length:
            content = content[:max_content_length] + "\n... (truncated)"

        prompt = SUMMARIZE_PROMPT.format(
            subject=thread.subject,
            participants=", ".join(thread.participants[:10]),  # Limit participants
            start_date=thread.date_range_start.strftime("%Y-%m-%d") if thread.date_range_start else "Unknown",
            end_date=thread.date_range_end.strftime("%Y-%m-%d") if thread.date_range_end else "Unknown",
            count=thread.message_count,
            content=content,
        )

        try:
            if self.provider == "gemini":
                response = await self._call_gemini(prompt)
            else:
                response = await self._call_ollama(prompt)
            self._parse_response(response, knowledge)
            self._stats["successful"] += 1

        except Exception as e:
            logger.error(f"Failed to summarize thread {thread.thread_id}: {e}")
            knowledge.extraction_error = str(e)
            knowledge.summary = f"Thread about: {thread.subject}"  # Fallback
            knowledge.topics = [thread.normalized_subject]
            self._stats["failed"] += 1

        return knowledge

    async def summarize_threads(
        self,
        threads: List[EmailThread],
        max_content_length: int = 8000,
        progress_callback=None,
    ) -> List[ThreadKnowledge]:
        """
        Summarize multiple threads.

        Args:
            threads: List of threads to summarize
            max_content_length: Maximum content per thread
            progress_callback: Called with (current, total) for progress

        Returns:
            List of ThreadKnowledge objects
        """
        results = []

        for i, thread in enumerate(threads):
            knowledge = await self.summarize_thread(thread, max_content_length)
            results.append(knowledge)

            if progress_callback:
                progress_callback(i + 1, len(threads))

        return results

    async def _call_ollama(self, prompt: str) -> str:
        """Call Ollama API for completion."""
        url = f"{self.ollama_host}/api/generate"

        payload = {
            "model": self.model,
            "prompt": prompt,
            "stream": False,
            "options": {
                "temperature": 0.3,  # Lower for more consistent extraction
                "num_predict": 1024,  # Limit response length
            },
        }

        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(url, json=payload)
            response.raise_for_status()

            data = response.json()
            return data.get("response", "")

    async def _call_gemini(self, prompt: str, max_retries: int = 10) -> str:
        """Call Google Gemini API for completion with retry logic."""
        import asyncio

        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"

        payload = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {
                "temperature": 0.3,
                "maxOutputTokens": 1024,
            },
        }

        headers = {
            "Content-Type": "application/json",
            "x-goog-api-key": self.gemini_api_key,
        }

        for attempt in range(max_retries):
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.post(url, json=payload, headers=headers)

                if response.status_code == 429:
                    # Rate limited - wait and retry with exponential backoff
                    wait_time = min(15 * (2 ** attempt), 300)  # 15, 30, 60, 120, 240, 300 max
                    logger.warning(f"Rate limited, waiting {wait_time}s (attempt {attempt + 1}/{max_retries})")
                    await asyncio.sleep(wait_time)
                    continue

                response.raise_for_status()
                data = response.json()

                # Extract text from Gemini response
                try:
                    # Add delay between requests to avoid rate limits (6s = 10 RPM)
                    await asyncio.sleep(6)
                    return data["candidates"][0]["content"]["parts"][0]["text"]
                except (KeyError, IndexError):
                    logger.error(f"Unexpected Gemini response format: {data}")
                    return ""

        raise Exception(f"Failed after {max_retries} retries due to rate limiting")

    def _parse_response(self, response: str, knowledge: ThreadKnowledge):
        """Parse LLM response and populate knowledge object."""
        # Try to extract JSON from response
        try:
            # Strip <think>...</think> tags from R1 models
            cleaned = re.sub(r'<think>[\s\S]*?</think>', '', response).strip()

            # Strip markdown code blocks
            cleaned = re.sub(r'```json\s*', '', cleaned)
            cleaned = re.sub(r'```\s*', '', cleaned)

            # Find JSON in response (may have text before/after)
            json_match = re.search(r'\{[\s\S]*\}', cleaned)
            if not json_match:
                raise ValueError("No JSON found in response")

            data = json.loads(json_match.group())

            # Populate knowledge
            knowledge.topics = data.get("topics", [])
            knowledge.summary = data.get("summary", "")
            knowledge.decisions = data.get("decisions", [])
            knowledge.advice = data.get("advice", [])
            knowledge.events = data.get("events", [])

            entities = data.get("entities", {})
            knowledge.entities_people = entities.get("people", [])
            knowledge.entities_places = entities.get("places", [])
            knowledge.entities_organizations = entities.get("organizations", [])

            privacy = data.get("privacy_level", 4)
            knowledge.privacy_level = max(3, min(5, int(privacy)))  # Clamp to 3-5

        except json.JSONDecodeError as e:
            logger.warning(f"Failed to parse JSON response: {e}")
            # Fallback: try to extract what we can
            knowledge.summary = response[:500] if response else ""
            knowledge.topics = [knowledge.subject]

    @property
    def stats(self) -> Dict[str, int]:
        return self._stats.copy()


async def test_summarizer():
    """Test the summarizer with a sample thread."""
    from .thread_aggregator import EmailMessage, EmailThread

    # Create test thread
    thread = EmailThread(
        thread_id="test123",
        subject="Test conversation",
        normalized_subject="test conversation",
    )

    thread.add_message(EmailMessage(
        message_id="msg1",
        from_address="alice@example.com",
        from_name="Alice",
        to_addresses=["bob@example.com"],
        cc_addresses=[],
        subject="Test conversation",
        date=datetime(2026, 1, 15, 10, 0),
        body="Hi Bob, I wanted to discuss the project timeline. Can we meet next week?",
        is_sent=False,
    ))

    thread.add_message(EmailMessage(
        message_id="msg2",
        from_address="bob@example.com",
        from_name="Bob",
        to_addresses=["alice@example.com"],
        cc_addresses=[],
        subject="Re: Test conversation",
        date=datetime(2026, 1, 15, 14, 30),
        body="Hi Alice, sure! How about Tuesday at 2pm? We can discuss the deliverables.",
        is_sent=True,
    ))

    thread.finalize()

    # Test summarization
    summarizer = EmailSummarizer()
    knowledge = await summarizer.summarize_thread(thread)

    print(f"Thread: {knowledge.subject}")
    print(f"Summary: {knowledge.summary}")
    print(f"Topics: {knowledge.topics}")
    print(f"Decisions: {knowledge.decisions}")
    print(f"Privacy Level: {knowledge.privacy_level}")


if __name__ == "__main__":
    import asyncio
    asyncio.run(test_summarizer())
