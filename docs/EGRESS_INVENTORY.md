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
Measured on a 16 GB M4 Mini running v1.0.33, 2026-08-17. The Tailscale
control-plane row in Honest residue below was re-measured on a live install
on 2026-09-18 and is dated there.

<!-- EGRESS-LEDGER-BINDING
hosts: 54
digest: 64838336bf9209cabbf155dc3508358f7d75579f09b2cc991a5cb367f019d0df
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
| web search (ostler-vane: DuckDuckGo, Brave, Wikipedia) | only when the owner asks a web search | yes, per web-search use | the search query |

## Web search (ostler-vane): three engines, nothing idle

`ostler-vane` bundles SearXNG. The installer writes its own settings
(`vane-searxng-settings.yml`, mounted read-only over `/etc/searxng/settings.yml`)
instead of the image's, which loaded every default engine and Google
autocomplete. Now: three engines (`duckduckgo` to `html.duckduckgo.com`, `brave`
to `search.brave.com`, `wikipedia` to `en.wikipedia.org`), and autocomplete,
the favicon resolver, the image proxy, metrics and the tor-exit-list plugin are
off. Each engine host is a ledger row. SearXNG and Vane run no timer or
startup network check of their own with these engines (read from Vane v1.12.2
and SearXNG source; not measured on a box). `tests/test_vane_searxng_has_no_idle_egress.py`
fails if a feature is switched back on or an engine is added without a row.

What the assistant can send: `web_search_tool` is in the egress gate's tool list
(ostler-assistant `crates/zeroclaw-runtime/src/agent/egress_gate.rs:55`) and
`requires_owner_approval` (`:77-80`, merged in #602, c23e22ca) lets it run
unasked only when every word of the query is a word the owner typed this turn;
an empty query, a non-owner turn or a forwarded message is denied.

Not covered by the above: Vane's own browser UI (reached on `:3000` behind the
credential) fetches a weather lookup, an IP-location lookup and favicons from
the owner's browser when the owner opens it. That is the browser, not the
container, and it is not an assistant path.

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

### `limactl`'s destinations: attributed from the code, 2026-10-21

They were listed here as unattributed because they changed between samples.
The cause is not mysterious and it is not one thing:

* **`limactl` is carrying the VM's traffic, not its own.** colima starts the
  VM with lima's `user-v2` network, which is a userspace network run by a
  `limactl` process. A TCP connection opened by a container inside the VM
  therefore shows on the Mac as a socket owned by `limactl`. What the probe
  saw under `limactl` is what the containers were talking to.
* **The image pulls are all `ghcr.io`.** Every compose image in the installer
  is a `ghcr.io/...@sha256:` digest. Layers are served from a CDN, so the
  addresses differ sample to sample. `ghcr.io` and
  `pkg-containers.githubusercontent.com` were already declared.
* **The Wikimedia address was a missing name.** `208.80.154.224` held by
  `limactl` on 2026-08-17 is `text-lb.eqiad.wikimedia.org`, the front end that
  `en.wikipedia.org` resolves to in some regions (a Hong Kong lookup returns
  `103.102.166.224`, 2026-10-21). The wiki-compiler container looks artists
  and organisations up on Wikipedia, MusicBrainz and OpenStreetMap, but only
  when `OSTLER_PUBLIC_LOOKUPS=agreed`, which the launcher sets from the
  customer's recorded yes. `en.wikipedia.org` and `overpass-api.de` were not
  in the ledger. They are now, and the `musicbrainz.org` and
  `nominatim.openstreetmap.org` rows now say the compiler path is live when
  consented (the host-side enricher for Nominatim is still dead code).
* **The VM image comes from GitHub.** colima's pinned image
  (`abiosoft/colima-core`, sha512-checked) is fetched by colima's own curl
  downloader, so it shows under `curl`, via a redirect to
  `release-assets.githubusercontent.com`, now declared.

What the VM does **not** fetch, read from the generated `lima.yaml` and
colima's embedded image table: no containerd or nerdctl archive
(`containerd.system` and `user` are false), no k3s (Kubernetes is off), no
`apt` in any provision script (Docker is baked into the image), and no
`docker.io` or `registry-1` pull.

Because the probe joins by name resolved in the same loop as the socket read,
none of this needs an IP range. A host that rotates addresses is matched by its
name, so the fix for a `limactl` row is always to declare the name.

**Not settled by reading, and not published as rows:** that a walk box really
uses `user-v2` (the version read was colima 0.10.3; the installer does not pin
colima, so `brew install colima` can change it), and whether the guest sends
NTP over UDP, which a TCP probe cannot see. On a walk box mid-install, run
`lsof -nP -iTCP -sTCP:ESTABLISHED -a -c limactl` and compare each remote's
reverse name with the ledger; if a row there matches nothing declared, that is
a new finding. `ps -ef | grep '[l]imactl usernet'` confirms the carrier.

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
