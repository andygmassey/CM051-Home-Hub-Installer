# v1.0.66 -- SCOPE

**A scoped cut is not a started cut.** This file exists so the next cut opens
against a written intent rather than whatever happened to be on main.
`scripts/new_cut.sh` refuses only on `cut.env`, so a SCOPE.md alone is allowed
and is the standard first step.

## WHY THIS CUT EXISTS

v1.0.65 shipped and was walked repeatedly on a cold macOS account. Nine walks
were spent getting past harness faults and staging gaps; walks 11 to 13 are the
first that ever reached the hydrate steps. **v1.0.65 is CONDEMNED.** It carries
a same-day regression that kills the install at step 21 of 40, and it inherits
a defect that has silently disabled contact and Places import since v1.0.60.

### THE WALK LADDER, SO THE COST OF EACH STOP IS ON THE RECORD

```
walk  5   step  6 of 40   config_save      PRODUCT defect  -> #1436, merged
walk  6-8 step 10 of 40   port 6333        MY OWN false zeros, three causes
walk  9   step 21 of 40   email-ingest     harness staging gap, disclosed
walk 10   step 21 of 40   consent_state    PRODUCT regression -> #1439
walk 11   step 38 of 38   hydrate x3       PRODUCT defect  -> #1442 + TNM's guard
walk 12   step 38 of 38   hydrate x3       same, reproduced
walk 13   running         with #1439 + #1442 staged
```

**Nothing in this cut may be described as "found by the walk" unless the walk
reached the step that found it.** Four of the nine stops above were mine.

## SCOPE -- THE FIXES THIS CUT CARRIES

### CM051 #1439 -- the install aborts at step 21, a same-day regression

`_ostler_consent_state` is CALLED at install.sh:21321 and DEFINED at 21370.
install.sh is a linear script whose step bodies are top-level statements in
file order, so the call ran against a name bash had not bound. `rc=127`, and
the install dies outright.

```
v1.0.63   the function does not exist at all
v1.0.64   the function does not exist at all
v1.0.65   BROKEN, call 21321, definition 21370
```

Both halves entered in ONE commit, e7b835ba (#1423, 2026-09-04T20:45:16+08).
`git tag --contains` returns v1.0.65 alone. **This is a regression written the
same day it shipped, not a latent defect the walks were too shallow to catch.**
The fix is a pure relocation: 17 lines out, 17 in.

### CM051 #1442 -- contacts and Places have never imported, since v1.0.60

Measured on the box from the installer's own diagnostic logs:

```
ModuleNotFoundError: No module named 'contact_syncer.photo_storage'
No module named contact_syncer.places_ingest
```

`install.sh:17729` copies the ROOT `contact_syncer/` (19 modules) into the
import pipeline. The complete vendored copy at `vendor/cm041/contact_syncer/`
has 24, and the five it lacks include the two the installer runs.

**The customer-visible shape is the dangerous part:** hydrate dies at
`elapsed_s=0`, the customer is told "your contacts are on this Mac but Ostler
imported 0 of them", and the install then reaches its end and reports
`DONE status=ok`. A completed install says nothing about the two dead features,
which is exactly why this survived six cuts.

Present in v1.0.60, .61, .62, .63, .64 and .65, every tag checked directly.

### TNM -- the unguarded substitution at install.sh:25424

A command substitution containing a pipeline with **no `|| { ... }` guard**,
sitting immediately after a guarded producer. The expensive call is defended
and the arithmetic after it is not. Proved by execution, and the class measured
the same way: **19 multi-line sites probed, 11 abort, 8 survive, 10 of the 11
in the hydrate family.** A parse-only count said 20 and would have handed over
nine non-defects.

#1442 stops the producer failing; this stops the counter aborting when a
producer does fail. **Neither is sufficient alone and they are separable.**

## SCOPE -- THE HARNESS FIXES THAT MADE THE ABOVE VISIBLE

### CM051 #1440 + #1441 -- a failed walk reported 0 and exited 0

`ttywalk.sh` published install.sh's RAW EXIT STATUS under the heading
"VERDICT", and ended on its last `ssh`, so it exited 0 whatever it found.
**Every walk of the night exited 0, including the ones that died at step 6.**
Walk 12 is the first that ever exited non-zero on a failure. #1441 then fixed
the two gates my own #1440 tripped on main.

## SUPERSEDED SCOPE -- ALREADY MERGED, KEPT SO THE HISTORY READS STRAIGHT

The first draft of this file scoped #1436 and #1431. Both merged before this
cut opened and are on main. They are not re-listed as scope.

## THE ORIGINAL TWO, FOR REFERENCE

Both are the same underlying gap: **the reuse path is the least-tested path in
the installer and the most likely one on a real customer Mac**, because a
restored home or a previous install leaves `config/.env` behind.

### CM051 #1436 -- an absent config key aborts the install

Found by walk 5 of v1.0.65 on a cold account, `--reset`:

```
Install aborted unexpectedly at line 12720 (step config_save):
    _v="$(_ostler_config_list_first "$_cfg" whatsapp allowed_numbers)"
#OSTLER DONE status=fail code=ERR-99-INSTALL-ABORT-L12720
```

`grep -oE` exits 1 on no match; `set -Eeuo pipefail` promotes that to the whole
pipeline even though `sed` exits 0; `set -e` kills the assignment. **Hits every
customer re-running the installer who did not choose WhatsApp.**

Reproduced and controlled on the box: key ABSENT -> exit 1 and the script died;
key PRESENT -> exit 0 with the value.

### CM051 #1431 -- "use previous answers" silently revoked consent

Measured on Andy's Mini: `ostler-consent show` returned null for every tickbox
on a COMPLETE install, and `config/.env` carried 21 keys of which zero were
consent. Self-perpetuating: reuse skips the questions, the decision variables
stay empty, the recorder is guarded on non-empty, so nothing is persisted for
the next reuse to restore. Three of four conversation feeds never installed.

## PINS

- **DAEMON: HOLD at bc63c445** unless something that REACHES THE ARTEFACT has
  moved. Re-measure; do not inherit the argument. The discriminator is "files
  outside .gitignore", with the `bc63c445~5..bc63c445` control to prove the
  zero is real.
- **CM051:** main head at tag time, and it must satisfy
  `git merge-base --is-ancestor <pin> origin/main`.

## 🎩 WALK SUBJECT

The `archie` account on the Mini (uid 502). ⚠️ **A WALK CONSUMES AN ACCOUNT'S
COLDNESS.** By the time this cut is walked, `archie` will have had several
installs. For a verdict that means anything about a cold box, walk a NEW
account and keep `archie` for harness iteration.

## WHAT THIS CUT DOES NOT FIX, STATED SO NOBODY ASSUMES IT DOES

1. **v1061-D005**, the step-count drift. Measured, mechanism recorded, NOT
   fixed: four of six `TOTAL_STEPS` decrement sites cannot be hoisted. Walk 4
   announced `total=41` and walk 5 announced `total=40` on the same tree, which
   is the same class showing up between runs.
2. **The pipefail class, PARTLY.** #1436 fixed one instance and TNM's change
   fixes the eleven multi-line sites he measured. **Single-line substitutions
   are an unmeasured population and the "30 pipelines / 330 substitutions"
   intersection is still open.** Stated rather than buried: this cut does not
   close the class.
3. **The ttywalk staging gap, WORKED AROUND NOT FIXED.** The harness stages the
   REPO; 23 of 48 DMG `Contents/Resources` entries were absent from the staged
   tree and the harness warned about only 3. For walks 10 onward I copied 22 of
   them in BY HAND from the mounted DMG. **That is a manual step living in a
   /private/tmp worktree that macOS clears on boot, not a fix.** `cm052_ai_conversations` is among the missing, so the
   AI-conversations path CANNOT BE WALKED AT ALL -- which is exactly the code
   #1428 and #1431 changed.
4. **v1063-D006 and v1063-D007**, both TNM's and both still open.

## THE GATE

`post_walk_qa.sh <walk-account>@<host> v1.0.66` -- 24 probes. **The bar is 24
PASS.** Not "zero FAIL", and CANNOT-RUN counts against, because that is
precisely how four cuts shipped over a dead gate.

## THE DOUBLE CLOSE, OPEN AND NAMED

`hydrate_graph` emits **two** `STEP_END` markers (3s and 22s) and the run emits
**two** terminal `DONE` markers, `status=fail` then `status=ok`. There is
exactly one `progress ... "hydrate_graph"` call in the file, at 24533, so the
step is opened once and **closed twice**. A `DONE status=fail` that a later
`status=ok` overwrites is a verdict that can be lost.

`_ostler_on_err` guards on `OSTLER_DONE_EMITTED`, a plain shell variable that
cannot cross out of a subshell, and install.sh:22764-22771 already documents
that mechanism for #639 at a different site. **TNM could not make it fire here
and refused to borrow it. It is unsolved, it is not in this cut's scope, and it
must not be described as understood.**
