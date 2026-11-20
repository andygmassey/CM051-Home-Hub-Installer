"""CB136: a reply debt is owed by a PERSON, and the raw sender is never the name.

Measured on the 135 walk box (synthetic names only in this file): the Hub's
reply-debt list carried a newsletter digest sender and a store receipt as people
the owner owed a reply to, and the chat answered with one of them.

Three rules, each with a test and a mutant:
  1. detect_thread never falls back to the raw sender string for the name.
  2. a newsletter, service or organisation sender is never a debt (identify_threads
     drops a name-keyed one; detect_thread refuses one that gets through).
  3. a receipt or order confirmation is automated, so it is never owed.
"""
from __future__ import annotations

import pathlib
from datetime import datetime, timedelta, timezone

from src.reply_debt import (
    Message,
    Thread,
    detect_thread,
    identify_threads,
    is_non_person_sender,
    owed_verdict,
)

NOW = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
OLD = NOW - timedelta(days=9)


class _Res:
    is_owner = False
    name = None
    kind = "email"


class _Dir:
    def resolve(self, handle):
        return _Res()

    def is_owner(self, name):
        return False


def _email_thread(sender: str, text: str, *, counterpart_name: str = "") -> Thread:
    return Thread(
        thread_id="email:synthetic-1",
        channel="email",
        messages=(Message(sender=sender, text=text, timestamp=OLD, is_from_owner=False),),
        privacy_level="L2",
        is_group=False,
        counterpart_name=counterpart_name,
    )


ASK = "Could you send me the revised quote for the project before Friday? Thanks"
RECEIPT = ("Acme store order number: W0000000000 Ordered on: 16/10/2026. "
           "Your order has been placed. Thank you for your order.")


# --- rule 2: a newsletter or service sender is never a debt -----------------

def test_a_newsletter_name_is_not_a_person():
    assert is_non_person_sender("acme digest weekly")
    assert is_non_person_sender("acme newsletter")
    assert is_non_person_sender("")  # no name: nobody we can name
    assert not is_non_person_sender("Jane Doe")


def test_a_newsletter_sender_is_dropped_before_it_becomes_a_debt():
    t = _email_thread("acme digest weekly", ASK)
    kept, excluded = identify_threads([t], _Dir())
    assert kept == []
    assert excluded["not_a_person"] == 1
    assert detect_thread(t, now=NOW) is None


def test_a_real_person_name_is_kept_as_the_name():
    t = _email_thread("Jane Doe", ASK)
    kept, _ = identify_threads([t], _Dir())
    assert len(kept) == 1
    debt = detect_thread(kept[0], now=NOW)
    assert debt is not None
    assert debt.person_name == "Jane Doe"


# --- rule 1: no raw-sender fallback -----------------------------------------

def test_detect_thread_never_uses_the_raw_sender_as_the_name():
    # The directory named nobody (counterpart_name empty). The sender string is
    # a real-looking name, but it must not become the debt's person.
    t = _email_thread("Jane Doe", ASK, counterpart_name="")
    assert detect_thread(t, now=NOW) is None


# --- rule 3: a receipt is automated ------------------------------------------

def test_a_receipt_is_not_owed():
    verdict, rule = owed_verdict(_email_thread("Jane Doe", RECEIPT))
    assert verdict == "no"
    assert rule == "receipt_or_automated"


def test_a_real_question_is_still_owed():
    t = Thread(
        thread_id="x", channel="email",
        messages=(Message(sender="Jane Doe", text=ASK, timestamp=OLD, is_from_owner=False),),
        counterpart_name="Jane Doe", counterpart_resolved=True,
    )
    assert detect_thread(t, now=NOW) is not None


def test_mutant_raw_sender_fallback_is_caught():
    """Mutant: restore `or last.sender`. The no-fallback test must go red."""
    src = pathlib.Path(__file__).resolve().parents[2] / "vendor" / "cm048_pipeline" / "src" / "reply_debt.py"
    real = src.read_text(encoding="utf-8")
    old = 'person = thread.counterpart_name or ""\n'
    assert real.count(old) == 1
    mutant_src = real.replace(old, 'person = thread.counterpart_name or thread.messages[-1].sender or "Unknown"\n')
    ns: dict = {}
    # Execute the mutant module under its real name so its relative imports resolve.
    import types
    mod = types.ModuleType("src.reply_debt_mutant")
    mod.__file__ = str(src)
    import sys
    sys.modules["src.reply_debt_mutant"] = mod
    exec(compile(mutant_src, str(src), "exec"), mod.__dict__)
    t = _email_thread("Jane Doe", ASK, counterpart_name="")
    assert mod.detect_thread(t, now=NOW) is not None, "mutant must name the raw sender"
    assert detect_thread(t, now=NOW) is None, "shipped code must not"
