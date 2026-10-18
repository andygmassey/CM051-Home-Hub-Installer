# Console-walk checklist items

Items that are NOT ssh probes and never will be, because the measurement
needs a reboot and a human at the console, not a click in a GUI dialog. The
TCC/GUI dialog gaps (the iMessage Automation grant, and the equivalent grant for Reminders.app) are tracked
in [`console_only_probes.tsv`](console_only_probes.tsv): those run as real
ssh probes that CANNOT-RUN for a stated reason, scored and ratcheted by the
walk record. A reboot cannot be driven that way at all, so it has no probe
file and is not scored by `run_box_walk.sh`. It is checked by hand, on this
list, every time a console walk happens.

## FileVault reboot recovery

**Why this cannot be an ssh probe.** install.sh offers FileVault enablement
during a fresh install (install.sh has ~30 references to FileVault across the
consent/enable/verify path). Enabling FileVault on an already-booted volume
defers encryption to the NEXT reboot, and the property this item exists to
check only exists AT boot time, before any user is logged in and therefore
before ssh has anything to connect to: the FileVault pre-boot unlock screen,
and whether the Hub comes back up correctly on the other side of it. An ssh
walk that reboots the box loses its own connection and cannot watch what
happens between power-on and login.

**Steps, and the exact screen expected at each one:**

1. During install, when prompted to enable FileVault, say yes (if this box's
   walk plan calls for exercising the FileVault path; skip this whole item on
   a walk plan that does not).
2. After the install finishes and the Hub is confirmed working (chat answers,
   Wiki renders), reboot the Mac from the Apple menu (not a hard power cycle;
   this checks the product's path, not disk resilience).
3. **Expected screen 1, within normal boot time:** the FileVault pre-boot
   unlock screen -- the account's photo/avatar, name, and a password field,
   on a plain dark background, BEFORE the usual macOS login window appears.
   If this screen never appears and the Mac goes straight to the desktop or
   the ordinary login window, FileVault did not actually enable: stop here
   and record the defect, this item is not continuable.
4. Enter the account password at the FileVault unlock screen.
5. **Expected screen 2:** the normal macOS desktop loads (not a second
   password prompt, not a crash, not a kernel panic).
6. Wait up to 2 minutes for the Hub's LaunchAgents to come up (same budget
   ttywalk.sh gives an ordinary cold start).
7. **Expected screen 3:** open the Hub app (or `http://localhost:8089/doctor`
   in a browser) and confirm it renders normally -- chat answers a question,
   the Doctor page's security-posture tile still says encryption enabled.
   This is the actual customer-visible property: a FileVault reboot must not
   silently leave the Hub unable to reach its own encrypted stores (the key
   file install.sh writes lives under `${OSTLER_DIR}/security`, on the SAME
   encrypted volume FileVault just unlocked, so a working unlock proves the
   key file survived it -- but only a human watching the Hub actually answer
   proves the SERVICES came back up using it).

**Record:** PASS if all three expected screens appeared in order and the Hub
answers normally afterwards. FAIL and the exact step number if any expected
screen did not appear or the Hub does not come back up. This item has no
CANNOT-RUN state: if the walk plan called for exercising FileVault, the human
either saw the unlock screen or did not.
