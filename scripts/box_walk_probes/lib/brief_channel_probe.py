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
import os
import re
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
NA = "N/A"

DECLARED = [
    "email: v1.0.107 has no 'email' delivery channel; if custom IMAP/SMTP is configured its fields round-tripped into config.toml",
    "whatsapp: if the customer enabled WhatsApp and it resolved as the brief channel, config.toml carries a non-empty recipient",
]


# A recipient is '+' then 7 to 15 digits, country code not 0: E.164. A WhatsApp
# LID ("<15 digits>@lid", or the bare 15 digits of one) is an opaque account
# id, not a dialable number, and must never read as a recipient. phonenumbers is
# deliberately NOT used: it is absent from the shipped python and, where present,
# rejects the Ofcom drama range (+44 7700 900xxx) every synthetic walk uses.
_E164 = re.compile(r"^\+[1-9][0-9]{6,14}$")


# Total digit count (country code included) a dialable number may have, by
# country code, for the codes a walk or a customer is likely to use. A '+' then
# 15 digits fits the generic E.164 bound but no listed code allows it, which is
# the shape of a WhatsApp LID. An unlisted code is capped at 14 digits: every
# live plan we know of for a code outside the table is shorter, and 15 is the
# LID length.
_LEN_BY_CC = {
    "1": (11, 11),    # NANP
    "44": (11, 12),   # UK
    "61": (11, 11),   # Australia
    "49": (10, 14),   # Germany
    "33": (11, 11),   # France
    "34": (11, 11),   # Spain
    "39": (10, 13),   # Italy
    "852": (11, 11),  # Hong Kong
    "86": (13, 13),   # China
    "91": (12, 12),   # India
    "81": (11, 12),   # Japan
    "65": (10, 10),   # Singapore
}
_DEFAULT_LEN = (7, 14)


def _length_ok(number):
    digits = number[1:]
    for cc_len in (3, 2, 1):
        cc = digits[:cc_len]
        if cc in _LEN_BY_CC:
            lo, hi = _LEN_BY_CC[cc]
            return lo <= len(digits) <= hi
    lo, hi = _DEFAULT_LEN
    return lo <= len(digits) <= hi


def _has_number(v):
    """allowed_numbers is written as a one-line TOML array of quoted strings;
    true when at least one item is a strict E.164 number. A bare `[]`, `[""]`,
    digits without '+', or an '@lid' shape is not a number."""
    items = re.findall(r'"([^"]*)"', v if isinstance(v, str) else "")
    return any(_E164.match(i) and "@" not in i and _length_ok(i) for i in items)


WRITER_ROW = "install.sh's own channel writer, run off-box with answer 5 and a synthetic number (no daemon, no network): [channels.whatsapp] carries session_path and an E.164 allowed_numbers"


def judge_writer(wcfg):
    """Judge a config.toml generated by install.sh's real writer. Not a box
    measurement, so it is never counted as the box's WhatsApp arm."""
    if wcfg is None:
        return (WRITER_ROW, None, "NOT MEASURED: the writer could not be run off-box")
    wa = wcfg.get("channels_whatsapp") or {}
    if not wa.get("enabled"):
        return (WRITER_ROW, False, "the writer emitted no enabled [channels.whatsapp] for answer 5")
    if not _has_number(wa.get("allowed_numbers")):
        return (WRITER_ROW, False, "the writer wrote no E.164 allowed_numbers for answer 5 (dm_policy allowlist would deny every inbound message)")
    if not wa.get("session_path"):
        return (WRITER_ROW, False, "the writer wrote no session_path for answer 5")
    return (WRITER_ROW, True, "OFF-BOX: the shipped writer emits enabled, session_path and an E.164 allowed_numbers; nothing was enabled or paired on this box")


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
            # NOT APPLICABLE, not "not measured": nothing was enabled, so there is
            # no field that could have failed to round-trip. Counting this as
            # CANNOT made the whole probe CANNOT-RUN on every box that does not
            # use custom IMAP, i.e. every walk box (v1.0.115). The guard below
            # (_nothing_measured) keeps a box where NOTHING was examined from
            # passing on N/A rows alone.
            add(DECLARED[0], NA, "N/A: this box's install did not enable a custom-IMAP/SMTP email channel (Apple-Mail-only, or email channel disabled) -- nothing to round-trip")
        elif not email_cfg.get("smtp_host"):
            add(DECLARED[0], False, "[channels.email] is enabled but smtp_host is empty -- the wizard's SMTP prompt did not reach the file")
        else:
            add(DECLARED[0], True, "[channels.email] enabled, smtp_host={} smtp_port={}; NOT evidence the daemon can send through it, only that the captured fields are present".format(email_cfg.get("smtp_host"), email_cfg.get("smtp_port")))

    wa_cfg = cfg.get("channels_whatsapp") or {}
    wa_jobs = [j for j in jobs if j.get("delivery_channel") == "whatsapp"]
    wa_has_number = _has_number(wa_cfg.get("allowed_numbers"))
    if not wa_cfg.get("enabled"):
        add(DECLARED[1], None, "NOT MEASURED: this box's install did not enable the WhatsApp channel")
    elif wa_jobs:
        if any(not j.get("delivery_to") for j in wa_jobs):
            add(DECLARED[1], False, "WhatsApp resolved as the brief channel but at least one cron job's delivery.to is empty -- a customer who enabled WhatsApp would get silent non-delivery (#446/CX-68 shape)")
        else:
            add(DECLARED[1], True, "{} cron job(s) resolved delivery.channel=whatsapp with a non-empty recipient; actual WhatsApp Web dispatch is NOT measured (no readiness API in this repo, no paired session on a fresh walk box)".format(len(wa_jobs)))
    elif not wa_has_number and not jobs:
        add(DECLARED[1], None, "NOT MEASURED: WhatsApp is enabled but no brief channel resolved at all and no recipient was written")
    elif not wa_has_number:
        add(DECLARED[1], False, "WhatsApp is enabled but [channels.whatsapp] carries no allowed_numbers: dm_policy defaults to allowlist, so every inbound message, including the customer's replies, would be denied")
    elif not wa_cfg.get("session_path"):
        add(DECLARED[1], False, "WhatsApp is enabled with a recipient but [channels.whatsapp] has no session_path: the daemon reports it 'enabled but not configured'")
    else:
        # iMessage is FIRST when both are available (install.sh, "iMessage stays
        # FIRST"), so a customer with both gets no whatsapp cron job and the
        # WhatsApp path is configured by [channels.whatsapp] alone. Measured
        # here: the recipient install.sh captured was WRITTEN, with a session_path.
        add(DECLARED[1], True, "[channels.whatsapp] enabled with session_path and a non-empty allowed_numbers recipient (another channel took the brief, so no whatsapp cron job is expected); actual WhatsApp Web dispatch is NOT measured (no paired session on a fresh walk box)")

    if "writer_config" in f:
        out.append(judge_writer(f["writer_config"]))

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


def generate_writer_config(install_sh):
    """parse_config of what install.sh's real writer emits for answer 5, or None
    when it could not be run (reason on stderr)."""
    import subprocess
    gen = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_whatsapp_config.sh")
    r = subprocess.run(["bash", gen, install_sh], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        return None
    return parse_config(r.stdout)


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


# The shape a walk box gets when walk_drive answers channel_choice=5: iMessage
# AND WhatsApp enabled, no custom IMAP. iMessage takes the brief, so there is
# no whatsapp cron job; the WhatsApp path is [channels.whatsapp] alone.
_WALK_BOX_TOML = """
[channels.imessage]
enabled = true
allowed_contacts = ["PHONEPLACEHOLDER"]

[channels.apple_mail]
enabled = true

[channels.whatsapp]
enabled = true
mode = "personal"
session_path = "/tmp/ostler-synthetic/state/whatsapp-session.db"
allowed_numbers = ["PHONEPLACEHOLDER"]

[[cron.jobs]]
id = "morning-brief"
delivery = { mode = "announce", channel = "imessage", to = "PHONEPLACEHOLDER", best_effort = false }
""".replace("PHONEPLACEHOLDER", _SYNTH_WA_NUMBER)

_WALK_BOX_NO_RECIPIENT_TOML = _WALK_BOX_TOML.replace('allowed_numbers = ["' + _SYNTH_WA_NUMBER + '"]', 'allowed_numbers = []')
_WALK_BOX_NO_SESSION_TOML = _WALK_BOX_TOML.replace('session_path = "/tmp/ostler-synthetic/state/whatsapp-session.db"\n', "")
_WALK_BOX_WHATSAPP_OFF_TOML = _WALK_BOX_TOML.replace("[channels.whatsapp]\nenabled = true", "[channels.whatsapp]\nenabled = false")


# A LID-shaped value, composed from parts so no 15-digit literal sits in source
# (pii-scan shape guard). Opaque account id, never a dialable number.
_LID_DIGITS = "12345" * 3


def _repo_install_sh():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "..", "install.sh"))


def self_test():
    import copy
    import tempfile
    fails = []
    mutants = [0]   # negative controls that were run AND caught, counted, not claimed

    def caught(label):
        mutants[0] += 1
        print("  ok    mutant caught: {}".format(label))

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
        caught("whatsapp resolved with an empty recipient")

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
        caught("a delivery.channel of 'email' that should not exist in this build")

    unreadable = {"config": None}
    if [ok for n, ok, _ in judge(unreadable) if n in DECLARED and ok is not None]:
        fails.append("an unreadable config should read CANNOT-RUN for both arms")
    else:
        caught("an unreadable config.toml is CANNOT-RUN for both arms, never a pass")

    walk = {"config": parse_config(_WALK_BOX_TOML)}
    if row(walk, 1) != [True] or row(walk, 0) != [NA]:
        fails.append("the walk-box shape (iMessage first, WhatsApp configured, no custom IMAP) should be whatsapp ok + email N/A, got {} / {}".format(row(walk, 1), row(walk, 0)))
    elif report_rc(judge(walk)) != EX_PASS:
        fails.append("the walk-box shape should be a PASS overall")
    else:
        print("  ok    config shape (iMessage first, WhatsApp written, no custom IMAP): PASS, email N/A")

    for label, toml in (("no recipient written", _WALK_BOX_NO_RECIPIENT_TOML), ("no session_path", _WALK_BOX_NO_SESSION_TOML)):
        if row({"config": parse_config(toml)}, 1) != [False]:
            fails.append("config mutant '{}' not caught: {}".format(label, row({"config": parse_config(toml)}, 1)))
        else:
            caught("WhatsApp config with {}".format(label))

    off = judge({"config": parse_config(_WALK_BOX_WHATSAPP_OFF_TOML)})
    if report_rc(off) != EX_CANNOT or [ok for n, ok, _ in off if n == DECLARED[1]] != [None]:
        fails.append("walk34 shape (WhatsApp off, no custom IMAP) must report the WhatsApp arm CANNOT and the box CANNOT-RUN, got rc {}".format(report_rc(off)))
    else:
        print("  ok    WhatsApp off + no custom IMAP (the walk34 shape): WhatsApp arm CANNOT, box CANNOT-RUN, never a pass")

    # _has_number: strict E.164 with '+', LID shapes rejected. RED cases first.
    # Composed from parts (pii-scan shape guard); GREEN is the Ofcom drama range.
    green_gb = "+44" + "7700" + "900123"
    for label, val in (("bare 15-digit LID digits", '["' + "9" * 15 + '"]'),
                       ("LID with @lid suffix", '["' + _LID_DIGITS + '@lid"]'),
                       ("'+' LID with @lid suffix", '["+' + _LID_DIGITS + '@lid"]'),
                       ("E.164 digits without '+'", '["' + green_gb[1:] + '"]'),
                       ("too short after '+'", '["+12345"]'),
                       ("'+' then 15 digits (LID-shaped, +1 cannot be that long)", '["+1' + "0" * 13 + '1"]'),
                       ("'+' then 15 digits under an unlisted country code", '["+' + "7" * 15 + '"]'),
                       ("empty list", "[]"),
                       ("empty string item", '[""]')):
        if _has_number(val):
            fails.append("_has_number accepted {}".format(label))
        else:
            caught("_has_number rejects {}".format(label))
    if not _has_number('["' + green_gb + '"]'):
        fails.append("_has_number rejected a valid synthetic +44 7700 900xxx number")
    else:
        print("  ok    _has_number accepts a valid synthetic +44 7700 900xxx number (GREEN)")

    # THE REAL WRITER, OFF-BOX. install.sh's own channel writer is run in a temp
    # HOME with answer 5 and a synthetic number; the probe judges THAT file.
    install_sh = _repo_install_sh()
    wcfg = generate_writer_config(install_sh)
    if wcfg is None:
        fails.append("could not run install.sh's channel writer off-box at {}".format(install_sh))
    else:
        wrow = judge_writer(wcfg)
        if wrow[1] is not True:
            fails.append("the real writer's answer-5 config does not pass: {}".format(wrow[2]))
        else:
            print("  ok    real writer (off-box, answer 5, synthetic number): enabled, session_path, E.164 allowed_numbers")
        for label, key, val in (("no allowed_numbers", "allowed_numbers", None),
                                ("no session_path", "session_path", None),
                                ("a LID as the recipient", "allowed_numbers", '["' + _LID_DIGITS + '@lid"]'),
                                ("bare LID digits as the recipient", "allowed_numbers", '["' + "9" * 15 + '"]')):
            m = copy.deepcopy(wcfg)
            if val is None:
                m["channels_whatsapp"].pop(key, None)
            else:
                m["channels_whatsapp"][key] = val
            if judge_writer(m)[1] is not False:
                fails.append("generated-config mutant '{}' not caught".format(label))
            else:
                caught("generated config with {}".format(label))
        # Writer-level mutant: delete the allowed_numbers echo from a COPY of
        # install.sh and re-run the real generator. The probe must go red.
        try:
            src = open(install_sh, encoding="utf-8").read()
            marker = 'echo "allowed_numbers = [\\"${_wa_recipient_esc}\\"]"'
            if marker not in src:
                fails.append("writer mutant could not be built: the allowed_numbers echo was not found in install.sh")
            else:
                with tempfile.TemporaryDirectory() as td:
                    mp = os.path.join(td, "install.sh")
                    with open(mp, "w", encoding="utf-8") as fh:
                        fh.write(src.replace(marker, ":", 1))
                    mw = generate_writer_config(mp)
                if mw is None or judge_writer(mw)[1] is not False:
                    fails.append("a writer that no longer emits allowed_numbers was not caught")
                else:
                    caught("install.sh's writer edited to stop emitting allowed_numbers")
        except IOError as exc:
            fails.append("writer mutant could not read install.sh: {}".format(exc))

    if [ok for n, ok, _ in judge({"config": None}) if n in DECLARED and ok is True]:
        fails.append("an empty collection reads as a pass")
    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return EX_FAIL
    print("SELF-TEST PASS: good fixtures pass, {} mutants caught by their own assertion".format(mutants[0]))
    return EX_PASS


def report_rc(rows):
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    measured = [n for n, ok, _ in rows if ok is True and n in DECLARED]
    # N/A rows are not evidence. A box where no declared assertion held, and none
    # failed, examined nothing: that is CANNOT-RUN, never a pass on N/A alone.
    if not fails and not measured:
        return EX_CANNOT
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


def report(rows):
    for name, ok, detail in rows:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok is True or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} brief-channel assertions ({} failed, {} not measured)".format(len(rows), len(fails), len(cannot)))
    return report_rc(rows)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        facts = json.load(open(argv[1]))
        if argv[2:3] == ["--install-sh"]:
            facts["writer_config"] = generate_writer_config(argv[3])
        return report(judge(facts))
    if argv[:1] == ["box"]:
        return box_main(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
