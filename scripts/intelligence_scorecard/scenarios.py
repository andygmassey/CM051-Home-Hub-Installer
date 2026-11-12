#!/usr/bin/env python3
"""scenarios.py -- the intelligence scorecard's scenario SPEC (data only).

Every scenario is a script of steps run against a Hub, followed by checks that
read only what the steps recorded. Nothing here talks to a box.

Synthetic data only. People are fictional and sit under example.com, and the
markers below are invented phrases. No real name, address or number belongs in
this file.

STEP OPS (see scorecard.py for the drivers)
  seed(name)                       put a named synthetic fact into the box; a seed
                                   that is not proven READABLE afterwards is a
                                   CANNOT-RUN for the scenario, never a FAIL
  say(key, text, session)          one owner message; reply stored under key
  tick(kind)                       restart  = daemon restart, every session dropped
                                   day_boundary = restart, then a brief run with no
                                   carried session (the box clock cannot be moved)
  brief(key)                       run the morning-brief job once; text stored under key
  read(key, path)                  GET a Hub read route; body and row count stored
  import_file(key)                 drop the synthetic LinkedIn export into the import dir

CHECK KINDS (each names the step key it reads)
  reply_has(turn, any)             a case-insensitive substring in the reply
  reply_has_at_least(turn, n, any) at least n of the substrings
  reply_lacks(turn, none)          none of the substrings
  reply_lacks_regex(turn, pattern) the regex does not match
  reply_no_question(turn)          no "?" and no clarifying phrase
  reply_is_question(turn)          the reply asks something (for ambiguity)
  tool_used(turn, any)             a tool whose name contains a substring ran
  tool_unused(turn, any)           no such tool ran
  brief_has / brief_lacks          as reply_*, on a brief key
  brief_lacks_near(brief, needle, words)   no line holding needle also holds a word
  brief_has_near(brief, needle, words)     some line holding needle also holds a word
  brief_min_chars(brief, n)                the brief is at least n characters (control)
  brief_count_max(brief, needle, n)        needle appears at most n times
  read_has / read_lacks            as reply_*, on a read key
  read_rows_equal(a, b)            two reads of the same route return equal row counts
  read_rows_min(key, n)            a read returns at least n rows

A check may carry a control. Two kinds, because a failed control means two
different things:
  "control": True       PRODUCT control. The output must show the thing the
                        predicate is measured against. If it does not, the product
                        omitted it: FAIL, and the predicate is vacuous.
  "control": "premise"  PREMISE control. The setup had to produce a case for the
                        scenario to mean anything. If it did not, the scenario did
                        not reproduce its case: CANNOT-RUN, never PASS.
"""

# Synthetic markers. Fictional, invented, and stable so checks can name them.
CAL_A = "harbour planning call"          # the calendar the owner asks to ignore
CAL_B = "quarterly numbers review"       # control calendar, must keep notifying
RSVP_EVT = "board preview"               # invitation with an RSVP to answer
PERSON = "Alex"                   # alex@example.com, fictional
TODO_TXT = "harbour quote for Alex"
PREF_TOKEN = CAL_A
JANE = "Jane"                     # jane@example.com, fictional
ABSENT = "Casey"                  # never seeded: refusal target

SEEDS = {
    "calendar_event_a": {"kind": "calendar_event", "title": CAL_A, "when": "today 09:00"},
    "calendar_event_b": {"kind": "calendar_event", "title": CAL_B, "when": "today 11:00"},
    "rsvp_pending": {"kind": "rsvp_invite", "title": RSVP_EVT, "owner_response": "pending"},
    "rsvp_accepted": {"kind": "rsvp_invite", "title": RSVP_EVT, "owner_response": "accepted"},
    "person_surveyor": {"kind": "person_fact", "subject": PERSON,
                        "fact": "Alex works as a surveyor at harbour survey ltd"},
    "person_last_met": {"kind": "person_fact", "subject": PERSON,
                        "fact": "Last met Alex on 14 March 2030 at the harbour site walk"},
    "person_three_facts": {"kind": "person_fact_many", "subject": PERSON, "facts": [
        "Alex works as a surveyor at harbour survey ltd",
        "Alex is based in Plymouth",
        "Alex led the harbour site walk in March 2030"]},
    "todo_harbour": {"kind": "todo", "text": TODO_TXT},
    "message_budget": {"kind": "conversation", "from": PERSON,
                       "text": "The budget for the harbour job is 40 thousand"},
}

SCENARIOS = [
    # ---- instruction persistence -------------------------------------------
    {"id": "P01", "tag": "PLUMBING", "group": "persistence",
     "title": "an ignore instruction is acknowledged and stored",
     "steps": [
         {"op": "say", "key": "ask", "session": "s1",
          "text": "Please ignore the %s for notifications." % CAL_A},
         {"op": "read", "key": "prefs", "path": "/api/v1/preferences"},
     ],
     "checks": [
         {"id": "acknowledged", "kind": "reply_has", "turn": "ask",
          "any": ["ignore", "won't", "will not", "noted", "understood", "stop"]},
         {"id": "stored", "kind": "read_has", "read": "prefs", "any": [PREF_TOKEN]},
     ]},
    {"id": "P02", "tag": "PLUMBING", "group": "persistence",
     "title": "an ignore instruction survives a daemon restart",
     "steps": [
         {"op": "say", "key": "set", "session": "s1",
          "text": "Please ignore the %s for notifications." % CAL_A},
         {"op": "tick", "kind": "restart"},
         {"op": "say", "key": "ask", "session": "s2",
          "text": "Which calendars are you ignoring for notifications?"},
     ],
     "checks": [
         {"id": "recalled_after_restart", "kind": "reply_has", "turn": "ask", "any": [CAL_A]},
     ]},
    {"id": "P03", "tag": "PLUMBING", "group": "persistence",
     "title": "an ignore instruction holds across a day boundary in the brief",
     "steps": [
         {"op": "seed", "name": "calendar_event_a", "pre": True},
         {"op": "seed", "name": "calendar_event_b", "pre": True},
         {"op": "say", "key": "set", "session": "s1",
          "text": "Please ignore the %s for notifications." % CAL_A},
         {"op": "tick", "kind": "day_boundary"},
         {"op": "brief", "key": "next_day"},
     ],
     "checks": [
         {"id": "ignored_calendar_absent", "kind": "brief_lacks", "brief": "next_day", "none": [CAL_A]},
         {"id": "control_calendar_present", "kind": "brief_has", "brief": "next_day",
          "any": [CAL_B], "control": True},
     ]},
    {"id": "P04", "tag": "PLUMBING", "group": "persistence",
     "title": "an ignore instruction for one calendar does not hide another",
     "steps": [
         {"op": "seed", "name": "calendar_event_a", "pre": True},
         {"op": "seed", "name": "calendar_event_b", "pre": True},
         {"op": "say", "key": "set", "session": "s1",
          "text": "Please ignore the %s for notifications." % CAL_A},
         {"op": "brief", "key": "same_day"},
     ],
     "checks": [
         {"id": "control_calendar_present", "kind": "brief_has", "brief": "same_day", "any": [CAL_B],
          "control": True},
         {"id": "ignored_calendar_absent", "kind": "brief_lacks", "brief": "same_day", "none": [CAL_A]},
     ]},
    {"id": "P05", "tag": "PLUMBING", "group": "persistence",
     "title": "a revoked ignore instruction brings the calendar back",
     "steps": [
         {"op": "seed", "name": "calendar_event_a", "pre": True},
         {"op": "say", "key": "set", "session": "s1",
          "text": "Please ignore the %s for notifications." % CAL_A},
         {"op": "say", "key": "revoke", "session": "s1",
          "text": "Actually you can notify me about the %s again." % CAL_A},
         {"op": "tick", "kind": "day_boundary"},
         {"op": "brief", "key": "after_revoke"},
     ],
     "checks": [
         {"id": "revoked_calendar_back", "kind": "brief_has", "brief": "after_revoke", "any": [CAL_A]},
     ]},
    {"id": "P06", "tag": "PLUMBING", "group": "persistence",
     "title": "a fresh session can list what it was told to ignore",
     "steps": [
         {"op": "say", "key": "set", "session": "s1",
          "text": "Please ignore the %s for notifications." % CAL_A},
         {"op": "tick", "kind": "restart"},
         {"op": "say", "key": "ask", "session": "s9",
          "text": "What did I ask you to stop notifying me about?"},
     ],
     "checks": [
         {"id": "listed_from_store", "kind": "reply_has", "turn": "ask", "any": [CAL_A]},
         {"id": "read_a_store", "kind": "tool_used", "turn": "ask",
          "any": ["pref", "memory", "commit"]},
     ]},
    {"id": "P07", "tag": "REASONING", "group": "persistence",
     "title": "a paraphrased ignore instruction is understood and stored",
     "steps": [
         {"op": "say", "key": "set", "session": "s1",
          "text": "%s is just noise for me, keep it off my alerts." % CAL_A},
         {"op": "read", "key": "prefs", "path": "/api/v1/preferences"},
     ],
     "checks": [
         {"id": "stored_from_paraphrase", "kind": "read_has", "read": "prefs", "any": [PREF_TOKEN]},
     ]},
    # ---- current-state awareness -------------------------------------------
    {"id": "C01", "tag": "PLUMBING", "group": "current_state",
     "title": "a brief does not ask for an RSVP the owner already gave",
     "steps": [
         {"op": "seed", "name": "rsvp_accepted", "pre": True},
         {"op": "brief", "key": "b1"},
     ],
     "checks": [
         {"id": "no_rsvp_request", "kind": "brief_lacks_near", "brief": "b1", "needle": RSVP_EVT,
          "words": ["respond", "reply", "rsvp", "confirm"]},
         {"id": "brief_nonempty", "kind": "brief_min_chars", "brief": "b1", "n": 40, "control": True},
     ]},
    {"id": "C02", "tag": "PLUMBING", "group": "current_state",
     "title": "an RSVP answered on day 1 is not requested again on day 2",
     "steps": [
         {"op": "seed", "name": "rsvp_pending", "pre": True},
         {"op": "brief", "key": "day1"},
         {"op": "say", "key": "answer", "session": "s1",
          "text": "I've accepted the %s invitation." % RSVP_EVT},
         {"op": "tick", "kind": "day_boundary"},
         {"op": "brief", "key": "day2"},
     ],
     "checks": [
         {"id": "day2_no_rsvp_request", "kind": "brief_lacks_near", "brief": "day2",
          "needle": RSVP_EVT, "words": ["respond", "reply", "rsvp", "confirm"]},
         {"id": "day1_asked_it", "kind": "brief_has_near", "brief": "day1",
          "needle": RSVP_EVT, "words": ["respond", "reply", "rsvp", "confirm"], "control": "premise"},
     ]},
    {"id": "C03", "tag": "PLUMBING", "group": "current_state",
     "title": "a finished to-do leaves the open list",
     "steps": [
         {"op": "seed", "name": "todo_harbour", "pre": True},
         {"op": "read", "key": "before", "path": "/api/v1/commitments?owner=user&status=open"},
         {"op": "say", "key": "done", "session": "s1",
          "text": "I've sent the %s. Please mark that to-do done." % TODO_TXT},
         {"op": "read", "key": "after", "path": "/api/v1/commitments?owner=user&status=open"},
         {"op": "brief", "key": "b1"},
     ],
     "checks": [
         {"id": "open_list_before_has_it", "kind": "read_has", "read": "before",
          "any": ["harbour quote"], "control": "premise"},
         {"id": "open_list_after_lacks_it", "kind": "read_lacks", "read": "after",
          "none": ["harbour quote"]},
         {"id": "brief_lacks_it", "kind": "brief_lacks", "brief": "b1", "none": ["harbour quote"]},
     ]},
    {"id": "C04", "tag": "PLUMBING", "group": "current_state",
     "title": "a rescheduled meeting is answered with its latest time",
     "steps": [
         {"op": "say", "key": "t1", "session": "s1",
          "text": "The %s is at 10:00 tomorrow." % CAL_A},
         {"op": "say", "key": "t2", "session": "s1",
          "text": "Actually it moved to 15:00."},
         {"op": "say", "key": "ask", "session": "s1",
          "text": "When is the %s?" % CAL_A},
     ],
     "checks": [
         {"id": "latest_time_given", "kind": "reply_has", "turn": "ask",
          "any": ["15:00", "3pm", "3 pm", "15.00"]},
         {"id": "old_time_not_given", "kind": "reply_lacks_regex", "turn": "ask",
          "pattern": r"\b10[:.]00\b|\b10\s?(am|a\.m)\b"},
     ]},
    {"id": "C05", "tag": "REASONING", "group": "current_state",
     "title": "an empty store yields a brief that invents nothing",
     "steps": [
         {"op": "brief", "key": "empty"},
     ],
     "checks": [
         {"id": "no_invented_task", "kind": "brief_lacks", "brief": "empty",
          "none": ["respond to", "you need to", "overdue", "action required"]},
         {"id": "brief_nonempty", "kind": "brief_min_chars", "brief": "empty", "n": 40, "control": True},
     ]},
    # ---- conversational reference resolution -------------------------------
    {"id": "R01", "tag": "REASONING", "group": "reference",
     "title": "'add a calendar entry' after discussing an invitation adds it, unasked",
     "steps": [
         {"op": "say", "key": "context", "session": "s1",
          "text": "%s has invited me to a call on Friday at 2pm about the harbour quote." % PERSON},
         {"op": "say", "key": "add", "session": "s1", "text": "Add a calendar entry for that."},
     ],
     "checks": [
         {"id": "no_clarifying_question", "kind": "reply_no_question", "turn": "add"},
         {"id": "created_entry", "kind": "tool_used", "turn": "add",
          "any": ["calendar_event_create", "calendar"]},
     ]},
    {"id": "R02", "tag": "REASONING", "group": "reference",
     "title": "'move it to Monday' moves the entry just created, unasked",
     "steps": [
         {"op": "say", "key": "context", "session": "s1",
          "text": "%s has invited me to a call on Friday at 2pm about the harbour quote." % PERSON},
         {"op": "say", "key": "add", "session": "s1", "text": "Add a calendar entry for that."},
         {"op": "say", "key": "move", "session": "s1", "text": "Move it to Monday."},
     ],
     "checks": [
         {"id": "no_clarifying_question", "kind": "reply_no_question", "turn": "move"},
         {"id": "changed_entry", "kind": "tool_used", "turn": "move", "any": ["calendar"]},
     ]},
    {"id": "R03", "tag": "REASONING", "group": "reference",
     "title": "an ambiguous 'add it' asks which one, and creates nothing yet",
     "steps": [
         {"op": "say", "key": "context", "session": "s1",
          "text": "%s invited me to a call on Friday. %s invited me to one on Monday."
                  % (PERSON, JANE)},
         {"op": "say", "key": "add", "session": "s1", "text": "Add a calendar entry for it."},
     ],
     "checks": [
         {"id": "asks_which", "kind": "reply_is_question", "turn": "add"},
         {"id": "did_not_guess", "kind": "tool_unused", "turn": "add",
          "any": ["calendar_event_create"]},
     ]},
    # ---- not repeating answered questions ----------------------------------
    {"id": "Q01", "tag": "PLUMBING", "group": "repeats",
     "title": "a fact the owner gave is not asked for again in the same session",
     "steps": [
         {"op": "say", "key": "give", "session": "s1", "text": "My office is in Plymouth."},
         {"op": "say", "key": "use", "session": "s1",
          "text": "Help me plan my week around my office."},
     ],
     "checks": [
         {"id": "did_not_ask_again", "kind": "reply_lacks_regex", "turn": "use",
          "pattern": r"(where|which town|what town|what city|location of).{0,30}office\??"},
         {"id": "used_the_fact", "kind": "reply_has", "turn": "use", "any": ["Plymouth"]},
     ]},
    {"id": "Q02", "tag": "PLUMBING", "group": "repeats",
     "title": "a fact the owner gave is not asked for again after a restart",
     "steps": [
         {"op": "say", "key": "give", "session": "s1", "text": "My office is in Plymouth."},
         {"op": "tick", "kind": "restart"},
         {"op": "say", "key": "use", "session": "s2",
          "text": "Help me plan a visit to my office."},
     ],
     "checks": [
         {"id": "did_not_ask_again", "kind": "reply_lacks_regex", "turn": "use",
          "pattern": r"(where|which town|what town|what city|location of).{0,30}office\??"},
         {"id": "used_the_fact", "kind": "reply_has", "turn": "use", "any": ["Plymouth"]},
     ]},
    # ---- grounded recall ----------------------------------------------------
    {"id": "G01", "tag": "PLUMBING", "group": "recall",
     "title": "a person fact is recalled from the store, through a tool",
     "steps": [
         {"op": "seed", "name": "person_surveyor", "pre": True},
         {"op": "say", "key": "ask", "session": "s1", "text": "What do you know about %s?" % PERSON},
     ],
     "checks": [
         {"id": "fact_recalled", "kind": "reply_has", "turn": "ask", "any": ["surveyor"]},
         {"id": "used_people_tool", "kind": "tool_used", "turn": "ask", "any": ["pwg_people", "person"]},
     ]},
    {"id": "G02", "tag": "PLUMBING", "group": "recall",
     "title": "the date of the last meeting is recalled from the store",
     "steps": [
         {"op": "seed", "name": "person_last_met", "pre": True},
         {"op": "say", "key": "ask", "session": "s1", "text": "When did I last meet %s?" % PERSON},
     ],
     "checks": [
         {"id": "date_recalled", "kind": "reply_has", "turn": "ask",
          "any": ["14 March", "March 14", "2030-03-14", "14/03"]},
     ]},
    {"id": "G03", "tag": "PLUMBING", "group": "recall",
     "title": "a message quote is recalled with its source named",
     "steps": [
         {"op": "seed", "name": "message_budget", "pre": True},
         {"op": "say", "key": "ask", "session": "s1",
          "text": "What did %s say about the budget?" % PERSON},
     ],
     "checks": [
         {"id": "quote_recalled", "kind": "reply_has", "turn": "ask", "any": ["40 thousand", "40k", "40,000"]},
         {"id": "source_named", "kind": "reply_has", "turn": "ask",
          "any": ["message", "email", "whatsapp", "imessage", "conversation"]},
     ]},
    {"id": "G04", "tag": "REASONING", "group": "recall",
     "title": "a summary of a person draws on the stored facts, not on guesswork",
     "steps": [
         {"op": "seed", "name": "person_three_facts", "pre": True},
         {"op": "say", "key": "ask", "session": "s1",
          "text": "Summarise what you know about %s in two sentences." % PERSON},
     ],
     "checks": [
         {"id": "two_facts_used", "kind": "reply_has_at_least", "turn": "ask", "n": 2,
          "any": ["surveyor", "Plymouth", "site walk"]},
     ]},
    # ---- refusal to invent --------------------------------------------------
    {"id": "F01", "tag": "REASONING", "group": "refusal",
     "title": "an unknown person is refused, not described",
     "steps": [
         {"op": "say", "key": "ask", "session": "s1",
          "text": "What did %s say about the lease last week?" % ABSENT},
     ],
     "checks": [
         {"id": "says_no_record", "kind": "reply_has", "turn": "ask",
          "any": ["no record", "don't have", "do not have", "couldn't find", "could not find",
                  "no information", "not aware", "no messages", "nothing on"]},
     ]},
    {"id": "F02", "tag": "REASONING", "group": "refusal",
     "title": "an unknown meeting gets no invented time",
     "steps": [
         {"op": "say", "key": "ask", "session": "s1",
          "text": "When is my meeting with the ministry of synthetic affairs?"},
     ],
     "checks": [
         {"id": "says_not_found", "kind": "reply_has", "turn": "ask",
          "any": ["no record", "don't have", "do not have", "couldn't find", "could not find",
                  "not in your", "no meeting", "nothing"]},
         {"id": "no_invented_time", "kind": "reply_lacks_regex", "turn": "ask",
          "pattern": r"\b\d{1,2}[:.]\d{2}\b|\b\d{1,2}\s?(am|pm)\b"},
     ]},
    # ---- idempotent import --------------------------------------------------
    {"id": "I01", "tag": "PLUMBING", "group": "import",
     "title": "the same LinkedIn export is announced once, not every day",
     "steps": [
         {"op": "import_file", "key": "imp1"},
         {"op": "brief", "key": "after_first"},
         {"op": "import_file", "key": "imp2"},
         {"op": "brief", "key": "after_second"},
     ],
     "checks": [
         {"id": "first_import_announced", "kind": "brief_has", "brief": "after_first",
          "any": ["linkedin"], "control": True},
         {"id": "no_reimport_announcement", "kind": "brief_count_max", "brief": "after_second",
          "needle": "importing", "n": 0},
     ]},
    {"id": "I02", "tag": "PLUMBING", "group": "import",
     "title": "re-importing the same export adds no rows",
     "steps": [
         {"op": "import_file", "key": "imp1"},
         {"op": "read", "key": "rows1", "path": "/api/v1/people/context?name=Jane"},
         {"op": "import_file", "key": "imp2"},
         {"op": "read", "key": "rows2", "path": "/api/v1/people/context?name=Jane"},
     ],
     "checks": [
         {"id": "rows_present", "kind": "read_rows_min", "read": "rows1", "n": 1, "control": True},
         {"id": "no_new_rows", "kind": "read_rows_equal", "a": "rows1", "b": "rows2"},
     ]},
    # ---- basic multi-step ---------------------------------------------------
    {"id": "M01", "tag": "REASONING", "group": "multistep",
     "title": "find a message, then set a reminder for it, in one request",
     "steps": [
         {"op": "say", "key": "ask", "session": "s1",
          "text": "Find the message from %s about the budget and remind me to reply tomorrow at 9am."
                  % PERSON},
     ],
     "checks": [
         {"id": "reminder_made", "kind": "tool_used", "turn": "ask",
          "any": ["remind", "cron", "commit", "todo"]},
         {"id": "no_clarifying_question", "kind": "reply_no_question", "turn": "ask"},
     ]},
    {"id": "M02", "tag": "PLUMBING", "group": "multistep",
     "title": "a to-do stated in chat appears on the open list",
     "steps": [
         {"op": "say", "key": "add", "session": "s1",
          "text": "Add a to-do: send %s the harbour quote by Friday." % JANE},
         {"op": "read", "key": "open", "path": "/api/v1/commitments?owner=user&status=open"},
     ],
     "checks": [
         {"id": "todo_on_open_list", "kind": "read_has", "read": "open", "any": ["harbour quote"]},
     ]},
]
