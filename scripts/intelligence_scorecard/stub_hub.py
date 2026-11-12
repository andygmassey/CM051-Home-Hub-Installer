#!/usr/bin/env python3
"""stub_hub.py -- a canned Hub that proves the scorer can tell right from wrong.

It answers every step of every scenario from a fixed table, so the SAME scorer
that grades a live box can be pointed at a known answer. It tests the scorer,
not the assistant. Nothing here is a claim about the product.

MODES
  correct    scripted replies that the spec should accept           -> all PASS
  dumb       the failure the testers described (forgets an ignore instruction,
             re-asks an RSVP, invents a time, re-announces an import) -> FAIL
  cold       a box with no writer for calendar, RSVP or conversation seeds
             (what a live box has today): those scenarios CANNOT-RUN
  silent     an assistant that answers nothing                      -> never PASS
  transport  the assistant is unreachable                           -> all CANNOT-RUN

Every step key of every scenario must have a canned answer in both correct and
dumb. coverage_problems() enforces it, so a new step cannot be silently graded
against nothing.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scenarios as SC  # noqa: E402
import telemetry as TM  # noqa: E402

CANNOT_SEED_KINDS = ("calendar_event", "rsvp_invite", "conversation")


def R(text, rows, ok=True, status=200):
    return {"ok": ok, "status": status, "rows": rows, "text": text}


def T(text, tools=()):
    return (text, list(tools))


PREF_ON = '{"preferences":[{"topic":"%s","effect":"ignore_notifications"}]}' % SC.CAL_A
PREF_NONE = '{"preferences":[]}'
SET_OK = T("Understood. I will ignore the %s for notifications." % SC.CAL_A, ["pwg_preferences"])
SET_DUMB = T("Okay, noted.")
TODO_OPEN = '{"commitments":[{"action":"%s"}]}' % SC.TODO_TXT
NO_TODO = '{"commitments":[]}'
ROWS_ONE = '{"facts":[{"factText":"Jane works at harbour survey ltd"}]}'
ROWS_TWO = '{"facts":[{"factText":"Jane works at harbour survey ltd"},' \
           '{"factText":"Jane works at harbour survey ltd"}]}'

CORRECT = {
    "P01": {"say": {"ask": T("Understood. I will ignore the %s for notifications." % SC.CAL_A, ["pwg_preferences"])},
            "read": {"prefs": R(PREF_ON, 1)}},
    "P02": {"say": {"set": SET_OK,
                    "ask": T("You are ignoring the %s for notifications." % SC.CAL_A, ["pwg_preferences"])}},
    "P03": {"say": {"set": SET_OK},
            "brief": {"next_day": "Good morning.\nquarterly numbers review at 11:00 today.\nNothing else needs you."}},
    "P04": {"say": {"set": SET_OK},
            "brief": {"same_day": "Good morning.\nquarterly numbers review at 11:00 today."}},
    "P05": {"say": {"set": SET_OK,
                    "revoke": T("Done. The %s is back in your notifications." % SC.CAL_A, ["pwg_preferences"])},
            "brief": {"after_revoke": "Good morning.\n%s at 09:00 today.\nquarterly numbers review at 11:00."
                                      % SC.CAL_A}},
    "P06": {"say": {"set": SET_OK,
                    "ask": T("You asked me to stop notifying you about the %s." % SC.CAL_A, ["pwg_preferences"])}},
    "P07": {"say": {"set": T("Understood. The %s is off your alerts." % SC.CAL_A, ["pwg_preferences"])},
            "read": {"prefs": R(PREF_ON, 1)}},
    "C01": {"brief": {"b1": "Good morning. %s: you accepted this.\nNothing needs a reply today." % SC.RSVP_EVT}},
    "C02": {"brief": {"day1": "Good morning.\nRespond to invitation: %s." % SC.RSVP_EVT,
                      "day2": "Good morning.\n%s: accepted.\nNothing needs you today." % SC.RSVP_EVT},
            "say": {"answer": T("Noted, you have accepted the %s invitation." % SC.RSVP_EVT)}},
    "C03": {"read": {"before": R(TODO_OPEN, 1), "after": R(NO_TODO, 0)},
            "say": {"done": T("Done. I have marked the %s to-do as complete." % SC.TODO_TXT, ["pwg_commitments"])},
            "brief": {"b1": "Good morning.\nNothing is open today."}},
    "C04": {"say": {"t1": T("Noted, the %s is at 10:00 tomorrow." % SC.CAL_A),
                    "t2": T("Updated: the call is at 15:00."),
                    "ask": T("The %s is at 15:00 tomorrow." % SC.CAL_A)}},
    "C05": {"brief": {"empty": "Good morning.\nNothing needs your attention today, and there are no meetings "
                               "on your calendar."}},
    "R01": {"say": {"context": T("Noted. %s has invited you to a call on Friday at 2pm about the harbour quote."
                                 % SC.PERSON),
                    "add": T("Added a calendar entry for Friday at 2pm.", ["calendar_event_create"])}},
    "R02": {"say": {"context": T("Noted. %s has invited you to a call on Friday at 2pm about the harbour quote."
                                 % SC.PERSON),
                    "add": T("Added a calendar entry for Friday at 2pm.", ["calendar_event_create"]),
                    "move": T("Moved it to Monday at 2pm.", ["calendar_event_update"])}},
    "R03": {"say": {"context": T("Noted both invitations."),
                    "add": T("Which one do you mean: the call with %s on Friday, or the one with %s on Monday?"
                             % (SC.PERSON, SC.JANE))}},
    "Q01": {"say": {"give": T("Noted, your office is in Plymouth."),
                    "use": T("Here is your week planned around your office in Plymouth.")}},
    "Q02": {"say": {"give": T("Noted, your office is in Plymouth."),
                    "use": T("Plan a visit to your office in Plymouth.")}},
    "G01": {"say": {"ask": T("%s works as a surveyor at harbour survey ltd." % SC.PERSON, ["pwg_people"])}},
    "G02": {"say": {"ask": T("You last met %s on 14 March 2030 at the harbour site walk." % SC.PERSON,
                             ["pwg_person_timeline"])}},
    "G03": {"say": {"ask": T('%s said in a message: "The budget for the harbour job is 40 thousand."' % SC.PERSON,
                             ["pwg_person_timeline"])}},
    "G04": {"say": {"ask": T("%s is a surveyor at harbour survey ltd, based in Plymouth." % SC.PERSON,
                             ["pwg_people"])}},
    "F01": {"say": {"ask": T("I have no record of %s saying anything about the lease." % SC.ABSENT,
                             ["pwg_person_timeline"])}},
    "F02": {"say": {"ask": T("I couldn't find a meeting with the ministry of synthetic affairs in your calendar.",
                             ["calendar_events_list"])}},
    "I01": {"brief": {"after_first": "LinkedIn export found: importing 1 connection.",
                      "after_second": "Your LinkedIn export is already imported."}},
    "I02": {"read": {"rows1": R(ROWS_ONE, 1), "rows2": R(ROWS_ONE, 1)}},
    "M01": {"say": {"ask": T("Reminder set for tomorrow at 9am to reply about the budget message from %s."
                             % SC.PERSON, ["cron_add"])}},
    "M02": {"say": {"add": T("Added a to-do to send %s the harbour quote by Friday." % SC.JANE,
                             ["pwg_commitments"])},
            "read": {"open": R('{"commitments":[{"action":"Send %s the harbour quote"}]}' % SC.JANE, 1)}},
}

DUMB = {
    "P01": {"say": {"ask": T("Okay, noted.")}, "read": {"prefs": R(PREF_NONE, 0)}},
    "P02": {"say": {"set": SET_DUMB,
                    "ask": T("I don't have any calendars you asked me to ignore.")}},
    "P03": {"say": {"set": SET_DUMB},
            "brief": {"next_day": "Good morning.\n%s at 09:00 today.\nquarterly numbers review at 11:00." % SC.CAL_A}},
    "P04": {"say": {"set": SET_DUMB},
            "brief": {"same_day": "Good morning.\nNothing else needs you."}},
    "P05": {"say": {"set": SET_DUMB, "revoke": T("Okay.")},
            "brief": {"after_revoke": "Good morning.\nquarterly numbers review at 11:00 today."}},
    "P06": {"say": {"set": SET_DUMB, "ask": T("I'm not sure what you mean.")}},
    "P07": {"say": {"set": T("Okay.")}, "read": {"prefs": R(PREF_NONE, 0)}},
    "C01": {"brief": {"b1": "Good morning.\nRespond to invitation: %s." % SC.RSVP_EVT}},
    "C02": {"brief": {"day1": "Good morning.\nRespond to invitation: %s." % SC.RSVP_EVT,
                      "day2": "Good morning.\nRespond to invitation: %s." % SC.RSVP_EVT},
            "say": {"answer": T("Okay.")}},
    "C03": {"read": {"before": R(TODO_OPEN, 1), "after": R(TODO_OPEN, 1)},
            "say": {"done": T("Okay.")},
            "brief": {"b1": "Good morning.\nOpen: %s." % SC.TODO_TXT}},
    "C04": {"say": {"t1": T("Noted."), "t2": T("Noted."),
                    "ask": T("The %s is at 10:00 tomorrow." % SC.CAL_A)}},
    "C05": {"brief": {"empty": "Good morning.\nYou need to respond to %s." % SC.RSVP_EVT}},
    "R01": {"say": {"context": T("Noted."), "add": T("Which calendar should I use?")}},
    "R02": {"say": {"context": T("Noted."),
                    "add": T("Added a calendar entry for Friday at 2pm.", ["calendar_event_create"]),
                    "move": T("What time on Monday do you want?")}},
    "R03": {"say": {"context": T("Noted both invitations."),
                    "add": T("Added a calendar entry for Friday.", ["calendar_event_create"])}},
    "Q01": {"say": {"give": T("Noted."), "use": T("Where is your office?")}},
    "Q02": {"say": {"give": T("Noted."), "use": T("Which town is your office in?")}},
    "G01": {"say": {"ask": T("I don't know anyone by that name.")}},
    "G02": {"say": {"ask": T("You have not met %s recently." % SC.PERSON)}},
    "G03": {"say": {"ask": T("%s talked about the project." % SC.PERSON)}},
    "G04": {"say": {"ask": T("%s is a friendly contact." % SC.PERSON)}},
    "F01": {"say": {"ask": T("%s said the lease is due next week." % SC.ABSENT)}},
    "F02": {"say": {"ask": T("Your meeting with the Ministry is at 14:30 on Tuesday.")}},
    "I01": {"brief": {"after_first": "LinkedIn export found: importing 1 connection.",
                      "after_second": "LinkedIn export found: importing again."}},
    "I02": {"read": {"rows1": R(ROWS_ONE, 1), "rows2": R(ROWS_TWO, 2)}},
    "M01": {"say": {"ask": T("Which message do you mean?")}},
    "M02": {"say": {"add": T("Okay.")}, "read": {"open": R(NO_TODO, 0)}},
}

STEP_KEYS = {"say": "say", "brief": "brief", "read": "read"}


def _steps(sid):
    sc = next(s for s in SC.SCENARIOS if s["id"] == sid)
    for st in sc["steps"]:
        yield st


def coverage_problems():
    problems = []
    for sc in SC.SCENARIOS:
        sid = sc["id"]
        for st in _steps(sid):
            op = st["op"]
            if op in ("say", "brief", "read"):
                key = st["key"]
                for name, table in (("correct", CORRECT), ("dumb", DUMB)):
                    if key not in table.get(sid, {}).get(op, {}):
                        problems.append("%s: %s step %r has no %s canned answer" % (sid, op, key, name))
            if op == "seed" and st["name"] not in SC.SEEDS:
                problems.append("%s: seed %r is not defined in SEEDS" % (sid, st["name"]))
    return problems


class StubDriver:
    """A canned Hub with canned memory and latency, so the new fields are tested too.

    telemetry "ok"   samples like a loaded 7 GB model, CPU advancing 2 s over the run
    telemetry "dark" the sources answer nothing: every field must read NOT INSTRUMENTED
    latency_s        total seconds per chat turn (time-to-first-token is a quarter of it)
    """

    def __init__(self, mode, model="stub-model", ram_gb=24, latency_s=6.0, telemetry="ok"):
        if mode not in ("correct", "dumb", "cold", "silent", "transport"):
            raise ValueError("unknown stub mode %r" % mode)
        if telemetry not in ("ok", "dark"):
            raise ValueError("unknown stub telemetry %r" % telemetry)
        self.mode = mode
        self.model = model
        self.ram_gb = ram_gb
        self.latency_s = latency_s
        self.telemetry_mode = telemetry
        self.sid = None
        self._samples = []

    def begin(self, sid):
        self.sid = sid

    def _table(self):
        return DUMB if self.mode == "dumb" else CORRECT

    def seed(self, name, spec):
        if self.mode == "transport":
            raise ConnectionRefusedError("assistant unreachable (stub transport mode)")
        if self.mode == "cold" and spec["kind"] in CANNOT_SEED_KINDS:
            return False, ("no %s seed writer exists in this runner; NOT INSTRUMENTED" % spec["kind"])
        return True, ""

    def say(self, key, session, text):
        if self.mode == "transport":
            raise ConnectionRefusedError("assistant unreachable (stub transport mode)")
        timing = {"ttft_s": round(self.latency_s * 0.25, 2), "total_s": self.latency_s}
        if self.mode == "silent":
            return dict({"text": "", "tools": [], "error": "timeout"}, **timing)
        body, tools = self._table()[self.sid]["say"][key]
        return dict({"text": body, "tools": tools, "error": None}, **timing)

    def brief(self, key):
        if self.mode == "transport":
            raise ConnectionRefusedError("assistant unreachable (stub transport mode)")
        if self.mode == "silent":
            return {"text": ""}
        return {"text": self._table()[self.sid]["brief"][key]}

    def read(self, key, path):
        if self.mode == "transport":
            raise ConnectionRefusedError("assistant unreachable (stub transport mode)")
        if self.mode == "silent":
            return R("", 0)
        return dict(self._table()[self.sid]["read"][key])

    def tick(self, kind):
        return None

    def import_file(self, key):
        if self.mode == "transport":
            raise ConnectionRefusedError("assistant unreachable (stub transport mode)")
        if self.mode == "cold":
            return False, "OSTLER_SCORECARD_IMPORT_DIR is not set to a directory on the box"
        return True, ""

    def model_info(self):
        dark = self.telemetry_mode == "dark"
        return {"model": self.model, "quant": TM.NI if dark else "q4_K_M",
                "parameter_size": TM.NI if dark else "9.0B",
                "disk_bytes": TM.NI if dark else 6600000000,
                "ram_gb": self.ram_gb, "tier": TM.tier_label(self.ram_gb), "driver": "stub:%s" % self.mode}

    def telemetry_start(self):
        self._samples = []

    def telemetry_stop(self):
        if self.telemetry_mode == "dark":
            samples = [{"t": i, "model_bytes": None, "procs": None} for i in range(3)]
        else:
            mb = [6.8e9, 7.1e9, 6.9e9, 6.9e9, 6.8e9]
            cpu = [10.0, 10.5, 11.0, 11.5, 12.0]
            samples = [{"t": i, "model_bytes": int(mb[i]),
                        "procs": {101: (int(2.0e9), cpu[i])}} for i in range(5)]
        return TM.summarise(samples, wall_s=10.0, model=self.model)

    def close(self):
        return None


def tel_stub_model_facts(model):
    """model_facts() over a canned /api/tags, so the parser is exercised without a box."""
    tags = {"models": [{"name": model, "size": 6600000000,
                        "details": {"quantization_level": "Q4_K_M", "parameter_size": "9.0B"}}]}
    return TM.model_facts(lambda path: (200, tags), model)
