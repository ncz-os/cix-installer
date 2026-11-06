#!/bin/bash
# audit-dpkg-state.sh [--snapshot FILE]
#
# Audit a host's dpkg state the way it has to be audited: as the login user, from
# dpkg's own status abbreviations, and without treating "removed, config files
# left" or "held" as damage.
#
# WHY THIS EXISTS. The fleet probe that ran before this did `sudo -n dpkg --audit`,
# which needs a password on every test host, so it printed nothing on all six and
# proved nothing while looking like a clean result. The real state on MEDUSA was
# `iF` on a kernel image plus three unpacked module packages, hidden behind it.
#
# Second reason: an UNPACKED module package is not always harmless. On 2026-11-05
# a kernel image went half-configured because DKMS tried to install t2gmux/t2smc
# into /lib/modules/<kver>/updates/dkms - the exact paths a kver-scoped prebuilt
# module package already owned - and refused without --force. dpkg reported the
# half-configured image and said nothing about the overlap that caused it. So this
# audit names the overlap explicitly:
#
#   RESIDUE   <package> <state> <version>   status is H/U/F/W/t (a real fault)
#   COLLISION <module> <kver> <package>     DKMS has the module BUILT for that kernel
#                                           and a prebuilt package already owns the
#                                           destination .ko (the state that makes the
#                                           postinst fail). DKMS "installed" is not a
#                                           collision: it skips instead of refusing.
#
# Allowed states, deliberately not reported as residue: `ii` installed, `hi` held,
# `rc`/`nc` removed with config files left. A hold and a leftover conffile are
# policy, not damage; calling them faults is how an audit gets ignored.
#
# Exit: 0 clean, 1 residue or collision found, 2 usage, 3 nothing was audited
# (empty snapshot) - an empty audit is not a pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

SNAP=
while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot) SNAP="${2:?--snapshot needs a file}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) echo "usage: $(basename "$0") [--snapshot FILE]" >&2; exit 2 ;;
    esac
done

command -v python3 >/dev/null 2>&1 || { echo "audit-dpkg-state: python3 is required" >&2; exit 2; }
T="$(mktemp "${TMPDIR:-/tmp}/ncz-dpkaudit.XXXXXX")" || exit 2
trap 'rm -f "$T"' EXIT

if [ -n "$SNAP" ]; then
    [ -r "$SNAP" ] || { echo "audit-dpkg-state: cannot read $SNAP" >&2; exit 2; }
    tr -d '\r' < "$SNAP" > "$T"
else
    : > "$T"
    # 1. every package's status abbreviation
    dpkg-query -W -f='pkg ${db:Status-Abbrev} ${Package} ${Version}\n' 2>/dev/null >> "$T"
    # 2. what the installed module packages own, so an overlap can be named
    for p in $(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E -- '-modules-[0-9]' | head -40); do
        dpkg -L "$p" 2>/dev/null | grep -E '^/lib/modules/.*/updates/dkms/.*\.ko$' \
            | sed "s|^|owns $p |" >> "$T"
    done
    # 3. what DKMS thinks it has built or installed, per kernel.
    # dkms lives in /usr/sbin and is NOT on a normal user's PATH - looking only at
    # PATH silently skipped the collision check on the one host that had the bug.
    DKMS_BIN="$(command -v dkms 2>/dev/null || true)"
    for c in /usr/sbin/dkms /sbin/dkms /usr/local/sbin/dkms; do
        [ -n "$DKMS_BIN" ] && break
        [ -x "$c" ] && DKMS_BIN="$c"
    done
    if [ -n "$DKMS_BIN" ]; then
        "$DKMS_BIN" status 2>/dev/null | sed -nE 's|^([^,]+), ([^,]+), [^:]+: (.+)$|dkms \1 \2 \3|p' >> "$T"
        echo "tools dkms $DKMS_BIN" >> "$T"
    else
        echo "tools dkms-missing -" >> "$T"
    fi
fi

python3 -I - "$T" <<'PY'
import re
import sys

RESIDUE_STATES = set("HUFWt")
rows_pkg = []
rows_owns = []
rows_dkms = []
tools = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    f = line.split()
    if not f:
        continue
    if f[0] == "pkg" and len(f) >= 3:
        state, name = f[1], f[2]
        version = f[3] if len(f) > 3 else "-"
        rows_pkg.append((state, name, version))
    elif f[0] == "owns" and len(f) >= 3:
        rows_owns.append((f[1], f[2]))
    elif f[0] == "tools":
        tools.append(" ".join(f[1:]))
    elif f[0] == "dkms" and len(f) >= 4:
        mod = f[1]
        kver = f[2]
        state = " ".join(f[3:])
        rows_dkms.append((mod, kver, state))

if not rows_pkg:
    print("audit-dpkg-state: nothing audited (no package rows) - not a pass")
    sys.exit(3)

residue = [(s, n, v) for (s, n, v) in rows_pkg if len(s) >= 2 and s[1] in RESIDUE_STATES]

# COLLISION: a prebuilt module package owns /lib/modules/<kver>/updates/dkms/<file>.ko
# and DKMS has the same module for the same kernel (built or installed). That is the
# pair that makes a kernel postinst fail, and dpkg never says so.
claimed = {}  # (module_base, kver) -> package
for pkg, path in rows_owns:
    m = re.match(r"^/lib/modules/([^/]+)/updates/dkms/([^/]+)\.ko$", path)
    if not m:
        continue
    kver, mod = m.group(1), m.group(2)
    claimed[(mod, kver)] = pkg

# The failing state is `built`: DKMS has something to install into that path and the
# package already owns it, so dkms refuses without --force and the kernel postinst
# dies. `installed` means DKMS already put its own artifact there and skips - proven on
# MEDUSA: after `dkms install --force`, the same call returns "already installed ...
# skip" instead of "override by specifying --force". So "installed" is not a collision.
collisions = []
for (mod, kver, state) in rows_dkms:
    if state.startswith("installed"):
        continue
    base = mod.split("/")[0]
    if (base, kver) in claimed:
        collisions.append((base, kver, claimed[(base, kver)], mod, state))

for s, n, v in sorted(residue, key=lambda r: r[1]):
    print("RESIDUE   %-40s %s  %s" % (n, s, v))
for base, kver, pkg, mod, state in sorted(collisions):
    print("COLLISION %-40s %s  prebuilt %s vs dkms %s (%s)" % (base, kver, pkg, mod, state))

held = [n for (s, n, v) in rows_pkg if s[:1] == "h"]
leftover = [n for (s, n, v) in rows_pkg if len(s) >= 2 and s[1] == "c"]
if any(t.startswith("dkms-missing") for t in tools):
    print("NOTE      dkms not found on this host: the prebuilt/DKMS overlap cannot be "
          "checked (nothing to check when the host has no DKMS)")
print("audit-dpkg-state: %d package(s); %d residue; %d dkms/prebuilt collision(s); "
      "%d held; %d removed-with-conffiles"
      % (len(rows_pkg), len(residue), len(collisions), len(held), len(leftover)))
sys.exit(1 if (residue or collisions) else 0)
PY
