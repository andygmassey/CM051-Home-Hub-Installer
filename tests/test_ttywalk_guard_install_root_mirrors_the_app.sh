#!/usr/bin/env bash
# The harness (scripts/ttywalk.sh) replicates the .app's admin-shell loopback-guard step because it has no .app.
# This extracts the install-root invocation from gui/OstlerInstaller/Auth/AuthorizationHelper.swift and from ttywalk.sh,
# normalises both to the same placeholders and diffs them (command AND lib-path quoting): either side changing goes RED.
# SWIFT= / TTYWALK= override the files (mutation proof). Exit 0 same / 1 differ / 2 cannot run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - "${SWIFT:-gui/OstlerInstaller/Auth/AuthorizationHelper.swift}" "${TTYWALK:-scripts/ttywalk.sh}" <<'PY'
import re, sys
try:
    sw = open(sys.argv[1]).read(); tw = open(sys.argv[2]).read()
except Exception as e:
    print("CANNOT-RUN: %s" % e); sys.exit(2)
def swift_expr(line):
    # "lit" + ident + "lit" ...  ->  literals joined, ident `lib`->@LIB@ , `res`->@RES@
    out = []
    for part in re.findall(r'"((?:[^"\\]|\\.)*)"|(\b[a-z]+\b)', line):
        lit, ident = part
        out.append(lit if ident == '' else {'lib': '@LIB@', 'res': '@RES@'}.get(ident, '<?%s>' % ident))
    return ''.join(out)
m1 = re.search(r'let lib = (.+)$', sw, re.M); m2 = re.search(r'shell \+= (" ; /bin/bash ".+)$', sw, re.M)
t1 = re.search(r"^LG_LIB_TMPL=\"(.*)\"$", tw, re.M); t2 = re.search(r"^LG_INSTALL_ROOT_TMPL='(.*)'$", tw, re.M)
if not (m1 and m2 and t1 and t2):
    print("CANNOT-RUN: could not extract (swift lib=%s cmd=%s ; ttywalk lib=%s cmd=%s)" % (bool(m1), bool(m2), bool(t1), bool(t2))); sys.exit(2)
s_lib = swift_expr(m1.group(1)); s_cmd = swift_expr(m2.group(1)).replace(' ; ', '', 1).replace('$ORIG_USER', '@OWNER@')
t_lib = t1.group(1); t_cmd = t2.group(1)
# the Swift `let lib` builds the quoted path from `res`; the harness template names it the same way
bad = 0
for name, a, b in (('lib path quoting', s_lib, t_lib), ('install-root command', s_cmd, t_cmd)):
    if a == b: print("  ok   %s identical: %s" % (name, a))
    else: print("  FAIL %s differs\n       swift:   %s\n       ttywalk: %s" % (name, a, b)); bad += 1
if re.search(r'install-root[^"]*"\s*\+\s*lib\s*\+\s*"[^"]*\S', m2.group(1)): print("  FAIL swift passes more than 2 args"); bad += 1
sys.exit(1 if bad else 0)
PY
