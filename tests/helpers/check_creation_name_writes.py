#!/usr/bin/env python3
"""v1018-D011 creation-path check, driven by tests/test_creation_name_writes.sh.

THE GAP THIS EXISTS FOR. ``_upsert_display_name`` carries the whole name
rule -- the tier table (v1018-D658) and the kinship refusal (v1018-D659) --
and it is called at all five ingest sources. But it is not the only writer.
Each source ALSO emits a ``pwg:displayName`` triple inside its own
``if not _person_exists(uri)`` creation ``INSERT DATA``, and that write goes
nowhere near the tier. On a FRESH INSTALL nothing exists, so the creation
branch is the branch every customer takes, and the guarded upsert that runs
immediately after can only ever look at a value it has already lost the
argument about:

  * a REFUSED value (a kinship word) is written by the creation INSERT and
    then declined by the upsert, so the refusal changes nothing;
  * a HANDLE written by calendar/photos/mail carries no
    ``displayNameProvisional`` flag, and the tier-2 upgrade guard is
    ``!BOUND(?old) || BOUND(?prov)`` -- with a name bound and no flag, BOTH
    disjuncts are false, so a real name arriving later can never land.

Everything below drives the SHIPPED ``ingest_*`` functions against synthetic
extractor JSON with a stubbed ``_sparql_update``, and asserts on the SPARQL
they actually emit. Reading the module is what missed this in the first
place: the helper exists, the call sites exist, and the defect is in neither.

FIXTURES ARE SYNTHETIC AND MUST STAY THAT WAY (Rule zero). Phone numbers are
from Ofcom's drama-reserved 07700 900xxx range, domains are ``.invalid`` or
``example.com``, and the person names are invented. The one word taken from
life is "Mum", which is a relationship word rather than anybody's name.

Emits one ``PASS: `` / ``FAIL: `` line per assertion. Never a raw traceback.
"""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile

# Synthetic identifiers, all provably fictional.
KIN = "Mum"                              # a relationship, never a name
FACE_NAME = "Wren Ravensworth"           # invented
ATTENDEE_NAME = "Corin Ravensworth"      # invented
MAIL_HANDLE = "c.ravensworth@example.com"
CAL_HANDLE = "d.ravensworth@example.com"
PHONE_A = "+447700900123"                # Ofcom drama range
PHONE_B = "+447700900456"
JID_A = "447700900123@s.whatsapp.net"
JID_B = "447700900456@s.whatsapp.net"


def fail(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


def _stub_optional_deps() -> None:
    """Stand in for third-party packages the ingest imports but this check
    never exercises, so the guard runs on a bare python3.

    Only names that are genuinely unreachable from the creation path are
    stubbed, and each one is imported ONLY if it is actually missing -- a
    machine that has the real package uses the real package.
    """
    import types

    if "nameparser" not in sys.modules:
        try:
            import nameparser  # noqa: F401
        except ImportError:
            stub = types.ModuleType("nameparser")

            class HumanName:  # minimal shape: identifier_quality only reads parts
                def __init__(self, raw=""):
                    parts = (raw or "").split()
                    self.first = parts[0] if parts else ""
                    self.last = parts[-1] if len(parts) > 1 else ""
                    self.middle = " ".join(parts[1:-1])
                    self.title = ""
                    self.suffix = ""

                def __str__(self):
                    return " ".join(p for p in (self.first, self.middle, self.last) if p)

            stub.HumanName = HumanName
            sys.modules["nameparser"] = stub


def load_module(repo: pathlib.Path):
    """Import the SHIPPED vendored package, not a copy of it."""
    vendor = repo / "vendor"
    if not (vendor / "ostler_fda" / "pwg_ingest.py").exists():
        fail(f"shipped module missing under {vendor}")
    _stub_optional_deps()
    sys.path.insert(0, str(vendor))
    try:
        from ostler_fda import pwg_ingest  # type: ignore[import-not-found]
    except Exception as exc:  # noqa: BLE001
        fail(f"cannot import the shipped module: {type(exc).__name__}: {exc}")
    return pwg_ingest


def write_fixtures(d: pathlib.Path) -> None:
    (d / "photos_people.json").write_text(json.dumps([
        {"name": KIN, "photo_count": 9, "first_seen": "2020-01-01T00:00:00+00:00"},
        {"name": FACE_NAME, "photo_count": 4, "first_seen": "2020-01-02T00:00:00+00:00"},
    ]), encoding="utf-8")

    (d / "calendar_events.json").write_text(json.dumps([
        {"title": "Sunday lunch", "start_date": "2024-03-01",
         "attendees": [KIN, ATTENDEE_NAME, CAL_HANDLE]},
    ]), encoding="utf-8")

    # count >= 3 or the source skips it as an infrequent sender.
    (d / "apple_mail_contacts.json").write_text(json.dumps({
        MAIL_HANDLE: 12,
    }), encoding="utf-8")

    (d / "imessage_conversations.json").write_text(json.dumps([
        {"participants": [PHONE_A], "message_count": 5,
         "last_message": "2024-03-01T10:00:00+00:00", "display_name": ""},
    ]), encoding="utf-8")

    (d / "whatsapp_conversations.json").write_text(json.dumps([
        {"tier": "whatsapp_dm", "participants": [JID_A],
         "last_message": "2024-03-01T10:00:00+00:00"},
        {"tier": "whatsapp_dm", "participants": [JID_B],
         "last_message": "2024-03-02T10:00:00+00:00"},
    ]), encoding="utf-8")


class Harness:
    """Stubs every side effect and records the SPARQL each source emits."""

    def __init__(self, mod, existing=()):
        self.mod = mod
        self.captured: list[str] = []
        self.existing = set(existing)
        self._saved = {}

    def __enter__(self):
        m = self.mod
        for name, repl in (
            ("_sparql_update", lambda q: self.captured.append(q)),
            ("_sparql_query", lambda q: []),
            ("_person_exists", lambda uri: uri in self.existing),
            ("_identifier_exists", lambda uri: False),
            ("_observe_identifier", lambda ident, label="": False),
        ):
            self._saved[name] = getattr(m, name, None)
            setattr(m, name, repl)
        return self

    def __exit__(self, *exc):
        for name, old in self._saved.items():
            if old is not None:
                setattr(self.mod, name, old)
        return False

    def display_names(self) -> list[str]:
        """Every value written as a pwg:displayName, in emission order."""
        out = []
        for q in self.captured:
            for line in q.splitlines():
                s = line.strip().rstrip(" .")
                if "pwg:displayName " in s and '"' in s:
                    out.append(s.split('"')[1])
        return out

    def creation_blocks(self) -> list[str]:
        """The INSERT DATA payloads -- the fresh-install creation writes."""
        return [q for q in self.captured if "INSERT DATA" in q]


def main(repo_str: str) -> int:
    mod = load_module(pathlib.Path(repo_str))
    checks: list[tuple[str, bool]] = []

    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        write_fixtures(d)

        # -------------------------------------------------- fresh install
        with Harness(mod) as h:
            mod.ingest_photos_people(d)
            photos = list(h.display_names())
            photos_blocks = h.creation_blocks()

        with Harness(mod) as h:
            mod.ingest_calendar(d)
            cal = list(h.display_names())
            cal_blocks = h.creation_blocks()

        with Harness(mod) as h:
            mod.ingest_mail_contacts(d)
            mail_blocks = h.creation_blocks()

        with Harness(mod) as h:
            mod.ingest_imessage(d)
            imsg_blocks = h.creation_blocks()

        with Harness(mod) as h:
            mod.ingest_whatsapp(d)
            wa_blocks = h.creation_blocks()

        # POSITIVE CONTROL, first and unconditional. Every assertion below
        # is an ABSENCE claim, and an absence proves nothing unless the
        # probe is shown finding something present in the same run.
        checks.append((
            "CONTROL: the probe sees an ordinary name written by the photos source",
            FACE_NAME in photos,
        ))
        checks.append((
            "CONTROL: the probe sees an ordinary name written by the calendar source",
            ATTENDEE_NAME in cal,
        ))
        checks.append((
            "CONTROL: each source emitted at least one creation INSERT",
            all(len(b) > 0 for b in (photos_blocks, cal_blocks, mail_blocks,
                                     imsg_blocks, wa_blocks)),
        ))

        # ---- v1018-D659 at the CREATION site ---------------------------
        # A Photos face label and a calendar attendee name are both free
        # text off a contact card, so both can be a relationship word.
        checks.append((
            "a kinship face label is never written as a displayName on a fresh install",
            KIN not in photos,
        ))
        checks.append((
            "a kinship calendar attendee is never written as a displayName on a fresh install",
            KIN not in cal,
        ))
        checks.append((
            "refusing the label does not stop the other people being created",
            FACE_NAME in photos and ATTENDEE_NAME in cal,
        ))

        # ---- v1018-D658 at the CREATION site ---------------------------
        # A handle written WITHOUT the provisional flag can never be
        # replaced: the tier-2 guard is `!BOUND(?old) || BOUND(?prov)` and
        # with a name bound and no flag both disjuncts are false.
        FLAG = "pwg:displayNameProvisional"

        def handle_writes_are_flagged(blocks) -> bool:
            for q in blocks:
                names = [ln.strip().split('"')[1] for ln in q.splitlines()
                         if "pwg:displayName " in ln and '"' in ln]
                if not names:
                    continue
                if any(mod._is_provisional_display_name(n) for n in names):
                    if FLAG not in q:
                        return False
            return True

        for label, blocks in (
            ("calendar", cal_blocks),
            ("apple mail", mail_blocks),
            ("photos", photos_blocks),
            ("imessage", imsg_blocks),
            ("whatsapp", wa_blocks),
        ):
            checks.append((
                f"a handle created by the {label} source is flagged provisional, "
                "so a real name can still replace it",
                handle_writes_are_flagged(blocks),
            ))

        # ---- the WhatsApp `display` binding ----------------------------
        # `display` is assigned inside the not-exists branch and read after
        # it. When the first participant already exists the name is unbound
        # (the ingest dies) and on later iterations it holds the PREVIOUS
        # participant's handle, which the tier-0 guard will write onto any
        # node that has no name yet -- one person's page titled with
        # another person's phone number.
        first_uri = mod._person_uri(mod._person_id_from_identifier(JID_A))
        crashed = ""
        leaked = False
        with Harness(mod, existing={first_uri}) as h:
            try:
                mod.ingest_whatsapp(d)
            except Exception as exc:  # noqa: BLE001
                crashed = f"{type(exc).__name__}: {exc}"
            else:
                second_uri = mod._person_uri(mod._person_id_from_identifier(JID_B))
                for q in h.captured:
                    if second_uri in q and "+447700900123" in q:
                        leaked = True

        checks.append((
            "the WhatsApp ingest survives a first participant who already exists",
            crashed == "",
        ))
        if crashed:
            print("        (raised %s)" % crashed)
        checks.append((
            "no participant's handle is written against another participant's node",
            not leaked,
        ))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_creation_name_writes.py <repo-root>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
