#!/bin/bash
# check-pin-coherence.sh -- cross-file pin agreement inside one commit
# (docs/BUILD-STABILITY.md, measure M3).  Offline: reads only the tree.
#
# Rules (each reported as "[pin-coherence] OK|FAIL|SKIP <rule>: ..."):
#   snapshot         base.pin amd64 + arm64 snapshot == release.conf
#                    NCZ_BASE_MIRROR_SNAPSHOT == forky-snapshot.tsv snapshot ==
#                    determinism.pin snapshot.  Always repo-wide: a half re-pin
#                    is wrong for every arch.
#   sid-exceptions   every manifests/sid-exceptions.tsv row's snapshot == the pin
#   rootfs-inputs    every prebuilt rootfs row in manifests/build-inputs.tsv
#                    records the snapshot it was built at, and it is the pin.
#                    Until M8 adds a snapshot column, the record is the note's
#                    "snapshot YYYYMMDDTHHMMSSZ".
#   kernel-revision  the +rNNN packaging revision == every assets/kernel-manifest.json
#                    kernel deb == every manifests/ncz-packages.tsv Sky1 kernel
#                    row, and each manifest deb has a ledger row with the same
#                    sha256.  The packaging revision is assets/kernel/mainline.deb-revision
#                    when that file exists (a repackaging of the staged release;
#                    never older than it), else the rNNN of assets/kernel/mainline.release.
#                    arm64 only.
#   tracked-debs     every .deb tracked in git under assets/ has an exact
#                    (name, version, arch) row in manifests/ncz-packages.tsv or
#                    manifests/vendor-debs.tsv whose sha256 is the file's.
#
# Usage: build/check-pin-coherence.sh [--root DIR] [--arch amd64|arm64]
#   --arch limits the per-arch rules (rootfs rows, sid rows, debs of that arch
#   or "all"; the kernel rule runs for arm64 only).  Default: every arch.
# Exit: 0 coherent, 1 at least one FAIL, 2 usage error / not a repo tree.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ARCH=""
usage() { echo "usage: $0 [--root DIR] [--arch amd64|arm64]" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --root) [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
        --arch) [ $# -ge 2 ] || usage; ARCH="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "[pin-coherence] unknown argument: $1" >&2; usage ;;
    esac
done
case "$ARCH" in ""|amd64|arm64) ;; *) echo "[pin-coherence] bad --arch '$ARCH'" >&2; usage ;; esac
[ -d "$ROOT/manifests" ] && [ -f "$ROOT/release.conf" ] \
    || { echo "[pin-coherence] $ROOT is not a repo tree (no manifests/ or release.conf)" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "[pin-coherence] $ROOT is not a git work tree (tracked-debs needs git)" >&2; exit 2; }
TRACKED="$(git -C "$ROOT" ls-files -- 'assets/*.deb')" \
    || { echo "[pin-coherence] git ls-files failed in $ROOT" >&2; exit 2; }

exec python3 -I - "$ROOT" "$ARCH" "$TRACKED" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
from urllib.parse import unquote

root, arch, tracked = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
STAMP = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
KERNEL_PKGS = ("linux-image-cixmini", "linux-headers-cixmini", "cixmini-boot")
fails = 0

def say(kind, rule, msg):
    print(f"[pin-coherence] {kind} {rule}: {msg}")

def fail(rule, msg):
    global fails
    fails += 1
    say("FAIL", rule, msg)

def rows(rel):
    p = root / rel
    if not p.is_file():
        return None
    out = []
    for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if line.strip() and not line.startswith("#"):
            out.append((n, line.split("\t")))
    return out

def kv(rel):
    r = rows(rel)
    return None if r is None else {c[0]: c[1] for _, c in r if len(c) >= 2}

def arch_ok(a):
    return not arch or a in (arch, "all")

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def split_deb(name):  # name_version_arch.deb -> (name, version, arch) | None
    m = re.match(r"^([^_]+)_([^_]+)_([^_]+)\.deb$", name)
    return (m.group(1), unquote(m.group(2)), m.group(3)) if m else None

def revision(version):
    m = re.search(r"\+(r[0-9]+)$", version)
    return m.group(1) if m else None

# --- snapshot ---------------------------------------------------------------
pin = None
seen = {}
rc_lines = [l for l in (root / "release.conf").read_text(encoding="utf-8").splitlines()
            if l.startswith("NCZ_BASE_MIRROR_SNAPSHOT=")]
if len(rc_lines) != 1:
    fail("snapshot", f"release.conf has {len(rc_lines)} NCZ_BASE_MIRROR_SNAPSHOT= lines (want exactly 1)")
else:
    v = rc_lines[0].split("=", 1)[1].strip().strip('"')
    if STAMP.match(v):
        pin = v
        seen["release.conf NCZ_BASE_MIRROR_SNAPSHOT"] = v
    else:
        fail("snapshot", f"release.conf NCZ_BASE_MIRROR_SNAPSHOT '{v}' is not YYYYMMDDTHHMMSSZ")
bp = rows("manifests/base.pin")
if bp is None:
    fail("snapshot", "manifests/base.pin is missing")
else:
    archs = {}
    for n, c in bp:
        if len(c) < 4:
            fail("snapshot", f"manifests/base.pin:{n}: fewer than 4 columns")
            continue
        archs[c[0]] = c[3]
        seen[f"base.pin {c[0]}"] = c[3]
    for a in ("amd64", "arm64"):
        if a not in archs:
            fail("snapshot", f"manifests/base.pin has no {a} row")
for rel in ("manifests/forky-snapshot.tsv", "manifests/determinism.pin"):
    d = kv(rel)
    if d is None or "snapshot" not in d:
        fail("snapshot", f"{rel} has no snapshot row")
    else:
        seen[f"{Path(rel).name} snapshot"] = d["snapshot"]
if pin is None and seen:
    pin = next(iter(seen.values()))
if len(set(seen.values())) > 1:
    fail("snapshot", "pins disagree: " + ", ".join(f"{k}={v}" for k, v in seen.items()))
elif pin:
    say("OK", "snapshot", f"{pin} in " + ", ".join(seen))

# --- sid-exceptions ---------------------------------------------------------
sid = rows("manifests/sid-exceptions.tsv") or []
bad = 0
for n, c in sid:
    if len(c) < 10:
        fail("sid-exceptions", f"manifests/sid-exceptions.tsv:{n}: fewer than 10 columns"); bad += 1
    elif arch_ok(c[2]) and c[9] != pin:
        fail("sid-exceptions", f"manifests/sid-exceptions.tsv:{n}: {c[0]} {c[1]} {c[2]} reviewed at snapshot {c[9]}, pin is {pin}"); bad += 1
if not bad:
    say("OK", "sid-exceptions", f"{len(sid)} row(s) at the pin")

# --- rootfs-inputs ----------------------------------------------------------
bi = rows("manifests/build-inputs.tsv") or []
bad = checked = 0
for n, c in bi:
    if len(c) < 5 or not re.search(r"rootfs[^/]*\.tar(\.[a-z0-9]+)?$", c[1]) or not arch_ok(c[0]):
        continue
    checked += 1
    m = re.findall(r"snapshot ([0-9]{8}T[0-9]{6}Z)", c[4])
    if not m:
        fail("rootfs-inputs", f"manifests/build-inputs.tsv:{n}: {c[0]} {c[1]} records no build snapshot"); bad += 1
    elif any(s != pin for s in m):
        fail("rootfs-inputs", f"manifests/build-inputs.tsv:{n}: {c[0]} {c[1]} built at snapshot {','.join(m)}, pin is {pin}"); bad += 1
if not bad:
    say("OK", "rootfs-inputs", f"{checked} rootfs row(s) built at the pin")

# --- kernel-revision --------------------------------------------------------
ledger = rows("manifests/ncz-packages.tsv") or []
if arch == "amd64":
    say("SKIP", "kernel-revision", "the Sky1 kernel is arm64-only")
else:
    bad = 0
    rel_p = root / "assets/kernel/mainline.release"
    rel = rel_p.read_text(encoding="utf-8").strip() if rel_p.is_file() else ""
    m = re.match(r"^(r[0-9]+)-", rel)
    staged = m.group(1) if m else None
    if not staged:
        fail("kernel-revision", f"assets/kernel/mainline.release '{rel}' has no rNNN- revision"); bad += 1
    # The packaging revision the debs carry: assets/kernel/mainline.deb-revision
    # when present (a repackaging of the staged release, e.g. r293 over r292),
    # else the staged release's own revision.  Never older than the staged one.
    want, src = staged, f"mainline.release ({rel})"
    dr_p = root / "assets/kernel/mainline.deb-revision"
    if dr_p.is_file():
        vals = [l.split("#", 1)[0].strip() for l in dr_p.read_text(encoding="utf-8").splitlines()]
        vals = [v for v in vals if v]
        if len(vals) != 1 or not re.fullmatch(r"r[0-9]+", vals[0]):
            fail("kernel-revision", f"assets/kernel/mainline.deb-revision must hold exactly one rNNN value, has {vals}"); bad += 1
            want = None
        else:
            want, src = vals[0], f"mainline.deb-revision over staged {rel}"
            if staged and int(want[1:]) < int(staged[1:]):
                fail("kernel-revision", f"assets/kernel/mainline.deb-revision {want} is older than the staged release {rel}"); bad += 1
                want = None
    try:
        debs = json.loads((root / "assets/kernel-manifest.json").read_text(encoding="utf-8"))["kernel_debs"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        fail("kernel-revision", f"assets/kernel-manifest.json unreadable: {e}"); bad += 1; debs = []
    if not debs and not bad:
        fail("kernel-revision", "assets/kernel-manifest.json pins no kernel_debs"); bad += 1
    lrows = {}
    for n, c in ledger:
        if len(c) >= 4 and c[0] in KERNEL_PKGS:
            lrows.setdefault((c[0], c[1], c[2]), []).append(c[3])
            r = revision(c[1])
            if want and r != want:
                fail("kernel-revision", f"manifests/ncz-packages.tsv:{n}: {c[0]} {c[1]} is revision {r}, "
                     f"packaging revision is {want} ({src})"); bad += 1
    for d in debs:
        f = Path(str(d.get("file", ""))).name
        p = split_deb(f)
        if not p:
            fail("kernel-revision", f"assets/kernel-manifest.json: unparseable deb name '{f}'"); bad += 1; continue
        r = revision(p[1])
        if want and r != want:
            fail("kernel-revision", f"assets/kernel-manifest.json pins {f} (revision {r}), "
                 f"packaging revision is {want} ({src})"); bad += 1
        shas = lrows.get(p)
        if not shas:
            fail("kernel-revision", f"assets/kernel-manifest.json pins {f}; manifests/ncz-packages.tsv has no {p[0]} {p[1]} {p[2]} row"); bad += 1
        elif d.get("sha256") not in shas:
            fail("kernel-revision", f"{f}: kernel-manifest sha256 {d.get('sha256')} != ncz-packages.tsv {','.join(shas)}"); bad += 1
    if not bad:
        say("OK", "kernel-revision", f"{want} ({src}) in kernel-manifest.json ({len(debs)} debs) and ncz-packages.tsv")

# --- tracked-debs -----------------------------------------------------------
known = {}
for n, c in ledger:
    if len(c) >= 4:
        known.setdefault((c[0], c[1], c[2]), []).append(("manifests/ncz-packages.tsv", c[3]))
for n, c in rows("manifests/vendor-debs.tsv") or []:
    if len(c) >= 6:
        known.setdefault((c[0], c[1], c[2]), []).append(("manifests/vendor-debs.tsv", c[5]))
bad = checked = 0
for rel in sorted(l for l in tracked.splitlines() if l):
    p = split_deb(Path(rel).name)
    if not p:
        fail("tracked-debs", f"{rel}: not a name_version_arch.deb file name"); bad += 1; continue
    if not arch_ok(p[2]):
        continue
    checked += 1
    hits = known.get(p)
    if not hits:
        fail("tracked-debs", f"{rel}: no {p[0]} {p[1]} {p[2]} row in manifests/ncz-packages.tsv or manifests/vendor-debs.tsv"); bad += 1
        continue
    fp = root / rel
    if not fp.is_file():
        fail("tracked-debs", f"{rel}: tracked but missing from the work tree"); bad += 1; continue
    h = sha256(fp)
    if h not in {s for _, s in hits}:
        fail("tracked-debs", f"{rel}: sha256 {h} != " + ", ".join(f"{l} {s}" for l, s in hits)); bad += 1
if not bad:
    say("OK", "tracked-debs", f"{checked} tracked deb(s) under assets/ match a ledger row")

print(f"[pin-coherence] {'FAILED' if fails else 'OK'}: {fails} finding(s)")
sys.exit(1 if fails else 0)
PY
