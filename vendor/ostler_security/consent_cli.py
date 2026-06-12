"""Tiny CLI shim so ``install.sh`` (Bash) can persist consent records.

``install.sh`` is Bash and cannot import Python modules directly. To
keep the wording-hash math + the atomic-write semantics in ONE place
(``ostler_security.consent`` + ``legal.consent_strings``), we expose
this CLI so the installer can shell out::

    python3 -m ostler_security.consent_cli record \
        --tickbox article_9_special_category_consent \
        --decision accepted \
        --region eu \
        --user-id "$USER_ID"

And similarly for the WhatsApp tickbox and EU voice gate. The
wording text + version are looked up by tickbox id from the
``legal`` package, so the bash side never has to embed the wording.

Read paths are also exposed so the bash post-install banner can
verify what got written (sanity check).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Allow ``python3 -m ostler_security.consent_cli`` to import ``legal``
# without the package having been pip-installed. install.sh runs us
# from the Hub venv with HR015 root on PYTHONPATH; tests + dev runs
# need the parent of ostler_security/ on the path too.
_HR015_ROOT = Path(__file__).resolve().parent.parent
if str(_HR015_ROOT) not in sys.path:
    sys.path.insert(0, str(_HR015_ROOT))

from ostler_security import consent  # noqa: E402

try:
    from legal import (  # noqa: E402
        ARTICLE_9_EU_CONSENT,
        EU_VOICE_SPEAKER_ID_CONSENT,
        THIRD_PARTY_DATA_NOTICE,
        WHATSAPP_UNOFFICIAL_RISK_CONSENT,
    )
except ImportError as exc:  # pragma: no cover - smoke
    print(
        f"[consent_cli] could not import legal package: {exc}", file=sys.stderr,
    )
    sys.exit(2)


# Map cli tickbox arg -> ConsentString. Single source of truth.
TICKBOX_REGISTRY = {
    ARTICLE_9_EU_CONSENT.tickbox_id: ARTICLE_9_EU_CONSENT,
    WHATSAPP_UNOFFICIAL_RISK_CONSENT.tickbox_id: WHATSAPP_UNOFFICIAL_RISK_CONSENT,
    EU_VOICE_SPEAKER_ID_CONSENT.tickbox_id: EU_VOICE_SPEAKER_ID_CONSENT,
    # #659: the third-party-data acknowledgement install.sh records for
    # every region (tickbox id "third_party_data_personal_records"). It was
    # defined in legal/consent_strings.py and called by install.sh but never
    # registered here, so argparse `choices` rejected it (exit 2) and the
    # consent was silently dropped (Doctor showed it "missing" despite an
    # active accept).
    THIRD_PARTY_DATA_NOTICE.tickbox_id: THIRD_PARTY_DATA_NOTICE,
}


def _cmd_record(args: argparse.Namespace) -> int:
    cs = TICKBOX_REGISTRY.get(args.tickbox)
    if cs is None:
        print(
            f"[consent_cli] unknown tickbox: {args.tickbox!r}. Known ids: "
            f"{sorted(TICKBOX_REGISTRY)}",
            file=sys.stderr,
        )
        return 2

    consent.record_consent(
        tickbox_id=cs.tickbox_id,
        wording_text=cs.text,
        wording_version=cs.version,
        decision=args.decision,
        region=args.region,
        wording_hash=cs.sha256(),
        hub_version=args.hub_version,
        user_id=args.user_id,
        scope=cs.scope,
    )
    return 0


def _cmd_show(args: argparse.Namespace) -> int:
    rec = consent.read_consent(args.tickbox)
    if rec is None:
        print("null")
        return 1
    print(json.dumps(rec, indent=2))
    return 0


def _cmd_check(args: argparse.Namespace) -> int:
    """Exit 0 when consent is current, exit 2 when missing/stale.
    Used by Rust startup gates that prefer to subprocess this CLI
    rather than parse the JSON themselves.
    """
    cs = TICKBOX_REGISTRY.get(args.tickbox)
    if cs is None:
        print(f"[consent_cli] unknown tickbox: {args.tickbox!r}", file=sys.stderr)
        return 2
    if consent.is_current(cs.tickbox_id, cs.sha256()):
        print("ok")
        return 0
    rec = consent.read_consent(cs.tickbox_id)
    if rec is None:
        print("missing", file=sys.stderr)
    elif rec.get("decision") != "accepted":
        print("declined", file=sys.stderr)
    else:
        print("stale_hash", file=sys.stderr)
    return 2


def _cmd_text(args: argparse.Namespace) -> int:
    """Print the current bundled wording for ``--tickbox``. install.sh
    uses this to render the consent screen so the screen text + the
    persisted wording_text + the SHA-256 cannot drift.
    """
    cs = TICKBOX_REGISTRY.get(args.tickbox)
    if cs is None:
        print(f"[consent_cli] unknown tickbox: {args.tickbox!r}", file=sys.stderr)
        return 2
    sys.stdout.write(cs.text)
    return 0


def _cmd_remove_all(_args: argparse.Namespace) -> int:
    """Wipe the consent registry. install.sh calls this when the user
    declines the Article 9 screen, to leave no ``~/.ostler/`` residue.
    """
    consent.remove_all()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="ostler-consent",
        description="Record / inspect Ostler consent decisions.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_rec = sub.add_parser("record", help="persist a decision")
    p_rec.add_argument(
        "--tickbox", required=True, choices=sorted(TICKBOX_REGISTRY),
    )
    p_rec.add_argument(
        "--decision", required=True, choices=["accepted", "declined"],
    )
    p_rec.add_argument(
        "--region", required=True, choices=["eu", "uk", "us", "row"],
    )
    p_rec.add_argument("--user-id", default=os.environ.get("USER_ID"))
    p_rec.add_argument(
        "--hub-version",
        default=os.environ.get("OSTLER_HUB_VERSION", "0.1.0"),
    )
    p_rec.set_defaults(func=_cmd_record)

    p_show = sub.add_parser("show", help="print one record as JSON")
    p_show.add_argument("--tickbox", required=True)
    p_show.set_defaults(func=_cmd_show)

    p_chk = sub.add_parser("check", help="exit 0 if consent current, 2 otherwise")
    p_chk.add_argument(
        "--tickbox", required=True, choices=sorted(TICKBOX_REGISTRY),
    )
    p_chk.set_defaults(func=_cmd_check)

    p_txt = sub.add_parser("text", help="print bundled wording for a tickbox")
    p_txt.add_argument(
        "--tickbox", required=True, choices=sorted(TICKBOX_REGISTRY),
    )
    p_txt.set_defaults(func=_cmd_text)

    p_rm = sub.add_parser(
        "remove-all", help="wipe consent registry (decline-and-abort)",
    )
    p_rm.set_defaults(func=_cmd_remove_all)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
