#!/usr/bin/env python3
"""The Doctor must not show a customer the year 2318.

PROVED-RED-BY: this file, mutation 1 and mutation 2.

THE DEFECT, MEASURED ON A LIVE BOX 2026-09-18, on the wire, from the endpoint
the customer's own Doctor page reads:

    GET http://127.0.0.1:8089/api/v1/box-status
    llm.keep_alive = "2318-12-29T02:25:59.162660807+08:00"

CONTROLS taken in the same read, so the finding is not a pattern artefact: the
payload was 1478 bytes so it was really read, and the same regex shape found
exactly one far-future date and zero ordinary ones, which matches a payload
carrying this single timestamp rather than a predicate that matches everything.

WHAT THE VALUE MEANS. install.sh starts Ollama with OLLAMA_KEEP_ALIVE=-1, which
is Ollama's way of saying keep the model resident indefinitely, and Ollama
expresses that as an expires_at roughly three centuries out. The number is not
wrong and it is not Ollama's bug. box_status.py piped an internal sentinel to a
customer-facing surface unchanged.

WHY A THRESHOLD AND NOT A LITERAL STRING. Pinning the exact date would break the
moment Ollama picks a different far one, and would break SILENTLY: the sentinel
would start rendering as a date again with nothing to notice. Any expiry more
than ten years out cannot be a real keep-alive window on a machine that reboots,
so the threshold IS the meaning rather than a guess at it.

THREE ANSWERS, NOT TWO, and the third is the one that keeps this honest. None
passes through. A parseable NEAR date passes through unchanged, because that is
a real expiry a customer may want to see. An UNPARSEABLE value passes through
too: the job is to translate a sentinel, not to swallow a value we do not
recognise. Hiding an unexpected string would trade a visible oddity for an
invisible one, which is the trade this repo keeps paying for.

British English throughout; " -- " not em-dashes.
"""
import datetime as dt
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "vendor" / "doctor" / "agent" / "box_status.py"

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok    {msg}")


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")
    if detail:
        for line in str(detail).splitlines():
            print(f"        | {line}")


def load(text):
    """Exec a candidate source and hand back its translator, or None."""
    ns = {}
    try:
        exec(compile(text, "box_status_candidate", "exec"), ns)
    except Exception as exc:                      # a mutant that will not import
        return None, exc
    return ns.get("_keep_alive_for_a_person"), None


def main():
    print("test_a_sentinel_is_not_a_date_on_a_customer_surface")
    if not SRC.is_file():
        print(f"CANNOT-RUN: no box_status at {SRC}", file=sys.stderr)
        return 2
    src = SRC.read_text(encoding="utf-8")

    # ── 0. CONTROL: the file was read AND a fabricated name is absent, so the
    #       reads below discriminate rather than matching anything.
    if "_keep_alive_for_a_person" in src and "_definitely_not_here_xyzzy" not in src:
        ok("(0) CONTROL: the translator is present and a fabricated name is not")
    else:
        bad("(0) CONTROL FAILED: the source could not be read discriminatingly")
        return 1

    fn, exc = load(src)
    if fn is None:
        bad("(1) the translator could not be loaded", exc)
        return 1
    ok("(1) the translator loads")

    # ── 2. THE LIVE VALUE. Exactly the string measured on the box, nanoseconds
    #       and a +08:00 offset included, because both defeated the first
    #       implementation attempt.
    live = "2318-12-29T02:25:59.162660807+08:00"
    got = fn(live)
    if got == "indefinite":
        ok("(2) the live sentinel measured on the box renders as 'indefinite'")
    else:
        bad(f"(2) the sentinel rendered as {got!r}; a customer still sees a date")

    # ── 3. A REAL EXPIRY SURVIVES. Without this, 'always return indefinite'
    #       passes assertion 2 and destroys the field's meaning.
    near = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5)).isoformat()
    if fn(near) == near:
        ok("(3) a real five-minute expiry passes through unchanged")
    else:
        bad(f"(3) a real expiry was rewritten to {fn(near)!r}; the field now says nothing")

    # ── 4. THREE STATES. An unparseable value is not swallowed.
    if fn("not-a-date") == "not-a-date" and fn(None) is None and fn("") == "":
        ok("(4) None, empty and unparseable all pass through rather than being swallowed")
    else:
        bad(f"(4) got {fn('not-a-date')!r} / {fn(None)!r} / {fn('')!r}")

    # ── 5. AND IT IS WIRED. A translator nothing calls is the failure mode this
    #       repo keeps paying for, and it is the exact shape of the original
    #       defect: a correct value, never consulted.
    if '"keep_alive": _keep_alive_for_a_person(' in src:
        ok("(5) the status payload CALLS it, so this is wired and not merely written")
    else:
        bad("(5) the translator exists and the payload still emits expires_at raw")

    # ===================================================================
    # MUTATION. Both ways of getting this wrong must go RED.
    # ===================================================================
    print()
    print("  -- mutation --")

    m1 = src.replace("return _KEEP_ALIVE_INDEFINITE", "return expires_at", 1)
    if m1 == src:
        bad("(M1) the mutant could not be built, so nothing was mutation-tested")
    else:
        f1, _ = load(m1)
        r1 = f1(live) if f1 else "no translator"
        if r1 == live:
            ok("(M1) RED ON THE DEFECT: with the translation removed the customer sees "
               "the 2318 date again, so assertion (2) is load-bearing")
        else:
            bad(f"(M1) MUTANT SURVIVED: removing the translation still gave {r1!r}")

    # -1 and not 0, and the first attempt at this mutant was wrong in a way
    # worth recording: with the threshold at 0 the comparison is `days > 0`, and
    # a five-minute-future date has days == 0, so it still passed through. The
    # mutant changed nothing and reported assertion (3) as proving nothing when
    # the MUTANT was the thing at fault. A mutant that does not apply looks
    # exactly like one that was not caught.
    m2 = src.replace("_KEEP_ALIVE_SENTINEL_YEARS = 10", "_KEEP_ALIVE_SENTINEL_YEARS = -1", 1)
    if m2 == src:
        bad("(M2) the mutant could not be built, so the over-reach direction was not tested")
    else:
        f2, _ = load(m2)
        r2 = f2(near) if f2 else "no translator"
        if r2 == "indefinite":
            ok("(M2) RED ON OVER-REACH: a negative threshold swallows a REAL expiry, "
               "which assertion (3) catches")
        else:
            bad(f"(M2) MUTANT SURVIVED: a negative threshold left a real expiry as {r2!r}, "
                "so assertion (3) proves nothing")

    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
