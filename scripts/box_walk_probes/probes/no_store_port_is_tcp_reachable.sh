#!/usr/bin/env bash
# probes/no_store_port_is_tcp_reachable.sh
# ============================================================================
# QUESTION: can anything on this Mac open a TCP connection to an Ostler store
#           or UI, without presenting any credential?
#
# THIS IS THE PROBE FOR #550, AND #550 WAS DEMONSTRATED, NOT ARGUED.
#
# From an ordinary second account on the owner's Mac, with no credential and no
# race:
#
#     curl -s -m 5 --noproxy '*' -H 'Host: localhost' \
#       'http://127.0.0.1:7878/query?query=SELECT (COUNT(*) AS ?n) WHERE {?s ?p ?o}'
#     -> a valid SPARQL result over the owner's entire knowledge graph
#
# The store-proxy in front of it checks the Host header and the Origin header.
# Both are supplied by the client. They were built against DNS-rebinding and
# cross-origin form POSTs -- BROWSER threats -- under an assumption written
# down at install.sh:14674: "a local user on this Mac can already read :8044
# directly, so it adds no local surface." That assumption is `local == owner`,
# and it is the root of the whole class.
#
# ---------------------------------------------------------------------------
# WHY THIS ASSERTS ABSENCE OF A PORT AND NOT A REFUSED CREDENTIAL
#
# Every credential-based design was defeated on this box:
#   - a shared nonce is presented TO whatever answers the port, so a squatter
#     receives it on first use
#   - a token in the URL is harvested from argv, which is READABLE ACROSS
#     ACCOUNTS on macOS (measured)
#   - a cookie is scoped to HOST and not to PORT (RFC 6265), so any loopback
#     port the neighbour binds receives it
#
# So the assertion is topological: after the fix there is no TCP endpoint to
# connect to, from ANY account including the owner's.
#
# ⚠️ THE ROUTE THAT WOULD DELIVER THAT STATE IS DEAD, AND THIS BLOCK USED TO
# NAME IT ANYWAY. It said the owner reaches the stores "over a unix socket in a
# 0700 directory, where the kernel does the authorising". The measurement at
# MUST_BE_CLOSED below kills that: a UDS created inside the colima VM crosses
# the bind-mount as a FILE, not as a connection, so there is no UDS route for
# ANY of these services. Every one of them runs in that VM.
#
# The assertion above is unchanged and still correct. What is gone is the means.
# Leaving the dead means written here as though it were the plan is how the
# ledger sends the next reader to build something that cannot work, so it is
# struck rather than quietly deleted -- somebody has already tried it once.
#
# That is also why this probe does NOT need a second account. Before the fix
# the ports answer everyone; after it they answer no one. One account can tell
# those apart.
#
# ---------------------------------------------------------------------------
# THE POSITIVE CONTROL, AND WHY IT IS NOT ONE OF THE STORE PORTS
#
# "Nothing is listening" and "I could not look" print identically. So this
# probe refuses to report PASS unless it has SEEN a listening port in the same
# invocation. The Hub gateway is used for that: it must stay reachable on
# loopback for the product to work at all, and daemon_is_listening.sh already
# treats it as a hard requirement.
#
# If the control port is closed, the verdict is CANNOT_RUN, never PASS. A run
# where the whole stack is down must not be reported as a security property.
#
# ---------------------------------------------------------------------------
# 8144 IS IN THE LIST, AND MY FIRST DRAFT EXCLUDED IT ON THE ROOT-CAUSE PREMISE
#
# I excluded the wiki tailnet gate because it is "defended by content -- the
# identity headers tailscaled stamps, which a peer cannot forge". The generator
# says exactly that, and the scope is in the sentence:
#
#     # Tailscale stamps this header ... so A TAILNET PEER cannot forge it.
#     map $http_tailscale_user_login $ostler_wiki_user_ok { default 0; "<owner>" 1; }
#     map $http_tailscale_funnel_request $ostler_wiki_not_funnel { default 0; "" 1; }
#     server { listen 8144; ... if either map is 0 -> 403 ... }
#
# `$http_tailscale_user_login` is a REQUEST HEADER. The deletion that makes it
# trustworthy happens inside tailscaled. A local client connecting straight to
# 127.0.0.1:8144 never traverses tailscaled, so nothing deletes anything and the
# client supplies both values itself. Omitting the funnel header satisfies limb
# one; sending the owner's email -- an address, not a secret -- satisfies limb
# two. 8144 IS published: install.sh has - "127.0.0.1:8144:8144".
#
# So it is very likely a seventh route to the same graph, and my exclusion
# inherited the premise this probe exists to kill: a control aimed at the only
# attacker its model contained, and an exclusion that adopted the same model.
# Included. If it turns out to be genuinely defended, the right answer is to
# prove that and remove it, not to assume it.
#
# BASH 3.2. No associative arrays, no mapfile.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="no_store_port_is_tcp_reachable"
PROBE_QUESTION="can any local account be SERVED by an Ostler store or UI without a credential, and does the install's own credential still get in?"

# The ports that MUST NOT answer after the fix, and why each is here.
#
# 2026-08-28: THREE OF THESE ROWS USED TO SAY "-> unix socket". That remedy is
# NOT AVAILABLE and the rows are corrected below. Measured with a control: a
# unix socket created INSIDE a container crosses a colima bind-mount as a FILE
# and NOT as a connection -- the host sees a real socket inode (`-S` passes) and
# `curl --unix-socket` against it fails, while the identical curl against a
# host-created socket succeeds. Connectability belongs to the kernel that owns
# the socket, which is the VM's. Every service below runs in that VM, so no
# UDS route exists for any of them. Measured on mountType=virtiofs / vm-type=vz
# (colima's default, and install.sh:10116 does not pin it); sshfs and 9p
# unmeasured.
#
# The ASSERTION is unchanged and still correct: none of these may answer. Only
# the stated route to that state was wrong, and a wrong route in the file that
# explains the hold sends the next reader to build something that cannot work.
#
# ⚠️ THIS TABLE WAS STALE IN THE REASSURING DIRECTION FOR A WEEK. Three rows
# still described the stores as half-done AFTER the 2026-08-28 work closed them,
# which made the whole surface read as unfinished and helped hide the ONE port
# that genuinely was not (8044). A stale security note is worse than no note: it
# was accurate when written, and nothing said otherwise.
#
# AND THEN IT WENT STALE THE OTHER WAY. #1609 closed 8044 and this table went on
# calling it "the worst surface" -- pessimistic rather than reassuring, so it
# wasted attention instead of hiding a hole, but it is the same failure and it
# has the same cause: a row that records a verdict and not the tag it was taken
# at. Every row below now names one. If you are reading this and the tag is old,
# re-measure before you believe it.
#
# SO EACH ROW NOW SAYS WHICH TAG IT WAS VERIFIED AT, and the distinction that
# matters is DEFERRED BY DECISION versus DECIDED AND NOT DONE. Per
# HR015/launch/DECISION_550_what_shut_means_2026-08-28.md:
#   line 106  8044  "direct publish removed | ABSENT"     <- decided for v1.0
#   line 107  3000  KNOWN RESIDUAL, v1.0.1                <- deferred
#   line 108  8144  KNOWN RESIDUAL, v1.0.1                <- deferred
#
#   6333  qdrant REST via store-proxy   -> CLOSED. Native api-key, and it is ON
#                                          BY DEFAULT: OSTLER_STORE_AUTH_ENFORCE
#                                          defaults to 1 (install.sh:12876,
#                                          :16223, :16812, :16943). VERIFIED at
#                                          tag v1.0.71, reading the shipped
#                                          default rather than a PR title.
#                                          MUST_STILL_PUBLISH still pins the
#                                          PORT open -- host clients have no
#                                          other route -- but an uncredentialled
#                                          read is refused. Published != readable.
#   7878  oxigraph SPARQL via store-proxy -> CLOSED. Proxy bearer credential
#                                          (#1214), also default-ON via the same
#                                          flag (install.sh:16943). #550 was
#                                          demonstrated here, and this is the
#                                          door it came through.
#   6334  qdrant gRPC, direct           -> unpublished (#1209; 0 consumers in
#                                          355 .py, 759 .rs, 144 ts)
#   6379  redis/valkey, direct          -> CLOSED. requirepass, default-ON via
#                                          OSTLER_REDIS_AUTH_ENFORCE:-1
#                                          (install.sh:12838). The Doctor probe
#                                          no longer breaks under auth: it parses
#                                          the URL with urlsplit and sends AUTH
#                                          BEFORE PING
#                                          (vendor/doctor/agent/status_collector.py:572-578).
#                                          The old note here said the opposite.
#   8044  wiki-site                     -> CLOSED (refuses). auth_basic on the
#                                          store-proxy, install.sh:17276-17277,
#                                          with the 0600-include pattern the
#                                          oxigraph bearer already used.
#                                          Guarded by
#                                          tests/test_the_wiki_port_demands_a_credential.sh
#                                          and .../survives_the_credential.sh --
#                                          two arms, so it cannot pass by
#                                          refusing everything. VERIFIED at
#                                          origin/main fa33901f (#1594, #1609).
#                                          ⚠️ THE PREMISE THAT HELD THIS UP FOR A
#                                          WEEK WAS FALSE AND IS RECORDED HERE
#                                          SO IT IS NOT RE-DERIVED: this row
#                                          used to say a browser "can take no
#                                          bearer; and a cookie gives no port
#                                          isolation (RFC 6265)". Both halves
#                                          are true and the conclusion does not
#                                          follow, because HTTP AUTHENTICATION
#                                          IS NOT A COOKIE. Its scope is the
#                                          protection space -- scheme plus
#                                          AUTHORITY, and authority includes the
#                                          port -- so a credential saved for
#                                          127.0.0.1:8044 is not offered to
#                                          127.0.0.1:9999. That is precisely the
#                                          port isolation cookies lack.
#   3000  vane                          -> CLOSED (refuses). ⚠️ THIS ROW READ
#                                          "🔴 OPEN ... no auth of any kind ...
#                                          Exposes vane_data, the customer's
#                                          chat history" UNTIL 2026-09-06, and
#                                          it was STALE -- in the frightening
#                                          direction, which is the one that gets
#                                          quoted. #1660 landed the credential
#                                          the row itself predicted would
#                                          transfer from 8044. Measured in
#                                          install.sh rather than recalled:
#                                          ostler-vane-auth.conf +
#                                          ostler-vane-htpasswd mounted into the
#                                          store-proxy (16791-16792), an nginx
#                                          `server { listen 3000; ... include
#                                          /etc/nginx/ostler-vane-auth.conf; }`
#                                          block (17305-17309), and the htpasswd
#                                          written with the same apr1 + 0600
#                                          pattern as the wiki (17429). It is
#                                          published at 127.0.0.1:3000 and it
#                                          refuses an uncredentialled read.
#   8144  wiki tailnet gate            -> WAS: its identity check is
#                                        client-supplied over a local
#                                        connection. CLOSED by #1683, which
#                                        added the same credential 8044 has
#                                        carried since #1594. This row's own
#                                        question below -- "can tailscale serve
#                                        be pointed at anything other than a
#                                        host TCP port? If no, it joins 8044
#                                        and 3000 and is solved by whatever
#                                        solves those" -- was answered NO, and
#                                        that is exactly what happened.
#                                        Its ONLY consumer is `tailscale serve`
#                                        on the host, so it must stay a TCP
#                                        port; the UDS alternative is dead per
#                                        the measurement above.
# ── #1618: REACHABILITY IS THE WRONG PREDICATE FOR A CREDENTIALLED PORT ─────
#
# The single MUST_BE_CLOSED list below used to hold all seven ports and ask one
# question of them: does a TCP connect succeed. That was right while the stores
# had NO auth, because reachable then meant readable.
#
# It is wrong for a port a human opens in a browser, and for every store now
# fronted by the credentialled store-proxy. Those ports MUST accept a connect --
# that is what "open the wiki" means, and what `tailscale serve` needs on 8144 --
# so a connect can never tell a protected surface from an unprotected one.
#
# MEASURED, and this is why the row never went green: the probe is named in 7
# walk records and has PASSED IN NONE. Five measured failures, one broken probe,
# one not measured. Not an 8044 regression -- 6333 and 7878 are published on
# loopback by store-proxy and answer a connect, so the row failed structurally
# whatever the auth said. #1609 put 8044 into that class; it did not create it.
#
# So the question is split by what the port IS:
#
#   MUST_NOT_LISTEN     nothing may answer at all. A connect that SUCCEEDS is
#                       the defect. This is the original predicate, kept for the
#                       ports it is actually true of.
#
#   MUST_REFUSE_UNAUTH  the port is published on purpose and must stay so, but
#                       an UNCREDENTIALLED request must be refused. A 200 is the
#                       defect. Connect success proves nothing either way.
#
# Per-port grounds are in the table above, read out of install.sh rather than
# recalled. 6334 is unpublished (#1209, zero consumers). Everything else is
# published deliberately and carries a credential.
# Both lists are INJECTABLE (set-but-empty is honoured, so a test can empty
# one) so scripts/tests/test_no_store_port_probe_reads_the_credential.sh can
# aim the real probe at a fake surface on a free port. The defaults are the
# product.
MUST_NOT_LISTEN="${OSTLER_PROBE_MUST_NOT_LISTEN-6334}"

# port:kind:path -- each published surface, the credential the installer minted
# for it, and the path the installer's OWN post-install checks request:
#   store     curl config at secrets/store-curl.conf (bearer + api-key, -K)
#             6333 /collections and 7878 /query?query=ASK{} are what
#             install.sh's signal-2 check proves with, verbatim
#   wiki      auth_basic, user ostler, secrets/wiki_password (8044, the
#             installer's own last check requests / and expects 200)
#   wikigate  the same credential INSIDE the tailnet gate block (#1683), plus
#             the owner header the gate maps; refuses everyone until Tailscale
#             has named an owner, BY DESIGN, and that state is reported as
#             such rather than as a lock-out
#   vane      auth_basic, user ostler, secrets/vane_password (#1660)
#   redis     requirepass, the password in the REDIS_AUTH_ARGS line of .env
SURFACES="${OSTLER_PROBE_SURFACES-6333:store:/collections 7878:store:/query?query=ASK%7B%7D 8044:wiki:/ 8144:wikigate:/ 3000:vane:/ 6379:redis:-}"

# Which arms run. "both" is the product question. "1" runs only the
# uncredentialled arm: the #550 demonstration surface, for a run from a SECOND
# local account whose $HOME holds none of the owner's credential files. There
# arm 2 would read CANNOT-RUN for a reason that is not the product's, and a
# narrowing that is DECLARED, printed and named in the verdict beats one the
# reader has to infer from a missing-file line. Anything else is CANNOT-RUN.
PROBE_ARMS="${OSTLER_PROBE_ARMS:-both}"

# 6379 is redis, not HTTP, so it cannot be asked with curl. It is listed here
# because the PROPERTY is identical -- an uncredentialled client must be refused
# -- and adjudicated by its own sensor below. Naming the property once and
# instantiating it per protocol is the point of #1618; a list that silently
# dropped redis would be the same blind spot in a smaller box.

# ── 8144: NO LONGER AN EXPECTED RED, AND STILL DO NOT UNPUBLISH THE PORT ────
#
# 8144 belongs in the list, but NO LONGER FOR THE REASON FIRST WRITTEN HERE.
#
# WAS: "its two identity limbs are request headers, and a local client that
# never traverses tailscaled supplies them itself". That was true and it is
# now fixed -- #1683 added the wiki credential INSIDE the 8144 server block,
# measured against the pinned nginx: a forged owner header went 200 -> 401,
# the credentialled owner still gets 200 and the body, and a wrong password
# gets 401.
#
# ⚠️ THIS PARAGRAPH USED TO SAY 8144 "stays in MUST_BE_CLOSED because THIS
# SENSOR MEASURES TCP REACHABILITY, NOT AUTHENTICATION", and that a red here
# means only "a local account can OPEN a socket". Both halves were true and the
# conclusion has expired: #1618 changed the sensor. It now asks the question the
# old one could not, so 8144 moves to MUST_REFUSE_UNAUTH and is expected GREEN
# -- a red here means the credential #1683 added is GONE, which is a finding
# rather than a shrug.
#
# The port still must remain published (see below), and that is unchanged.
#
# But it CANNOT be closed the way 6334 and 6379 were, and the reason is
# measured rather than assumed:
#
#     install.sh:21269
#       "$TS_CLI" --socket="$TS_SOCK" serve --bg --https=443 "http://127.0.0.1:8144"
#
# **tailscaled reaches the gate by connecting to 127.0.0.1:8144 from the host.**
# So whatever can reach it for tailscaled can be reached by any local account:
# they are the same loopback. Unpublish the port and `tailscale serve` has
# nothing to proxy to, and the tailnet wiki path dies silently.
#
# So this row is expected RED until the HAND-OFF changes, not until somebody
# deletes a compose line. The open question that decides the shape of that fix:
# can `tailscale serve` be pointed at anything other than a host TCP port?
# If yes, 8144 is a topology fix like the stores. If no, it joins 8044 and
# 3000 and is solved by whatever solves those.
#
# A red that carries its own reason is a gate. A red that invites a wrong fix
# is a trap. This comment is the difference.

# Must be OPEN, or we cannot tell "closed" from "cannot look".
CONTROL_PORT="${OSTLER_GATEWAY_PORT:-8000}"

# THE SENSOR IS A CONNECT, NOT A LISTENER LOOKUP.
#
# The first draft used `lsof -nP -iTCP:<port> -sTCP:LISTEN`. That is the defect
# of #549 reproduced inside the gate built to close it: **lsof is
# permission-scoped**, so a listener owned by ANOTHER account is invisible and
# reads as closed. A positive control does not save it, because the control is
# read through the same permission scope: on a box where the gateway is owned by
# the running account and the stores are owned by another (which is the exact
# topology of the 2026-08-28 walk box), the control PASSES and every store port
# reads closed. The gate would have printed PASS on the machine that produced
# the demonstration.
#
# A connect is what the attacker does. It is not permission-scoped, and on
# loopback there is no filtering to confuse it.
#
# And no `2>/dev/null` on the decisive read: a swallowed error becomes a zero
# and a zero reads as closed.
#
#   prints: open | closed | error:<rc>
port_state() {
    _rc="$(box_run "nc -z -w 2 127.0.0.1 $1 >/dev/null 2>&1; echo \$?")"
    case "$_rc" in
        0) printf 'open\n' ;;
        1) printf 'closed\n' ;;
        *) printf 'error:%s\n' "$_rc" ;;
    esac
}

# ── THE CREDENTIAL SENSORS ───────────────────────────────────────────────────
#
# TWO ARMS PER PUBLISHED SURFACE, AND THE SECOND IS WHAT MAKES THE FIRST MEAN
# ANYTHING. A surface that refuses EVERYTHING -- a dead upstream, a proxy whose
# htpasswd mount failed, a store booted with a key nobody holds -- answers 401
# to an uncredentialled request exactly as a healthy one does. One arm cannot
# tell those apart, and "refuses everyone" is the state a customer meets as
# "the wiki will not open". So every published surface is asked twice:
#
#   arm 1  WITHOUT a credential        must be refused     a 2xx here is #550
#   arm 2  WITH the install's own      must be served      a 401 here is a lock-out
#
# The credential is the install's own, read ON THE BOX from the file the
# installer wrote, and never by this probe. The remote command names a PATH;
# curl consumes the secret from a config piped on stdin (-K -), so it is in no
# argv on either machine. argv is readable across accounts on macOS, which is
# the class this probe polices -- a probe that leaked the credential it was
# checking would be the defect wearing a badge.
#
# --noproxy '*' IS NOT OPTIONAL. A local proxy answers for EVERY host, so
# without it a 200 can come from the proxy rather than from the service, and
# this probe would report a store readable that never saw the request. Same
# reason the registry probes in this estate print remote_ip.
#
# THREE OUTCOMES, NOT TWO. curl writes 000 when it could not connect or timed
# out. That is NOT "refused" and it is NOT "readable": it is CANNOT-RUN for that
# port, and it is returned as such rather than folded into either verdict.
#
# 🔴 EVERY URL IS SINGLE-QUOTED IN THE REMOTE COMMAND. box_run sends the line
# to the walk box over ssh, where the login shell is ZSH, and zsh treats a bare
# ? as a single-character glob: it matches no file and ABORTS THE COMMAND before
# curl ever runs. That is #1737 -- it is why --wipe-stores had never once
# succeeded, and it tests clean locally because bash does not glob a bare ? the
# same way. The 7878 row carries a query string ON PURPOSE (it is the URL the
# installer proves with), which is exactly the shape that bit, so the quotes
# are load-bearing. The unit test drives these strings through `zsh -c` where
# zsh exists.
_http_code() {   # $1 url, $2 prelude: a box command printing a curl config ("" = no credential)
    if [ -n "$2" ]; then
        box_run "{ $2; } | curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 6 -K - '$1'; echo"
    else
        box_run "curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 6 '$1'; echo"
    fi
}

# Redis speaks its own protocol. An uncredentialled PING against a server with
# requirepass answers -NOAUTH; without it, +PONG. Asked with nc rather than
# redis-cli: nc ships on macOS and this probe already relies on it, redis-cli
# does not and its absence used to turn the whole 6379 row into CANNOT-RUN.
# The credentialled arm reads the password on the box from the .env line the
# installer upserted and hands it to a printf BUILTIN, so it is in no argv.
_redis_state() {   # $1 port, $2 absolute .env path on the box ("" = no credential)
    if [ -n "$2" ]; then
        box_run "command -v nc >/dev/null 2>&1 || { echo no_client; exit 0; }; pw=\"\$(sed -n 's/^REDIS_AUTH_ARGS=--requirepass //p' '$2' | tr -d '\"')\"; [ -n \"\$pw\" ] || { echo no_credential; exit 0; }; printf 'AUTH %s\r\nPING\r\n' \"\$pw\" | nc -w 3 127.0.0.1 $1 2>&1 | tr -d '\r' | tail -n 1"
    else
        box_run "command -v nc >/dev/null 2>&1 || { echo no_client; exit 0; }; printf 'PING\r\n' | nc -w 3 127.0.0.1 $1 2>&1 | tr -d '\r' | head -n 1"
    fi
}

# Map a reading to one of: refused | readable | unmeasurable
# "readable" is the word for a SERVED request in both arms: in arm 1 it is the
# defect, in arm 2 it is the control passing. The mapper does not know which
# arm it is feeding, and must not.
_verdict_for_http() {
    case "$1" in
        401|403) printf 'refused\n' ;;
        000|'')  printf 'unmeasurable\n' ;;
        2??|3??) printf 'readable\n' ;;
        *)       printf 'unmeasurable\n' ;;
    esac
}

_verdict_for_redis() {
    case "$1" in
        *NOAUTH*|*WRONGPASS*|*"not permitted"*|*"invalid password"*) printf 'refused\n' ;;
        *PONG*)                                                       printf 'readable\n' ;;
        *)                                                            printf 'unmeasurable\n' ;;
    esac
}

# ── WHERE THE INSTALLER LEFT EACH CREDENTIAL ────────────────────────────────
#
# Resolved against the BOX's own $HOME, once, so every remote command carries
# an absolute path in single quotes. #1284 is what an unexpanded $HOME inside
# quotes costs: curl was handed a path that did not exist and issued no
# request. Overridable so the unit test can point the probe at a fixture; the
# defaults are the installer's own paths (_seed_wiki_password,
# _ostler_write_store_curl_config, the REDIS_AUTH_ARGS upsert, the gate conf).
# The single quotes are the point: $HOME must expand on the BOX, not here.
# shellcheck disable=SC2016
_box_home() { box_run 'printf %s "$HOME"'; }
_file_on_box() { box_run "test -r '$1' && echo yes || echo no"; }

_resolve_credential_paths() {   # $1 the box's $HOME
    STORE_CURL_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-$1/.ostler/secrets/store-curl.conf}"
    WIKI_PASSWORD_FILE="${OSTLER_PROBE_WIKI_PASSWORD_FILE:-$1/.ostler/secrets/wiki_password}"
    VANE_PASSWORD_FILE="${OSTLER_PROBE_VANE_PASSWORD_FILE:-$1/.ostler/secrets/vane_password}"
    REDIS_ENV_FILE="${OSTLER_PROBE_REDIS_ENV_FILE:-$1/.ostler/.env}"
    WIKI_GATE_CONF="${OSTLER_PROBE_WIKI_GATE_CONF:-$1/ostler-wiki-gate.conf}"
    case "$WIKI_GATE_CONF" in "$1/ostler-wiki-gate.conf") WIKI_GATE_CONF="$1/.ostler/ostler-wiki-gate.conf" ;; esac
}

# The credentialled arm's curl config, as a command the BOX runs. Prints the
# command on stdout. rc 2: the credential file is not on the box (path on
# stdout). rc 3: the arm does not apply and the reason on stdout says why.
_prelude_for() {   # $1 kind
    case "$1" in
        store)
            [ "$(_file_on_box "$STORE_CURL_CONF")" = yes ] || { printf '%s\n' "$STORE_CURL_CONF"; return 2; }
            printf "cat '%s'\n" "$STORE_CURL_CONF" ;;
        wiki)
            [ "$(_file_on_box "$WIKI_PASSWORD_FILE")" = yes ] || { printf '%s\n' "$WIKI_PASSWORD_FILE"; return 2; }
            printf "sed 's/^/user = \"ostler:/; s/\$/\"/' '%s'\n" "$WIKI_PASSWORD_FILE" ;;
        vane)
            [ "$(_file_on_box "$VANE_PASSWORD_FILE")" = yes ] || { printf '%s\n' "$VANE_PASSWORD_FILE"; return 2; }
            printf "sed 's/^/user = \"ostler:/; s/\$/\"/' '%s'\n" "$VANE_PASSWORD_FILE" ;;
        wikigate)
            [ "$(_file_on_box "$WIKI_PASSWORD_FILE")" = yes ] || { printf '%s\n' "$WIKI_PASSWORD_FILE"; return 2; }
            if [ "$(_file_on_box "$WIKI_GATE_CONF")" != yes ]; then
                printf 'the wiki gate conf %s is not on the box, so 8144 has no owner bound and refuses everyone BY DESIGN (fail-closed until Tailscale names the owner)\n' "$WIKI_GATE_CONF"; return 3
            fi
            _owner="$(box_run "sed -n 's/^    \"\(.*\)\" 1;\$/\1/p' '$WIKI_GATE_CONF' | head -n 1")"
            if [ -z "$_owner" ]; then
                printf 'the wiki gate conf %s names no owner yet, so 8144 refuses everyone BY DESIGN (fail-closed until Tailscale names the owner)\n' "$WIKI_GATE_CONF"; return 3
            fi
            printf "sed 's/^/user = \"ostler:/; s/\$/\"/' '%s'; printf 'header = \"Tailscale-User-Login: %%s\"\\n' '%s'\n" "$WIKI_PASSWORD_FILE" "$_owner" ;;
        redis)
            [ "$(_file_on_box "$REDIS_ENV_FILE")" = yes ] || { printf '%s\n' "$REDIS_ENV_FILE"; return 2; }
            printf '%s\n' "$REDIS_ENV_FILE" ;;
        *)
            printf 'unknown surface kind %s -- the SURFACES table names a credential this probe does not know how to present\n' "$1"; return 3 ;;
    esac
}

# ---------------------------------------------------------------------------
# THE ADJUDICATION, AS A PURE FUNCTION.
#
# Separated from the measuring so the self-test can exercise the DECISION with
# fabricated readings, rather than asserting things about its own fixtures. A
# self-test that only proves its stubs return what they were written to return
# has demonstrated nothing about the probe.
#
#   classify <control_listener_count> <listening_that_must_not> \
#            <served_without_credential> <refused_the_installs_credential> \
#            <unmeasurable>
#     -> CANNOT_RUN | FAIL | PASS
#
# ORDER IS THE CONTRACT, and it is not the obvious one.
#
#   1. a bad control first -- a run whose control failed proves nothing in
#      EITHER direction, so it can never be read as a finding.
#   2. then FAIL, and this outranks unmeasurable ON PURPOSE. If one port is
#      demonstrably wrong and another could not be measured, the demonstrated
#      defect is the result. Downgrading a proven FAIL to CANNOT_RUN because a
#      SIBLING was unreadable is how a real finding gets lost in a shrug. A
#      lock-out is a demonstrated defect too: the surface answered, and it
#      refused the credential the installer itself wrote.
#   3. then unmeasurable -> CANNOT_RUN. Three outcomes, three branches. A port
#      we could not ask has NOT passed.
#   4. PASS only when every port was measured and every one behaved on BOTH
#      arms.
classify() {
    _c="$1"; _listening="$2"; _readable="$3"; _locked="$4"; _unmeasured="$5"
    case "$_c" in ''|*[!0-9]*) printf 'CANNOT_RUN\n'; return ;; esac
    # A closed control means the stack is down. Every store port then reads
    # closed for a reason that is not the fix.
    if [ "$_c" -eq 0 ]; then printf 'CANNOT_RUN\n'; return; fi
    if [ -n "$_listening" ] || [ -n "$_readable" ] || [ -n "$_locked" ]; then printf 'FAIL\n'; return; fi
    if [ -n "$_unmeasured" ]; then printf 'CANNOT_RUN\n'; return; fi
    printf 'PASS\n'
}

run_probe() {
    n_checked=0; listening_list=""; readable_list=""; locked_list=""; unmeasured_list=""; served_list=""; refused_list=""

    c_state="$(port_state "$CONTROL_PORT")"
    case "$c_state" in open) c=1 ;; closed) c=0 ;; *) c="" ;; esac
    case "$(classify "$c" "" "" "" "")" in
        CANNOT_RUN)
            probe_examined 0 "store/UI surfaces"
            probe_cannot_run "control port ${CONTROL_PORT} is ${c_state}. A closed or unreadable control cannot be told apart from a closed store port, so this run proves nothing about #550."
            ;;
    esac
    probe_note "positive control: ${CONTROL_PORT} has a listener, so this probe can see an open port"

    case "$PROBE_ARMS" in
        both|1) ;;
        *)
            probe_examined 0 "store/UI surfaces"
            probe_cannot_run "OSTLER_PROBE_ARMS='${PROBE_ARMS}' is not one of both|1. A probe that does not know which arms it was asked for cannot say which it ran."
            ;;
    esac
    if [ "$PROBE_ARMS" = both ]; then
        box_home="$(_box_home)"
        if [ -z "$box_home" ]; then
            probe_examined 0 "store/UI surfaces"
            probe_cannot_run "could not read \$HOME on the box, so no credential path can be resolved and the second arm cannot run. A probe that cannot present the credential cannot tell a refusal from a lock-out."
        fi
        _resolve_credential_paths "$box_home"
    fi

    # CLASS 1: nothing may answer. A successful connect IS the defect.
    for p in $MUST_NOT_LISTEN; do
        n_checked=$((n_checked + 1))
        st="$(port_state "$p")"
        case "$st" in
            error:*) unmeasured_list="${unmeasured_list} ${p}(connect:${st})" ;;
            open)    listening_list="${listening_list} ${p}" ;;
        esac
    done

    # CLASS 2: published on purpose. Arm 1: an UNCREDENTIALLED request must be
    # refused. Arm 2: the install's OWN credential must be served. Connect
    # state is deliberately not consulted -- these ports are SUPPOSED to accept
    # a connection, so asking whether they do answers a question nobody has.
    for e in $SURFACES; do
        p="${e%%:*}"; rest="${e#*:}"; kind="${rest%%:*}"; path="${rest#*:}"
        n_checked=$((n_checked + 1))
        if [ "$kind" = redis ]; then
            r1="$(_redis_state "$p" "")"; v1="$(_verdict_for_redis "$r1")"
        else
            r1="$(_http_code "http://127.0.0.1:${p}${path}" "")"; v1="$(_verdict_for_http "$r1")"
        fi
        case "$v1" in
            readable)     readable_list="${readable_list} ${p}(${r1})"; continue ;;
            unmeasurable) unmeasured_list="${unmeasured_list} ${p}(${r1:-no-reading})"; continue ;;
        esac
        # Arm 1 refused. Declared arm-1-only: stop here, and say so at the end.
        if [ "$PROBE_ARMS" = 1 ]; then refused_list="${refused_list} ${p}"; continue; fi
        # Arm 2: is that refusal a credential check, or a wall?
        prelude="$(_prelude_for "$kind")"; prc=$?
        case "$prc" in
            2) unmeasured_list="${unmeasured_list} ${p}(credential-file-absent:${prelude})"; continue ;;
            3) probe_note "${p}: credentialled arm not applicable -- ${prelude}"; continue ;;
        esac
        if [ "$kind" = redis ]; then
            r2="$(_redis_state "$p" "$prelude")"; v2="$(_verdict_for_redis "$r2")"
        else
            r2="$(_http_code "http://127.0.0.1:${p}${path}" "$prelude")"; v2="$(_verdict_for_http "$r2")"
        fi
        case "$v2" in
            readable) served_list="${served_list} ${p}" ;;
            refused)  locked_list="${locked_list} ${p}(${r2})" ;;
            *)        unmeasured_list="${unmeasured_list} ${p}(with-credential:${r2:-no-reading})" ;;
        esac
    done

    probe_examined "$n_checked" "store/UI surfaces, arms=${PROBE_ARMS} (control ${CONTROL_PORT} confirmed open)"

    case "$(classify "$c" "$listening_list" "$readable_list" "$locked_list" "$unmeasured_list")" in
        FAIL)
            if [ -n "$listening_list" ] || [ -n "$readable_list" ]; then
                probe_fail "an uncredentialled client is served by these Ostler surfaces, so every account on this Mac can read them:${listening_list}${readable_list}. #550 was demonstrated against 7878 with one unauthenticated curl. A port listed with a 2xx answered a request that carried NO credential; a port listed bare should not be listening at all.${locked_list:+ Also refusing the credential the installer wrote:${locked_list}.}"
            else
                probe_fail "these surfaces refused an uncredentialled request AND refused the install's OWN credential, read on the box from the file the installer wrote:${locked_list}. That refusal cannot be credited to a credential check -- it is the shape of a dead upstream or a mis-mounted htpasswd, and it is what the customer meets as a surface that will not open. Served with the credential, so genuinely gated:${served_list:- none}."
            fi
            ;;
        PASS)
            # States ONLY what was measured, on the arms that ran. A green
            # verdict that hands the reader a mechanism is the sentence that
            # gets quoted into a ship note, so WHICH mechanism refused each one
            # is not asserted.
            if [ "$PROBE_ARMS" = 1 ]; then
                probe_pass "ARM 1 ONLY (OSTLER_PROBE_ARMS=1): every one of the ${n_checked} store/UI surfaces refused an uncredentialled request (401/403, or NOAUTH for redis):${refused_list}${MUST_NOT_LISTEN:+; the ${MUST_NOT_LISTEN} class refused a connection outright}. ${CONTROL_PORT} was confirmed open in the same run. Arm 2, the install's own credential must be served, was NOT RUN, so this verdict does NOT exclude a lock-out; run as the install owner with both arms for that"
            fi
            probe_pass "every one of the ${n_checked} store/UI surfaces behaved on both arms: an uncredentialled request was refused (401/403, or NOAUTH for redis)${MUST_NOT_LISTEN:+, the ${MUST_NOT_LISTEN} class refused a connection outright}, and the install's own credential, read on the box, was served by:${served_list:- none needed}. ${CONTROL_PORT} was confirmed open in the same run, so this is a measured refusal and not a blind probe. WHICH mechanism gated each surface is NOT asserted here -- read the per-port table in this file"
            ;;
        *)
            probe_cannot_run "adjudication was inconclusive for control='${c}' listening='${listening_list}' served-without-credential='${readable_list}' refused-the-credential='${locked_list}' unmeasurable='${unmeasured_list}'. A surface that could not be asked, on either arm, has NOT passed."
            ;;
    esac
}

self_test() {
    # Exercises classify() with fabricated readings. Every case names the real
    # situation it stands for.
    fails=""

    # 1. THE ORIGINAL DEFECT. Control up, something LISTENING that must not be.
    [ "$(classify 1 ' 6334' '' '' '')" = "FAIL" ] || fails="${fails} listening-port-not-FAIL"

    # 2. #1618's DEFECT, and the one the old predicate could not see: the port
    #    is published (as it must be) and served an UNCREDENTIALLED request.
    [ "$(classify 1 '' ' 8044(200)' '' '')" = "FAIL" ] || fails="${fails} uncredentialled-200-not-FAIL"

    # 3. THE FIX, and the arm that matters most for THIS probe specifically.
    #    It is named in 7 walk records and has passed in NONE, so "it went
    #    green" is unreadable until PASS is shown to be reachable at all.
    [ "$(classify 1 '' '' '' '')" = "PASS" ] || fails="${fails} clean-box-not-PASS"

    # 4. THE TRAP THIS PROBE EXISTS TO AVOID. Control DOWN, nothing found.
    [ "$(classify 0 '' '' '' '')" = "CANNOT_RUN" ] || fails="${fails} stopped-stack-read-as-PASS"

    # 5. Control unreadable -> CANNOT_RUN, not PASS.
    [ "$(classify '' '' '' '' '')" = "CANNOT_RUN" ] || fails="${fails} unreadable-control-not-CANNOT_RUN"

    # 6. Control down AND a finding -> still CANNOT_RUN, in either direction.
    [ "$(classify 0 ' 6333' '' '' '')" = "CANNOT_RUN" ] || fails="${fails} down-control-with-finding-adjudicated"

    # 7. A port we COULD NOT ASK has not passed. Three outcomes, three branches.
    [ "$(classify 1 '' '' '' ' 3000(000)')" = "CANNOT_RUN" ] || fails="${fails} unmeasurable-read-as-PASS"

    # 8. FAIL OUTRANKS CANNOT_RUN. A demonstrated uncredentialled read must not
    #    be softened to "inconclusive" because a SIBLING port was unreadable.
    [ "$(classify 1 '' ' 8044(200)' '' ' 3000(000)')" = "FAIL" ] || fails="${fails} fail-downgraded-by-sibling-unmeasurable"

    # 9. THE SECOND ARM. Refused without a credential AND refused WITH the
    #    install's own. "Refuses everyone" is not a pass; it is a lock-out.
    [ "$(classify 1 '' '' ' 8044(401)' '')" = "FAIL" ] || fails="${fails} lock-out-not-FAIL"

    # 10. And a lock-out also outranks an unmeasurable sibling.
    [ "$(classify 1 '' '' ' 8044(401)' ' 3000(000)')" = "FAIL" ] || fails="${fails} lock-out-downgraded-by-sibling-unmeasurable"

    # 11-17. THE SENSOR MAPPERS. classify() is only as good as what feeds it.
    #    401 and 403 are both refusals: auth_basic answers 401, the store-proxy's
    #    host check answers 403, and either means the request was not served.
    [ "$(_verdict_for_http 401)" = "refused" ]      || fails="${fails} http-401-not-refused"
    [ "$(_verdict_for_http 403)" = "refused" ]      || fails="${fails} http-403-not-refused"
    [ "$(_verdict_for_http 200)" = "readable" ]     || fails="${fails} http-200-not-readable"
    [ "$(_verdict_for_http 000)" = "unmeasurable" ] || fails="${fails} http-000-not-unmeasurable"
    [ "$(_verdict_for_redis '-NOAUTH Authentication required.')" = "refused" ] || fails="${fails} redis-noauth-not-refused"
    [ "$(_verdict_for_redis '+PONG')" = "readable" ] || fails="${fails} redis-pong-not-readable"
    [ "$(_verdict_for_redis 'no_client')" = "unmeasurable" ] || fails="${fails} redis-missing-client-not-unmeasurable"

    probe_examined 17 "adjudication cases"

    # ── THE RUNNER'S CONTRACT, WHICH THIS FUNCTION USED TO BREAK ──────────
    #
    # run_box_walk.sh phase 1 invokes every probe with --self-test and reads:
    #     output contains 'VERDICT: BROKEN'  -> BROKEN
    #     else rc == 1                       -> ok, "goes red on known-bad input"
    #     else                               -> BROKEN, "returned N, expected 1"
    #
    # A --self-test is a NEGATIVE CONTROL: its job is to prove the probe CAN
    # return red. Ending the healthy path in probe_pass exits 0, so the runner
    # took the third branch and marked this probe BROKEN -- which is exactly
    # what the v1.0.50 walk recorded, and why its store-port verdict was
    # discarded rather than counted.
    #
    # THE TWO OUTCOMES STAY DISTINGUISHABLE, which is the whole point:
    #   cases misbehave -> emit VERDICT: BROKEN, runner reports BROKEN
    #   cases behave    -> probe_fail, exit 1, no BROKEN string, runner ok
    # Both exit 1; the RUNNER discriminates on the string, not the code.
    if [ -n "$fails" ]; then
        printf 'VERDICT: BROKEN -- %s self-test adjudication is wrong:%s\n' \
            "${PROBE_NAME:-no_store_port_is_tcp_reachable}" "$fails"
        printf '%s: BROKEN -- classify() misadjudicated%s, so this probe cannot be trusted to detect #550\n' \
            "${PROBE_NAME:-no_store_port_is_tcp_reachable}" "$fails"
        exit 1
    fi
    probe_fail "NEGATIVE CONTROL DEMONSTRATED (this red is the expected result of --self-test, not a finding): classify() returned FAIL on a port that must not listen, on a published port that served an UNCREDENTIALLED request, and on a surface that refused the install's OWN credential; PASS only with the control up and nothing found; CANNOT_RUN on a stopped or unreadable control and on a surface that could not be asked; and both kinds of FAIL outranked an unmeasurable sibling. The sensor mappers turned 401/403 into refused, 2xx into readable, 000 into unmeasurable, and redis NOAUTH/PONG/no-client into the same three. 17 of 17 adjudication cases behaved."
}

probe_main "$@"
