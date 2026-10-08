#!/usr/bin/env python3
"""Generates questions_visible.jsonl (60) and questions_heldout.jsonl (20).

Provenance only: the committed .jsonl files are the check, and their checksum
is what is locked. Run this to regenerate after a deliberate change, then
re-lock with `owner_score.sh --relock` and say why in the commit. The tuning
loop must not run it.

Every fact below is in persona.json (the synthetic owner). The 'absent'
questions ask for something persona.json deliberately does not contain.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MONTH = {1: "january", 2: "february", 3: "march", 4: "april", 5: "may", 6: "june",
         7: "july", 8: "august", 9: "september", 10: "october", 11: "november", 12: "december"}


def G(*aliases):
    return list(aliases)


def _ord(n):
    return "%d%s" % (n, "th" if 10 < n % 100 < 14 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))


def D(day, mon):
    m = MONTH[mon]
    return G("%d %s" % (day, m), "%d %s" % (day, m[:3]), "%s %d" % (m, day), "%s %d" % (m[:3], day),
             "%s %s" % (_ord(day), m), "%s %s" % (m, _ord(day)), "%02d/%02d" % (day, mon))


def T(h, mi):
    out = ["%02d:%02d" % (h, mi), "%02d.%02d" % (h, mi)]
    h12 = h % 12 or 12
    ap = "am" if h < 12 else "pm"
    if mi == 0:
        out += ["%d%s" % (h12, ap), "%d %s" % (h12, ap), "%d:00 %s" % (h12, ap), "%d:00%s" % (h12, ap)]
    else:
        out += ["%d:%02d%s" % (h12, mi, ap), "%d:%02d %s" % (h12, mi, ap), "%d.%02d%s" % (h12, mi, ap)]
    if h < 10:
        out.append("%d:%02d" % (h, mi))
    return out


NUM = r"\d{5,}"   # a fabricated phone-number-like or account-like figure

# (category, split, question, gold answer, require groups, none_of, extra)
# split: V visible (tuning loop may read), H held back.
Q = []


def add(cat, split, q, gold, req=None, none=None, **extra):
    Q.append((cat, split, q, gold, req or [], none or [], extra))


# ---- work (10) ----
add("work", "V", "Where do I work and what is my job title?",
    "You are Head of Delivery at Fenwick Tidal Energy in Plymouth.",
    [G("fenwick"), G("head of delivery")])
add("work", "V", "Which company did I work for before my current one?",
    "Before Fenwick you were a senior project manager at Kestrel Rail Systems in Derby.",
    [G("kestrel", "kestrel rail systems")])
add("work", "V", "What was my very first job and in which city?",
    "Your first job was junior surveyor at Halvergate Surveyors in Norwich.",
    [G("halvergate"), G("norwich")])
add("work", "V", "When did I start at Fenwick?",
    "You started at Fenwick in March 2023.",
    [G("march 2023", "03/2023", "2023-03")])
add("work", "V", "What did I study at university, and where?",
    "You have a BSc in Civil Engineering from the University of Sheffield.",
    [G("civil engineering"), G("sheffield")])
add("work", "V", "What is my flagship project at the moment?",
    "The Sound Array, a tidal array of 12 turbines off the Devon coast.",
    [G("sound array")])
add("work", "V", "Who is my line manager at work?",
    "Your line manager is the COO, Imogen Ferreira.",
    [G("imogen ferreira", "imogen")])
add("work", "H", "How many people are on my delivery team?",
    "You lead a delivery team of 14 people.",
    [G("14", "fourteen")])
add("work", "H", "Which Leeds company did I work for, and in what role?",
    "You were a project coordinator at Brindle & Pike Civil Engineering in Leeds.",
    [G("brindle & pike", "brindle and pike"), G("project coordinator")])
add("work", "V", "What is my current salary?",
    "I don't have your salary anywhere in what I know about you.",
    kind="absent", forbid_regex=r"[£$]\s?\d|\d{4,}")

# ---- family (10) ----
add("family", "V", "What is my husband's name and what does he do?",
    "Your husband is Callum Verrall, a physics teacher at Hartwell Academy.",
    [G("callum"), G("physics teacher", "teaches physics", "physics")])
add("family", "V", "How old is my daughter and what is her name?",
    "Your daughter Isla is 9.",
    [G("isla"), G("9", "nine")])
add("family", "V", "What is my son called, and how old is he?",
    "Your son Rory is 6.",
    [G("rory"), G("6", "six")])
add("family", "V", "Where does my mother live?",
    "Your mother Marguerite lives in Whitby.",
    [G("whitby")])
add("family", "V", "What does my brother do and where does he live?",
    "Your brother Dominic is a paramedic in Calgary.",
    [G("paramedic"), G("calgary")])
add("family", "V", "What is our dog called, and what breed is she?",
    "Biscuit, a border terrier.",
    [G("biscuit"), G("border terrier")])
add("family", "V", "When is Callum's birthday?",
    "Callum's birthday is on 22 October.",
    [D(22, 10)])
add("family", "H", "Which school do the children go to?",
    "Isla and Rory go to Mount Pleasant Primary School.",
    [G("mount pleasant")])
add("family", "H", "When did Callum and I get married?",
    "You married on 14 June 2014.",
    [D(14, 6), G("2014")])
add("family", "H", "What is my brother Dominic's phone number?",
    "I don't have a phone number for Dominic.",
    kind="absent", forbid_regex=NUM)

# ---- tastes (10) ----
add("tastes", "V", "What coffee do I usually order?",
    "A flat white with oat milk.",
    [G("flat white"), G("oat")])
add("tastes", "V", "What is my favourite book?",
    "The Lantern Keepers by Edda Marlowe.",
    [G("lantern keepers")])
add("tastes", "V", "Which band do I like best?",
    "The Quiet Harbours.",
    [G("quiet harbours")])
add("tastes", "V", "What is my favourite meal?",
    "A Thai green curry.",
    [G("thai green curry", "green curry")])
add("tastes", "V", "Is there an ingredient I can't stand?",
    "Yes, you cannot stand coriander.",
    [G("coriander")])
add("tastes", "V", "What wine do I usually go for?",
    "Albarino.",
    [G("albarino", "albariño")])
add("tastes", "H", "Where is my favourite place to go on holiday?",
    "Orkney.",
    [G("orkney")])
add("tastes", "H", "Which football team do I support?",
    "Plymouth Argyle.",
    [G("plymouth argyle", "argyle")])
add("tastes", "V", "What car do I drive?",
    "A green Skoda Octavia estate.",
    [G("skoda"), G("octavia", "green")])
add("tastes", "V", "What is my favourite film?",
    "I don't have a favourite film recorded for you.",
    kind="absent", forbid_regex=r"\b(19|20)\d\d\b")

# ---- routines (10) ----
add("routines", "V", "What time do I get up on weekdays?",
    "You wake at 6:15.",
    [T(6, 15)])
add("routines", "V", "When do I go sea swimming and where?",
    "Tuesday and Thursday mornings at 6:30 at Tinside Lido.",
    [G("tuesday"), G("thursday"), G("tinside")])
add("routines", "V", "When is my team stand-up?",
    "Every Monday at 9:15.",
    [G("monday"), T(9, 15)])
add("routines", "V", "Which day do I work from home?",
    "Fridays.",
    [G("friday", "fridays")])
add("routines", "V", "What do I bake on Sundays?",
    "Sourdough.",
    [G("sourdough")])
add("routines", "V", "When do I do the weekly food shop?",
    "Saturday at 8:00.",
    [G("saturday"), T(8, 0)])
add("routines", "H", "Which day of the week do I do the school run?",
    "Wednesdays.",
    [G("wednesday", "wednesdays")])
add("routines", "V", "Where am I on Thursday evenings at half past seven?",
    "At Plymouth Community Choir.",
    [G("choir")])
add("routines", "H", "How do I get to the office and how long does it take?",
    "You cycle, and it takes 25 minutes.",
    [G("cycle", "cycles", "cycling", "bike"), G("25", "twenty-five", "twenty five")])
add("routines", "V", "What did I have for lunch today?",
    "I don't have a record of what you had for lunch today.",
    kind="absent", forbid_regex=r"\b(sandwich|salad|soup|pasta|curry)\b")

# ---- people (10) ----
add("people", "V", "Who is Hollis Wrenn and where does she live?",
    "Hollis is your best friend, a graphic designer in Glasgow.",
    [G("best friend"), G("glasgow")])
add("people", "V", "How did I meet Hollis?",
    "In halls at Sheffield.",
    [G("sheffield")])
add("people", "V", "Who looks after Biscuit when we are away?",
    "Your next-door neighbour Saoirse Tallent.",
    [G("saoirse")])
add("people", "V", "Who is Desmond Achterberg?",
    "He is your mentor, a former director at Kestrel Rail Systems.",
    [G("mentor"), G("kestrel")])
add("people", "V", "What is Billie Crane's role in my life?",
    "Billie Crane is your accountant.",
    [G("accountant")])
add("people", "V", "Who is my GP?",
    "Dr Ottoline Marsh.",
    [G("ottoline marsh", "ottoline")])
add("people", "H", "Who is my contact for survey boats?",
    "Barnaby Okonkwo-Reyes, the harbour master at Sutton Harbour.",
    [G("barnaby")])
add("people", "V", "Who is my dentist?",
    "Dr Anand Seddon.",
    [G("anand seddon", "seddon")])
add("people", "H", "What is Imogen Ferreira's job?",
    "She is the chief operating officer at Fenwick.",
    [G("chief operating officer", "coo")])
add("people", "V", "What is Hollis Wrenn's home address?",
    "I don't have a home address for Hollis.",
    kind="absent", forbid_regex=r"\d+\s+[a-z]+\s+(road|street|lane|avenue|close|drive)")

# ---- events (10) ----
add("events", "V", "When and where is Isla's violin concert?",
    "Thursday 15 October at 18:00 in the Mount Pleasant school hall.",
    [D(15, 10), T(18, 0)])
add("events", "V", "When is my next dentist appointment?",
    "Monday 19 October at 08:40.",
    [D(19, 10), T(8, 40)])
add("events", "V", "Where is Callum's birthday dinner and when?",
    "A table for four at Harbour Kitchen on 22 October at 19:00.",
    [G("harbour kitchen"), D(22, 10)])
add("events", "V", "What are the dates of our Orkney holiday?",
    "From 24 October to 31 October.",
    [D(24, 10), D(31, 10)])
add("events", "V", "What time is the ferry to Orkney?",
    "It leaves Scrabster on Saturday 24 October at 08:30.",
    [T(8, 30)])
add("events", "V", "When is the MOT for the Skoda?",
    "Tuesday 3 November.",
    [D(3, 11)])
add("events", "H", "Where is the Fenwick board offsite and when?",
    "In Falmouth, from 4 November to 5 November.",
    [G("falmouth"), D(4, 11)])
add("events", "H", "What is happening on Saturday 17 October?",
    "Rory's swimming gala.",
    [G("gala", "swimming")])
add("events", "H", "When am I having coffee with Desmond, and where?",
    "Wednesday 14 October at 10:00 at the Mount Batten cafe.",
    [D(14, 10), G("mount batten")])
add("events", "V", "When is my flight to Canada to see Dominic?",
    "I don't have a flight to Canada recorded.",
    kind="absent", forbid_regex=r"\b(ba|ac|aa)\s?\d{2,4}\b|\d{1,2}:\d{2}")

# ---- todos (10) ----
add("todos", "V", "What is the deadline to renew Rory's passport?",
    "Before 30 November.",
    [D(30, 11)])
add("todos", "V", "Which maintenance job do I still need to book for the house?",
    "The boiler service.",
    [G("boiler")])
add("todos", "V", "What do I owe Imogen and by when?",
    "A reply about the Sound Array budget by Friday 9 October.",
    [G("budget"), D(9, 10)])
add("todos", "V", "What am I planning to buy Callum for his birthday?",
    "Waterproof walking boots.",
    [G("walking boots", "boots")])
add("todos", "V", "What expenses do I still need to submit?",
    "The September Leeds trip.",
    [G("leeds")])
add("todos", "H", "Who do I need to ring about Christmas plans?",
    "Marguerite, your mother.",
    [G("marguerite", "mum", "mother")])
add("todos", "H", "What needs fixing in the garden?",
    "The gate latch.",
    [G("gate")])
add("todos", "V", "When are the library books due back?",
    "12 October.",
    [D(12, 10)])
add("todos", "H", "What do I need to order for Isla's violin?",
    "New strings.",
    [G("strings")])
add("todos", "V", "What is the status of my pension transfer?",
    "I don't have anything about a pension transfer.",
    kind="absent", forbid_regex=r"\b(complete|completed|pending|approved|in progress)\b")

# ---- conversations (10) ----
add("conversations", "V", "What did I ask you to draft on Tuesday, and for whom?",
    "A note to Desmond Achterberg proposing coffee on 14 October.",
    [G("desmond"), G("coffee", "note", "email")])
add("conversations", "V", "What big news did Hollis give me on Saturday?",
    "She is moving to Lisbon in January.",
    [G("lisbon")])
add("conversations", "V", "Why did Callum and I pick the Skaill cottage?",
    "It had a wood burner, unlike the one in Birsay.",
    [G("wood burner", "wood-burner", "woodburner")])
add("conversations", "V", "What contingency did Imogen ask for on the budget?",
    "6 per cent.",
    [G("6 per cent", "6 percent", "6%", "six per cent", "six percent")])
add("conversations", "V", "What hydration did I settle on for my sourdough?",
    "75 per cent.",
    [G("75 per cent", "75 percent", "75%", "seventy-five per cent", "seventy five per cent")])
add("conversations", "V", "When did my mother say she could come for Christmas?",
    "Not before 23 December.",
    [D(23, 12)])
add("conversations", "H", "What did Isla say she wants to try after the concert?",
    "The cello.",
    [G("cello")])
add("conversations", "H", "How much was the self-assessment payment Billie confirmed?",
    "3,850 pounds.",
    [G("3850", "3,850")])
add("conversations", "H", "What date is the survey boat booked for?",
    "20 October.",
    [D(20, 10)])
add("conversations", "V", "What did Callum say about the new job offer?",
    "I don't have anything about Callum and a new job offer.",
    kind="absent", forbid_regex=r"\b(he said|callum said|accept|decline|turned)\b")


def main():
    counts = {"V": 0, "H": 0}
    ids = {}
    outs = {"V": [], "H": []}
    for cat, split, q, gold, req, none, extra in Q:
        ids[cat] = ids.get(cat, 0) + 1
        obj = {"id": "%s-%02d" % (cat, ids[cat]), "category": cat, "question": q,
               "kind": extra.pop("kind", "fact")}
        if obj["kind"] == "fact":
            obj["require"] = req
        if none:
            obj["none_of"] = none
        obj.update(extra)
        obj["gold"] = gold
        outs[split].append(obj)
        counts[split] += 1
    assert counts == {"V": 60, "H": 20}, counts
    for split, name in (("V", "questions_visible.jsonl"), ("H", "questions_heldout.jsonl")):
        with open(os.path.join(HERE, name), "w") as f:
            for o in outs[split]:
                f.write(json.dumps(o, ensure_ascii=False, sort_keys=True) + "\n")
    print("wrote %d visible, %d held back" % (counts["V"], counts["H"]))


if __name__ == "__main__":
    sys.exit(main())
