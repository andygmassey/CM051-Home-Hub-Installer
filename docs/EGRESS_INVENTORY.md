# Egress inventory: what leaves the Mac, and why

> **STATUS: NOT PUBLISHED, and the reason changed on 2026-08-17.**
> Andy approved publication conditional on the inventory being complete. It is
> now materially more complete than the first draft (9 declared destinations to
> 45) and it is not finishable as a document, because the section on
> public-data enrichment needs a MEASURED run before we put a number on it.
> That measurement is the last thing between here and publication.
> Filed under the rule in `feedback_publish_the_discipline_not_the_difficulty_map`.

Instrument: `scripts/box_walk_probes/probes/no_unexpected_egress.sh`.
Ledger: `scripts/box_walk_probes/egress_hosts.tsv`.
Measured on a 16 GB M4 Mini running v1.0.33, 2026-08-17.

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
| source sweep | nothing, but it over-reports badly: a string that looks like a URL is not a fetch | `pwg.dev` x193 and `www.w3.org` x92 are RDF namespaces, never dereferenced; `www.apple.com` x28 is a plist DTD |

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

Boundary: loopback, RFC1918 LAN, link-local, Tailscale CGNAT. Full detail in
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

`install.sh:13217` runs `services.enrich.src.cli enrich --all`. Roughly twenty
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

## The false positives, listed rather than dropped

A reader running the obvious grep will hit these. They are strings, not fetches.

| string | count | what it actually is |
|---|---|---|
| `pwg.dev` | 193 in CM051, 276 across the tree | RDF namespace URI. An identifier, never dereferenced by our code. Verified: all occurrences are prefix declarations or R2RML templates, none passed to an HTTP client. Separately a real problem, because the domain is unregistered: #743, migrating to `schema.ostler.ai` |
| `www.w3.org` | 92 | RDF/XML and XSD namespace URIs |
| `www.wikidata.org` | 20 | mostly namespace URIs; the enrichment client is the real fetch and has its own row |
| `www.apple.com` | 28 | the `DOCTYPE` string in every plist |
| `xmlns.com`, `semweb.mmlab.be`, `www.apache.org` | 22 | FOAF and licence-header namespaces |
| API documentation links | ~20 | comments pointing at vendor docs, next to clients that have their own rows |

## Honest residue

Still unattributed, and neither is noise:

1. `tailscale -> 199.165.136.100:443`, sustained, matching nothing Tailscale
   publishes: not the 88-node DERP map, not `log.tailscale.io`, not
   `login`/`controlplane`. A dependency's egress, still ours to explain because
   we ship it.
2. `limactl`'s install-phase destinations, which change between samples.

Publishing an inventory with unexplained rows is better than publishing one
that quietly drops them. But this is not finished, and the enrichment
measurement above is the blocker, not these two.

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
