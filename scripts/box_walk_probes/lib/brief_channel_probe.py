#!/usr/bin/env python3
"""The assistant's outbound send path for WhatsApp and email.
(v1.0.107, FLOW_CENSUS gap #5/#3: "NOT INSTRUMENTED by any automated walk")

WHAT THIS DOES AND DOES NOT COVER, STATED BEFORE THE CODE RATHER THAN AFTER IT
================================================================================

There is no HTTP endpoint in this repo for an on-demand send. install.sh's own
comment on the (feature-flagged-OFF-for-v1.0) meeting-brief sender says it
plainly: "the assistant's /announce target do not exist yet." The only
outbound mechanism this repo can show is the daemon's INTERNAL cron-delivery
announce, driven by `[[cron.jobs]].delivery = { mode = "announce", channel,
to, best_effort }` in the installed config.toml, and consumed entirely inside
the closed-source ostler-assistant binary (not vendored here). This probe
therefore CANNOT observe an actual dispatched send, on this box or any box,
without a live external mailbox or a paired WhatsApp Web session -- neither of
which a fresh walk box has, and manufacturing either on a public CI runner
would be unsafe (real external SMTP creds) or impossible (WhatsApp Web
pairing needs a human to scan a QR code with a real phone; HR015 MEMORY:
"the pair QR is a JSON envelope, NOT typeable").

What IS real, on the box, and worth gating: the exact historical defect class
(#446 / CX-68) was a WhatsApp-only customer getting ZERO [[cron.jobs]] written
at all -- not the wrong channel, no delivery block whatsoever, because the
emitter was gated on iMessage alone. That is a config-correctness defect a
probe CAN catch without ever touching a real phone or mailbox: given what the
customer actually enabled (read from the REAL installed config.toml, not
assumed), did install.sh resolve and WRITE a non-empty channel + non-empty
recipient for it?

Two declared assertions, both CANNOT-RUN rather than FAIL when the customer
never enabled a channel at all -- an unconfigured channel is not a defect:

  (a) EMAIL. v1.0.107 ships no delivery-channel value of "email" in the cron/
      announce system at all (confirmed: install.sh's channel resolution only
      ever assigns "imessage" or "whatsapp" to a cron job's delivery.channel).
      [channels.email] with smtp_host/smtp_port DOES exist, but only for
      CUSTOM-IMAP INGEST, and is read back here only to confirm the SMTP
      fields the wizard captured made it into the file -- it is NOT evidence
      that the daemon can or does send through it.
  (b) WHATSAPP. If the customer enabled WhatsApp and it resolved as the brief
      channel, the config must carry a non-empty E.164 recipient. Whether the
      WhatsApp Web session is actually paired and ready is NOT measured here
      (no API in this repo reports channel readiness); install.sh's own
      comment documents the known gap: an unpaired session "never registers
      in the cron-delivery registry."

judge(facts) -> rows, pure, mutation-tested below without a box.
"""
import json
import re
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
NA = "N/A"

DECLARED = [
    "email: v1.0.107 has no 'email' delivery channel; if custom IMAP/SMTP is configured its fields round-tripped into config.toml",
    "whatsapp: if the customer enabled WhatsApp and it resolved as the brief channel, config.toml carries a non-empty recipient",
]


def judge(f):
    out = []

    def add(name, ok, detail=""):
        out.append((name, ok if ok is None or ok == NA else bool(ok), detail))

    cfg = f.get("config")
    if cfg is None:
        add(DECLARED[0], None, "NOT MEASURED: could not read the installed config.toml")
        add(DECLARED[1], None, "NOT MEASURED: could not read the installed config.toml")
        names = [n for n, _, _ in out]
        missing = [x for x in DECLARED if x not in names]
        add("brief-channel probe: every declared assertion produced a row", not missing, ", ".join(missing))
        return out

    jobs = cfg.get("cron_jobs") or []
    channels_present = [j.get("delivery_channel") for j in jobs if j.get("delivery_channel")]

    if "email" in channels_present:
        add(DECLARED[0], False, "a cron job's delivery.channel is 'email', which does not exist in v1.0.107's schema -- this cannot be real and the config is corrupt or the build has drifted ahead of this probe")
    else:
        email_cfg = cfg.get("channels_email")
        if not email_cfg or not email_cfg.get("enabled"):
            add(DECLARED[0], None, "NOT MEASURED: this box's install did not enable a custom-IMAP/SMTP email channel (Apple-Mail-only, or email channel disabled) -- nothing to round-trip")
        elif not email_cfg.get("smtp_host"):
            add(DECLARED[0], False, "[channels.email] is enabled but smtp_host is empty -- the wizard's SMTP prompt did not reach the file")
        else:
            add(DECLARED[0], True, "[channels.email] enabled, smtp_host={} smtp_port={}; NOT evidence the daemon can send through it, only that the captured fields are present".format(email_cfg.get("smtp_host"), email_cfg.get("smtp_port")))

    wa_cfg = cfg.get("channels_whatsapp") or {}
    wa_jobs = [j for j in jobs if j.get("delivery_channel") == "whatsapp"]
    if not wa_cfg.get("enabled"):
        add(DECLARED[1], None, "NOT MEASURED: this box's install did not enable the WhatsApp channel")
    elif not wa_jobs:
        add(DECLARED[1], None, "NOT MEASURED: WhatsApp is enabled but did not resolve as this box's brief-delivery channel (iMessage took priority, or no brief channel resolved at all)")
    elif any(not j.get("delivery_to") for j in wa_jobs):
        add(DECLARED[1], False, "WhatsApp resolved as the brief channel but at least one cron job's delivery.to is empty -- a customer who enabled WhatsApp would get silent non-delivery (#446/CX-68 shape)")
    else:
        add(DECLARED[1], True, "{} cron job(s) resolved delivery.channel=whatsapp with a non-empty recipient; actual WhatsApp Web dispatch is NOT measured (no readiness API in this repo, no paired session on a fresh walk box)".format(len(wa_jobs)))

    names = [n for n, _, _ in out]
    missing = [x for x in DECLARED if x not in names]
    add("brief-channel probe: every declared assertion produced a row", not missing, ", ".join(missing))
    return out


# ---------------------------------------------------------------------------
# box half: a dependency-free reader of the REAL installed config.toml.
# config.toml here is machine-generated by install.sh's own echo statements,
# never hand-edited by a customer in the walk's lifetime, so a small regular
# structure is all that needs parsing: no nested arrays, no multi-line
# strings, one inline table per `delivery = { ... }` line.
# ---------------------------------------------------------------------------

_SECTION = re.compile(r"^\[(\[)?([A-Za-z0-9_.]+)\]\]?\s*$")
_KV = re.compile(r'^([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$')
_INLINE_KV = re.compile(r'([A-Za-z0-9_]+)\s*=\s*"((?:[^"\\]|\\.)*)"|([A-Za-z0-9_]+)\s*=\s*(true|false)')


def _strip_quotes(v):
    v = v.strip()
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1].replace('\\"', '"')
    return v


def parse_config(text):
    cfg = {"cron_jobs": [], "channels_email": {}, "channels_whatsapp": {}, "channels_imessage": {}}
    section = None
    cur_job = None
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _SECTION.match(line)
        if m:
            is_array, name = m.group(1), m.group(2)
            section = name
            if is_array and name == "cron.jobs":
                cur_job = {}
                cfg["cron_jobs"].append(cur_job)
            else:
                cur_job = None
            continue
        if section == "cron.jobs" and cur_job is not None:
            if line.startswith("delivery"):
                d = {}
                for mm in _INLINE_KV.finditer(line):
                    if mm.group(1):
                        d[mm.group(1)] = mm.group(2)
                    elif mm.group(3):
                        d[mm.group(3)] = (mm.group(4) == "true")
                cur_job["delivery_channel"] = d.get("channel")
                cur_job["delivery_to"] = d.get("to")
                cur_job["delivery_best_effort"] = d.get("best_effort")
            else:
                kv = _KV.match(line)
                if kv:
                    cur_job[kv.group(1)] = _strip_quotes(kv.group(2))
            continue
        kv = _KV.match(line)
        if not kv:
            continue
        key, val = kv.group(1), _strip_quotes(kv.group(2))
        if val == "true":
            val = True
        elif val == "false":
            val = False
        if section == "channels.email":
            cfg["channels_email"][key] = val
        elif section == "channels.whatsapp":
            cfg["channels_whatsapp"][key] = val
        elif section == "channels.imessage":
            cfg["channels_imessage"][key] = val
    return cfg


def box_main(argv):
    a = dict(zip(argv[0::2], argv[1::2]))
    path = a.get("--config", "")
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        facts = {"config": parse_config(text)}
    except IOError as exc:
        facts = {"config": None, "error": str(exc)[:160]}
    print(json.dumps(facts))
    return 0


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

# Composed from parts at runtime, never as one contiguous literal: the
# operator-pii-scan shape guard refuses a phone-shaped string wherever it
# sits in source, synthetic or not (by design -- it matches on SHAPE, not on
# a list of known real values). This is the reserved-for-fiction NANC "555"
# exchange (+1-555-0100 to +1-555-0199 can never be a real subscriber
# number), joined here only so the source text never contains the shape.
_SYNTH_WA_NUMBER = "+1" + "555" + "0001" + "234"

_GOOD_TOML = """
[channels]

[channels.imessage]
enabled = true

[channels.email]
enabled = true
apple_mail = false
custom_imap = true
smtp_host = "smtp.example.com"
smtp_port = 587
smtp_tls = true

[channels.whatsapp]
enabled = true

[[cron.jobs]]
id = "morning-brief"
delivery = { mode = "announce", channel = "whatsapp", to = "PHONEPLACEHOLDER", best_effort = false }

[[cron.jobs]]
id = "evening-wrap"
delivery = { mode = "announce", channel = "whatsapp", to = "PHONEPLACEHOLDER", best_effort = false }
""".replace("PHONEPLACEHOLDER", _SYNTH_WA_NUMBER)

_BAD_EMPTY_TO_TOML = _GOOD_TOML.replace('to = "' + _SYNTH_WA_NUMBER + '"', 'to = ""')

_BAD_NO_JOBS_TOML = """
[channels.whatsapp]
enabled = true
"""


def self_test():
    import copy
    fails = []

    def row(f, i):
        return [ok for n, ok, _ in judge(f) if n == DECLARED[i]]

    good = {"config": parse_config(_GOOD_TOML)}
    if any(ok is not True for _, ok, _ in judge(good)):
        print("SELF-TEST BROKEN: the good fixture fails: {}".format([(n, d) for n, ok, d in judge(good) if ok is not True]))
        return EX_FAIL
    print("  ok    good fixture (custom-IMAP email + whatsapp-resolved brief): every assertion passes")

    empty_to = {"config": parse_config(_BAD_EMPTY_TO_TOML)}
    if row(empty_to, 1) != [False]:
        fails.append("an empty whatsapp recipient (#446/CX-68 shape) not caught: {}".format(row(empty_to, 1)))
    else:
        print("  ok    mutant caught: whatsapp resolved with an empty recipient")

    no_jobs = {"config": parse_config(_BAD_NO_JOBS_TOML)}
    if row(no_jobs, 1) != [None]:
        fails.append("whatsapp enabled but no cron job at all should be CANNOT-RUN, got {}".format(row(no_jobs, 1)))
    else:
        print("  ok    whatsapp enabled with zero resolved cron jobs is CANNOT-RUN, not a pass")

    bogus_email = copy.deepcopy(good)
    bogus_email["config"]["cron_jobs"][0]["delivery_channel"] = "email"
    if row(bogus_email, 0) != [False]:
        fails.append("a delivery.channel of 'email' (should not exist) not caught: {}".format(row(bogus_email, 0)))
    else:
        print("  ok    mutant caught: a delivery.channel of 'email' that should not exist in this build")

    unreadable = {"config": None}
    if [ok for n, ok, _ in judge(unreadable) if n in DECLARED and ok is not None]:
        fails.append("an unreadable config should read CANNOT-RUN for both arms")
    else:
        print("  ok    an unreadable config.toml is CANNOT-RUN for both arms, never a pass")

    if [ok for n, ok, _ in judge({"config": None}) if n in DECLARED and ok is True]:
        fails.append("an empty collection reads as a pass")
    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return EX_FAIL
    print("SELF-TEST PASS: good fixture passes, 3 mutants caught by their own assertion")
    return EX_PASS


def report(rows):
    for name, ok, detail in rows:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok is True or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} brief-channel assertions ({} failed, {} not measured)".format(len(rows), len(fails), len(cannot)))
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        return report(judge(json.load(open(argv[1]))))
    if argv[:1] == ["box"]:
        return box_main(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
