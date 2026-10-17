# Walk probe spec: meeting_brief_text_is_grounded

Status: BLOCKING (`scripts/walk_promote_scope.tsv`).
Issue: ostler-ai/ostler-assistant#471, definition of done item 4.
Probe: `scripts/box_walk_probes/probes/meeting_brief_text_is_grounded.sh`
Judge: `scripts/box_walk_probes/lib/meeting_brief_sent_text.py`
Seed: `scripts/box_walk_probes/lib/meeting_brief_seed.py`

## Question

For a rich contact, a contact with no logged meetings, and a thin contact, is
the TEXT the installed sender posts to the assistant's `/announce` grounded in
what the Hub knows?

## Why the text, not "a brief was sent"

A probe that asserted only that a brief was sent would have passed on the old
sender, which sent "this is your first face-to-face meeting" for a contact with
no logged meetings. It would also have passed on any sender that sends nothing
if the assertion were "no error", and it could not see that the pre-change
sender crashed reading its own stdin on every tick (so it never sent anything).
The assertions below are on the sent text, and "zero announces" is a FAIL.

## Procedure (runs on the walk box, over ssh like the other probes)

1. Preconditions, each CANNOT-RUN when absent (never a pass):
   - `~/.ostler/bin/ostler-meeting-brief-sender` is installed. It is
     feature-flagged off by default (`INSTALL_MEETING_BRIEF_LAUNCHAGENT`), so
     on a stock install this probe is CANNOT-RUN until the flag is flipped.
   - The installed assistant binary answers `meeting-brief --help`.
   - A service token is readable (`PWG_SERVICE_TOKEN` or
     `~/.ostler/secrets/service_token`) and a Hub answers `/health`.
2. Seed three fictional contacts into the box graph through Oxigraph's update
   endpoint (default graph only), then PROVE the seed readable through the Hub
   (`/api/v1/people/context?name=Alexandra%20Patel` returns `found: true`). A seed
   that did not land is a harness failure and is CANNOT-RUN, not a product FAIL.
3. Start a loopback shim. It answers `GET /api/v1/meeting/upcoming` with three
   meetings whose single attendees are the three contacts (a walk box has no
   calendar event in the next 20 minutes), forwards every other GET to the real
   Hub with the service token, and records `POST /announce` instead of
   delivering it.
4. Run the INSTALLED sender unmodified with `OSTLER_HUB_HOST` and
   `OSTLER_ASSISTANT_URL` pointed at the shim. The sender calls the installed
   assistant binary (`meeting-brief`) per attendee, which reads the real
   `people/context` and `person/<slug>/timeline` handlers over the seeded graph.
5. Forget the seed (`DELETE` on the `urn:ostler-walk-fixture:` subjects) and the
   idempotency rows (`walk-fixture-brief-%`), whatever happened above.
6. Grade the captured announces.

## Assertions (all must hold; each prints `ok` or `FAIL`)

| Scope | Assertion |
|---|---|
| all | exactly three announces, one per seeded meeting uid (a silent sender FAILS) |
| all | every announce is `kind: meeting_brief` |
| each | no banned claim or generic advice in the sent text (`first meeting`, `first face`, `never met`, `warm welcome`, `be sure to`, `would be appropriate`, `people in common`, `mutual` and the rest of the list in the judge) |
| each | no em dash or en dash |
| each | none of the old shape's `With:`, `Wiki:`, `Last chat:`, `Open:`, `Location:` lines |
| each | within 150 words |
| rich (Alexandra Patel) | names the last topic: `Lisbon workshop budget review` |
| rich | names the open promise the owner owes: `You owe: Share the workshop deck with Alexandra` |
| rich | says who she is: `Acme Corp` |
| none (Philip Coe) | says `no meetings logged` |
| none | says who they are: `Globex Corp` |
| thin (Catherine Stewart) | says there is little on file, and the contact's own part is under 40 words |

The rich contact has no mutual-contact line on purpose: the Hub exposes no such
field (see the field table in the PR), so any `people in common` or `mutual`
text is an invention and FAILS.

## Negative controls

`--self-test` runs the judge on a good capture (must pass) and on 13 mutants,
each of which must go red by its own assertion: the old first-face-to-face
brief, `none` saying `first meeting`, `none` dropping `no meetings logged`, rich
losing its topic, rich losing its promise, an invented mutual contact, a thin
brief padded with generic advice, a thin brief that does not say it is thin, a
dash, the old `With:/Wiki:` shape, an over-budget message, a sender that sent
nothing, and only two of three announced. A missing prerequisite must be
CANNOT-RUN. CI runs this on every change to the probe.

## What this does and does not prove

Proves, on the box: the installed sender, the installed assistant binary, the
box's Hub and the box's graph together produce grounded text for the three
shapes. The calendar edge (the three meetings) and the delivery edge (WhatsApp)
are replaced by the shim; the attendee `outstanding_todos` for the rich contact
are injected in the shape the Hub returns, because a walk box has no calendar
event to derive them from.

Does not prove: that a real WhatsApp message arrives, or that a real meeting on
the owner's calendar yields a brief. That is definition-of-done item 5 and needs
the owner's own meeting with the sender enabled.
