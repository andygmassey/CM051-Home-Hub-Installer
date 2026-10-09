"""Output-language resolution for CM048 summaries and todos.

Product decision (founder, 2026-09-22): the UI stays English, but a
non-English owner gets first-class summaries, todos and transcripts.

ONE DEFAULT, documented here and in ``settings.yaml.example``:

  ``summary_language: conversation`` (the default) writes the summary
  and todos in the language the conversation was held in. If the owner
  sets ``summary_language`` to a language code (``de``, ``fr``, ``ja``
  ...) every summary and todo list is written in that language instead,
  whatever language the conversation was in.

Precedence for the language of the narrative text:

  1. ``settings.summary_language`` when it is a language code
  2. the capture-side language (``metadata["language"]``, recorded by
     CM042 / CM031 from Whisper's auto-detect)
  3. the dominant language detected from the transcript text
  4. the language part of ``settings.locale`` (en-GB -> en)

Structure is NOT localised. Section headings (``## Action items``),
table column names and JSON keys are machine-parsed downstream and stay
exactly as the prompt shows them. Only the prose inside them changes
language. Proper nouns and quoted source text stay as written.

Detection is a deliberately small, dependency-free heuristic (Unicode
script ranges, then stopword scoring for Latin-script languages). It is
only a fallback for when the capture side did not record a language, and
it is conservative: it returns ``None`` rather than guessing.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

CONVERSATION = "conversation"

# Names used in the prompt instruction. English names are what the
# local models follow most reliably.
LANGUAGE_NAMES: dict[str, str] = {
    "en": "English",
    "fr": "French",
    "de": "German",
    "es": "Spanish",
    "it": "Italian",
    "pt": "Portuguese",
    "nl": "Dutch",
    "ja": "Japanese",
    "zh": "Chinese",
    "yue": "Cantonese (written Chinese)",
    "ko": "Korean",
    "ru": "Russian",
    "ar": "Arabic",
    "he": "Hebrew",
    "hi": "Hindi",
    "th": "Thai",
    "el": "Greek",
    "pl": "Polish",
    "sv": "Swedish",
    "tr": "Turkish",
    "uk": "Ukrainian",
}

_STOPWORDS: dict[str, frozenset[str]] = {
    "en": frozenset(
        "the and is are was were to of in that it for on with this have be "
        "will we you i not but they at as from or by".split()
    ),
    "fr": frozenset(
        "le la les des du une est sont pour dans que qui nous vous je il elle "
        "pas avec sur au aux et ce cette mais ou ne on par plus bonjour merci "
        "demain je'".split()
    ),
    "de": frozenset(
        "der die das den dem und ist sind nicht ich wir sie er es ein eine "
        "einen mit auf für von zu im am auch aber wie wird werden haben "
        "hallo danke morgen".split()
    ),
    "es": frozenset(
        "el la los las de del y es son que en un una por con para no se lo "
        "su al como pero más hola gracias mañana nosotros vamos".split()
    ),
    "it": frozenset(
        "il lo la gli le di del della e è sono che in un una per con non si "
        "come ma più ciao grazie domani abbiamo".split()
    ),
    "pt": frozenset(
        "o a os as de do da e é são que em um uma para com não se como mas "
        "mais olá obrigado amanhã".split()
    ),
    "nl": frozenset(
        "de het een en is zijn dat van in op te voor met niet ik we jij hij "
        "ze maar ook hallo bedankt morgen".split()
    ),
}

# (compiled range, language) tested in order. Kana first so Japanese
# text that also contains Han characters is not read as Chinese.
_SCRIPTS: tuple[tuple[re.Pattern, str], ...] = (
    (re.compile("[぀-ヿㇰ-ㇿ]"), "ja"),
    (re.compile("[가-힯ᄀ-ᇿ]"), "ko"),
    (re.compile("[一-鿿㐀-䶿]"), "zh"),
    (re.compile("[Ѐ-ӿ]"), "ru"),
    (re.compile("[؀-ۿ]"), "ar"),
    (re.compile("[֐-׿]"), "he"),
    (re.compile("[ऀ-ॿ]"), "hi"),
    (re.compile("[฀-๿]"), "th"),
    (re.compile("[Ͱ-Ͽ]"), "el"),
)

_WORD_RE = re.compile(r"[^\W\d_]+(?:'[^\W\d_]+)?", re.UNICODE)
_SPEAKER_PREFIX_RE = re.compile(r"^\s*(?:\*\*)?\[?[^:\n]{1,40}\]?(?:\*\*)?\s*[:：]\s*", re.MULTILINE)


def normalise_code(value: object) -> Optional[str]:
    """Reduce ``fr``, ``fr-FR``, ``fr_FR``, ``French`` to ``fr``.

    Returns ``None`` for empty / unknown input. ``yue`` is kept distinct
    because Whisper reports it; ``zh-HK`` / ``zh-TW`` fold to ``zh``.
    """
    if not isinstance(value, str):
        return None
    v = value.strip().lower().replace("_", "-")
    if not v or v in {"auto", "unknown", "und", CONVERSATION}:
        return None
    by_name = {n.split(" ")[0].lower(): c for c, n in LANGUAGE_NAMES.items()}
    if v in by_name:
        return by_name[v]
    head = v.split("-")[0]
    if 2 <= len(head) <= 3 and head.isalpha():
        return head
    return None


def detect_language(text: str) -> Optional[str]:
    """Best-effort dominant language of ``text``; ``None`` if unsure."""
    if not text or not text.strip():
        return None
    body = _SPEAKER_PREFIX_RE.sub("", text)

    # Script pass: count letters per non-Latin script.
    counts: dict[str, int] = {}
    for pattern, lang in _SCRIPTS:
        n = len(pattern.findall(body))
        if n:
            counts[lang] = n
    if counts:
        # Japanese text mixes kana and Han; any real kana share wins.
        if "ja" in counts and counts["ja"] >= 2:
            return "ja"
        lang, n = max(counts.items(), key=lambda kv: kv[1])
        if n >= 3:
            return lang

    words = [w.lower() for w in _WORD_RE.findall(body)]
    if len(words) < 3:
        return None
    scores = {
        lang: sum(1 for w in words if w in sw) for lang, sw in _STOPWORDS.items()
    }
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    best, best_n = ranked[0]
    runner_n = ranked[1][1]
    if best_n == 0:
        return None
    # Needs a clear margin, or a decent share of the words, to commit.
    if best_n >= 2 and (best_n > runner_n or best_n / len(words) >= 0.2):
        return best
    return None


def language_mix(text: str) -> dict[str, float]:
    """Per-line language shares, e.g. ``{"zh": 0.7, "en": 0.3}``.

    Used to flag mixed-language conversations so the prompt can tell the
    model to keep each speaker's own-language quotes as written.
    """
    tally: dict[str, int] = {}
    total = 0
    for line in text.splitlines():
        lang = detect_language(line)
        if lang is None:
            continue
        tally[lang] = tally.get(lang, 0) + 1
        total += 1
    if not total:
        return {}
    return {k: round(v / total, 3) for k, v in sorted(tally.items(), key=lambda kv: -kv[1])}


@dataclass(frozen=True)
class OutputLanguage:
    """Resolved language for the narrative text of one conversation."""

    code: str
    name: str
    source: str  # "setting" | "capture" | "detected" | "locale"
    mixed: tuple[str, ...] = ()  # other languages present in the transcript

    def to_metadata(self) -> dict:
        out = {"summary_language": self.code, "summary_language_source": self.source}
        if self.mixed:
            out["languages_present"] = ",".join((self.code, *self.mixed))
        return out


def _name(code: str) -> str:
    return LANGUAGE_NAMES.get(code, code)


def resolve_output_language(
    settings,
    metadata: Optional[dict],
    transcript: str,
) -> OutputLanguage:
    """Pick the language for the summary and todos. See module docstring."""
    metadata = metadata or {}
    setting = getattr(settings, "summary_language", CONVERSATION) or CONVERSATION
    chosen = normalise_code(setting)

    mix = language_mix(transcript or "")
    # The conversation's own language: capture side first, then text.
    spoken = normalise_code(metadata.get("language")) or detect_language(transcript or "")

    if chosen:
        source, code = "setting", chosen
    elif spoken:
        source = "capture" if normalise_code(metadata.get("language")) else "detected"
        code = spoken
    else:
        source = "locale"
        code = normalise_code(getattr(settings, "locale", "en-GB")) or "en"

    others = tuple(
        lang for lang, share in mix.items() if lang != code and share >= 0.15
    )
    return OutputLanguage(code=code, name=_name(code), source=source, mixed=others)


def language_instruction(lang: OutputLanguage) -> str:
    """The prompt block that tells the model which language to write in.

    Kept in English on purpose: it is an instruction to the model, not UI.
    """
    lines = [
        f"Write every summary sentence, topic name, topic point and todo "
        f"in {lang.name}.",
        "Keep the structure EXACTLY as specified above: section headings "
        "(for example `## Action items`), table column names "
        "(Owner, Action, Deadline, Priority, Notes) and JSON keys stay in "
        "English because software reads them. Only the prose inside them "
        f"is written in {lang.name}.",
        "Proper nouns (people, places, products, organisations) and "
        "quoted source text stay exactly as written in the transcript. "
        "Never translate a direct quote.",
        "Do not drop anything because it is not English: a commitment "
        "made in any language is a todo.",
    ]
    if lang.mixed:
        others = ", ".join(_name(c) for c in lang.mixed)
        lines.append(
            f"The conversation mixes languages ({others} also appear). "
            f"Write the narrative in {lang.name} and leave each speaker's "
            "own-language quotes as spoken."
        )
    return "--- OUTPUT LANGUAGE ---\n" + "\n".join(lines) + "\n"


_CJK_RE = re.compile("[぀-ヿ㐀-䶿一-鿿가-힯]")
_OTHER_NON_LATIN_RE = re.compile("[Ͱ-ϿЀ-ӿ֐-ۿऀ-ॿ฀-๿]")


def chars_per_token(text: str) -> float:
    """Rough characters-per-token for budgeting a prompt, by script mix.

    The chunker and the prompt excerpt caps were written for English at
    ~4 characters per token. CJK text runs at roughly 1 to 1.5 tokens PER
    character, so a character cap that is safe for English can be four
    times over the model's context window for Japanese or Chinese, and
    Ollama then truncates silently. Blend by the share of each script.
    """
    sample = text[:20000]
    if not sample:
        return 4.0
    n = len(sample)
    cjk = len(_CJK_RE.findall(sample)) / n
    other = len(_OTHER_NON_LATIN_RE.findall(sample)) / n
    latin = max(0.0, 1.0 - cjk - other)
    return max(1.0, 4.0 * latin + 1.5 * cjk + 2.5 * other)


def scale_char_budget(text: str, chars: int) -> int:
    """Scale an English-calibrated character budget to ``text``'s script."""
    return max(1, int(chars * chars_per_token(text) / 4.0))
