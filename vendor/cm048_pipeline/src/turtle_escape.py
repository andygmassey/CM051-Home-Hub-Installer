"""Turtle / SPARQL literal escape for double-quoted string literals.

Lifted from the canonical Python implementation at
``whatsapp_bridge/bridge.py:212`` (``_escape``) and the gateway's
``services/gateway/src/sparql_escape.py``. CM048 emits Turtle (not
SPARQL UPDATE) but the W3C grammar for STRING_LITERAL_QUOTE is
identical between the two: the same character set must be escaped to
keep an attacker-controllable string trapped inside its surrounding
double-quotes.

Covers:

- ``\\`` -> ``\\\\`` (must be first so we do not double-escape our own
  escapes)
- ``"``  -> ``\\"``
- ``\\n``, ``\\r``, ``\\t`` (newline, carriage return, tab)
- U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR -- Turtle / SPARQL
  serialisers may treat these as literal terminators

Use this for every interpolation into a Turtle ``"..."`` string literal
in the CM048 triple-builders. The pre-existing builders had three
classes of inline interpolation:

1. ``_fact_to_triples`` already passes ``fact["text"]`` through
   ``json.dumps`` -- safe (JSON escape happens to be a strict
   superset of Turtle string-literal escape for the bytes the
   builder interpolates).
2. ``_signal_to_triples`` and ``_conversation_to_triples`` interpolate
   bare LLM-classification values (``warmth``, ``trust``, ``setting``,
   ``shape``, ``stakes``) and ``settings.user_id`` directly into
   ``"..."`` literals with no escape -- this module fixes that.
3. ``_fact_to_triples`` also interpolates ``fact["type"]``,
   ``fact["domain"]``, ``fact["privacy_level"]``, ``fact["signal_strength"]``
   bare. Same fix.
"""

from __future__ import annotations

# Use chr() / ord() to avoid Write-tool encoding ambiguity around the
# U+2028 / U+2029 codepoints. Functionally identical to a string
# literal containing the raw codepoints; just unambiguous in source.
_LINE_SEPARATOR = chr(0x2028)
_PARAGRAPH_SEPARATOR = chr(0x2029)


def escape_turtle_literal(text) -> str:
    """Escape ``text`` for safe insertion into a Turtle ``"..."`` literal.

    Returns the escaped string ready to drop between the outer quotes
    of a Turtle string literal. The caller still owns the surrounding
    quote characters.

    Accepts non-string inputs (``str()``-coerces) so call sites that
    pass through dict ``.get(...)`` defaults of any type stay valid.
    """
    s = text if isinstance(text, str) else str(text)
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
        .replace(_LINE_SEPARATOR, "\\u2028")
        .replace(_PARAGRAPH_SEPARATOR, "\\u2029")
    )
