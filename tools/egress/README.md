# tools/egress -- the instruments the egress inventory was measured with

These are the probes used to answer "where does the shipped code actually send
bytes, and to whom" for the egress inventory (#740, #741, #742, #761). They are
**measuring instruments, not product**. Nothing in `install.sh` or the daemon
invokes them and nothing should.

They are here because the inventory is **not finished** -- #742 records five
destination families that were never sampled -- and because the findings they
produced are now quoted in customer-facing copy. A claim that rests on a
measurement nobody can re-run is a claim nobody can check. Until today these
sat untracked in a working tree, which is the same invisibility recorded as
#778: real, relied on, and one `rm -rf` from gone.

## What each one answers

| script | question |
|---|---|
| `sweep_fetch_sites.sh` | Which hosts does the shipped tree actually FETCH? Classifies by **call site**, not by string. |
| `sweep_enrich_clients.sh` | For each enrichment client: which host, and is it key-gated (inert without a key) or unconditional? |
| `probe_meta_socket.sh` | Which WhatsApp code path is the running daemon on, and does the binary hold a Meta endpoint? |
| `probe_meta_socket2.sh` | Is that socket **steady state**, or only open during a pairing attempt? |
| `probe_meta_socket3.sh` | Re-checks the shape of every zero pass 1-2 produced. |
| `probe_meta_socket4.sh` | Re-does two measurements from pass 3 that were unsound. |
| `cats.py` | Category histogram over the `preferences` collection (what enrichment would be offered). |
| `enrichcheck.py` | Samples payloads per category to see what enrichment actually wrote. |

## Two things they are built around, and why

**A string that looks like a URL is not a destination.** The naive sweep returns
193 hits for one namespace host and 92 for `w3.org`, and **neither is ever
fetched** -- they are RDF namespace URIs, identifiers rather than addresses.
`sweep_fetch_sites.sh` therefore counts a host only when it shares a line with
something that opens a socket. This is the over-reporting half of the problem;
the under-reporting half is the package managers, which reach a default registry
with **no literal URL in the source at all**, so they are counted separately and
by call-site count rather than by hostname.

**Every zero gets its shape checked.** `probe_meta_socket3.sh` and `4.sh` exist
because passes 1 and 2 produced zeros, and "nothing found" and "nothing looked
at" print identically. Two measurements in pass 3 turned out to be unsound and
pass 4 redoes them rather than reporting them. Read all four in order; the later
passes correct the earlier ones and the corrections are the point.

## Running them

The repo-reading sweeps take the repo root from `git rev-parse --show-toplevel`,
so run them from anywhere inside a checkout. The box probes read a live install
and honour `OSTLER_APP_ROOT` / `OSTLER_STATE_DIR` (both default under `$HOME`).
The Python probes talk to Qdrant on loopback.

Operator paths were parameterised out before these were committed -- this repo
is public, and a hardcoded home directory is the exact class recorded as #698.

## The bound on what they prove

`sweep_fetch_sites.sh` reads `install.sh`, `vendor/` and `scripts/`. It says
**nothing** about a destination reached from a compiled binary, from a container
image, or through a client library whose call site names no host. #761 records a
related harness bound: a run that blocked `httpx` was clean partly by
entry-point luck, because three enrichment files use `aiohttp`.

Do not quote a number from these without saying which of those it could not see.
