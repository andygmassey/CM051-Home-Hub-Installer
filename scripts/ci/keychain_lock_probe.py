#!/usr/bin/env python3
"""MEASUREMENT ONLY. CI-only (refuses unless CI=true): creates a throwaway
keychain, adds an item, then runs each candidate lock detector against the
UNLOCKED control and the LOCKED keychain, printing rc/stderr/stdout per call
with a hard timeout. Never run on a developer Mac (create-keychain edits the
search list)."""
import ctypes, ctypes.util, os, subprocess, sys, tempfile

if os.environ.get("CI") != "true":
    print("CANNOT-RUN: CI only", file=sys.stderr); sys.exit(2)
SEC = "/usr/bin/security"

def run(args, label, t=15, inp=None):
    try:
        p = subprocess.run([SEC] + args, capture_output=True, text=True,
                           timeout=t, stdin=subprocess.DEVNULL if inp is None else None, input=inp)
        print(f"PROBE {label}: rc={p.returncode} stdout={p.stdout.strip()[:120]!r} stderr={p.stderr.strip()[:200]!r}")
        return p
    except subprocess.TimeoutExpired:
        print(f"PROBE {label}: TIMEOUT after {t}s (hang)"); return None

def ctypes_status(path):
    sf = ctypes.CDLL(ctypes.util.find_library("Security"))
    ref = ctypes.c_void_p()
    sf.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    rc = sf.SecKeychainOpen(path.encode(), ctypes.byref(ref))
    st = ctypes.c_uint32()
    sf.SecKeychainGetStatus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    rc2 = sf.SecKeychainGetStatus(ref, ctypes.byref(st))
    return rc, rc2, st.value

d = tempfile.mkdtemp(prefix="kcprobe-")
kc = os.path.join(d, "t.keychain-db"); pw = os.urandom(8).hex()
before = subprocess.run([SEC, "list-keychains", "-d", "user"], capture_output=True, text=True).stdout
run(["create-keychain", "-p", pw, kc], "create")
run(["unlock-keychain", "-p", pw, kc], "unlock")
run(["-i"], "add-item", inp=f'add-generic-password -U -s probe -a probe -w {"ab"*32} "{kc}"\n')
def battery(tag):
    run(["show-keychain-info", kc], f"{tag} show-keychain-info")
    run(["find-generic-password", "-s", "probe", "-a", "probe", kc], f"{tag} find-generic-password(no -w)")
    run(["find-generic-password", "-s", "probe", "-a", "probe", "-w", kc], f"{tag} find-generic-password -w")
    run(["find-generic-password", "-s", "nope", "-a", "nope", kc], f"{tag} find-generic-password(missing item)")
    rc, rc2, st = ctypes_status(kc)
    print(f"PROBE {tag} ctypes SecKeychainGetStatus: open={rc} status_rc={rc2} status={st} unlocked_bit={st & 1}")
battery("UNLOCKED")
run(["lock-keychain", kc], "lock")
battery("LOCKED")
run(["delete-keychain", kc], "delete")
after = subprocess.run([SEC, "list-keychains", "-d", "user"], capture_output=True, text=True).stdout
print("SEARCHLIST_UNCHANGED" if before == after else "SEARCHLIST_CHANGED")
