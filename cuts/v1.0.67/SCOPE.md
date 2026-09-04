# v1.0.67 -- SCOPE

**A scoped cut is not a started cut.** This file exists so the next cut opens
against a written intent rather than whatever happened to be on main.
`scripts/new_cut.sh` refuses only on `cut.env`, so a SCOPE.md alone is allowed
and is the standard first step. **There is no `cut.env` here yet, on purpose.**

## WHY THIS CUT EXISTS

v1.0.66 is BUILT, SIGNED, NOTARISED and PUBLISHED, and it is the first artefact
ever driven by an artefact walk (`ttywalk.sh --from-dmg`) rather than a walk of
the checkout. It is not condemned. It carries two defects that were found
AFTER it was cut, neither of which aborts an install.

### THE DISTINCTION v1.0.66's OWN cut.env INVITES, SO STATE IT PLAINLY

v1.0.66's `cut.env` says "Walked green on archie@192.168.1.240: 39 steps, 0
not-ok". **That was a walk of the TREE the cut was made from, not of the DMG.**
The artefact walk is a different rung and it is the one that judges the bytes a
customer receives. Nothing in this file may cite the tree walk as artefact
evidence.

## SCOPE

```
#1437   declining must not wipe an install already there PRODUCT   MERGED 22:58:25Z
#1457   two UNMEASURED flags that nothing reads          PRODUCT   MERGED 22:33:28Z
#1459   a subshell must not emit a terminal DONE (#642)  PRODUCT   MERGED 22:34:11Z
#1466   the upgrade path reverts the Homebrew PATH fix   PRODUCT   MERGED 22:53:37Z
```

**All four VERIFIED as v1.0.67 content by blob comparison against the tag, not
by merge time.** A pin compares the `install.sh` BLOB, not the commit, so
"merged after the tag" is an argument and this is a measurement:

```
probe                             v1.0.66 tag   main
_OSTLER_FINAL_PREEXISTED               0          6    NEW   (#1437)
counter_failed_count_unmeasured        6         10    NEW   (#1457, +4 sites)
BASH_SUBSHELL:-0                       0          1    NEW   (#1459)
[[ "$_k" == "PATH" ]] && continue      0          1    NEW   (#1466)
```

### #1437 -- DECLINING MUST NOT WIPE AN INSTALL THAT WAS ALREADY THERE

Data loss on the re-install decline path. Reviewed by TNM, who closed the
open question with a PROOF rather than a sample: the `OSTLER_DIR` binding at
the decline arm is ONE FLAG WITH OPPOSITE GUARDS -- the only promote that
precedes the arm runs when `SKIP_PHASE2 == true`, the arm is reachable only
when it is `false`, and the col-0 `if` opened at 7853 is still open at 9760 at
depth 2. The other four promote sites are all after the arm.

⚠️ **KNOWN CONSEQUENCE, named rather than discovered later:** the wipe WAS the
staging cleanup on that path. `composite_cleanup` arms at 10442, after both
decline arms, and the traps at 9748 clean no staging, so a declined re-install
now leaves `/tmp/ostler-prelaunch-$$`. Not `~/.ostler`, so the Article 9
invariant as written still holds, and the OS clears it. **Follow-up job
dispatched** to remove `$OSTLER_PRELAUNCH_DIR` explicitly, guarded on `-n` and
`-d`; an explicit removal is honest about which tree is being cleaned and
survives a rebinding, which an incidental wipe was not even while it worked.

### THE UPGRADE PATH SILENTLY REVERTS THE 2026-08-20 HOMEBREW-PATH FIX

**Added 22:45Z. On severity this OUTRANKS both items above**, and it only hits
customers who already have containers running -- the ones with the most to lose.

`_upg_preserve_plist_env` (install.sh:530..550) walks every key in the OLD plist
and, where the key also exists in the new one, `Set`s the old value. **`Set`
replaces, and there is no PATH exclusion.** Called on the assistant at :657 and
the keepalive at :675.

Reproduced by TNM and INDEPENDENTLY by me, using the real function extracted
from main and two plists differing only in PATH:

```
Set :EnvironmentVariables lines in the function : 1
PATH exclusions                                 : 0

BEFORE new.plist PATH   /usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
AFTER  new.plist PATH   /usr/bin:/bin:/usr/sbin:/sbin          🔴 OVERWRITTEN
function rc             0
CONTROL OSTLER_HOME     preserved correctly
```

**The control is the point: the function is right for every other key.** This is
not a broken function, it is a MISSING EXCLUSION -- PATH is the one key whose
old value must lose.

**Why it is serious.** `/usr/bin:/bin:/usr/sbin:/sbin` is exactly the PATH the
assistant plist's own comment records as producing, measured on a real power
cycle: *"colima FATA exec limactl: executable file not found in $PATH ...
Qdrant, Oxigraph, Redis, Vane, wiki-site and store-proxy were all gone until
someone started Colima by hand."* An upgrading pre-2026-08-20 customer gets the
fix reverted and **their container stack does not survive a reboot.**

**THE GATE IS GREEN BECAUSE IT TESTS THE TEMPLATE.**
`tests/test_launchagent_homebrew_path.sh` has **0** references to
upgrade / preserve / `_upg_`. It asserts the templates carry the PATH; nothing
asserts the value SURVIVES an upgrade. The fix shipped, the gate stayed green,
and it never reached an upgrading customer.

**The test must assert SURVIVAL**, running the real extracted function over a
pre-fix old plist and today's new one, and it must carry a MUST-PRESERVE control
(a non-PATH key) so a fix that simply stops preserving anything cannot pass.

### #1457 -- A COUNTER THAT COULD NOT RUN WAS PUBLISHED AS A MEASURED ZERO

`_HYDRATE_EMAIL_COUNTS_UNMEASURED` and `_AICONV_UNMEASURED` are ASSIGNED in the
shipped install.sh and read by NOTHING. In both cases the next lines manufacture
the value whose absence was just recorded (`case ''|*[!0-9]*) X=0` and
`${X:-0}`), so email reports `no_correspondents_in_window` -- a cause nobody
observed -- for a count nobody could take. Calendar and contacts already carry
the guard, and calendar's own comment states the mechanism.

Reporting honesty, not data loss. No install aborts on it.

### #1459 -- A PHANTOM TERMINAL MARKER DURING A HEALTHY INSTALL

`set -E` propagates the ERR trap into a command substitution's subshell. The
child emits a TERMINAL `DONE status=fail` and sets `OSTLER_DONE_EMITTED=1`
inside itself, then dies with the flag. Measured by TNM on 3.2.57: same pid,
`subshell=1 status=fail` then `subshell=0 status=ok`.

**Customer impact, measured from the consumer side rather than assumed:**
`InstallerCoordinator.swift` overwrites `finished` on each DONE (1825),
`failureState` is COMPUTED not stored (227), and `process.terminate()` is
reached only from user-initiated `cancel()` (1142). So the failure banner
renders with an `ERR-99-INSTALL-ABORT-Lnnnn` code during a healthy install and
then REVERTS. **Not a false success, not a killed install.** The residual risk
is a customer who acts on that banner and aborts a working install.

Exposure is the `X="$( ... )" || { ... }` shape -- **19 sites, every hydrate
counter**. Both TNM and I first published "9 `local X=$( )` sites"; both of us
corrected it to 2 within four minutes of each other, independently, because
`$((` arithmetic matches any pattern anchored on `$(`. The 2 are `date +%s` and
`printf | tr`, both benign. **The `local` subset is not the exposure.**

## NOT IN SCOPE, AND WHY

- **The SC2155 split** (`local X; X="$(cmd)"`). Correct, mechanical, and worth
  almost nothing here: 2 sites, both benign. It does not belong in a cut whose
  purpose is the 19.
- **Hoisting `OSTLER_DONE_EMITTED`.** Already measured at 0 DONE markers,
  `lib/progress_emitter.sh:717-725`. The obvious fix is the wrong one and the
  measurement is on the record.
- **Moving 17 ubuntu-only CI jobs to macos runners.** A cost decision, not a
  cut decision. The static bash-4 guard already shipped is the right 90%.

## HARNESS WORK ALREADY ON main, WHICH THIS CUT INHERITS

None of it reaches the DMG; it changes what the walk can see and say.

```
#1454   ttywalk can walk the ARTEFACT, not just the repo
#1456   the call-before-definition CLASS gate (#1439 fixed one instance)
#1458   a slow step is not a wedged one -- walk 6 was killed at step 11 of 40
        while PERFECTLY healthy, on a 3.5 GB pull install.sh documents as silent
#1460   a tally that contradicts the log is not a pass  (open)
```

**#1460 matters to this cut specifically.** The subshell's
`__OSTLER_FAILED_STEPS` dies with it while the `STEP_END` it wrote survives on
the marker wire, so a walk could carry a `status=error` step in its log AND
`failed_steps=0` in the marker being graded. `adjudicate()` returned PASS on
exactly that. Until #1460 is merged and deployed, **an artefact walk's own
verdict cannot be trusted to catch this class** and must be cross-read against
the log.

## PRECONDITIONS BEFORE A cut.env IS WRITTEN

1. The v1.0.66 ARTEFACT walk reaches a verdict, and that verdict is read with
   the reconciliation in #1460 rather than the driver that shipped with it.
2. `post_walk_qa.sh archie@192.168.1.240` run against the artefact. **The bar is
   0 FAIL and 0 BROKEN with every CANNOT-RUN accounted for, NOT 24 PASS.** Many
   of the 24 probes are data-dependent and correctly return CANNOT-RUN on a
   freshly reset box; chasing 24/24 there is chasing an unreachable number.
3. #1457 reviewed by TNM and merged.
4. #1459's RED control pinned to a pre-fix blob and merged. Its current red is
   the test refusing to certify coverage it no longer has, which is correct
   behaviour and must not be resolved by weakening the control.

## DAEMON PIN

Expected to HOLD at `bc63c445`. **The argument must be RE-MEASURED, not
inherited from v1.0.66** -- a pin reused without one is indistinguishable from a
pin nobody checked. Measure `ahead_by/behind_by`, the files outside
`.gitignore`, a control predicate that returns non-zero so the zero is real, and
the Quality Gate's enumerated count against its declared `total_count`.
