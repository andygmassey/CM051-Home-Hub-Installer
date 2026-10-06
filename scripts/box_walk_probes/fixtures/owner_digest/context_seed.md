# Personal Context

Baseline awareness of the people, meetings, and preferences that matter to the person you assist. Generated locally from their personal graph; treat it as background, not a transcript.
_Last updated: 2026-10-06 19:36 UTC._

## About you

- Name: Jane Doe
- Work: ExampleCo, Initech
- Roles: Director at ExampleCo (2021 to present); Engineer at Initech (2015 to 2019)
- Places: Lives in Fictionville
- Family and close people: Has a sister called Liz Doe

## Confirmed by you

Facts the person confirmed to you directly. Treat these as authoritative; they override anything inferred below.

- the boat is called seaworthy

## People you interact with most

- Mary Smith, Acme Corp (40 messages, 2 meetings)
- Bob Jones, Globex (12 messages, 1 meetings)
- Sam Patel, Acme Corp (3 messages)

## Recent meetings (last 7 days)

- Design review with Mary (2026-10-04 19:36)

## Calendar events by owner

Each item is labelled with WHOSE calendar it came from. Use only these facts; never merge two people's events, never reassign one person's trip to another, and do not invent flight numbers, routings, destinations or times. If an item is under another person's calendar, attribute it to that person, not to the person you assist.

**Unattributed:**
- Planning with Bob (2026-10-08 19:36)

## Preferences and things to keep in mind

- Trail running (Sport)
- Jazz (Music)
- Not keen on: Opera (Music)

## Key organisations

- Acme Corp (2 people)
- Globex (1 person)

## Looking something up

For a specific person or detail not listed above, call the `pwg_people` tool with the person's name, or `pwg_person_timeline` for the user's full history with them. Do not fetch graph data over `http_request`: the pwg_ tools are the route to the graph.
