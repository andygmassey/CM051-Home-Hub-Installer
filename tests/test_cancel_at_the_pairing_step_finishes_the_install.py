#!/usr/bin/env python3
"""F&F 2026-11-05 item 6: Cancel at the last step threw away the install.

Cross-contract (GUI writes, install.sh reads), source level:
  a. install.sh's tailscale_signin wait loop polls ${TS_STATE_DIR}/.signin_skip
     and breaks on it;
  b. the Swift writer targets the SAME relative path;
  c. install.sh does not delete the marker between step entry and the loop
     (a click during the URL poll must survive);
  d. the footer's Cancel goes through requestCancel and only terminates on
     .terminate; the pair-later button exists and has copy.
Usage: test_...py [repo_root]
"""
import pathlib, re, sys
R = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
def rd(rel):
    f = R / rel
    if not f.is_file(): print(f"CANNOT-RUN: {rel} missing"); sys.exit(2)
    return f.read_text(encoding="utf-8")
sh, pol, cv = rd("install.sh"), rd("gui/OstlerInstaller/Steps/LateStepPolicy.swift"), rd("gui/OstlerInstaller/Views/ContentView.swift")
copy = rd("gui/OstlerInstaller/Resources/ViewCopy.en-US.json")
fail = 0
def chk(c, m):
    global fail
    print(("  [PASS] " if c else "  [FAIL] ") + m); fail += (not c)

chk('TS_SKIP_SENTINEL="${TS_STATE_DIR}/.signin_skip"' in sh and 'if [[ -f "$TS_SKIP_SENTINEL" ]]' in sh, "install.sh polls the skip marker")
chk('TS_STATE_DIR="${OSTLER_DIR}/tailscale"' in sh and '".ostler/tailscale/.signin_skip"' in pol, "Swift writer path equals install.sh path")
i = sh.index('gui_step_begin "tailscale_signin"'); j = sh.index('if [[ -f "$TS_SKIP_SENTINEL" ]]')
between = sh[i:j]
n_rm = len(re.findall(r'rm -f[^\n]*signin_skip|rm -f "\$TS_SKIP_SENTINEL"', between))
chk(n_rm == 1, f"marker is cleared exactly once between step entry and the loop (found {n_rm}), at entry")
chk('"tailscale_signin"' in pol and "pairingStepIds" in pol, "tailscale_signin is a pairing step")
chk("requestCancel()" in cv and "== .terminate" in cv, "footer Cancel goes through requestCancel and terminates only for .terminate")
chk(not re.search(r'footer\.cancel_button"\)\)\s*\{\s*coordinator\.cancel\(\)', cv), "footer Cancel no longer calls cancel()+terminate unconditionally")
chk("footer.finish_pair_later_button" in cv and '"finish_pair_later_button"' in copy, "Finish and pair later button exists with copy")
print(f"fail={fail}"); sys.exit(1 if fail else 0)
