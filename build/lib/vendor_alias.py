#!/usr/bin/env python3
"""vendor_alias.py -- resolve a vendor apt alias (e.g. vivaldi-stable) to one exact deb.

Alias for discovery, store for reproducibility. The alias row in
manifests/vendor-aliases.tsv names a vendor's signed apt repository and a package
name. `refresh` resolves the newest version of that package per architecture,
verifies the whole chain (index signature by a pinned key -> Packages sha256 and
size from the signed index -> deb sha256 and size from Packages -> deb control
fields), stages the deb in the tree and records the result in the ledgers:

  manifests/vendor-debs.tsv    name, resolved version, arch, vendor, pool URL, sha256
  manifests/build-inputs.tsv   the staged store file (arch, dest, sha256, size)
  sbom/expected-assets.txt     existing rows for the package are updated in place

Image builds never resolve the alias; they consume the staged store file pinned
above. Re-running with nothing new upstream changes no file and downloads nothing
when the pinned deb is already staged.

Usage:
  vendor_alias.py refresh <root> <package>...   # resolve, stage, rewrite ledgers
  vendor_alias.py check   <root> <package>...   # resolve only; exit 10 if a pin is behind
  vendor_alias.py parse-index <file>            # (tests) print SHA256 entries of a Release
"""

import functools
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ALIAS_COLS = [
    "package",
    "repo_url",
    "suite",
    "component",
    "index",
    "keyring",
    "key_fprs",
    "store_dir",
    "arches",
    "vendor",
    "role",
]
TIMEOUT = int(os.environ.get("NCZ_VENDOR_FETCH_TIMEOUT", "600"))


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_aliases(root):
    path = os.path.join(root, "manifests/vendor-aliases.tsv")
    rows = {}
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            p = line.split("\t")
            if len(p) != len(ALIAS_COLS):
                die(f"{path}:{n}: expected {len(ALIAS_COLS)} columns, got {len(p)}")
            r = dict(zip(ALIAS_COLS, p))
            if r["index"] not in ("inrelease", "release"):
                die(f"{path}:{n}: index must be inrelease or release")
            rows[r["package"]] = r
    return rows


def fetch(url, dest):
    """Download url to dest (file:// works too, for tests)."""
    req = urllib.request.Request(url, headers={"User-Agent": "ncz-vendor-alias/1"})
    try:
        with (
            urllib.request.urlopen(req, timeout=TIMEOUT) as r,
            open(dest + ".part", "wb") as o,
        ):
            shutil.copyfileobj(r, o, 1 << 20)
    except (OSError, ValueError) as e:
        if os.path.exists(dest + ".part"):
            os.unlink(dest + ".part")
        die(f"download failed: {url}: {e}")
    os.replace(dest + ".part", dest)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kw)


def keyring(root, alias, work):
    """Dearmor the pinned keyring and require its primary fingerprints to equal key_fprs."""
    asc = os.path.join(root, alias["keyring"])
    want = sorted(x.strip().upper() for x in alias["key_fprs"].split(",") if x.strip())
    r = run(["gpg", "--batch", "--show-keys", "--with-colons", asc])
    if r.returncode != 0:
        die(f"{alias['keyring']}: cannot read key: {r.stderr.strip()}")
    got, prev = [], ""
    for line in r.stdout.splitlines():
        f = line.split(":")
        if f[0] == "fpr" and prev == "pub":
            got.append(f[9].upper())
        prev = f[0]
    if sorted(got) != want:
        die(f"{alias['keyring']}: primary key fingerprints {got} != pinned {want}")
    kr = os.path.join(work, "keyring.gpg")
    with open(asc, "rb") as i, open(kr, "wb") as o:
        r = subprocess.run(
            ["gpg", "--batch", "--dearmor"], stdin=i, stdout=o, check=False
        )
    if r.returncode != 0:
        die(f"{alias['keyring']}: gpg --dearmor failed")
    return kr, want


def verified_release(alias, work, kr, fprs):
    """Fetch and verify the signed index; return its signed text."""
    base = f"{alias['repo_url']}/dists/{alias['suite']}"
    if alias["index"] == "inrelease":
        src = os.path.join(work, "InRelease")
        fetch(f"{base}/InRelease", src)
        out = os.path.join(work, "Release.signed")
        cmd = ["gpgv", "--status-fd", "1", "--keyring", kr, "--output", out, src]
    else:
        out = os.path.join(work, "Release")
        sig = os.path.join(work, "Release.gpg")
        fetch(f"{base}/Release", out)
        fetch(f"{base}/Release.gpg", sig)
        cmd = ["gpgv", "--status-fd", "1", "--keyring", kr, sig, out]
    r = run(cmd)
    if r.returncode != 0:
        die(f"{alias['package']}: index signature not valid: {r.stderr.strip()}")
    # VALIDSIG <sig fpr> ... <primary fpr> (the last field) must be a pinned primary key.
    ok = False
    for line in r.stdout.splitlines():
        p = line.split()
        if len(p) >= 3 and p[1] == "VALIDSIG" and p[-1].upper() in fprs:
            ok = True
    if not ok:
        die(f"{alias['package']}: index not signed by a pinned primary key {fprs}")
    with open(out, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if alias["suite"] not in re.findall(
        r"^(?:Suite|Codename):\s*(\S+)", text, re.MULTILINE
    ):
        die(f"{alias['package']}: signed index is not for suite {alias['suite']}")
    return text


def sha256_entries(text):
    """{path: (sha256, size)} from the SHA256 section of a Release file."""
    ent, on = {}, False
    for line in text.splitlines():
        if line.startswith("SHA256:"):
            on = True
            continue
        if on and line.startswith(" "):
            p = line.split()
            if len(p) == 3:
                ent[p[2]] = (p[0].lower(), int(p[1]))
            continue
        on = False
    return ent


def stanzas(text):
    cur = {}
    for line in text.splitlines() + [""]:
        if not line.strip():
            if cur:
                yield cur
            cur = {}
            continue
        if line[0] in " \t":
            continue
        k, _, v = line.partition(":")
        cur[k.strip()] = v.strip()


def dpkg_cmp(a, b):
    if a == b:
        return 0
    if run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0:
        return -1
    return 1


def resolve(alias, arch, work, release_text):
    rel = f"{alias['component']}/binary-{arch}/Packages"
    ent = sha256_entries(release_text)
    if rel not in ent:
        die(
            f"{alias['package']}: the signed index lists no {rel} (no {arch} build published)"
        )
    path = os.path.join(work, f"Packages-{arch}")
    fetch(f"{alias['repo_url']}/dists/{alias['suite']}/{rel}", path)
    sha, size = ent[rel]
    if sha256_file(path) != sha or os.path.getsize(path) != size:
        die(f"{alias['package']}: {rel} does not match the signed index")
    with open(path, encoding="utf-8", errors="replace") as f:
        cands = [
            s
            for s in stanzas(f.read())
            if s.get("Package") == alias["package"] and s.get("Architecture") == arch
        ]
    if not cands:
        die(f"{alias['package']}: no {arch} package in the signed index")
    best = max(
        cands,
        key=functools.cmp_to_key(lambda x, y: dpkg_cmp(x["Version"], y["Version"])),
    )
    for k in ("Version", "Filename", "SHA256", "Size"):
        if not best.get(k):
            die(f"{alias['package']}/{arch}: index entry has no {k}")
    if ":" in best["Version"] or "/" in best["Version"]:
        die(
            f"{alias['package']}/{arch}: version {best['Version']!r} cannot name a staged file"
        )
    return {
        "version": best["Version"],
        "url": f"{alias['repo_url']}/{best['Filename']}",
        "sha256": best["SHA256"].lower(),
        "size": int(best["Size"]),
    }


def read_lines(path):
    with open(path) as f:
        return f.read().split("\n")


def write_if_changed(path, lines):
    new = "\n".join(lines)
    with open(path) as f:
        if f.read() == new:
            return False
    with open(path + ".part", "w") as f:
        f.write(new)
    os.replace(path + ".part", path)
    return True


def record(root, alias, arch, res, dest):
    """Rewrite the ledger rows for <package>/<arch>; return the list of files changed."""
    pkg, changed = alias["package"], []
    note = (
        f"{alias['role']}; alias {pkg} from {alias['repo_url']} "
        f"{alias['suite']}/{alias['component']} (manifests/vendor-aliases.tsv), "
        f"resolved by build/refresh-vendor-debs.sh"
    )
    vf = os.path.join(root, "manifests/vendor-debs.tsv")
    L, hit = read_lines(vf), 0
    for i, line in enumerate(L):
        p = line.split("\t")
        if len(p) >= 7 and p[0] == pkg and p[2] == arch:
            L[i] = "\t".join(
                [
                    pkg,
                    res["version"],
                    arch,
                    alias["vendor"],
                    res["url"],
                    res["sha256"],
                    note,
                ]
            )
            hit += 1
    if hit != 1:
        die(f"manifests/vendor-debs.tsv: expected one {pkg}/{arch} row, found {hit}")
    if write_if_changed(vf, L):
        changed.append("manifests/vendor-debs.tsv")

    bf = os.path.join(root, "manifests/build-inputs.tsv")
    prefix = f"{arch}\t{alias['store_dir']}/{pkg}_"
    row = "\t".join(
        [
            arch,
            dest,
            res["sha256"],
            str(res["size"]),
            (
                f"{alias['vendor']} {pkg} {res['version']} (alias {pkg}, signed index verified by "
                f"build/refresh-vendor-debs.sh; same bytes as manifests/vendor-debs.tsv)"
            ),
        ]
    )
    B, out, placed = read_lines(bf), [], False
    for line in B:
        if line.startswith(prefix):
            if not placed:
                out.append(row)
                placed = True
            continue
        out.append(line)
    if not placed:
        while out and out[-1] == "":
            out.pop()
        out += [row, ""]
    if write_if_changed(bf, out):
        changed.append("manifests/build-inputs.tsv")

    sf = os.path.join(root, "sbom/expected-assets.txt")
    if os.path.exists(sf):
        S = read_lines(sf)
        pat = re.compile(
            re.escape(f"{alias['store_dir']}/{pkg}_")
            + r"[^|/]*_"
            + re.escape(arch)
            + r"\.deb\|"
        )
        S = [f"{dest}|{res['size']}|{res['sha256']}" if pat.match(x) else x for x in S]
        if write_if_changed(sf, S):
            changed.append("sbom/expected-assets.txt")
    return changed


def stage(root, alias, arch, res):
    d = os.path.join(root, alias["store_dir"])
    os.makedirs(d, exist_ok=True)
    name = f"{alias['package']}_{res['version']}_{arch}.deb"
    out = os.path.join(d, name)
    fetched = False
    if not (
        os.path.isfile(out)
        and os.path.getsize(out) == res["size"]
        and sha256_file(out) == res["sha256"]
    ):
        fetch(res["url"], out + ".dl")
        if (
            os.path.getsize(out + ".dl") != res["size"]
            or sha256_file(out + ".dl") != res["sha256"]
        ):
            os.unlink(out + ".dl")
            die(f"{name}: downloaded bytes do not match the signed index")
        os.replace(out + ".dl", out)
        fetched = True
    for k, want in (
        ("Package", alias["package"]),
        ("Version", res["version"]),
        ("Architecture", arch),
    ):
        r = run(["dpkg-deb", "-f", out, k])
        if r.returncode != 0 or r.stdout.strip() != want:
            die(f"{name}: control field {k}={r.stdout.strip()!r}, expected {want!r}")
    # Only the resolved deb stays in the tree, so the layer builder stages exactly one.
    for f in os.listdir(d):
        if (
            f != name
            and f.startswith(alias["package"] + "_")
            and f.endswith(f"_{arch}.deb")
        ):
            os.unlink(os.path.join(d, f))
            print(
                f"  removed superseded local {alias['store_dir']}/{f} (the store keeps its copy)"
            )
    return f"{alias['store_dir']}/{name}", fetched


def pinned(root, pkg, arch):
    for line in read_lines(os.path.join(root, "manifests/vendor-debs.tsv")):
        p = line.split("\t")
        if len(p) >= 7 and p[0] == pkg and p[2] == arch:
            return p[1], p[5]
    return None, None


def main(argv):
    if len(argv) >= 2 and argv[0] == "parse-index":
        with open(argv[1]) as f:
            for k, (s, n) in sorted(sha256_entries(f.read()).items()):
                print(f"{s} {n} {k}")
        return 0
    if len(argv) < 3 or argv[0] not in ("refresh", "check"):
        print(__doc__, file=sys.stderr)
        return 2
    mode, root, pkgs = argv[0], os.path.abspath(argv[1]), argv[2:]
    aliases = load_aliases(root)
    behind, changed_files, staged = 0, set(), []
    base_tmp = os.environ.get("TMPDIR") or "/var/tmp"
    for pkg in pkgs:
        if pkg not in aliases:
            die(f"{pkg}: not in manifests/vendor-aliases.tsv")
        a = aliases[pkg]
        with tempfile.TemporaryDirectory(prefix="vendor-alias.", dir=base_tmp) as work:
            kr, fprs = keyring(root, a, work)
            text = verified_release(a, work, kr, fprs)
            for arch in [x for x in a["arches"].split(",") if x]:
                res = resolve(a, arch, work, text)
                pv, ps = pinned(root, pkg, arch)
                state = (
                    "current"
                    if (pv, ps) == (res["version"], res["sha256"])
                    else f"pinned {pv}"
                )
                print(
                    f"{pkg} {arch}: alias resolves to {res['version']} sha256 {res['sha256']} ({state})"
                )
                if mode == "check":
                    behind += state != "current"
                    continue
                dest, fetched = stage(root, a, arch, res)
                changed_files.update(record(root, a, arch, res, dest))
                staged.append(
                    f"{arch}\t{dest}\t{'downloaded' if fetched else 'already staged'}"
                )
    if mode == "check":
        return 10 if behind else 0
    for s in staged:
        print("staged\t" + s)
    for f in sorted(changed_files):
        print("changed\t" + f)
    if not changed_files:
        print("ledgers unchanged (pins already at the alias' current version)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
