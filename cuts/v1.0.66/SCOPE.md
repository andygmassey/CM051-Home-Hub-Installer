# v1.0.66 -- SCOPE

**A scoped cut is not a started cut.** This file exists so the next cut opens
against a written intent rather than whatever happened to be on main.
`scripts/new_cut.sh` refuses only on `cut.env`, so a SCOPE.md alone is allowed
and is the standard first step.

## WHY THIS CUT EXISTS

v1.0.65 shipped and was WALKED on a genuinely cold macOS account for the first
time. The walk found one product defect, and it is a customer-facing one.

## SCOPE -- TWO PRODUCT FIXES, BOTH ON THE RE-INSTALL PATH

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
2. **The pipefail class.** #1436 fixed the ONE instance the walk proved.
   install.sh has 30 `| grep` pipelines and 330 command substitutions and the
   overlap is UNMEASURED. Dispatched to TNM with the boundary that the property
   is an exit status and only running it decides.
3. **The ttywalk staging gap.** The harness stages the REPO; 23 of 48 DMG
   `Contents/Resources` entries are absent from the staged tree and the harness
   warns about 3. `cm052_ai_conversations` is among the missing, so the
   AI-conversations path CANNOT BE WALKED AT ALL -- which is exactly the code
   #1428 and #1431 changed.
4. **v1063-D006 and v1063-D007**, both TNM's and both still open.

## THE GATE

`post_walk_qa.sh <walk-account>@<host> v1.0.66` -- 24 probes. **The bar is 24
PASS.** Not "zero FAIL", and CANNOT-RUN counts against, because that is
precisely how four cuts shipped over a dead gate.
