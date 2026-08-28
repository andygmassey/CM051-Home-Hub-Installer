# Threat model: other user accounts on the same Mac

**Status:** active constraint. Read this before changing anything that binds a
port, writes to a shared path, or probes a local service.

**Raised:** 2026-08-28, after a second unprivileged macOS account read the
owner's knowledge graph on a live install.

---

## The premise that was never written down

`install.sh` contains this, above the wiki tailnet gate:

> The gate is bound to 127.0.0.1:8144 on the host: unreachable off-box except
> through the tunnel, and **a local user on this Mac can already read :8044
> directly, so it adds no local surface.**

That is not an oversight. It is a reasoned decision, it is written down, and it
is **correct under the threat model it was made in**. It was answering a locked
product call — *"my devices means the tailnet, not the LAN"* — and it reasoned
that off-box access requires the tunnel while on-box access is already the
owner's.

Every step of that reasoning is sound. It rests on one premise:

> **A local user is the owner.**

That sentence appears nowhere in the codebase, because nobody had reason to
doubt it. And an assumption that is never stated is an assumption that can
never be reviewed. It could only be challenged by someone who happened to
notice the shape of the decisions it produced.

**It is false on any Mac with more than one user account.** A household Mac. A
shared machine. A customer who adds an account for a partner or a child, a
month after installing, with no action on our part and no warning from us.

---

## Why this produced so many findings at once

These are not separate defects. They are one assumption, observed six times:

| finding | what it looked like | the actual root |
|---|---|---|
| #550 | stores readable from a second account | local == owner |
| #548 | 9 health probes assert liveness, never identity | local == owner |
| #549 | `_check_port` uses an unprivileged `lsof` | local == owner |
| #538 | fixed `/tmp` diagnostic sinks | local == owner |
| #547 | orphaned worker, unowned lifecycle | local == owner |
| 8044 | wiki reasoned as adding "no local surface" | local == owner |

The store-proxy's Host and Origin allowlists are the clearest illustration.
Under the premise, every local process belongs to the owner, so the only
hostile actor able to reach loopback is a **web page in the owner's own
browser** — and Host/Origin allowlisting is exactly the right defence against
that. **The controls were never weak. They were correctly aimed at the only
attacker the model contained.**

This is why patching the instances one at a time is the wrong shape of fix. A
patch list closes the six we found. It does not close the seventh.

---

## The rule

> **A process running as another local user account is not the owner, is not
> trusted, and must not be assumed to be either.**

Concretely, when reviewing or writing code in this repo:

**Binding a port.** A published loopback port is reachable by every local
account. "Bound to 127.0.0.1" is a defence against the *network*, not against
the *machine*. If the service behind it has no credential, publishing it grants
every local account full access.

**Probing a service.** "Something answered on this port" does not mean "my
service answered". On a multi-account Mac the responder may belong to someone
else. A health probe must assert identity, not liveness. See #548.

**Detecting a conflict.** `lsof` is permission-scoped: an unprivileged process
cannot see another user's sockets, so it reports "free" for a port another
account holds. Test the property you care about — attempt the bind and catch
`EADDRINUSE`. See #549.

**Writing a diagnostic or a data file.** A fixed path under `/tmp` is shared,
predictable, and writable-adjacent by other accounts. It is a symlink-squat
target, and a handler that reads back a file it did not write can report a
stranger's session as its own. See #538.

**Serving a browser.** Browsers cannot open Unix sockets. Any surface a
customer opens in a browser must stay on TCP, and therefore cannot be protected
by filesystem permissions. Those surfaces need **authentication**; topology
alone cannot carry them.

---

## What does not count as a fix

Recorded because each of these was proposed during the incident and each was
defeated on inspection:

- **A stated limitation in the docs.** The exposure is silent and the customer
  has no way to observe it.
- **A per-install nonce written into the store.** Defeated by an attacker
  present before install: the token is written into their listener, and they
  echo it back forever.
- **Moving the proxy to the host.** It still needs a published TCP port to
  reach the service, and any TCP port the proxy can reach, a second account can
  reach too.
- **Anything whose green verdict is produced by an identity-blind probe.** It
  will report success against the wrong stack.

---

## How to test a change against this model

From a **second, unprivileged** account on the same Mac, not from the owner's:

1. Attempt a protocol-agnostic TCP connection to every published port. Every
   one must be refused.
2. Re-run the original defect's exact reproduction. It must be refused — not
   an empty result, not a 403, refused.
3. For any browser-facing surface, confirm an unauthenticated request is
   rejected.

Use `--noproxy '*'` on every curl. A local proxy can answer for every host
probed and manufacture a passing result.

---

## Review question

Any change touching ports, shared paths, local probes or local trust must
answer this, in writing, in the PR:

> **What happens if a second user account on this Mac is hostile?**

If the answer is "that cannot happen", say why, and say it where the next
person will read it. That is the sentence whose absence caused all of the
above.
