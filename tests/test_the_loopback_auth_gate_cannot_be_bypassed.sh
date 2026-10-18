#!/bin/bash
# The loopback-auth gate must not be foolable, and this fires the exact shapes
# that fooled it.
#
# WHY: the gate's first version was reviewed adversarially and FOUR working
# bypasses were found, each reproduced with a real file. The worst was that it
# searched the whole file for words like "Authorization", so an unauthenticated
# client sitting beside "# TODO: add Authorization" passed clean. A gate whose
# evidence can be a comment is checking prose, not behaviour -- the exact defect
# class the gate exists to catch, inside the gate.
#
# Every case below FAILED to be caught before the hardening. Two negative
# controls sit alongside them, because a gate that catches everything is as
# useless as one that catches nothing: a properly credentialled client must
# come back clean, and an empty tree must be CANNOT-RUN rather than PASS.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
G="$PWD/scripts/verify_loopback_clients_authenticate.py"
[ -f "$G" ] || { echo "FAIL: gate script missing at $G"; exit 1; }
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/vendor/fake_component"
cp install.sh "$T/install.sh" || exit 1
fails=0
mk(){ printf '%s' "$2" > "$T/vendor/fake_component/$1"; }
rc(){ python3 "$G" "$T" >/dev/null 2>&1; echo $?; }
want_caught(){ if [ "$(rc)" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1 -- BYPASS OPEN"; fails=$((fails+1)); fi; }

mk c.py 'import requests
s = requests.Session()
r = s.get("http://127.0.0.1:8090/api/v1/suggestions")
'
want_caught "requests.Session().get with no credential"

mk c.py 'from urllib.request import urlopen
r = urlopen("http://127.0.0.1:8090/api/v1/reply-debt")
'
want_caught "a bare urlopen with no credential"

mk c.py 'import requests
# TODO: add Authorization header here one day
r = requests.get("http://127.0.0.1:8090/api/v1/people")
'
want_caught "a comment mentioning Authorization is not a credential"

mk c.py 'import os, requests
requests.get("http://127.0.0.1:8090/health")
u = "http://127.0.0.1:8090" + os.environ.get("EP", "/api/v1/suggestions")
requests.get(u)
'
want_caught "a public literal does not excuse a route built at runtime"

# Archie's finding: one authed call used to exempt every OTHER client in the
# same module, and a module with an authed admin call beside an unauthed data
# call is completely ordinary code, not an evasion.
mk c.py 'import os, requests
tok = open(os.path.expanduser("~/.ostler/secrets/service_token")).read().strip()
requests.get("http://127.0.0.1:8090/api/v1/admin",
             headers={"Authorization": "Bearer " + tok})


















def later_and_far_away():
    return requests.get("http://127.0.0.1:8090/api/v1/suggestions")
'
want_caught "an authed call elsewhere in the file does not exempt an unauthed one"

# A shell client, which the first version could not see at all.
mk c.sh '#!/bin/bash
curl -s "http://127.0.0.1:8090/api/v1/people"
'
want_caught "a shell client is in scope"
rm -f "$T/vendor/fake_component/c.sh"

mk c.py 'import os, requests
tok = open(os.path.expanduser("~/.ostler/secrets/service_token")).read().strip()
requests.get("http://127.0.0.1:8090/api/v1/suggestions",
             headers={"Authorization": "Bearer " + tok})
'
if [ "$(rc)" = "0" ]; then echo "  ok   NEGATIVE CONTROL: a credentialled client is not flagged"
else echo "  FAIL NEGATIVE CONTROL: false positive on a correct client"; fails=$((fails+1)); fi

# THE PIN. The gate sees signals.py only because fetch_signals carries a default
# base_url containing a gated host; the live caller overrides it. Delete that
# default and the front-page client silently leaves the gate's coverage. This
# fails loudly instead.
if grep -qE "127\.0\.0\.1:(8089|8090)|localhost:(8089|8090)" \
        vendor/cm059_editor/compiler/signals.py 2>/dev/null; then
    echo "  ok   PIN: signals.py still carries a gated host literal, so it stays in scope"
else
    echo "  FAIL PIN: signals.py no longer names a gated host -- the front-page client has"
    echo "       silently left this gate's coverage. See the known-uncovered shape in the"
    echo "       gate's docstring; do not delete this pin, fix the coverage."
    fails=$((fails+1))
fi

rm -f "$T/vendor/fake_component/c.py"
if [ "$(rc)" = "3" ]; then echo "  ok   NEGATIVE CONTROL: an empty tree is CANNOT-RUN, not PASS"
else echo "  FAIL NEGATIVE CONTROL: empty tree did not report CANNOT-RUN"; fails=$((fails+1)); fi

echo
[ "$fails" = "0" ] && { echo "All cases passed."; exit 0; }
echo "$fails case(s) failed."; exit 1
