# Egress inventory — what leaves the Mac, and why

> **STATUS: NOT PUBLISHED. NOT APPROVED FOR PUBLICATION.**
> This is the internal artefact. Publishing anything derived from it needs
> Andy's explicit yes, and is gated on #718. Filed under the rule in
> `feedback_publish_the_discipline_not_the_difficulty_map`.

Measured on a 16 GB M4 Mini running v1.0.33, during and after a first install,
2026-08-17. Instrument: `scripts/box_walk_probes/probes/no_unexpected_egress.sh`.

## Why this exists

A cold outside read of the marketing site concluded the privacy claim was
*"a diagram, not a proof"*. That was correct: the estate had no runnable
instrument that observed the network at all. This is the first reading.

## What the instrument can and cannot say

It samples **established TCP sockets** per process and classifies each remote
address against a declared boundary, joining to hostnames resolved **in the
same call on the same box** so the mapping is contemporaneous.

It **cannot** see:

- a connection that opens and closes between two samples
- UDP, DNS, or a request proxied by another process
- **the content of anything**

A shared CDN address serves many tenants, so a hostname match means
*consistent with*, never *was*. The "carries" column of the ledger is a claim
by us, not a measurement. This narrows what an unexplained connection could be;
it does not certify what an explained one carried.

Stating those limits is the point. "Nothing found" and "nothing looked at"
print identically unless the denominator is on the page.

## The reading

Boundary: loopback, RFC1918 LAN, link-local, Tailscale CGNAT. 27 established
connections on the box; 17 excluded as the operator's own processes (Mail,
WhatsApp.app, Safari, sshd and so on, excluded **by name**, and the exclusion
list is in the source).

| process | destination | attributed to | how |
|---|---|---|---|
| `tailscale` | `192.200.0.115:80` | `controlplane.tailscale.com` | contemporaneous DNS |
| `tailscale` | `205.147.105.30:443` | `derp20c.tailscale.com` (hkg) | live DERP map, fetched in the same call |
| `tailscale` | `199.165.136.100:443` | **UNATTRIBUTED** | matches nothing: not the 88-node DERP map, not `log.tailscale.io`, not `login`/`controlplane` |
| `ostler-assistant` | `57.144.97.32:443` | **Meta Platforms Ireland Limited** (`whois`, netname `FB-BLOCK`) | see below |
| `curl` (install only) | `185.199.109.153/154:443`, `20.205.243.164:443` | GitHub ranges, exact host not pinned | transient, install phase |
| `limactl` (install only) | `208.80.154.224:443`, later `103.102.166.224` | **UNATTRIBUTED** | transient, and more than one destination |

Install-phase traffic is a **one-shot surface**. The `curl` and `limactl`
connections were gone forty minutes later. Steady state can be sampled any
day; the install cannot.

## The finding that matters

`ostler-assistant` — our own signed binary — held a sustained TLS session to
Meta. Traced to the connector rather than guessed:

- `📡 Channels: imessage, whatsapp` in the assistant log: the channel is live
- setup path is `setup channels --interactive whatsapp`, prompting for
  "the WhatsApp app on your phone" — i.e. **WhatsApp Web device linking**
- device linking maintains a session with Meta's servers by construction

The user consented, knowingly, to a connector whose risks are described
unusually well: the wording names Meta Platforms Ireland Ltd, states the
account-suspension risk plainly, defaults to **off**, and bounds "nothing is
sent to **us**" by object to Creative Machines — which remains **true**.

But the mechanism is described as:

> "by reading WhatsApp Web's storage on your Mac"
> "The messages stay on your Mac."

A reader concludes no session with Meta is involved. One is. The data source
description is accurate; the **mechanism** description is incomplete, and the
omission runs in the direction that flatters us.

That is not a leak and it is not dishonesty. It is a sentence that has to be
corrected before anyone is invited to check our claims, because the entire
product rests on sentences like it being exact. Tracked as #741.

## What this changes about the public claim

An unbounded *"nothing ever leaves your Mac"* is **false** and would be
falsified by anyone running Little Snitch for ten minutes. The licence check,
the update feed, Tailscale and the WhatsApp connector all legitimately talk.

The bounded form survives and is what we can defend: **nothing about you** ever
leaves, plus a published inventory of what does and why. Bound by changing the
object, never by adding a qualifier — a qualifier signals there is something
being qualified.

## Honest residue

Two destinations remain unattributed, and neither is noise:

1. `tailscale -> 199.165.136.100:443`, sustained, matching nothing Tailscale
   publishes. A dependency's egress, still ours to explain because we ship it.
2. `limactl`'s install-phase destinations, which change between samples.

Publishing an inventory with unexplained rows is better than publishing one
that quietly drops them. But it is not finished, and it should not be
published in this state.
