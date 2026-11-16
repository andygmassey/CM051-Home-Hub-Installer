# ostler_fda people index: card or conversation keeps a sender-shaped person; exclusion declared

**Location and shape only, never content.**

Tree: `ostler_fda`. File: `pwg_ingest.py`.

## What changed, per file

| tree | file | change |
|---|---|---|
| `ostler_fda` | `pwg_ingest.py` | `service_sender_reason` takes `has_card` and `has_conversation` and keeps the person when either is true, after the phone rule |
| `ostler_fda` | `pwg_ingest.py` | `ingest_people_to_qdrant` computes the reason per person and returns `excluded` and `by_reason` on its ok path |

## Why

The people step drops notification and organisation senders before it counts
`total`, and the drop was not declared. On the v1.0.132 box, all 394 persons
that the graph held but the vector store did not were rows the sender rule
flagged, so `people_stores_reconcile` and `people_count_agreement` counted
them as unvectored named people (`C=372` in the 132 walk). 22 of the 394 had a
personal-looking first.last address; 2 of those had a last-contact channel,
which is a proxy for a conversation with the owner.

The fix keeps a person who has a contact card or a last-contact channel, the
same way a phone keeps one, and declares the rows it leaves out by reason.

## Measured

Synthetic members only: `tests/test_people_declared_exclusion.py`, three tests.
Red on origin/main before the fix (declared count missing; card keep fails);
green after. Mutants: removing the card/conversation keep fails the keep test;
dropping the declared count fails the declared-count test.

The probe re-check (the #438 pattern) is not in this change.
