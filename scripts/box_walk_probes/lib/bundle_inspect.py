#!/usr/bin/env python3
# scripts/box_walk_probes/lib/bundle_inspect.py
# ===========================================================================
# THE READER THAT SHOWS ITS WORKING.
#
# WHY THIS FILE EXISTS
# --------------------
# v1.0.46 BOM row 6, an unresolved contradiction that blocked a claim:
#
#     installed_bundle_seal_intact reports all three Ostler bundles MISSING
#     from /Applications, while a direct SSH read finds /Applications/Ostler.app
#     present (short=0.7.1, mtime 22 Aug 17:34).
#
# Two readers, opposite answers, and NEITHER could be cited, because neither
# recorded what it had actually looked at. The old probe printed
#
#     MISSING   /Applications/Ostler.app
#
# and that one word covers three different facts that must never share an
# appearance:
#
#     PRESENT      it is there
#     ABSENT       the parent directory was listed and it is not in it
#     CANNOT-LOOK  the read was refused, or an ancestor could not be searched,
#                  so absence was never established
#
# A verdict with no record of what was inspected cannot be audited. So this
# module refuses to answer the question "is it there" without also answering
# "on which machine, as which user, at which resolved path, and if not, what
# did the kernel actually say".
#
# WHAT IT EMITS  (tab separated, one record per line, key=value)
#
#     HOST     hostname, uid, euid, user, transport (local or ssh), python
#     CONTEXT  SIP status, TCC full-disk-access canary, sandbox container
#     PATH     requested, expanded, resolved, state, errno, strerror, and for
#              an ABSENT verdict the ancestor that was listed and how many
#              entries it held -- the DENOMINATOR that makes absence provable
#     TOTAL    present / absent / cannot_look counts
#
# HOW ABSENCE IS PROVED, AND WHY A BARE stat IS NOT ENOUGH
# -------------------------------------------------------
# os.lstat raising ENOENT is not by itself proof of absence: an unsearchable
# ancestor raises EACCES on some paths and, in sandboxed contexts, can mask a
# path entirely. So an ENOENT leaf is only promoted to ABSENT after the highest
# listable ancestor has been enumerated and the missing component confirmed
# not to be in it. If no ancestor can be listed, the verdict is CANNOT-LOOK.
#
# NO SWALLOWED ERRORS. Every OSError is reported with its errno name and
# strerror. csrutil stderr is captured and printed rather than discarded. A
# probe that hides the reason a syscall failed is the defect this file exists
# to remove.
#
# ===========================================================================
# THIS FILE MUST NOT CONTAIN A SINGLE-QUOTE CHARACTER.
#
# installed_bundle_seal_intact.sh ships this source to the box under test by
# wrapping it in single quotes for the remote shell:
#
#     ssh box "python3 -c <this file, single quoted> /Applications/Ostler.app"
#
# One apostrophe -- in a comment, a docstring, anywhere -- terminates that
# quoting and the remote shell mangles the rest into arguments. The failure is
# a syntax error on the far side, i.e. a reader that produces no reading, which
# is exactly the shape being fixed here. tests/test_a_denied_read_is_not_an_
# absence.sh asserts the absence of the character, so this is enforced and not
# merely requested.
# ===========================================================================

import errno as errno_mod
import os
import platform
import plistlib
import socket
import subprocess
import sys
import time

PRESENT = "PRESENT"
ABSENT = "ABSENT"
CANNOT_LOOK = "CANNOT-LOOK"

# errno values that mean "the path is not there", as opposed to "the read was
# refused". Everything else is a refusal until proved otherwise.
ABSENCE_ERRNOS = (errno_mod.ENOENT, errno_mod.ENOTDIR)


def errno_name(number):
    if number is None:
        return "-"
    return errno_mod.errorcode.get(number, "E%d" % number)


def flat(value):
    # One record per line, so tabs and newlines inside a value would corrupt
    # the record shape the shell caller parses.
    if value is None:
        return "-"
    text = str(value)
    if text == "":
        return "-"
    return text.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def emit(kind, fields):
    parts = [kind]
    for key, value in fields:
        parts.append("%s=%s" % (key, flat(value)))
    sys.stdout.write("\t".join(parts) + "\n")


def safe_getcwd():
    try:
        return os.getcwd()
    except OSError as exc:
        return "unavailable:%s" % errno_name(exc.errno)


def sip_status():
    # csrutil is macOS only. Its STDERR is captured and reported, never
    # discarded: "the tool is missing" and "the tool said no" are different
    # facts and a probe that folds them together is lying by omission.
    try:
        proc = subprocess.Popen(
            ["/usr/bin/csrutil", "status"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        out, err = proc.communicate()
    except OSError as exc:
        return ("unknown", "csrutil-unavailable:%s:%s"
                % (errno_name(exc.errno), exc.strerror))
    out_text = out.decode("utf-8", "replace").strip()
    err_text = err.decode("utf-8", "replace").strip()
    if proc.returncode != 0:
        return ("unknown", "rc=%d stderr=%s" % (proc.returncode, err_text or "-"))
    return (out_text or "-", err_text or "-")


def tcc_state():
    # A named canary for the one permission regime that could plausibly deny a
    # read on this box WITHOUT a filesystem mode saying so. An ssh session on
    # macOS has no Full Disk Access unless it has been granted explicitly, and
    # a TCC refusal surfaces as EPERM -- which a reader that prints only a
    # boolean would render as "not there".
    #
    # /Applications is NOT TCC protected, so this is CONTEXT and never a
    # verdict. It is here so an operator reading a CANNOT-LOOK can see at a
    # glance whether the reading context was a restricted one.
    canary = os.path.expanduser(
        "~/Library/Application Support/com.apple.TCC/TCC.db")
    try:
        handle = open(canary, "rb")
    except OSError as exc:
        if exc.errno in (errno_mod.EACCES, errno_mod.EPERM):
            return ("restricted", canary, errno_name(exc.errno))
        if exc.errno == errno_mod.ENOENT:
            return ("canary-absent", canary, errno_name(exc.errno))
        return ("unknown", canary, errno_name(exc.errno))
    try:
        handle.read(16)
    finally:
        handle.close()
    return ("full-disk-access", canary, "-")


def highest_listable_ancestor(path):
    # Walk up until a directory can actually be enumerated. Returns
    # (directory, entries, errno). entries is None when nothing could be
    # listed, and then errno says why -- which is the difference between
    # "looked and it was not there" and "never got to look".
    current = os.path.dirname(path) or "/"
    while True:
        try:
            return (current, os.listdir(current), None)
        except OSError as exc:
            parent = os.path.dirname(current)
            if exc.errno == errno_mod.ENOENT and parent and parent != current:
                current = parent
                continue
            return (current, None, exc.errno)


def bundle_short_version(path):
    info = os.path.join(path, "Contents", "Info.plist")
    try:
        handle = open(info, "rb")
    except OSError as exc:
        return "unreadable:%s" % errno_name(exc.errno)
    try:
        try:
            doc = plistlib.load(handle)
        except Exception as exc:
            return "unparseable:%s" % type(exc).__name__
    finally:
        handle.close()
    return doc.get("CFBundleShortVersionString") or "-"


def describe_present(requested, expanded, stat_result):
    try:
        resolved = os.path.realpath(expanded)
    except OSError as exc:
        resolved = "unresolvable:%s" % errno_name(exc.errno)
    is_link = os.path.islink(expanded)
    kind = "dir" if os.path.isdir(expanded) else "file"
    if is_link:
        kind = kind + "+symlink"
    mtime = time.strftime("%Y-%m-%dT%H:%M:%S",
                          time.localtime(stat_result.st_mtime))
    return [
        ("requested", requested),
        ("expanded", expanded),
        ("resolved", resolved),
        ("state", PRESENT),
        ("kind", kind),
        ("mode", oct(stat_result.st_mode & 0o7777)),
        ("owner_uid", stat_result.st_uid),
        ("mtime", mtime),
        ("short", bundle_short_version(expanded)),
        ("errno", "-"),
        ("strerror", "-"),
        ("proved_by", "lstat"),
    ]


def describe_failure(requested, expanded, exc):
    resolved_attempt = os.path.abspath(expanded)
    base = os.path.basename(expanded.rstrip(os.sep))

    if exc.errno not in ABSENCE_ERRNOS:
        # A refusal. This is CANNOT-LOOK and it must never be rendered as
        # absence, whatever the caller would prefer to print.
        return [
            ("requested", requested),
            ("expanded", expanded),
            ("resolved", resolved_attempt),
            ("state", CANNOT_LOOK),
            ("errno", errno_name(exc.errno)),
            ("strerror", exc.strerror or "-"),
            ("denied_at", expanded),
            ("proved_by", "lstat refused"),
        ]

    ancestor, entries, anc_errno = highest_listable_ancestor(expanded)

    if entries is None:
        # The leaf said ENOENT, but no ancestor could be enumerated, so the
        # ENOENT was never corroborated. Absence is NOT established.
        return [
            ("requested", requested),
            ("expanded", expanded),
            ("resolved", resolved_attempt),
            ("state", CANNOT_LOOK),
            ("errno", errno_name(exc.errno)),
            ("strerror", exc.strerror or "-"),
            ("denied_at", ancestor),
            ("ancestor_errno", errno_name(anc_errno)),
            ("proved_by", "no ancestor could be listed, so absence was never established"),
        ]

    if ancestor == (os.path.dirname(expanded) or "/") and base in entries:
        # stat says it is not there and the parent listing says it is. Do not
        # pick a side: this is an unstable reading, not a verdict.
        return [
            ("requested", requested),
            ("expanded", expanded),
            ("resolved", resolved_attempt),
            ("state", CANNOT_LOOK),
            ("errno", errno_name(exc.errno)),
            ("strerror", exc.strerror or "-"),
            ("listed", ancestor),
            ("entries", len(entries)),
            ("proved_by", "CONTRADICTION: lstat refused the leaf but the parent listing contains it"),
        ]

    return [
        ("requested", requested),
        ("expanded", expanded),
        ("resolved", resolved_attempt),
        ("state", ABSENT),
        ("errno", errno_name(exc.errno)),
        ("strerror", exc.strerror or "-"),
        ("listed", ancestor),
        ("entries", len(entries)),
        ("proved_by", "enumerated the ancestor and the component is not in it"),
    ]


def inspect(requested):
    expanded = os.path.expanduser(os.path.expandvars(requested))
    try:
        stat_result = os.lstat(expanded)
    except OSError as exc:
        return describe_failure(requested, expanded, exc)
    return describe_present(requested, expanded, stat_result)


def main(argv):
    if not argv:
        sys.stderr.write("bundle_inspect: no paths given; nothing was inspected\n")
        return 2

    sip, sip_detail = sip_status()
    tcc, tcc_canary, tcc_errno = tcc_state()

    emit("HOST", [
        ("hostname", socket.gethostname()),
        ("uid", os.getuid()),
        ("euid", os.geteuid()),
        ("user", os.environ.get("USER") or os.environ.get("LOGNAME")),
        ("transport", "ssh" if os.environ.get("SSH_CONNECTION") else "local"),
        ("ssh_client", os.environ.get("SSH_CONNECTION")),
        ("cwd", safe_getcwd()),
        ("python", platform.python_version()),
        ("platform", platform.platform()),
    ])
    emit("CONTEXT", [
        ("sip", sip),
        ("sip_detail", sip_detail),
        ("tcc", tcc),
        ("tcc_canary", tcc_canary),
        ("tcc_errno", tcc_errno),
        ("sandbox_container", os.environ.get("APP_SANDBOX_CONTAINER_ID")),
    ])

    counts = {PRESENT: 0, ABSENT: 0, CANNOT_LOOK: 0}
    for requested in argv:
        fields = inspect(requested)
        emit("PATH", fields)
        for key, value in fields:
            if key == "state":
                counts[value] = counts.get(value, 0) + 1

    emit("TOTAL", [
        ("requested", len(argv)),
        ("present", counts[PRESENT]),
        ("absent", counts[ABSENT]),
        ("cannot_look", counts[CANNOT_LOOK]),
    ])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
