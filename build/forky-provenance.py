#!/usr/bin/env python3
"""forky_provenance.py -- every package must have exactly one origin.

  NCZ     our own build: ncz-*/cix-*/cixmini-*/chromium-ncz-*/panthor-cix-dkms/
          zoder/linux-image-*/linux-headers-* (the namespace in
          post-install/lib/apt-separation.sh, read from there, never restated),
          or a Debian-named package that carries a "+ncz" version (the reviewed
          libdrm override rows in the same file).
  VENDOR  a third-party vendor's own deb, listed in manifests/vendor-debs.tsv
          (name, version, arch, vendor, url, sha256, note).
  FORKY   (name, version, arch) present in the pinned Debian forky snapshot
          Packages lists (release.conf NCZ_BASE_MIRROR_SNAPSHOT), and where the
          deb itself is available, byte-identical (sha256).

Anything else -- Ubuntu, another Debian suite, an older snapshot, unknown --
is a hard failure.  There is deliberately NO allow-by-reason mechanism.

Also audits apt configuration (sources + preferences) and os-release of every
rootfs it is pointed at.

Modes: --ubuntu-only skips the snapshot index (no network) and fails only on
Ubuntu evidence (maintainer / version / os-release / sources); it is what
`make lint-platform` runs.  Without it an index is required (fail closed).
"""

import argparse
import glob
import gzip
import hashlib
import lzma
import os
import re
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE) if os.path.basename(HERE) == "build" else HERE
if os.environ.get("NCZ_PROVENANCE_ROOT"):
    ROOT = os.environ["NCZ_PROVENANCE_ROOT"]

FAILS = []


def fail(src, what, why):
    FAILS.append((src, what, why))
    print(f"FAIL  [{src}] {what} :: {why}")


# ---------------------------------------------------------------- parsing
def parse_stanzas(text):
    for st in re.split(r"\n\s*\n", text):
        d = {}
        for line in st.split("\n"):
            if line[:1] in (" ", "\t"):
                continue
            if ":" in line:
                k, v = line.split(":", 1)
                d[k.strip()] = v.strip()
        if "Package" in d:
            yield d


def read_maybe_compressed(path):
    op = (
        lzma.open
        if path.endswith(".xz")
        else gzip.open
        if path.endswith(".gz")
        else open
    )
    with op(path, "rt", encoding="utf-8", errors="replace") as f:
        return f.read()


def deb_control(path):
    r = subprocess.run(
        ["dpkg-deb", "-f", path, "Package", "Version", "Architecture", "Maintainer"],
        capture_output=True,
        check=False,
        text=True,
    )
    d = {}
    for line in r.stdout.split("\n"):
        if ": " in line:
            k, v = line.split(": ", 1)
            d[k] = v
    return d


def slurp(path, **kw):
    with open(path, **kw) as f:
        return f.read()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


# ---------------------------------------------------------------- reference data
def load_tsv(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    for line in slurp(path, encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        rows.append(line.split("\t"))
    return rows


def bash_lines(fn):
    lib = os.path.join(ROOT, "post-install/lib/apt-separation.sh")
    r = subprocess.run(
        ["bash", "-c", f'. "{lib}"; {fn}'], capture_output=True, check=False, text=True
    )
    return [l for l in r.stdout.split("\n") if l]


def bash_var(name):
    lib = os.path.join(ROOT, "post-install/lib/apt-separation.sh")
    r = subprocess.run(
        ["bash", "-c", f'. "{lib}"; printf %s "${{{name}}}"'],
        capture_output=True,
        check=False,
        text=True,
    )
    return r.stdout.split()


def release_conf(key, default=""):
    p = os.path.join(ROOT, "release.conf")
    if os.path.isfile(p):
        m = re.search(rf'^{key}="?([^"\n]*)"?', slurp(p), re.MULTILINE)
        if m:
            return m.group(1)
    return default


class Ref:
    def __init__(self, a):
        self.ubuntu_only = a.ubuntu_only
        self.vendor = {}
        for r in load_tsv(
            a.vendor_debs or os.path.join(ROOT, "manifests/vendor-debs.tsv")
        ):
            if len(r) >= 7:
                self.vendor.setdefault((r[0], r[1], r[2]), set()).add(r[5])
        self.vendor_repos = [
            r
            for r in load_tsv(
                a.vendor_repos or os.path.join(ROOT, "manifests/vendor-repos.tsv")
            )
            if len(r) >= 4
        ]
        self.ns = bash_lines("ncz_apt_namespace_patterns")
        self.overrides = {
            l.split("\t")[0] for l in bash_lines("ncz_apt_debian_overrides")
        }
        self.ncz_hosts = bash_var("NCZ_APT_NCZ_HOSTS")
        self.codename = release_conf("NCZ_BASE_CODENAME", "forky")
        self.pin = release_conf("NCZ_BASE_MIRROR_SNAPSHOT", "")
        self.idx = {}
        if not self.ubuntu_only:
            self.load_index(a)

    def load_index(self, a):
        d = a.index_dir or os.environ.get("NCZ_FORKY_INDEX_DIR")
        if not d:
            print(
                "ERROR: no forky snapshot index (use --index-dir DIR, NCZ_FORKY_INDEX_DIR, or --fetch-index DIR); "
                "failing closed",
                file=sys.stderr,
            )
            sys.exit(2)
        if a.fetch_index:
            fetch_index(d, self.pin, self.codename)
        files = glob.glob(os.path.join(d, "*Packages*"))
        files = [f for f in files if f.endswith((".xz", ".gz", "Packages"))]
        if not files:
            print(f"ERROR: no Packages files in {d}", file=sys.stderr)
            sys.exit(2)
        for f in files:
            for s in parse_stanzas(read_maybe_compressed(f)):
                self.idx[(s["Package"], s["Version"], s["Architecture"])] = s.get(
                    "SHA256", ""
                )

    def ncz_name(self, name):
        if re.fullmatch(
            r"linux-(image|headers)(-.*)?-(amd64|arm64)|linux-(image|headers)-(amd64|arm64)",
            name,
        ):
            return False  # Debian's own kernels are never NCZ
        import fnmatch

        return any(fnmatch.fnmatchcase(name, p) for p in self.ns)


def fetch_index(d, pin, codename):
    os.makedirs(d, exist_ok=True)
    for arch in ("amd64", "arm64", "all"):
        for comp in (
            "main",
            "contrib",
            "non-free",
            "non-free-firmware",
            "main/debian-installer",
        ):
            if comp.endswith("installer") and arch == "all":
                continue
            url = f"https://snapshot.debian.org/archive/debian/{pin}/dists/{codename}/{comp}/binary-{arch}/Packages.xz"
            out = os.path.join(
                d, f"{codename}-{comp.replace(chr(47), chr(95))}-{arch}.Packages.xz"
            )
            if os.path.isfile(out):
                continue
            with urllib.request.urlopen(url, timeout=300) as r, open(out, "wb") as f:
                f.write(r.read())


# ---------------------------------------------------------------- classification
UBU_RE = re.compile(r"ubuntu", re.IGNORECASE)


def classify(ref, src, name, ver, arch, maint, sha=None):
    """Return origin string or None after emitting a FAIL."""
    what = f"{name} {ver} {arch}"
    key = (name, ver, arch)
    if UBU_RE.search(maint or ""):
        # Debian packages are routinely maintained by Debian developers with an
        # @ubuntu.com address (tpm2-tss, editorconfig...). Only a package whose
        # exact name/version/arch is in the pinned Debian snapshot (and whose
        # bytes match when known) is exonerated; the canonical Ubuntu-build
        # markers are never exonerated.
        canonical = re.search(r"Ubuntu Developers|lists\.ubuntu\.com", maint)
        in_debian = (
            (not ref.ubuntu_only)
            and key in ref.idx
            and not canonical
            and not (sha and ref.idx[key] and sha != ref.idx[key])
        )
        if not in_debian:
            if ref.ubuntu_only and not canonical:
                print(
                    f"WARN  [{src}] {what} :: @ubuntu.com maintainer ({maint}); needs the snapshot index to clear"
                )
            else:
                fail(
                    src,
                    what,
                    f"Ubuntu-maintained ({maint}) and not byte-identical to a Debian forky snapshot package",
                )
                return None
    if UBU_RE.search(ver):
        fail(src, what, "version contains 'ubuntu'")
        return None
    # vendor (must match the reviewed list exactly; sha enforced when known)
    v = ref.vendor.get((name, ver, arch))
    if v is not None:
        if sha and sha not in v:
            fail(
                src,
                what,
                f"vendor deb sha256 {sha[:16]}.. not pinned in vendor-debs.tsv",
            )
            return None
        return "vendor"
    if ref.ncz_name(name) or re.search(r"\+ncz", ver):
        return "ncz"
    if ref.ubuntu_only:
        return "unchecked"
    if key in ref.idx:
        if sha and ref.idx[key] and sha != ref.idx[key]:
            fail(
                src,
                what,
                f"same name/version as forky snapshot but sha256 differs (rebuilt/foreign bytes): {sha[:16]}.. vs {ref.idx[key][:16]}..",
            )
            return None
        return "forky"
    fail(
        src,
        what,
        "not NCZ, not a listed vendor deb, and not in the pinned forky snapshot (unknown origin)",
    )
    return None


def scan_status(ref, text, src):
    n = 0
    for d in parse_stanzas(text):
        if (
            "installed" not in d.get("Status", "installed")
            or d.get("Status", "").endswith("not-installed")
            or d.get("Status", "").split(" ")[-1]
            in ("config-files", "half-installed", "not-installed")
        ):
            continue
        n += 1
        classify(
            ref,
            src,
            d["Package"],
            d["Version"],
            d["Architecture"],
            d.get("Maintainer", ""),
        )
    return n


def scan_packages(ref, text, src):
    n = 0
    for d in parse_stanzas(text):
        n += 1
        classify(
            ref,
            src,
            d["Package"],
            d["Version"],
            d["Architecture"],
            d.get("Maintainer", ""),
            d.get("SHA256"),
        )
    return n


def scan_debs(ref, d, src):
    n = 0
    for p in sorted(
        glob.glob(os.path.join(d, "**", "*.deb"), recursive=True)
        + glob.glob(os.path.join(d, "**", "*.udeb"), recursive=True)
    ):
        c = deb_control(p)
        if "Package" not in c:
            fail(src, p, "unreadable deb")
            continue
        n += 1
        classify(
            ref,
            src + ":" + os.path.relpath(p, d),
            c["Package"],
            c["Version"],
            c["Architecture"],
            c.get("Maintainer", ""),
            sha256_file(p),
        )
    return n


# ---------------------------------------------------------------- apt config / os-release
SUITE_BAD = re.compile(
    r"\b(ubuntu|resolute|noble|jammy|plucky|questing|trixie|bookworm|bullseye|oldstable|stable|"
    r"testing|sid|unstable|experimental)\b|backports|proposed",
    re.IGNORECASE,
)


def parse_sources(text):
    """Yield (uri, suite) from one-line (.list) and deb822 (.sources) text."""
    if re.search(r"^Types:", text, re.MULTILINE):
        for st in re.split(r"\n\s*\n", text):
            d = {}
            for line in st.split("\n"):
                if ":" in line and not line.startswith("#"):
                    k, v = line.split(":", 1)
                    d[k.strip()] = v.strip()
            if d.get("Enabled", "yes").lower() == "no":
                continue
            for u in d.get("URIs", "").split():
                for s in d.get("Suites", "").split():
                    yield u, s
    else:
        for line in text.split("\n"):
            line = line.strip()
            if not line.startswith("deb"):
                continue
            line = re.sub(r"\[[^\]]*\]", "", line)
            parts = line.split()
            if len(parts) >= 3:
                yield parts[1], parts[2]


def source_ok(ref, uri, suite):
    u = uri.rstrip("/")
    m = re.match(r"https?://snapshot\.debian\.org/archive/debian/(\d{8}T\d{6}Z)$", u)
    if m:
        if suite != ref.codename:
            return f"snapshot suite '{suite}' is not '{ref.codename}'"
        if ref.pin and m.group(1) != ref.pin:
            return f"snapshot {m.group(1)} is not the pinned {ref.pin}"
        return None
    if re.match(r"https?://(deb|ftp)\.debian\.org/debian$", u) or re.match(
        r"https?://[a-z.]*\.debian\.org/debian$", u
    ):
        return (
            None
            if suite == ref.codename
            else f"suite '{suite}' is not '{ref.codename}'"
        )
    if u.startswith(("file:", "/")):
        return (
            None
            if not SUITE_BAD.search(suite)
            else f"offline source with suite '{suite}'"
        )
    host = re.sub(r"^\w+://", "", u).split("/")[0]
    if host in ref.ncz_hosts:
        return None
    for r in ref.vendor_repos:
        if host == r[0] and (r[1] in ("*", suite)):
            return None
    return f"source {u} {suite} is not forky, the NCZ repo, an offline pool or a listed vendor repo"


def audit_apt_files(ref, src, files):
    """files: dict relpath -> text for etc/apt/sources.list, sources.list.d/*, preferences(.d)/*"""
    for rel, text in files.items():
        if rel.endswith((".disabled", ".dpkg-old", "~")):
            continue
        if "/preferences" in "/" + rel:
            for st in re.split(r"\n\s*\n", text):
                m = re.search(r"Pin-Priority:\s*(-?\d+)", st)
                if not m or int(m.group(1)) < 0:
                    continue
                for pl in re.findall(r"^Pin:\s*(.*)$", st, re.MULTILINE):
                    if SUITE_BAD.search(pl) and not re.search(r"o=NCZ|origin", pl):
                        fail(src, rel, f"apt pin >=0 names a non-forky suite: '{pl}'")
            continue
        if not ("sources.list" in rel):
            continue
        for uri, suite in parse_sources(text):
            why = source_ok(ref, uri, suite)
            if why:
                fail(src, rel, why)


def audit_osrelease(src, text):
    kv = dict(re.findall(r"^([A-Z_]+)=(.*)$", text, re.MULTILINE))
    idv = kv.get("ID", "").strip('"')
    if idv == "ubuntu":
        fail(src, "os-release", "ID=ubuntu")
    if "ubuntu" in kv.get("ID_LIKE", "").lower():
        fail(src, "os-release", f"ID_LIKE={kv['ID_LIKE']} (claims Ubuntu lineage)")
    if "UBUNTU_CODENAME" in kv:
        fail(src, "os-release", "UBUNTU_CODENAME is set")


def scan_rootfs(ref, root, src):
    def rd(rel):
        p = os.path.join(root, rel)
        return slurp(p, errors="replace") if os.path.isfile(p) else None

    st = rd("var/lib/dpkg/status")
    n = scan_status(ref, st, src) if st else 0
    for rel in ("etc/os-release", "usr/lib/os-release"):
        t = rd(rel)
        if t:
            audit_osrelease(src, t)
            break
    files = {}
    for pat in (
        "etc/apt/sources.list",
        "etc/apt/sources.list.d/*",
        "etc/apt/preferences",
        "etc/apt/preferences.d/*",
    ):
        for p in glob.glob(os.path.join(root, pat)):
            if os.path.isfile(p):
                files[os.path.relpath(p, root)] = slurp(p, errors="replace")
    audit_apt_files(ref, src, files)
    return n


def scan_squashfs(ref, sq, src):
    def cat(rel):
        r = subprocess.run(
            ["unsquashfs", "-cat", sq, rel], capture_output=True, check=False
        )
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None

    st = cat("var/lib/dpkg/status")
    n = scan_status(ref, st, src) if st else 0
    for rel in ("etc/os-release", "usr/lib/os-release"):
        t = cat(rel)
        if t:
            audit_osrelease(src, t)
            break
    ls = subprocess.run(
        ["unsquashfs", "-ll", sq, "etc/apt"],
        capture_output=True,
        check=False,
        text=True,
    ).stdout
    files = {}
    for line in ls.split("\n"):
        m = re.search(
            r"squashfs-root/(etc/apt/(?:sources\.list(?:\.d/[^ ]+)?|preferences(?:\.d/[^ ]+)?))$",
            line.strip(),
        )
        if m and not line.startswith("d"):
            t = cat(m.group(1))
            if t is not None:
                files[m.group(1)] = t
    audit_apt_files(ref, src, files)
    return n


# ---------------------------------------------------------------- finished .img
def scan_image(ref, img, work):
    """Scan a finished GPT .img (data partition = largest ext4): the offline
    pool, every squashfs layer and the rescue/mgmt rootfs tarballs. Reads the
    image with debugfs, so no root and no loop mount are needed."""
    import json
    import shutil

    os.makedirs(work, exist_ok=True)
    fs = subprocess.run(
        ["findmnt", "-no", "FSTYPE", "-T", work],
        capture_output=True,
        check=False,
        text=True,
    ).stdout.strip()
    if fs in ("tmpfs", "ramfs", "devtmpfs"):
        print(
            f"ERROR: --work {work} is on {fs}; use local disk (e.g. ~/Projects/...)",
            file=sys.stderr,
        )
        sys.exit(2)
    j = json.loads(
        subprocess.run(
            ["sfdisk", "-J", img], capture_output=True, text=True, check=True
        ).stdout
    )
    part = max(j["partitiontable"]["partitions"], key=lambda x: x["size"])
    dev = f"{img}?offset={part['start'] * 512}"
    base = os.path.join(work, "img")
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base)
    pl = os.path.join(base, "payload")
    os.makedirs(pl)

    def dbg(*args):
        return subprocess.run(
            ["debugfs", "-R", " ".join(args), dev],
            capture_output=True,
            check=False,
            text=True,
        ).stdout

    for t in ("dists", "pool"):
        dbg("rdump", "/" + t, base)
    for line in dbg("ls", "-p", "/ncz-payload").split("\n"):
        f = line.split("/")[5] if line.count("/") >= 5 else ""
        if f.endswith(".squashfs"):
            dbg("dump", "/ncz-payload/" + f, os.path.join(pl, f))
    for rel in (
        "rescue",
        "mgmt",
        "cix-debs",
        "ncz-screensavers-plugin",
        "kernel",
        "npu",
    ):
        dbg("rdump", "/ncz-payload/assets/" + rel, pl)
    total = 0
    if os.path.isdir(os.path.join(base, "pool")):
        total += scan_debs(ref, os.path.join(base, "pool"), "image:pool")
    else:
        fail("image", img, "no /pool in the data partition")
    layers = sorted(glob.glob(os.path.join(pl, "*.squashfs")))
    if not layers:
        fail("image", img, "no squashfs layers found in /ncz-payload")
    for f in layers:
        total += scan_squashfs(ref, f, "image:" + os.path.basename(f))
    for tb in glob.glob(os.path.join(pl, "**", "*rootfs*.tar.zst"), recursive=True):
        d = tb[: -len(".tar.zst")] + ".x"
        os.makedirs(d, exist_ok=True)
        z = subprocess.Popen(["zstd", "-dc", tb], stdout=subprocess.PIPE)
        subprocess.run(
            [
                "tar",
                "-x",
                "-C",
                d,
                "--exclude=./dev/*",
                "--no-same-owner",
                "--no-same-permissions",
            ],
            stdin=z.stdout,
            capture_output=True,
            check=False,
        )
        total += scan_rootfs(ref, d, "image:" + os.path.basename(tb))
    for d in ("cix-debs", "ncz-screensavers-plugin", "kernel", "npu"):
        if os.path.isdir(os.path.join(pl, d)):
            total += scan_debs(ref, os.path.join(pl, d), "image:assets/" + d)
    shutil.rmtree(base, ignore_errors=True)
    return total


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--ubuntu-only", action="store_true")
    ap.add_argument("--index-dir")
    ap.add_argument(
        "--fetch-index",
        action="store_true",
        help="download the pinned snapshot Packages into --index-dir if absent",
    )
    ap.add_argument("--vendor-debs")
    ap.add_argument("--vendor-repos")
    ap.add_argument(
        "--debs", action="append", default=[], help="directory tree of .deb/.udeb files"
    )
    ap.add_argument(
        "--packages", action="append", default=[], help="Packages file (.xz/.gz ok)"
    )
    ap.add_argument("--status", action="append", default=[], help="dpkg status file")
    ap.add_argument(
        "--rootfs", action="append", default=[], help="extracted rootfs dir"
    )
    ap.add_argument(
        "--squashfs",
        action="append",
        default=[],
        help="squashfs layer (needs unsquashfs)",
    )
    ap.add_argument(
        "--image",
        action="append",
        default=[],
        help="finished .img (needs --work on local disk)",
    )
    ap.add_argument(
        "--work", help="scratch dir for --image (must not be tmpfs; removed afterwards)"
    )
    a = ap.parse_args()
    if not (a.debs or a.packages or a.status or a.rootfs or a.squashfs or a.image):
        ap.error("nothing to scan")
    ref = Ref(a)
    total = 0
    for d in a.debs:
        total += scan_debs(ref, d, d)
    for f in a.packages:
        total += scan_packages(ref, read_maybe_compressed(f), f)
    for f in a.status:
        total += scan_status(ref, slurp(f, errors="replace"), f)
    for r in a.rootfs:
        total += scan_rootfs(ref, r, r)
    for s in a.squashfs:
        total += scan_squashfs(ref, s, s)
    for im in a.image:
        if not a.work:
            ap.error("--image needs --work DIR")
        total += scan_image(ref, im, a.work)
    mode = (
        "ubuntu-only"
        if a.ubuntu_only
        else f"forky-provenance (snapshot {ref.pin}, {len(ref.idx)} index entries)"
    )
    print(f"== {mode}: {total} packages checked, {len(FAILS)} failure(s)")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
