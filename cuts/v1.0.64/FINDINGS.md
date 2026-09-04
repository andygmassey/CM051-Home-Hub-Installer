# v1.0.64 FINDINGS -- from the v1.0.63 box walk

**Artefact walked:** `OstlerInstaller-1.0.63.dmg`, sha256 `1c1bb8a941c1d24b…`
**Box:** Mini 16, UUID `E9589EC6-AA1E-5425-9D76-3AF64A0A05BD`, wiped via Erase All
Content and Settings 2026-09-04 ~06:00Z. First genuinely customer-shaped box in
the v1.0.5x/6x sequence.
**Walked by:** Archie, unattended pty driver, 2026-09-04 07:16-07:49Z. Andy's own
GUI walk follows separately.

⚠️ **ALL THREE FINDINGS ARE THE SAME CLASS: the installer makes a factual claim
about the machine that is not true.** That is the `install-error-honesty` family
(`scripts/box_walk_probes/probes/install_error_honesty.sh`) and the same shape as
#1401, where a terminal `DONE status=ok` asserted something the run had not done.

---

## W001 -- the CANCEL path says "nothing was written" and leaves 213M behind

**Reproduce:** run the installer, answer **N** to the final consent question
("One last thing: how third-party data works").

**It prints:**
```
No problem. Nothing has been installed and nothing was
written to your Mac.
#OSTLER	DONE	status=cancelled
```

**Measured immediately after:** `~/.ostler` PRESENT at **176M** (213M on a later
run). `/Applications/Ostler.app` gone, 0 LaunchAgents.

**WHAT the residue is, established from the run's own log ordering rather than
from a byte listing:** the log shows `Using bundled Python 3.11.15` and
`Security module installed into venv` at log line ~214; the consent prompt appears
at ~370. The app ships a **97M** `Contents/Resources/python` (3,556 files) which
`install.sh` copies to `~/.ostler/python` (see the comment at install.sh:2573),
then pip-installs the security module into that venv. 97M of interpreter plus a
populated venv accounts for the observed size.

**So the real sequence is:** copy a 97MB interpreter into the customer's home →
build a venv → install a security module → **then** ask whether they consent →
if they decline, tell them nothing was written.

**NOT A DEFECT, do not "fix" it:** the `[n]` default on that prompt. Consent must
be affirmative; a pre-ticked yes would be unlawful.

**Two open questions the fixer must answer first:**
1. Is the pre-consent venv build DELIBERATE (e.g. the questions need Python)? If
   so the fix is the CLAIM, not the ordering.
2. If it is not deliberate, the fix is to defer the venv until after consent.

**Control the test needs:** seed `~/.ostler` with a marker before cancelling and
assert the test goes RED when the message says "nothing written" and the marker
survives. Without that arm the test passes on any tree where the message is simply
absent.

---

## W002 -- Homebrew install FAILED on a clean box, aborting the whole install

```
#OSTLER	LOG	level=error	msg=[ERR-04-HOMEBREW-INSTALL] Homebrew install failed.
#OSTLER	DONE	status=fail	code=ERR-04-HOMEBREW-INSTALL	failed_steps=1	errors=2
#OSTLER	DONE	status=fail	code=ERR-99-INSTALL-ABORT-L10861	failed_steps=1	errors=1
```

**TIMING, measured with `date -u` on the box, not inferred:**
```
CLT finished installing   07:48:54Z
walk log ended            07:48:57Z   (3 seconds later)
```
Homebrew needs the Command Line Tools. The install reached the Homebrew step while
CLT was still absent, and CLT only landed because a human clicked a dialog.

**MUST BE ESTABLISHED BEFORE FIXING:** whether Homebrew failed *because* CLT was
missing, or for an unrelated reason. **W003 is why that cannot currently be
answered.**

---

## W003 -- the Homebrew error names a log file that does not exist

The error tells the customer:

> `Full output saved to /tmp/ostler-brew-install.log – attach it [to a support request]`

**There is no such file.** Measured on the box: no `/tmp/*brew*` or `/tmp/*homebrew*`
match, with a control confirming `/tmp` is readable and holds 6 entries.

**This is the most damaging of the three**, because it is the one that makes the
others undiagnosable. The single artefact a customer is instructed to send to
support is never written, so every ERR-04 report arrives with nothing attached and
W002 cannot be root-caused from a customer's machine.

**Control the test needs:** force the Homebrew step to fail, then assert the named
path EXISTS and is non-empty. A test that only greps for the message string would
pass on today's tree.

---

## Not yet reconciled

`~/.ostler` was **176M** at the first cancel and **213M** after the later run.
Nobody has enumerated either. The reconstruction above rests on log ordering plus
the shipped payload size, not on a byte-level listing.
