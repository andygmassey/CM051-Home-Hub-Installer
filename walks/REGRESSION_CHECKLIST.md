# Walk regression checklist — things a HUMAN found, that the walk cannot see

**Why this file exists.** On 2026-08-31 Andy walked v1.0.52 and found six defects.
**Three were already marked COMPLETED in the task register.** One of those three
(#454) says *"NOT box-walked"* in its own title, and was closed anyway.

That is not a tracking slip. It is the `completed` word meaning two different
things: *code exists on a branch* and *the customer sees it working*. Every row
below was closed on the first meaning and failed on the second.

**The rule this file enforces:** a customer-visible defect may not be marked
completed until it has been observed ABSENT on a walked box, by name, in this
file. Source-complete is not complete. Merged is not delivered. Delivered is
not invoked.

---

## HOW TO USE THIS BEFORE ANY CUT

Every row is a thing to LOOK AT on the box, in the app, with eyes or a probe.
Mark it only from an observation on the walked artefact, never from a diff.

    status  meaning
    ------  --------------------------------------------------------------
    OPEN    seen broken on the most recent walk
    FIXED   observed ABSENT on a walked box; name the version and the date
    UNSEEN  no walk has looked at this surface at all -- NOT the same as FIXED

`UNSEEN` is the important one. A surface nobody opened is not a passing surface,
and the walk's 21 probes cluster where measurement is easy (#533). Everything
in the GUI section below is currently invisible to automation.

---

## ANDY'S WALK, v1.0.52, 2026-08-31 — ALL SIX OPEN

| # | Surface | Defect | Register | Status |
|---|---|---|---|---|
| A1 | Home tab | Front Page content does not render; shows "Your Front Page is still settling in" | **#210 was COMPLETED** | OPEN |
| A2 | Settings | "Advanced" section still present; Andy and Archie agreed it would not exist | **#454 was COMPLETED, text says NOT box-walked** | OPEN |
| A3 | Wiki Front Page | "Still getting to know you" panel is a raw table: "Could not tell", "Not started yet", "Nothing found to read yet" | **#218 was COMPLETED** | OPEN |
| A4 | Bursar | "You're not on the meter" on a box that has installed and compiled a wiki | #482 pending | OPEN |
| A5 | People / duplicates | "Duplicate review is available on the Hub Mac only." rendered ON the Hub Mac, beside working buttons | not previously filed | OPEN |
| A6 | People | Colm O'Neill = Delganycolm; Emmaj Oneill = Emma Oneill (Andy's sister). Splits real people | #300 #298 #346 pending | OPEN |

### What is MEASURED behind these, so nobody re-discovers it

- **A4** — `~/.ostler/workspace/state` is ABSENT; `~/.ostler/state` exists.
  Control fired: 53,103 files under `~/.ostler`, 463 `*.json`, **0** `*.jsonl`.
  Two state directories; the journal writes to the one never created. This is
  #325 (OSTLER_HOME carries two meanings) surfacing as real data loss.
- **A6** — the SAME graph simultaneously OVER-merges: 136 Person nodes each carry
  2+ distinct `icloud_contact_uid`, swallowing 281 Contacts cards, worst case 5
  cards in one node. A single threshold change makes one half worse.
  `Delganycolm` and `Emmaj Oneill` are handle-shaped, not name-shaped, so check
  the display-name picker before the merge logic.

---

## THE CLASS PROBLEM THIS FILE ANSWERS

Three of six were closed while broken. The register has ~100 further rows in the
same shape. Before the next cut, any row that is BOTH marked completed AND
customer-visible must be re-checked on the box or moved to UNSEEN. Closing it
from a merged PR is what produced A1, A2 and A3.

Known siblings already carrying this shape, not yet re-verified:

    #206  Governor first-run welcome modal missing post-install     COMPLETED
    #211  SPA state-machine: firstrun copy on one tab, settled on   COMPLETED
          another, simultaneously
    #212  Wiki tab MkDocs black-bar leaks through iframe            COMPLETED
    #213  Doctor "CONNECTED SOURCES" under-counts                   COMPLETED
    #214  Timeline event render glomming title + location           COMPLETED
    #215  People tab shows a bare phone number as a person          COMPLETED
    #218  "Still getting to know you" typography                    COMPLETED -> NOW A3
    #223  43MB rollback anchor in the user's Documents folder       COMPLETED

Each is a GUI surface. None is covered by a box-walk probe. All were closed on
source, not on sight.

---

## STANDING RULE

Do not mark any row in this file FIXED from a diff, a merged PR, or a passing
unit test. Mark it FIXED when it has been LOOKED AT on a walked box and the
defect was not there, and write the version and date next to it. If nobody has
looked, it is UNSEEN, and UNSEEN never authorises a cut.
