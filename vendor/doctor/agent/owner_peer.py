"""Owner-only gate for the Doctor's credential routes (red team v1.0.124, S1).

THE HOLE. Five Doctor routes hand out or rotate a credential:

    POST /api/v1/auth/chat-token   mints a device bearer
    GET  /api/v1/extension/token   returns the browser-extension ingest key
    GET  /api/v1/pair/status       returns the pairing envelope (QR = token)
    POST /api/v1/pair/regenerate   rotates the pairing credential
    GET  /api/v1/whatsapp/pair     returns the WhatsApp link code

Before this module their only checks were browser-shaped (Sec-Fetch-Site,
Origin, Host). Loopback is shared by every account on a Mac, so a SECOND
macOS account could curl them, and `tailscale serve` forwards tailnet peers
onto the same loopback port, so any tailnet device could too.

THE PROOF OF OWNERSHIP, and why this one. The Doctor runs as the owner (a
per-user LaunchAgent). For a loopback TCP connection the kernel knows which
process holds the client end. We ask it, and admit only a peer that:

  1. arrived on a loopback address (a LAN or kernel-mode tailnet source is
     refused outright);
  2. is a process WE CAN SEE holding the client end of this exact connection.
     macOS libproc, called unprivileged, cannot see another account's processes,
     and Linux /proc/net/tcp reports the socket's uid, so another account is
     either invisible or visibly not us. Invisible is refused: unknown is not
     the owner;
  3. runs as the owner's uid;
  4. is not a FORWARDER. tailscaled (userspace mode, a per-user LaunchAgent)
     and the colima/lima host agents run as the owner and relay connections
     from OTHER machines (tailnet peers, containers). Their uid proves
     nothing about who is on the far side, so they are refused by name.

Why not a 0600 secret file presented by the client: every legitimate caller
today is the Doctor's OWN page (/pair-ios, /extension-setup, /whatsapp-pair)
in the owner's browser. Measured: CM031 origin/main has 0 hits for any of
these paths (ChatTokenService reads the Keychain since 2026-10-09) and the Hub
app (ostler-assistant web/src) has 0 hits (Pairing.tsx reads the gateway's
/admin/paircode). A page can only present a secret the server baked into it,
which any caller of the page would then also get. The peer check needs no
client change at all.

What it does NOT cover, stated so it is never overclaimed: any process
running AS THE OWNER is the owner here. That attacker can already read the
0600 admin token in ~/.ostler/secrets and mint from the gateway directly.
Browser drive-by from the owner's own Safari is a different attacker and is
still handled by _cross_site_refusal, which stays on every route.
"""
from __future__ import annotations

import ipaddress
import os
import sys
from dataclasses import dataclass
from typing import Callable, Optional

OWNER_ONLY_DETAIL = "refused: this Hub credential route is only available to the Mac's owner"

# Processes that relay connections from someone else. Matched on the
# executable's base name, case-insensitively.
FORWARDERS = frozenset({"tailscaled", "tailscale", "limactl", "gvproxy", "vpnkit", "socat"})



@dataclass(frozen=True)
class Peer:
    pid: Optional[int]
    uid: int
    command: Optional[str]


def owner_uid() -> int:
    """The uid the Doctor runs as, which IS the owner (per-user LaunchAgent)."""
    return os.geteuid()


def _is_loopback(host: Optional[str]) -> bool:
    if not host:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_loopback


# macOS: read the kernel's socket table IN PROCESS through libproc. No fork:
# the Hub WebView polls the Doctor about once a second and a fork per request
# is the defect tests/test_the_doctor_status_poll_has_a_fork_budget.py exists
# for (macOS SIGTERMs a daemon that forks like that). Offsets are
# <sys/proc_info.h>, measured with offsetof() on the macOS 26 SDK; a layout
# change makes the lookup find nothing, which is refused (fail closed), and
# the test's own-connection arm goes red.
LIBPROC = "/usr/lib/libproc.dylib"
_PROC_PIDLISTFDS, _PROC_PIDFDSOCKETINFO, _PROC_PIDTBSDINFO = 1, 3, 3
_PROX_FDTYPE_SOCKET, _SOCKINFO_TCP = 2, 2
_SOCKET_FDINFO_SIZE, _OFF_KIND, _OFF_FPORT, _OFF_LPORT = 792, 256, 264, 268
_BSDINFO_SIZE, _OFF_UID, _OFF_COMM = 136, 20, 48
_libproc_handle = None


def _libproc():
    global _libproc_handle
    if _libproc_handle is None or _libproc_handle[0] != LIBPROC:
        import ctypes
        _libproc_handle = (LIBPROC, ctypes.CDLL(LIBPROC, use_errno=True))
    return _libproc_handle[1]


def _peer_darwin(client_host: str, client_port: int, server_port: int) -> Optional[Peer]:
    import ctypes
    import socket as _s
    import struct
    try:
        lp = _libproc()
    except OSError:
        return None
    n = lp.proc_listallpids(None, 0)
    if n <= 0:
        return None
    pids = (ctypes.c_int * (n + 64))()
    n = lp.proc_listallpids(pids, ctypes.sizeof(pids)) or 0
    sockbuf = ctypes.create_string_buffer(_SOCKET_FDINFO_SIZE)
    for pid in pids[:n]:
        if pid <= 0:
            continue
        size = lp.proc_pidinfo(pid, _PROC_PIDLISTFDS, 0, None, 0)
        if size <= 0:
            continue  # not ours to see (another account) or gone
        fdbuf = ctypes.create_string_buffer(size + 8 * 32)
        got = lp.proc_pidinfo(pid, _PROC_PIDLISTFDS, 0, fdbuf, len(fdbuf))
        for k in range(0, max(got, 0) // 8):
            fd, fdtype = struct.unpack_from("<iI", fdbuf.raw, k * 8)
            if fdtype != _PROX_FDTYPE_SOCKET:
                continue
            if lp.proc_pidfdinfo(pid, fd, _PROC_PIDFDSOCKETINFO, sockbuf, _SOCKET_FDINFO_SIZE) != _SOCKET_FDINFO_SIZE:
                continue
            raw = sockbuf.raw
            if struct.unpack_from("<i", raw, _OFF_KIND)[0] != _SOCKINFO_TCP:
                continue
            fport = _s.ntohs(struct.unpack_from("<i", raw, _OFF_FPORT)[0] & 0xFFFF)
            lport = _s.ntohs(struct.unpack_from("<i", raw, _OFF_LPORT)[0] & 0xFFFF)
            if lport != client_port or fport != server_port:
                continue
            bsd = ctypes.create_string_buffer(_BSDINFO_SIZE)
            if lp.proc_pidinfo(pid, _PROC_PIDTBSDINFO, 0, bsd, _BSDINFO_SIZE) != _BSDINFO_SIZE:
                return Peer(pid=pid, uid=-1, command=None)
            uid = struct.unpack_from("<I", bsd.raw, _OFF_UID)[0]
            comm = bsd.raw[_OFF_COMM:_OFF_COMM + 16].split(b"\0", 1)[0].decode("utf-8", "replace")
            return Peer(pid=pid, uid=uid, command=comm or None)
    return None


def _hex_endpoint(host: str, port: int) -> Optional[str]:
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return None
    if ip.version != 4:
        return None
    return "%s:%04X" % (ip.packed[::-1].hex().upper(), port)


def _peer_linux(client_host: str, client_port: int, server_port: int) -> Optional[Peer]:
    local = _hex_endpoint(client_host, client_port)
    if local is None:
        return None
    try:
        with open("/proc/net/tcp") as fh:
            rows = fh.read().splitlines()[1:]
    except OSError:
        return None
    for row in rows:
        f = row.split()
        if len(f) < 10 or f[1] != local or not f[2].endswith(":%04X" % server_port):
            continue
        uid, inode = int(f[7]), f[9]
        target = f"socket:[{inode}]"
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            fd_dir = f"/proc/{pid}/fd"
            try:
                fds = os.listdir(fd_dir)
            except OSError:
                continue
            for fd in fds:
                try:
                    if os.readlink(f"{fd_dir}/{fd}") == target:
                        with open(f"/proc/{pid}/comm") as c:
                            return Peer(pid=int(pid), uid=uid, command=c.read().strip())
                except OSError:
                    continue
        # The socket is visible but its process is not: not ours to see.
        return Peer(pid=None, uid=uid, command=None)
    return None


def lookup_peer(client_host: str, client_port: int, server_port: int) -> Optional[Peer]:
    if sys.platform == "darwin":
        return _peer_darwin(client_host, client_port, server_port)
    if sys.platform.startswith("linux"):
        return _peer_linux(client_host, client_port, server_port)
    return None


# Indirection so tests can stand in for the kernel without an env knob: an
# environment variable that widens access is a backdoor on the customer box.
_lookup: Callable[[str, int, int], Optional[Peer]] = lookup_peer


def verdict(client, server) -> Optional[str]:
    """None to admit, else the refused_on reason. Fails closed at every step."""
    if not client or not server:
        return "peer-unknown"
    chost, cport = client[0], client[1]
    if not _is_loopback(chost):
        return "not-loopback"
    try:
        peer = _lookup(chost, int(cport), int(server[1]))
    except Exception:  # noqa: BLE001 - a guard that cannot run has not passed
        return "peer-unknown"
    if peer is None:
        return "peer-unknown"
    if peer.uid != owner_uid():
        return "peer-not-owner"
    if not peer.command:
        return "peer-unknown"
    if os.path.basename(peer.command).lower() in FORWARDERS:
        return "peer-is-forwarder"
    return None
