# Egress inventory: what leaves the Mac, and why

> **[not for publication until the measured run]** Delta revision 2026-10-21,
> read from source at CM051 origin/main 6c936e74 and ostler-assistant
> origin/main bb43a2db. Nothing in the 2026-10-21 sections was sampled on a box.
> Every claim there is tagged SOURCE (read, not measured) or says CANNOT-RUN.

> **STATUS: NOT PUBLISHED, and the reason changed on 2026-08-17.**
> Andy approved publication conditional on the inventory being complete. It is
> now materially more complete than the first draft (9 declared destinations to
> 45) and it is not finishable as a document, because the section on
> public-data enrichment needs a MEASURED run before we put a number on it.
> That measurement is the last thing between here and publication.
> Filed under the rule in `feedback_publish_the_discipline_not_the_difficulty_map`.

Instrument: `scripts/box_walk_probes/probes/no_unexpected_egress.sh`.
Ledger: `scripts/box_walk_probes/egress_hosts.tsv`.
Measured on a 16 GB M4 Mini running v1.0.33, 2026-08-17. The Tailscale
control-plane row in Honest residue below was re-measured on a live install
on 2026-09-18 and is dated there.

<!-- EGRESS-LEDGER-BINDING
hosts: 54
digest: 791065690f06d4b9ee9182f8628c54dd4e30737259e79866b682678121201248
-->

This document is BOUND to the set of hosts declared in the ledger above.
`tests/test_the_egress_inventory_still_describes_the_software.py` recomputes
that set and goes red when it drifts, so a release that adds an outbound
destination cannot quietly leave this page describing software that no longer
exists. The binding covers the host SET, not the file's bytes: rewording a
comment is not a change of claim, and a gate that cries at noise gets ignored.
Editing the block below is asserting that the prose here was re-read against
the new destination.

## Why this exists

A cold outside read of the marketing site concluded the privacy claim was
*"a diagram, not a proof"*. That was correct: the estate had no runnable
instrument that observed the network at all.

## The two ways to be wrong, and this document uses both methods

The first draft of this inventory was built from **sampling** alone and was
about half complete. The second pass added a **source sweep**. Neither is
sufficient, and they fail in opposite directions:

| method | what it misses | measured example |
|---|---|---|
| sampling | anything that opens and closes between two samples, which is most of an install | missed ghcr.io, registry.ollama.ai, huggingface.co, Homebrew, PyPI |
| source sweep | nothing, but it over-reports badly: a string that looks like a URL is not a fetch | `schema.ostler.ai` x292 and `www.w3.org` x114 are RDF namespaces, never dereferenced; `www.apple.com` x28 is a plist DTD |

So every row is classified by **call site**: a host counts when it appears
where something opens a socket, not merely where a string appears. The false
positives are listed below rather than quietly dropped, because a reader who
runs the same grep will find them and is entitled to know we did too.

## What the instrument can and cannot say

It samples **established TCP sockets** per process, attributes them by process
**lineage** (a system binary we spawned is ours; the socket-holder's own path
is not the test, or `/usr/bin/curl` would be excluded), and joins each remote
address to hostnames resolved **in the same call on the same box**, because
forward DNS is time-varying: `github.com` resolved to two different addresses
inside one minute on the day of measurement.

It **cannot** see:

- a connection that opens and closes between two samples
- UDP, DNS, or a request proxied by another process
- **the content of anything**

A shared CDN address serves many tenants, so a hostname match means
*consistent with*, never *was*. The "carries" column of the ledger is a claim
by us, not a measurement. This narrows what an unexplained connection could be;
it does not certify what an explained one carried. Stating those limits is the
point: "nothing found" and "nothing looked at" print identically unless the
denominator is on the page.

## The destination families

Boundary: loopback, RFC1918 LAN, link-local, Tailscale CGNAT. Crossing it is
not by itself a finding: the ledger says which crossings are declared, by
hostname where a name can reach the address and by CIDR where it cannot, and a
CIDR row attributes the owner of an address and never the service. Full detail in
the ledger; this is the shape.

| family | when | opt-in | carries something about the customer |
|---|---|---|---|
| GitHub release assets, ghcr.io, PyPI, Homebrew | install, and on upgrade | no | no |
| registry.ollama.ai, huggingface.co | install, and on model pull | no | no |
| ostler.ai (licence + updates) | install, then periodically | no | licence ID and machine fingerprint only |
| Tailscale control plane, DERP relays | while the tailnet is up | yes, per feature | no, relayed payloads are end-to-end encrypted |
| WhatsApp Web | only with the connector on | yes, off by default | it IS the customer's WhatsApp session |
| public-data enrichment (~20 hosts) | during and after ingest | no, and see below | **yes** |

## The WhatsApp connector: settled, and the consent wording is wrong

`ostler-assistant` held a TLS session to `57.144.97.32:443`. Settled from the
code path and the box, not by reasoning:

- the shipped binary contains `wa-rs` x83 and the WhatsApp Web hostnames
  (control: a nonsense string returns 0, `zeroclaw` returns 723)
- the config sets `session_path` and `pair_phone` and no `phone_number_id`, so
  `backend_type()` selects **web**, not the Cloud API
- the log carries 20 timestamped `zeroclaw_channels::whatsapp_web` lines
  issuing QR codes and pair codes, which are issued **by WhatsApp's servers**
- `mmg.whatsapp.net` resolves to exactly `57.144.97.32` from that box

The operator's own WhatsApp.app holds a **different** socket,
`57.144.97.33:5222` under its own PID. Two sessions, not one. An earlier draft
of this document explained the daemon's socket as a consequence of the
operator's own app being linked. That was reasoning rather than measurement and
it was wrong.

Zero-shape checked before any of that was written down: the binary CAN emit
`connected successfully`, `giving up` and `reconnecting in`. The log emits none
of them, so "the link never completed" is a real zero rather than an
uninterpretable one.

**The consequence for the consent wording.** It says Ostler reads

> "WhatsApp Web's storage on your Mac"

It does not. It registers **its own linked device** in the customer's WhatsApp
account and holds its own authenticated session with WhatsApp. That consumes a
Linked Devices slot and appears in their WhatsApp app as a device. The
ToS-risk paragraph in the consent is accurate and unusually frank; the
**mechanism** sentence is incomplete, and incomplete in the direction that
flatters us. Tracked as #741 and it must be corrected before anyone is invited
to check our claims.

`Nothing is sent to us` remains **true** and stays as it is: it is bounded by
its object, Creative Machines, and that bound holds.

## The family that puts the claim under real pressure

`install.sh:24246` (ostler-enrich-tick) and `install.sh:22271` (ostler-import) run
`services.enrich.src.cli enrich` (was `install.sh:13217` when this was written). Roughly twenty
public-data clients ship under
`vendor/cm019_preferences/services/enrich/src/clients/`, sharing an
`httpx.AsyncClient` built in `clients/base.py:141`.

Seven are key-gated and inert on a stock install with no key set: TMDB,
YouTube, Google Places, PodcastIndex, Semantic Scholar, Foursquare,
Spoonacular, plus the Ticketmaster/Eventbrite pair. **The rest are live by
default:** Wikidata, MusicBrainz, OpenLibrary, OpenFoodFacts, Crossref,
Nominatim/OpenStreetMap, the UPC databases, Amazon ASIN lookup and LinkedIn.

These queries are not telemetry and they are not our servers. But the
**subject** of each query is drawn from the customer's own data: the artist
they listen to, the book they are reading, the restaurant they went to, the
company someone in their contacts works for. A request to a third party whose
query string came from a customer's graph is something about them leaving the
Mac, whatever we intended by it.

The installer copy does disclose this, and names Wikidata:

> public-data queries (Wikidata for enrichment, local web search via ...)

Naming one of nine is not the same as disclosing nine.

**This is where the bounded claim has to be defended rather than asserted, and
it is not finished.** Before publication we owe:

1. a **measured** run: which clients actually fire on a stock install with a
   real preference set, and what the query strings contain. Reading the source
   tells us what CAN happen. It is the same distinction that made the first
   draft of this document wrong.
2. a decision, which is Andy's and not an engineering call: enrichment on by
   default, opt-in, or on with the destination list on screen at the moment of
   consent.
3. whatever (2) decides, the copy has to match it exactly.

Tracked as #742.

## Delta since 2026-09-18 and 2026-10-15 (SOURCE-read, not measured)

Verbs: ADDS a destination, GATES one that already exists, REMOVES, or NONE.

| change | state | effect on egress |
|---|---|---|
| CM051 #2912 `_public_lookups_agreed` (`install.sh:24153`), enrich CLI backstop `cli.py:69,562,1121` | merged 2026-10-15 | GATES Wikidata, MusicBrainz, OpenLibrary and the bookmark fetcher on a recorded `OSTLER_CONSENT_ENRICHMENT_DECISION=accepted`; question defaults to no (`install.sh:12754`). Still ungated: `enrich normalize` (no `require_public_lookup_consent` call between `cli.py:562` and `:1121`; 0 shipped callers) |
| consent copy names the set (`install.sh:1330-1346`, `:12793-12799`, `install.sh.strings.en-GB.sh:1340`) | merged | NONE; it makes the first run-section copy requirement checkable |
| oa #594 read-only tool allowlist for scheduled jobs | merged | GATES: cron agent runs cannot call network tools outside the list (`crates/zeroclaw-runtime/src/cron/tool_policy.rs`) |
| oa #597 `web_fetch` only on an owner-typed URL, `http_request` always asks | merged | GATES the two any-host tools (`egress_gate.rs:49-65`). Does NOT cover `weather` (below) |
| oa #599 app chat gets the same gate | merged | GATES the app-chat path (`crates/zeroclaw-gateway/src/ws.rs`) |
| oa #602 gate `web_search_tool` and `browser*` by owner text | OPEN, approved | GATES the search path (`egress_gate.rs:55`, tool name `web_search_tool` matches `web_search_tool.rs:592`). Stock search is the local Vane container; its public-engine fan-out is NOT INSTRUMENTED (engine list not read) |
| CM059 #32, #33, #34 | merged | GATES: watched and listened titles are never L1 and external scouts check `OSTLER_CONSENT_ENRICHMENT_DECISION` (`compiler/scouts.py:78-110`). ADDS nothing: the scouts ship no HTTP client (`compiler/scout_external.py:10`, `fetcher=None`). `vendor/cm059_editor` in CM051 is STALE: `grep public_lookups_agreed` returns 0 there (control: `scout` matches), so this gate is not in any CM051 artefact yet |
| HR015 #1177 / CM051 #3058 streaming_history | OPEN | ADDS no host. It reads local browser history; it widens the SUBJECTS that can reach the already-declared enrichment hosts (film, show and artist titles), which is why CM059 #32 matters. No urlopen or host literal in the PR |
| CM051 #2977 Ollama pinned from the official release | merged | github.com (declared). The release redirect target host was NOT MEASURED; `github-releases.githubusercontent.com` and `objects.githubusercontent.com` are declared, a newer GitHub asset host would show as UNATTRIBUTED |
| Tailscale sign-in (CM051 `6deba3ca`) | merged | NONE: `login.tailscale.com` already declared |
| call history, Spotify live | NOT FOUND | no open or merged PR, and no `api.spotify.com` or `accounts.spotify.com` in this tree (grep, rc 1; control: grep for `api.themoviedb.org` hits). If it exists on a branch, it ADDS Spotify hosts and needs a row |

## The assistant daemon: the 2026-10-15 gap, closed from source

`ostler-assistant` is now READ, from ostler-ai/ostler-assistant origin/main
bb43a2db (paths relative to that repo; 805 Rust files, 111 of them mention
`reqwest`). Source reading says what CAN happen on a stock
install. It does not say what DID, and no daemon socket was sampled.

**SURPRISING, undeclared until this revision:**

- `wttr.in`: the `weather` tool is registered unconditionally
  (`crates/zeroclaw-runtime/src/tools/mod.rs:392`), builds
  `https://wttr.in/<location>` from a model-chosen string
  (`crates/zeroclaw-tools/src/weather_tool.rs:14,142-145`), is absent from
  the installer's `non_cli_excluded_tools` (`install.sh:17808`) and from
  the egress gate (`egress_gate.rs:49`). A chat turn can send a location with no
  prompt. Fix is one word in the exclusion list or one line in `EGRESS_TOOLS`.
- `appcast.ostler.ai`: named in code (`crates/zeroclaw-gateway/src/invites_proxy.rs:39`)
  and the installer but the ledger held only `ostler.ai`.
- `api.github.com` for `zeroclaw-labs/zeroclaw` (`src/commands/update.rs:8-10`):
  the UPSTREAM project, manual `update` subcommand only (`src/main.rs:2608,2619`).

| destination | where | stock install | status |
|---|---|---|---|
| any host (`web_fetch`, `http_request`) | `schema.rs:3014-3015`, `2891-2892`; tools registered `tools/mod.rs:491,501` | enabled, `allowed_domains = ["*"]` | gated by #597 |
| local Vane, then public engines | `web_search_tool.rs:639`, `schema.rs:3307`, `install.sh:17598` | on, loopback to the container | engines NOT INSTRUMENTED; #602 open |
| `wttr.in` | above | on | UNDECLARED, ungated |
| `appcast.ostler.ai` | `invites_proxy.rs:39` | on | now declared |
| `api.github.com` | `update.rs:8` | manual command | now declared |
| `api.open-meteo.com`, `ipapi.co` | `brief/weather.rs:291,196` | library only | DEAD CODE: `resolve_location` and `fetch_weather` have no caller outside `weather.rs` |
| `browser`, `browser_open` | `schema.rs:2847` enabled | chat excludes them (`install.sh:17808`); CLI does not | #602 gates |
| brave, duckduckgo, searxng search | `web_search_tool.rs:637-639` | no (provider is vane) | config-gated |
| firecrawl | `schema.rs:2991` | no | config-gated |
| notion, jira, linkedin, image_gen, microsoft365, composio | `schema.rs:9528,9594,3749,4112,2713,2643` | no | all `enabled = false` |
| WhatsApp | `whatsapp_web.rs` | opt-in | declared above |
| other chat connectors (telegram, slack, discord, matrix, bluesky, ...) | compiled in | installer writes only imessage, email, apple_mail, whatsapp (`install.sh:17256-17397`) | unreachable without config |
| model providers | `install.sh` provider block | localhost:11434 | none |

Not read: `crates/zeroclaw-hardware`, `robot-kit`, `zeroclaw-plugins`, the TUI
onboarding links, and the per-site default of `hooks.webhook_audit`
(`webhook_audit.rs:316` posts to a configured URL; its default is unverified).

## What "the measured run" requires, and whether it can be done now

The doc above sets three owed items (the section on enrichment, items 1-3):

1. a MEASURED run on a stock install with a real preference set: which clients
   fire, and what the query strings contain;
2. Andy's decision on default, opt-in, or on with the list on screen;
3. copy that matches the decision exactly.

State on 2026-10-21: (2) is implemented as opt-in, default no
(`install.sh:12754`, `:24153`), pending Andy confirming that is the decision.
(3) is checkable: the consent names Wikidata, MusicBrainz, OpenLibrary and
bookmarks, which is the measured-LIVE set above. (1) is NOT done, and one half
of it has no instrument: sockets name HOSTS, and a TLS socket never shows a
query string. **Query content is NOT INSTRUMENTED** (command that would show it:
a TLS-terminating proxy on the enrich process only, or a client-side request
log; neither exists in `tools/egress`).

It can now be done for hosts, because the gate exists to give a clean decline
baseline. It cannot be done for content without building that instrument. It
also needs a build containing 7d211203; whether any cut contains it was not
checked.

### Plan (NOT run)

On a cold walk box, Mini only, never a customer or the Studio:

1. Record `df -h /`, the build version, and `git log` SHA of the DMG's vendor tree.
   Confirm the gate is present: `grep -c public_lookups_agreed` on the installed
   `ostler-import` (must be at least 1; 0 means stop).
2. Fixture: synthetic exports only (a music history, a reading list, a film
   list, a places list, three bookmarks to a host we run). Run
   `tools/egress/cats.py` to record the category histogram.
3. Run A, DECLINE: install answering no to `consent_enrichment`. Assert
   `OSTLER_CONSENT_ENRICHMENT_DECISION` is not `accepted`, `com.ostler.enrich` is not
   installed, and that no `ostler-import` run contacts an enrichment host. Sample with
   `no_unexpected_egress.sh` for the whole import. Control: the same probe, same
   box, with one `curl https://www.wikidata.org` fired by hand, MUST report it.
4. Run B, ACCEPT: re-run the installer answering yes. Drop the fixture, run one
   enrich tick. Sample with the probe at its shortest interval for the whole run.
   Record every declared enrichment host that appears and every one that does not.
5. Compare with the constructed set (Brand, Event, Foursquare, MusicBrainz,
   OpenLibrary, Places, PodcastIndex, TMDB, URLFetcher, Wikidata, YouTube). Any host
   outside the ledger is an UNATTRIBUTED finding and blocks.
6. Content: build or choose the instrument first (see above). Without it, state
   "query content NOT INSTRUMENTED" in the run record rather than a number.
7. Run `tools/egress/enrichcheck.py` after B for what enrichment WROTE. This is
   payloads written, not payloads sent, and is labelled as such.
8. Daemon: with the stock config, ask the assistant for the weather and for a
   search; sample `ostler-assistant` sockets with the probe. Expect `wttr.in`
   until the exclusion fix lands, and the Vane fan-out for search.
9. Update the `Measured on ... vX.Y.Z, DATE` line, flip each SOURCE tag to
   MEASURED or CANNOT-RUN, and bump the binding block.

Bounds that stay on the page: the probe misses connections that open and close
between samples, UDP, DNS and proxied requests, and reads no content.

## The false positives, listed rather than dropped

A reader running the obvious grep will hit these. They are strings, not fetches.

| string | count | what it actually is |
|---|---|---|
| `schema.ostler.ai` | 292 in CM051 | RDF namespace URI. An identifier, never dereferenced by our code. Verified: all occurrences are prefix declarations or R2RML templates, none passed to an HTTP client. This row previously named an unregistered third-party domain; #743 moved every identifier onto a host we own, and the gate that counted them is now a hard floor at zero |
| `urn:ostler:` | 192 in CM051 | URN identifiers for preferences, todos, conversations and named graphs. Non-dereferenceable by construction, so they cannot be a fetch under any tooling |
| `www.w3.org` | 92 | RDF/XML and XSD namespace URIs |
| `www.wikidata.org` | 20 | mostly namespace URIs; the enrichment client is the real fetch and has its own row |
| `www.apple.com` | 28 | the `DOCTYPE` string in every plist |
| `xmlns.com`, `semweb.mmlab.be`, `www.apache.org` | 22 | FOAF and licence-header namespaces |
| API documentation links | ~20 | comments pointing at vendor docs, next to clients that have their own rows |

## Honest residue

### One of the two is now explained, and the explanation is in the ledger

`tailscale -> 199.165.136.100:443` was listed here as unattributed from
2026-08-17 until 2026-09-18. It was sustained, and it matched nothing Tailscale
publishes: not the 88-node DERP map, not `log.tailscale.io`, not
`login`/`controlplane`.

It is Ostler's own Tailscale client holding its connection to Tailscale's
control plane on an address that Tailscale's control plane handed it, and that
DNS deliberately does not publish. Tailscale calls this a dial plan: control
gives a client alternative addresses to reach control on, so that a blocked or
hijacked route does not take the tailnet down. Measured on a live install:

* the connection is held by the `tailscaled` this product installs and runs,
  so it is ours to explain and we are not disowning it as a dependency's
* ARIN registers `199.165.136.0/24` to Tailscale Inc., and the org record lists
  exactly four blocks for them, so this is a closed set and not a range that
  grows quietly. Anyone can repeat that query
* the address is in neither DERP map: not the public default one, and not the
  map the client on the box itself holds
* it refuses an ordinary TLS handshake under every name we tried, while the
  identical request to a published control address completes and answers. The
  control-plane transport is Noise, not TLS, which is why no certificate can
  be read from it, by us or by anyone auditing us
* the client's own log records receiving a new dial plan from control, and
  forcing a port 443 dial, in the window the connection was held

**What that lets us say, and what it does not.** The destination is Tailscale's
own network, the purpose is the tailnet that lets your phone reach your Mac,
and the payloads Tailscale relays are end-to-end encrypted and not readable by
Tailscale. We cannot read the session either, so we cannot certify its contents
any more than an auditor could. The ledger now declares these networks by CIDR,
and the instrument reports such a connection in its own bucket, headed OWNER
ATTRIBUTED, SERVICE NOT, so a reader can see how much of the attribution rests
on who owns an address rather than on which service answered.

### Still unattributed

1. `limactl`'s install-phase destinations, which change between samples.

Publishing an inventory with unexplained rows is better than publishing one
that quietly drops them, and better again is going back and explaining one.
This is still not finished, and the enrichment measurement above is the
blocker, not this.

## Verify it yourself

The whole reason for the instrument is that a sceptic should not have to take
our word for it. On any Mac running Ostler:

```
lsof -nP -iTCP -sTCP:ESTABLISHED
```

Every row in the table above is reproducible from that in about ten seconds,
minus the install-phase traffic, which is a one-shot surface: sample it while
the installer runs or not at all.

For a continuous watch rather than a snapshot, **LuLu** (Objective-See) is
free, open source and does the job. We recommend it over Little Snitch for the
simple reason that Little Snitch costs money and nobody should have to buy
software to check ours.
