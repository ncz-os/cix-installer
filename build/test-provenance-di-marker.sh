#!/usr/bin/env bash
# test-provenance-di-marker.sh -- the debian-installer build-marker exemption,
# and the two conditions that keep it from being a blanket pass.
#
# Review (cycle 552) asked the right question about the allowance: matching on
# NAME + a timestamp regex alone would exempt a genuine debian-installer record
# on any image, which is a false negative in a provenance decision.  The
# exemption now needs BOTH the tree's own opt-in (NCZ_ONE_KERNEL_SUBSTRATE_UDEBS
# =exempt, read through _ncz_build_context) AND the record to come from an
# initrd's status file.  This suite pins all four cases:
#   1. opt-in + initrd origin + build stamp  -> exempted (di-build-marker)
#   2. no opt-in                             -> FAIL (not exempted)
#   3. opt-in, but the record is not from an initrd -> FAIL
#   4. opt-in + initrd, but the version is not a build stamp -> FAIL
#
# It drives the real classify_noarch() from build/forky-provenance.py (no copy
# of the logic), with a stub Ref and a throwaway trust root.  No root, no
# network, no deb fixtures.
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/build/forky-provenance.py"
[ -f "$LIB" ] || { echo "FAIL: $LIB is missing" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ncz-dimarker.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$*"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$*"; }

python3 - "$LIB" "$T" <<'PY'
import contextlib, importlib.util, io, os, sys

lib, tmp = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("forky_provenance", lib)
mod = importlib.util.module_from_spec(spec)
sys.modules["forky_provenance"] = mod
spec.loader.exec_module(mod)


def tree(name, opt_in):
    d = os.path.join(tmp, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "release.conf"), "w") as fh:
        fh.write("NCZ_ONE_KERNEL_SUBSTRATE_UDEBS=exempt\n" if opt_in
                 else "NCZ_BASE_CODENAME=forky\n")
    return d


class Ref:
    def __init__(self, root):
        self.root = root
        self.ubuntu_only = False
        self.ncz = []
        self.vendor = []
        self.trust = None
        self.snapshot = {}

    def note_kernel(self, *a, **k):
        return None


STAMP = "20261102-00:02:07"
INITRD = "[input:debian-testing-amd64-netinst.iso:initrd-status]"
NON_INITRD = "[input:some-ordinary-deb]"
MAINT = "Debian Installer <debian-installer@lists.debian.org>"


def call(root, src, ver):
    mod.FAILS[:] = []
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        got = mod.classify_noarch(Ref(root), src, "debian-installer", ver, MAINT)
    return got, list(mod.FAILS), buf.getvalue()


cases = [
    ("opt-in + initrd origin + build stamp", tree("a", True), INITRD, STAMP, "di-build-marker"),
    ("no opt-in", tree("b", False), INITRD, STAMP, None),
    ("opt-in, but not an initrd record", tree("c", True), NON_INITRD, STAMP, None),
    ("opt-in + initrd, but not a build stamp", tree("d", True), INITRD, "2026.11.02", None),
]
rc = 0
for label, root, src, ver, want in cases:
    got, fails, out = call(root, src, ver)
    if got == want:
        print("ok   %s -> %r" % (label, got))
    else:
        print("FAIL %s -> got %r, wanted %r" % (label, got, want))
        rc = 1
    if want is None:
        if fails:
            print("ok   %s: refusal is recorded with a reason" % label)
        else:
            print("FAIL %s: returned None but recorded no finding" % label)
            rc = 1
    else:
        if "identity only" in out:
            print("ok   %s: the note says why it is exempt" % label)
        else:
            print("FAIL %s: exempted without saying why: %r" % (label, out.strip()[:80]))
            rc = 1
sys.exit(rc)
PY
rc=$?
[ "$rc" = 0 ] || exit 1
echo
echo "== di-marker cases: the exemption and its three refusals =="
exit 0
