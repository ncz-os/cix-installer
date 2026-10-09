#!/usr/bin/env python3
"""forky-provenance.py -- every package must have exactly one reviewed origin.

  NCZ     its exact (name, version, arch) is in manifests/ncz-packages.tsv, a
          reviewed build ledger that names a canonical recipe + source revision
          and a reviewed sha256.  Package-name prefixes and "+ncz" versions are
          NOT proof of anything.
  VENDOR  a third-party vendor's own deb, listed in manifests/vendor-debs.tsv
          (name, version, arch, vendor, source, sha256, note); sha enforced when
          the deb bytes are available.
  FORKY   (name, version, arch) present in the PINNED Debian forky snapshot,
          whose signed Release is verified against the committed keyring and
          InRelease digest in manifests/forky-snapshot.tsv, with a sha256+size
          chain to every Packages index.  When the deb itself is available it
          must be byte-identical.

Anything else -- Ubuntu, another Debian suite, an older snapshot, unknown --
is a hard failure.  There is deliberately NO allow-by-reason mechanism.

Trust root: the checkout that contains this file.  No environment variable and
no command-line flag relocates the trust metadata (manifests/, release.conf).
The snapshot index DIRECTORY may be pointed anywhere, because its contents are
cryptographically verified against the committed InRelease digest and the
signed Release every run -- a location is not a trust decision.

Modes: --ubuntu-only is the offline lint mode (no network, no index, no trust
metadata); it fails only on explicit Ubuntu evidence and is what
`build/check-no-ubuntu.sh` runs.  Without it, a verified index is required (fail
closed).
"""

import argparse
import glob
import gzip
import hashlib
import json
import lzma
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# The checkout containing this verifier is the trust root.  Do NOT let an
# environment variable redirect a ship-mode invocation to a different tree with
# different release.conf/manifests.
ROOT = os.path.dirname(HERE) if os.path.basename(HERE) == "build" else HERE

# External tools run with a fixed, scrubbed environment: no inherited PATH
# tricks, no BASH_ENV, no BASH_FUNC_*, no NCZ_* overrides leaking into anything
# the verifier shells out to.
TOOL_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PIN_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# The exact, expected debugfs rdump warning a NON-ROOT scan cannot avoid: it
# cannot chown a dumped file.  Anchored so a differently-worded error is not
# mistaken for it.  Only ever tolerated for rdump, and only alongside the
# independent type+size completeness proof in check_complete().
CHOWN_PERM_RE = re.compile(
    r"^.*:?\s*Operation not permitted while changing ownership\s*$"
)

FAILS = []


def fail(src, what, why):
    FAILS.append((src, what, why))
    print(f"FAIL  [{src}] {what} :: {why}")


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def tool_env():
    return {"PATH": TOOL_PATH, "LC_ALL": "C", "LANG": "C"}


def run(argv, **kw):
    """subprocess.run with the scrubbed tool environment.  Callers may pass
    check=True; the default is check=False (we inspect return codes)."""
    kw.setdefault("check", False)
    return subprocess.run(argv, env=tool_env(), **kw)  # noqa: PLW1510


def need_tool(name):
    if shutil.which(name, path=TOOL_PATH):
        return True
    fail("env", name, "required tool not found (PATH is fixed and scrubbed)")
    return False


# ---------------------------------------------------------------- virtual archive root
class UnsafeArchive(Exception):
    """A tar/cpio member would escape the extraction root or link to the host."""


def safe_symlink_target(name, target):
    """Validate a symlink target against a VIRTUAL ARCHIVE ROOT.

    Returns ``(True, rewritten)`` when the link stays inside the archive's own
    virtual root, else ``(False, None)``.

    Absolute targets name a path inside the archive root, never the host:
    an initrd's ``etc/mtab -> /proc/mounts`` and a usrmerge rootfs's
    ``var/run -> /run`` / ``var/lock -> /run/lock`` are legitimate and were the
    false positives.  We rewrite an absolute target to the equivalent RELATIVE
    link so that, if it is ever materialised, it still cannot be followed onto
    the host.  A relative target that climbs above the root escapes and is
    rejected.  An empty or interior-NUL target is rejected.
    """
    if not target or "\x00" in target:
        return False, None
    if target.startswith("/"):
        virt = posixpath.normpath(target).lstrip("/")
        if virt in ("", "."):
            return False, None
        parent = posixpath.dirname(posixpath.normpath(name)) if name else ""
        rewritten = posixpath.relpath(virt, parent or ".")
        # relpath from one in-root path to another always stays in-root.
        return True, rewritten
    norm = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
    if norm == ".." or norm.startswith("../"):
        return False, None
    return True, target


def safe_hardlink_target(name):
    """A tar hard-link target must be a plain relative archive path; absolute or
    '..'-climbing targets could hard-link (and thus expose) a host file."""
    if not name or name.startswith("/") or "\x00" in name:
        return False
    return ".." not in name.split("/")


# ---------------------------------------------------------------- parsing
def parse_stanzas(text):
    """Yield every non-empty control stanza (dict).  Callers MUST validate with
    stanza_ok so a stanza with no Package is reported, never dropped."""
    for st in re.split(r"\n\s*\n", text or ""):
        d = {}
        for line in st.split("\n"):
            if line[:1] in (" ", "\t"):
                continue
            if ":" in line:
                k, v = line.split(":", 1)
                d[k.strip()] = v.strip()
        if d:
            yield d


def stanza_ok(d, src, kind="control"):
    missing = [k for k in ("Package", "Version", "Architecture") if not d.get(k)]
    if missing:
        fail(
            src,
            d.get("Package", "<record without Package>"),
            f"malformed {kind} record: missing field(s) {', '.join(missing)}",
        )
        return False
    return True


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
    r = run(
        ["dpkg-deb", "-f", path, "Package", "Version", "Architecture", "Maintainer"],
        capture_output=True,
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


# ---------------------------------------------------------------- trust metadata
def load_trust():
    p = os.path.join(ROOT, "manifests", "forky-snapshot.tsv")
    if not os.path.isfile(p):
        die(f"missing trust metadata {p}")
    kv = {}
    for line in slurp(p, encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        if "\t" not in line:
            die(f"malformed trust metadata line (need key<TAB>value): {line!r}")
        k, v = line.split("\t", 1)
        if k in kv:
            die(f"duplicate trust metadata key: {k}")
        kv[k.strip()] = v.strip()
    for k in (
        "snapshot",
        "codename",
        "inrelease_sha256",
        "inrelease_size",
        "keyring",
        "keyring_sha256",
    ):
        if not kv.get(k):
            die(f"trust metadata {p} lacks '{k}'")
    if not PIN_RE.match(kv["snapshot"]):
        die(f"trust metadata snapshot is not a valid timestamp: {kv['snapshot']!r}")
    if not SHA256_RE.match(kv["inrelease_sha256"]):
        die("trust metadata inrelease_sha256 is not a sha256")
    if not SHA256_RE.match(kv["keyring_sha256"]):
        die("trust metadata keyring_sha256 is not a sha256")
    return kv


def release_conf(key, default=None):
    """Strict single-assignment read of release.conf.  A malformed or duplicated
    value is a hard error, not a silently-truncated prefix.  Documented syntax:
    KEY=value or KEY="value"; either form must occupy the whole line, with no
    trailing comment, no inner quotes, and no single-quote form."""
    p = os.path.join(ROOT, "release.conf")
    vals = []
    if os.path.isfile(p):
        for line in slurp(p, encoding="utf-8").splitlines():
            if line.startswith("#"):
                continue
            m = re.match(rf"^{re.escape(key)}=(.*)$", line)
            if m:
                raw = m.group(1).strip()
                if raw.startswith('"'):
                    if len(raw) < 2 or not raw.endswith('"') or '"' in raw[1:-1]:
                        die(f"release.conf {key} has mismatched/inner quotes: {raw!r}")
                    val = raw[1:-1]
                elif raw.startswith("'"):
                    die(f"release.conf {key} must not use single quotes: {raw!r}")
                elif not raw or re.search(r"[\s#\"']", raw):
                    die(
                        f"release.conf {key} has trailing junk/unquoted whitespace: {raw!r}"
                    )
                else:
                    val = raw
                if not val:
                    die(f"release.conf {key} is empty")
                vals.append(val)
    if len(vals) > 1:
        die(f"release.conf defines {key} {len(vals)} times")
    if not vals:
        if default is None:
            die(f"release.conf has no {key}")
        return default
    return vals[0]


# ---------------------------------------------------------------- signed index
def strip_clearsign(text):
    lines = text.split("\n")
    if not lines or "BEGIN PGP SIGNED MESSAGE" not in lines[0]:
        return None
    i = 1
    while i < len(lines) and lines[i].strip() != "":
        i += 1
    body = []
    for line in lines[i + 1 :]:
        if line.startswith("-----BEGIN PGP SIGNATURE"):
            break
        body.append(line.removeprefix("- "))
    return "\n".join(body)


def parse_release_sha256(body):
    out = {}
    grab = False
    for line in body.split("\n"):
        if re.match(r"^SHA256:\s*$", line):
            grab = True
            continue
        if not grab:
            continue
        if not line.startswith(" "):
            if line.strip() == "":
                continue
            break
        m = re.match(r"\s+([0-9a-f]{64})\s+(\d+)\s+(\S+)\s*$", line)
        if m:
            out[m.group(3)] = (m.group(1), int(m.group(2)))
    return out


def gpgv_ok(keyring, path, signer_keys):
    if not need_tool("gpgv"):
        return False
    # Machine-readable status on fd 1; human output on stderr.
    r = run(
        ["gpgv", "--status-fd", "1", "--keyring", keyring, path],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        fail("index", path, "OpenPGP signature verification FAILED (gpgv)")
        return False
    if signer_keys:
        wanted = {k.upper() for k in signer_keys.split()}
        found = set()
        for line in (r.stdout or "").split("\n"):
            if not line.startswith("[GNUPG:] VALIDSIG"):
                continue
            f = line.split()
            # VALIDSIG <fpr> <date> <ts> <exp> <ver> <res> <algo> <hash> <class> [<primary-fpr>]
            if len(f) >= 3:
                found.add(f[2].upper())  # signing (sub)key fingerprint
            if len(f) >= 12:
                found.add(f[11].upper())  # primary key fingerprint, when emitted
        if not (wanted & found):
            fail(
                "index",
                path,
                "signature verified but VALIDSIG fingerprint is not one of the pinned keys",
            )
            return False
    return True


def atomic_fetch(url, dest, sha, size):
    d = os.path.dirname(dest)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".nczfetch-", dir=d)
    os.close(fd)
    try:
        with urllib.request.urlopen(url, timeout=300) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f)
            f.flush()
            os.fsync(f.fileno())
        got = os.path.getsize(tmp)
        if size is not None and got != size:
            raise ValueError(f"size {got} != expected {size}")
        if sha and sha256_file(tmp) != sha:
            raise ValueError("sha256 mismatch")
        os.replace(tmp, dest)
        tmp = None
    finally:
        if tmp and os.path.exists(tmp):
            os.remove(tmp)


def verify_index(d, trust, need, fetch, verify_pool=False, src="index"):
    """Verify the signed Release for the pinned snapshot and every needed
    Packages index against it.  Returns {key: (sha, filename, size)} or None.
    ANY failure (missing/corrupt/forged index, partial pool) fails the whole
    call; callers must not proceed on a partial result."""
    before = len(FAILS)
    codename = trust["codename"]
    pin = trust["snapshot"]
    keyring = trust["keyring"]
    if not d:
        fail(src, "index", "no index directory supplied")
        return None
    if not os.path.isabs(keyring):
        keyring = os.path.join(ROOT, keyring)
    if not os.path.isfile(keyring):
        fail(src, keyring, "trust keyring is missing")
        return None
    if sha256_file(keyring) != trust["keyring_sha256"]:
        fail(src, keyring, "trust keyring sha256 does not match forky-snapshot.tsv")
        return None

    ir = os.path.join(d, "dists", codename, "InRelease")
    want_sha = trust["inrelease_sha256"]
    want_size = int(trust["inrelease_size"])

    def inrelease_valid(p):
        return (
            os.path.isfile(p)
            and os.path.getsize(p) == want_size
            and sha256_file(p) == want_sha
            and gpgv_ok(keyring, p, trust.get("signer_keys", ""))
        )

    if not inrelease_valid(ir):
        if not fetch:
            fail(src, ir, "no valid signed InRelease for the pinned snapshot")
            return None
        url = f"https://snapshot.debian.org/archive/debian/{pin}/{trust['inrelease_path']}"
        try:
            atomic_fetch(url, ir, want_sha, want_size)
        except Exception as e:  # noqa: BLE001
            fail(src, ir, f"could not fetch/verify signed InRelease: {e}")
            return None
        if not inrelease_valid(ir):
            fail(
                src, ir, "downloaded InRelease did not verify against the committed pin"
            )
            return None

    body = strip_clearsign(slurp(ir, encoding="utf-8", errors="replace"))
    if body is None:
        fail(src, ir, "InRelease is not a clearsigned document")
        return None
    rel = parse_release_sha256(body)
    if not rel:
        fail(src, ir, "signed Release has no SHA256 index section")
        return None

    idx = {}
    for comp, arch in need:
        relpath = f"{comp}/binary-{arch}/Packages.xz"
        if relpath not in rel:
            fail(
                src,
                relpath,
                "not present in the signed Release (unexpected index shape)",
            )
            continue
        esha, esize = rel[relpath]
        dest = os.path.join(d, "dists", codename, comp, f"binary-{arch}", "Packages.xz")

        def pkg_valid(p, esha=esha, esize=esize):
            return (
                os.path.isfile(p)
                and os.path.getsize(p) == esize
                and sha256_file(p) == esha
            )

        if not pkg_valid(dest):
            if not fetch:
                fail(src, dest, "Packages index missing/corrupt (fetch disabled)")
                continue
            url = f"https://snapshot.debian.org/archive/debian/{pin}/dists/{codename}/{relpath}"
            try:
                atomic_fetch(url, dest, esha, esize)
            except Exception as e:  # noqa: BLE001
                fail(src, relpath, f"could not fetch/verify Packages index: {e}")
                continue
            if not pkg_valid(dest):
                fail(src, dest, "Packages index did not match the signed Release")
                continue
        try:
            text = read_maybe_compressed(dest)
        except Exception as e:  # noqa: BLE001
            fail(src, dest, f"Packages index could not be decompressed: {e}")
            continue
        stanzas = list(parse_stanzas(text))
        if not stanzas:
            fail(src, dest, "Packages index has no records")
            continue
        for s in stanzas:
            if not stanza_ok(s, f"{src}:{os.path.basename(dest)}", "Packages"):
                continue
            key = (s["Package"], s["Version"], s["Architecture"])
            idx[key] = (s.get("SHA256", ""), s.get("Filename", ""), s.get("Size", ""))

    if verify_pool:
        # Before a BUILD uses a local mirror, verify the actual referenced pool
        # bytes (sha256+size), not just the index metadata.
        seen = set()
        for key, (esha, fname, esize) in idx.items():
            if not fname or fname in seen:
                continue
            seen.add(fname)
            fp = os.path.join(d, fname)
            if not os.path.isfile(fp):
                fail(src, fname, "referenced pool file is missing from the mirror")
                continue
            if esize and os.path.getsize(fp) != int(esize):
                fail(src, fname, "pool file size does not match the signed index")
                continue
            if esha and sha256_file(fp) != esha:
                fail(src, fname, "pool file sha256 does not match the signed index")

    if len(FAILS) != before:
        return None
    if not idx:
        fail(src, d, "no verified index entries loaded (failing closed)")
        return None
    return idx


def all_need(trust):
    need = []
    for comp in trust["components"].split():
        for arch in trust["architectures"].split():
            need.append((comp, arch))
    for arch in ("amd64", "arm64"):
        need.append(("main/debian-installer", arch))
    return list(dict.fromkeys(need))


def read_candidate_packages(mirror):
    """Parse every Packages index in a candidate mirror.  The candidate's own
    metadata is NOT trusted to authorize anything; it only names the pool files."""
    rows = []
    files = glob.glob(os.path.join(mirror, "dists", "**", "Packages*"), recursive=True)
    if not files:
        fail("mirror", mirror, "candidate mirror has no Packages index")
        return rows
    for p in files:
        try:
            text = read_maybe_compressed(p)
        except Exception as e:  # noqa: BLE001
            fail("mirror", p, f"candidate Packages index could not be read: {e}")
            continue
        for s in parse_stanzas(text):
            if stanza_ok(s, "mirror:" + os.path.basename(p), "candidate Packages"):
                rows.append(s)
    return rows


def verify_candidate_mirror(ref, mirror, up_dir, fetch):
    """Authorize a (possibly self-signed, subset) offline mirror against the
    INDEPENDENTLY VERIFIED upstream snapshot index and the reviewed ledgers.
    The candidate's own Release/Packages can be regenerated but cannot authorize
    a package; every referenced pool deb must match its authorized sha256+size,
    and no orphan deb may sit in the pool unlisted."""
    if not os.path.isdir(mirror):
        fail("mirror", mirror, "candidate mirror directory does not exist")
        return False
    up = verify_index(up_dir, ref.trust, all_need(ref.trust), fetch, src="upstream")
    if up is None:
        fail("mirror", mirror, "upstream snapshot index could not be verified")
        return False
    records = read_candidate_packages(mirror)
    return (
        authorize_records(
            ref, records, mirror, up, "mirror", orphan_root=os.path.join(mirror, "pool")
        )
        is not None
    )


def authorize_records(ref, records, root, auth_idx, src, orphan_root=None):
    """Authorize candidate Packages records AND their referenced pool bytes
    against auth_idx (an already-authenticated identity -> (sha, filename, size)
    map) plus the reviewed vendor/NCZ ledgers.  The candidate's own metadata can
    never authorize a package.  Returns the set of referenced relative Filenames
    on success, or None if any record/pool/orphan check failed; on failure the
    required FAILs have already been emitted."""
    before = len(FAILS)
    referenced = set()
    rootr = os.path.realpath(root)
    for s in records:
        key = (s["Package"], s["Version"], s["Architecture"])
        sha = s.get("SHA256", "")
        fname = s.get("Filename", "")
        size = s.get("Size", "")
        what = f"{key[0]} {key[1]} {key[2]}"
        if not fname or not sha or not size:
            fail(src, what, "record lacks Filename/SHA256/Size")
            continue
        if fname.startswith("/") or os.path.isabs(fname):
            fail(src, what, f"Filename is absolute: {fname}")
            continue
        rel = os.path.normpath(fname)
        if rel == ".." or rel.startswith("../") or ".." in rel.split("/"):
            fail(src, what, f"Filename escapes the pool: {fname}")
            continue
        fp = os.path.join(root, rel)
        fpr = os.path.realpath(fp)
        if not (fpr == rootr or fpr.startswith(rootr + os.sep)):
            fail(src, rel, "pool file escapes the pool root (symlink/path traversal)")
            continue
        auth = None
        v = ref.vendor.get(key)
        if v is not None and sha in v:
            auth = "vendor"
        elif ref.ncz.get(key) == sha:
            auth = "ncz"
        elif key in auth_idx and auth_idx[key][0] == sha:
            auth = "verified"
        if auth is None:
            fail(
                src,
                what,
                "not authorized by the verified snapshot index or a "
                "reviewed vendor/NCZ ledger",
            )
            continue
        referenced.add(rel)
        if not os.path.isfile(fp):
            fail(src, rel, "pool file is missing")
            continue
        if os.path.getsize(fp) != int(size):
            fail(src, rel, "pool file size mismatch")
            continue
        if sha256_file(fp) != sha:
            fail(src, rel, "pool file sha256 mismatch")
            continue
        c = deb_control(fp)
        if (c.get("Package"), c.get("Version"), c.get("Architecture")) != key:
            fail(src, rel, "deb control identity does not match its Packages record")
            continue
    if orphan_root is not None:
        for p in glob.glob(
            os.path.join(orphan_root, "**", "*.deb"), recursive=True
        ) + glob.glob(os.path.join(orphan_root, "**", "*.udeb"), recursive=True):
            rel = os.path.normpath(os.path.relpath(p, root))
            if rel not in referenced:
                fail(src, rel, "orphan pool file not listed in any Packages index")
    if len(FAILS) != before:
        return None
    return referenced


def authorize_pool(ref, root, auth_idx, src, flat=False, orphan_root=None):
    """Find a pool's own Packages index (flat at root, or under dists/) and
    authorize it against the ALREADY-authenticated auth_idx + ledgers.  Returns
    the authorized Filename set or None (missing/empty/partial/foreign/unapproved
    pools do not authorize)."""
    if not os.path.isdir(root):
        return None
    files = (
        glob.glob(os.path.join(root, "Packages*"))
        if flat
        else glob.glob(os.path.join(root, "dists", "**", "Packages*"), recursive=True)
    )
    flags = "flat" if flat else "dists"
    records = []
    idx_src = f"{src}:{flags}"
    for p in files:
        try:
            text = read_maybe_compressed(p)
        except Exception as e:  # noqa: BLE001
            fail(src, p, f"Packages index could not be read: {e}")
            continue
        for s in parse_stanzas(text):
            if stanza_ok(s, idx_src, "Packages"):
                records.append(s)
    if not records:
        fail(src, root, "offline pool has no readable Packages records")
        return None
    return authorize_records(ref, records, root, auth_idx, src, orphan_root=orphan_root)


# ---------------------------------------------------------------- reference data
def load_tsv(path, min_cols, roster_name):
    rows = []
    if not os.path.isfile(path):
        die(f"missing reviewed manifest {roster_name}: {path}")
    for n, line in enumerate(slurp(path, encoding="utf-8").splitlines(), 1):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < min_cols:
            die(f"{roster_name}:{n} needs >= {min_cols} tab-separated columns")
        rows.append((n, parts))
    return rows


class Ref:
    def __init__(self, a):
        self.ubuntu_only = a.ubuntu_only
        self.verify_mirror = bool(a.verify_mirror)
        self.trust = {} if a.ubuntu_only else load_trust()
        self.pin = release_conf("NCZ_BASE_MIRROR_SNAPSHOT")
        self.codename = release_conf("NCZ_BASE_CODENAME")
        if not PIN_RE.match(self.pin or ""):
            die(
                f"release.conf NCZ_BASE_MIRROR_SNAPSHOT is not a valid timestamp: {self.pin!r}"
            )
        if not self.codename:
            die("release.conf has no NCZ_BASE_CODENAME")
        if not a.ubuntu_only:
            if self.pin != self.trust["snapshot"]:
                die(
                    f"release.conf pin '{self.pin}' != forky-snapshot.tsv "
                    f"snapshot '{self.trust['snapshot']}'"
                )
            if self.codename != self.trust["codename"]:
                die(
                    f"release.conf codename '{self.codename}' != trust metadata "
                    f"'{self.trust['codename']}'"
                )

        self.vendor = {}
        for n, r in load_tsv(
            os.path.join(ROOT, "manifests/vendor-debs.tsv"),
            7,
            "manifests/vendor-debs.tsv",
        ):
            if not SHA256_RE.match(r[5]):
                die(f"vendor-debs.tsv:{n} sha256 is not 64 hex")
            self.vendor.setdefault((r[0], r[1], r[2]), set()).add(r[5])
        self.ncz = {}
        for n, r in load_tsv(
            os.path.join(ROOT, "manifests/ncz-packages.tsv"),
            7,
            "manifests/ncz-packages.tsv",
        ):
            if not SHA256_RE.match(r[3]):
                die(f"ncz-packages.tsv:{n} sha256 is not 64 hex")
            # Columns: name, version, arch, sha256, recipe, source_revision, note.
            # The build recipe (col 5) and the canonical source revision (col 6)
            # must be non-empty; note (col 7) is optional.
            if not r[4].strip() or not r[5].strip():
                die(
                    f"ncz-packages.tsv:{n} needs a non-empty recipe (col 5) and "
                    f"source revision (col 6)"
                )
            self.ncz[(r[0], r[1], r[2])] = r[3]

        self.sources = []
        for n, r in load_tsv(
            os.path.join(ROOT, "manifests/vendor-repos.tsv"),
            8,
            "manifests/vendor-repos.tsv",
        ):
            self.sources.append(
                {
                    "kind": r[0],
                    "scheme": r[1].lower(),
                    "host": r[2].lower(),
                    "path": r[3],
                    "suite": r[4],
                    "approved": r[5],
                    "vendor": r[6],
                    "note": r[7],
                    "line": n,
                }
            )
        self.origins = {r["host"] for r in self.sources if r["approved"] == "yes"}
        self.origins.add(self.codename)
        # Offline (file:) roots that have actually been enumerated+verified in
        # THIS scan.  Empty for a standalone rootfs: a file: source cannot imply
        # approval of a pool nobody scanned.
        self.bound_offline = set()

        self.idx = {}
        if not a.ubuntu_only and not self.verify_mirror:
            need = []
            for comp in self.trust["components"].split():
                for arch in self.trust["architectures"].split():
                    need.append((comp, arch))
                need.append((comp, "all"))
            for arch in ("amd64", "arm64"):
                need.append(("main/debian-installer", arch))
            # de-dup, keep order
            need = list(dict.fromkeys(need))
            got = verify_index(a.index_dir, self.trust, need, a.fetch_index)
            if got is None:
                sys.exit(1)
            self.idx = got


# ---------------------------------------------------------------- classification
UBU_RE = re.compile(r"ubuntu", re.IGNORECASE)
UBU_CANONICAL = re.compile(r"Ubuntu Developers|lists\.ubuntu\.com")


def classify(ref, src, name, ver, arch, maint, sha=None):
    """Return origin string or None after emitting a FAIL."""
    what = f"{name} {ver} {arch}"
    key = (name, ver, arch)

    # Hard Ubuntu rejection first: never exonerated by anything.
    if UBU_CANONICAL.search(maint or ""):
        fail(src, what, f"Ubuntu-built ({maint}) -- never allowed")
        return None
    if UBU_RE.search(ver or ""):
        fail(src, what, "version contains 'ubuntu'")
        return None

    if ref.ubuntu_only:
        # Offline lint mode: identity-only, no byte cross-checks (the full gate
        # does those).  Explicit Ubuntu evidence already failed above.
        if ref.vendor.get(key) is not None:
            return "vendor-identity"
        if ref.ncz.get(key) is not None:
            return "ncz-identity"
        if UBU_RE.search(maint or ""):
            print(
                f"WARN  [{src}] {what} :: @ubuntu.com maintainer ({maint}); "
                f"needs the verified snapshot index to clear"
            )
        return "unchecked"

    v = ref.vendor.get(key)
    if v is not None:
        if sha and v and sha not in v:
            fail(
                src,
                what,
                f"vendor deb sha256 {sha[:16]}.. not pinned in vendor-debs.tsv",
            )
            return None
        return "vendor"

    n = ref.ncz.get(key)
    if n is not None:
        if sha and n and sha != n:
            fail(
                src,
                what,
                f"NCZ ledger sha256 mismatch: {sha[:16]}.. vs reviewed {n[:16]}..",
            )
            return None
        if not sha:
            # Identity-only: dpkg status / Packages carry no bytes; document the
            # limitation rather than pretend bytes were verified.
            print(f"NOTE  [{src}] {what} :: NCZ reviewed identity (no bytes to hash)")
            return "ncz-identity"
        return "ncz"

    if key in ref.idx:
        esha = ref.idx[key][0]
        if sha and esha and sha != esha:
            fail(
                src,
                what,
                f"same name/version as the forky snapshot but sha256 differs "
                f"(rebuilt/foreign bytes): {sha[:16]}.. vs {esha[:16]}..",
            )
            return None
        return "forky"

    if UBU_RE.search(maint or ""):
        fail(
            src,
            what,
            f"@ubuntu.com maintainer ({maint}) and not in the pinned forky snapshot",
        )
        return None
    fail(
        src,
        what,
        "not in the reviewed NCZ ledger, not a reviewed vendor deb, "
        "and not in the pinned forky snapshot (unknown origin)",
    )
    return None


def scan_status(ref, text, src):
    n = 0
    for d in parse_stanzas(text or ""):
        if not stanza_ok(d, src, "dpkg status"):
            continue
        raw_status = d.get("Status")
        if not raw_status:
            # A dpkg status record always carries Status; its absence is a
            # malformed record, not a package to silently skip or assume.
            fail(src, d["Package"], "dpkg status record has no Status field")
            continue
        state = raw_status.split(" ")[-1]
        if state in ("config-files", "not-installed"):
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
        if not stanza_ok(d, src, "Packages"):
            continue
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


def scan_debs(ref, d, src, required=True):
    if not os.path.isdir(d):
        if required:
            fail(src, d, "requested deb pool is missing")
        return 0
    if not need_tool("dpkg-deb"):
        return 0
    n = 0
    for p in sorted(
        glob.glob(os.path.join(d, "**", "*.deb"), recursive=True)
        + glob.glob(os.path.join(d, "**", "*.udeb"), recursive=True)
    ):
        c = deb_control(p)
        if "Package" not in c:
            fail(src, p, "unreadable deb (dpkg-deb could not parse control)")
            continue
        n += 1
        classify(
            ref,
            src + ":" + os.path.relpath(p, d),
            c["Package"],
            c["Version"],
            c.get("Architecture", ""),
            c.get("Maintainer", ""),
            sha256_file(p),
        )
    if required and n == 0:
        fail(src, d, "no .deb/.udeb found in a requested pool")
    return n


# ---------------------------------------------------------------- apt config / os-release
class BadSource(Exception):
    pass


def parse_sources(text):
    """Yield (uri, suite) from one-line (.list) and deb822 (.sources) text.
    Handles mixed-case fields and RFC822 continuation; rejects duplicate
    required fields."""
    if re.search(r"^Types\s*:", text, re.MULTILINE | re.IGNORECASE):
        for st in re.split(r"\n\s*\n", text):
            d = {}
            key = None
            for line in st.split("\n"):
                if line[:1] in (" ", "\t") and key:
                    d[key] += " " + line.strip()
                    continue
                if ":" in line and not line.lstrip().startswith("#"):
                    k, v = line.split(":", 1)
                    key = k.strip().lower()
                    if key in d:
                        raise BadSource(f"duplicate deb822 field '{key}'")
                    d[key] = v.strip()
            if d.get("enabled", "yes").lower() == "no":
                continue
            if not d:
                continue
            if not d.get("uris") or not d.get("suites"):
                raise BadSource("deb822 source is missing URIs and/or Suites")
            for u in d.get("uris", "").split():
                for s in d.get("suites", "").split():
                    yield u, s
    else:
        for line in text.split("\n"):
            line = line.strip()
            if line.startswith("deb-src "):
                continue
            if not line.startswith(("deb ", "deb\t")):
                continue
            line = re.sub(r"\[[^\]]*\]", "", line)
            parts = line.split()
            if len(parts) < 3:
                raise BadSource("malformed deb line (need URI and suite)")
            yield parts[1], parts[2]


def parse_pref_stanzas(text):
    """Split an apt preferences file into stanzas on 'Package:'.  Duplicate
    Pin/Pin-Priority records in one stanza are rejected (no bypass)."""
    starts = [m.start() for m in re.finditer(r"^Package\s*:", text, re.MULTILINE)]
    if not starts:
        if text.strip():
            raise BadSource("preferences file has no Package: record")
        return []
    bounds = starts + [len(text)]
    return [text[bounds[i] : bounds[i + 1]] for i in range(len(starts))]


def pin_ok(ref, pl):
    s = pl.strip()
    m = re.match(r"^origin\s+(\S+)\s*$", s, re.IGNORECASE)
    if m:
        return m.group(1).lower() in ref.origins
    m = re.match(r"^release\s+(.*)$", s, re.IGNORECASE)
    if m:
        fields = re.findall(r"([A-Za-z])\s*=\s*([^,\s]+)", m.group(1))
        seen = set()
        for k, v in fields:
            k = k.lower()
            if k in seen:
                return False
            seen.add(k)
            if k in ("n", "c", "a") and v != ref.codename:
                return False
            if k in ("o", "l") and v.lower() not in ("debian", "ncz", "ncz-os"):
                return False
        return True
    return bool(re.match(r"^version\s+\S+\s*$", s, re.IGNORECASE))


def uri_parts(uri):
    """Strict (scheme, host, path) or None.  Rejects credentials, ports, query
    strings, fragments and '..' path traversal -- exact URL matching only."""
    if "?" in uri or "#" in uri:
        return None
    m = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)(/.*)?$", uri)
    if not m:
        return None
    scheme = m.group(1).lower()
    authority = m.group(2)
    if "@" in authority or ":" in authority or not authority:
        return None
    path = m.group(3) or "/"
    if ".." in path.split("/") or "//" in path:
        return None
    return scheme, authority.lower(), path


def source_ok(ref, uri, suite):
    u = uri.rstrip("/")
    if uri.startswith("file:") or u.startswith(("/", "file:")):
        if "?" in uri or "#" in uri or ".." in uri:
            return f"unsafe offline source URI: {uri}"
        raw = uri.removeprefix("file:")
        p = os.path.normpath(raw)
        for r in ref.sources:
            if r["kind"] != "offline":
                continue
            # EXACT normalized path match against an explicit offline policy row.
            # A bound parent root must never authorize an unscanned child (e.g.
            # /cdrom must not admit /cdrom/unscanned-repo, whose own pool was
            # never cryptographically authorized); the flat media pool has its
            # own row and its own binding.
            root = os.path.normpath(r["path"])
            if p != root:
                continue
            if r["suite"] != "*" and r["suite"] != suite:
                return (
                    f"offline source {p} with suite '{suite}' is not the "
                    f"reviewed suite '{r['suite']}'"
                )
            if r["approved"] != "yes":
                return f"offline source {p} is not approved: {r['note']}"
            if root not in {os.path.normpath(b) for b in ref.bound_offline}:
                return (
                    f"offline source {p} is not bound to content enumerated+"
                    f"verified in this scan (standalone rootfs cannot approve "
                    f"an unscanned pool)"
                )
            return None
        return f"unknown offline source root '{p}' (not a reviewed layout path)"
    parts = uri_parts(uri)
    if not parts:
        return f"source {uri} is not a strict, exact URI"
    scheme, host, path = parts
    for r in ref.sources:
        if r["scheme"] != scheme or r["host"] != host:
            continue
        if r["kind"] == "debian-pin":
            want = r["path"].replace("<pin>", ref.pin)
            if path == want and suite == ref.codename:
                return None
            continue
        if path != r["path"]:
            continue
        if r["suite"] != "*" and r["suite"] != suite:
            continue
        if r["approved"] != "yes":
            return (
                f"source {host}{path} ({suite}) is 'pending' operator approval, "
                f"not approved: {r['note']}"
            )
        return None
    return (
        f"source {uri} {suite} is not a reviewed Debian forky, NCZ or vendor "
        f"source (exact URI+suite required)"
    )


def audit_apt_files(ref, src, files):
    for rel, text in files.items():
        if rel.endswith((".disabled", ".dpkg-old", ".dpkg-new", ".bak", "~")):
            continue
        if "/preferences" in "/" + rel:
            try:
                stanzas = parse_pref_stanzas(text)
            except BadSource as e:
                fail(src, rel, str(e))
                continue
            for st in stanzas:
                prios = re.findall(r"^Pin-Priority:\s*(-?\d+)", st, re.MULTILINE)
                if not prios:
                    fail(src, rel, "preferences stanza has no Pin-Priority")
                    continue
                if len(prios) > 1:
                    fail(src, rel, "preferences stanza has duplicate Pin-Priority")
                    continue
                if int(prios[0]) < 0:
                    continue
                pins = re.findall(r"^Pin:\s*(.*)$", st, re.MULTILINE)
                if not pins:
                    fail(
                        src, rel, "preferences stanza with Pin-Priority >= 0 has no Pin"
                    )
                    continue
                for pl in pins:
                    if not pin_ok(ref, pl):
                        fail(src, rel, f"apt pin >=0 not permitted: '{pl}'")
            continue
        if "sources.list" not in rel:
            continue
        if rel.endswith(".sources") and not re.search(
            r"^Types\s*:", text, re.MULTILINE | re.IGNORECASE
        ):
            fail(src, rel, ".sources file has no Types: field")
            continue
        try:
            parsed = list(parse_sources(text))
        except BadSource as e:
            fail(src, rel, str(e))
            continue
        for uri, suite in parsed:
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


def _safe_open(root, rel):
    """Resolve rel under root; reject symlinks/paths escaping root."""
    p = os.path.join(root, rel)
    rp = os.path.realpath(p)
    rr = os.path.realpath(root)
    if not (rp == rr or rp.startswith(rr + os.sep)):
        fail("rootfs", rel, "path escapes the scanned root (symlink/path traversal)")
        return None
    return p if os.path.isfile(rp) else None


def scan_rootfs(ref, root, src):
    if not os.path.isdir(root):
        fail(src, root, "requested rootfs is missing")
        return 0
    stp = _safe_open(root, "var/lib/dpkg/status")
    st = slurp(stp, errors="replace") if stp else None
    if st is None:
        fail(
            src, root, "rootfs has no var/lib/dpkg/status (cannot establish provenance)"
        )
        return 0
    n = scan_status(ref, st, src)
    if n == 0:
        fail(src, stp, "dpkg status has no records")
    for rel in ("etc/os-release", "usr/lib/os-release"):
        p = _safe_open(root, rel)
        if p:
            audit_osrelease(src, slurp(p, errors="replace"))
            break
    files = {}
    for pat in (
        "etc/apt/sources.list",
        "etc/apt/sources.list.d/*",
        "etc/apt/preferences",
        "etc/apt/preferences.d/*",
    ):
        for p in glob.glob(os.path.join(root, pat)):
            sp = _safe_open(root, os.path.relpath(p, root))
            if sp:
                files[os.path.relpath(p, root)] = slurp(sp, errors="replace")
    audit_apt_files(ref, src, files)
    return n


def scan_squashfs(ref, sq, src):
    if not os.path.isfile(sq):
        fail(src, sq, "squashfs layer is missing")
        return 0
    if not need_tool("unsquashfs"):
        return 0
    s = run(["unsquashfs", "-s", sq], capture_output=True, text=True)
    if s.returncode != 0:
        fail(src, sq, "squashfs layer is corrupt or unreadable (unsquashfs -s failed)")
        return 0

    def cat(rel):
        r = run(["unsquashfs", "-cat", sq, rel], capture_output=True)
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None

    st = cat("var/lib/dpkg/status")
    if st is None:
        # STRICT: a layer with no dpkg database cannot establish package origin
        # and is rejected by default.  Do NOT accept it just because it lacks an
        # apt/.deb surface: a foreign ELF overlay can override a packaged base
        # without any content binding.  Accepting it would be a policy
        # relaxation the operator never approved.  Binding the exact known
        # desktop-hotfix content to an EXTERNAL, committed overlay-source
        # manifest/hash (build_hotfix + exact file coverage) is required before
        # any such layer may pass; that binding does not exist yet, so the
        # desktop-hotfix layer remains an explicit blocker.
        fail(
            src,
            sq,
            "squashfs layer has no readable var/lib/dpkg/status "
            "(no package origin; strict reject -- content binding "
            "required, not a blanket overlay bypass)",
        )
        return 0
    n = scan_status(ref, st, src)
    if n == 0:
        fail(src, sq, "squashfs dpkg status has no records")
    for rel in ("etc/os-release", "usr/lib/os-release"):
        t = cat(rel)
        if t:
            audit_osrelease(src, t)
            break
    lst = run(["unsquashfs", "-ll", sq, "etc/apt"], capture_output=True, text=True)
    if lst.returncode != 0:
        fail(src, sq, "cannot list etc/apt in the squashfs layer")
        return n
    files = {}
    for line in lst.stdout.split("\n"):
        m = re.search(
            r"squashfs-root/(etc/apt/(?:sources\.list(?:\.d/[^ ]+)?|preferences(?:\.d/[^ ]+)?))$",
            line.strip(),
        )
        if m and not line.startswith("d"):
            t = cat(m.group(1))
            if t is None:
                fail(src, sq, f"listed apt file {m.group(1)} could not be read")
            else:
                files[m.group(1)] = t
    audit_apt_files(ref, src, files)
    return n


# ---------------------------------------------------------------- finished .img
def safe_extract_zst(tar_path, dest, src):
    """Safely extract a .tar.zst: decompress to an owned temp tar, prevalidate
    member names, then extract with tarfile's data filter (rejects absolute
    paths, '..', and links escaping the destination)."""
    if not need_tool("zstd"):
        return False
    base = os.path.dirname(dest)
    os.makedirs(base, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".ncztar-", dir=base)
    os.close(fd)
    try:
        with open(tmp, "wb") as out:
            p = subprocess.Popen(["zstd", "-dc", tar_path], stdout=out, env=tool_env())
            rc = p.wait()
        if rc != 0:
            fail(src, tar_path, "zstd decompression failed")
            return False
        with tarfile.open(tmp, "r:") as tf:
            seen = {}
            for m in tf.getmembers():
                if m.name.startswith("/") or ".." in m.name.split("/"):
                    fail(src, tar_path, f"unsafe tar member: {m.name}")
                    return False
                # Shadow check: two content-bearing members at the same
                # normalized path would let a later entry overwrite an earlier
                # mapped file (e.g. var/lib/dpkg/status) inside the root.  A
                # repeated plain directory entry is harmless; legitimate
                # usr-merge symlinks and pure data hard-links have distinct
                # names and are unaffected.
                nm = m.name.removeprefix("./")
                key = posixpath.normpath(nm) if nm not in ("", ".") else ""
                if key:
                    if key in seen and not (seen[key] and m.isdir()):
                        fail(
                            src,
                            tar_path,
                            "duplicate tar member path (would "
                            f"shadow earlier content): {m.name}",
                        )
                        return False
                    seen[key] = m.isdir()
            try:

                def _member_filter(member, *_):
                    # Names are prevalidated above; links need a virtual
                    # archive-root rewrite so an absolute symlink target
                    # (var/run -> /run) is materialised as a RELATIVE link that
                    # cannot be followed onto the host, and a hard-link cannot
                    # reach an absolute/'..'-climbing host path.
                    if member.issym():
                        ok, rewritten = safe_symlink_target(
                            member.name, member.linkname
                        )
                        if not ok:
                            raise UnsafeArchive(
                                f"tar symlink escapes: {member.name} -> {member.linkname}"
                            )
                        member.linkname = rewritten
                    elif member.islnk():
                        if not safe_hardlink_target(member.linkname):
                            raise UnsafeArchive(
                                f"tar hard-link escapes: {member.name} -> {member.linkname}"
                            )
                    return member

                tf.extractall(dest, filter=_member_filter)
            except UnsafeArchive as e:
                fail(src, tar_path, f"safe tar extraction failed: {e}")
                return False
            except Exception as e:  # noqa: BLE001
                fail(src, tar_path, f"safe tar extraction failed: {e}")
                return False
        return True
    except Exception as e:  # noqa: BLE001
        fail(src, tar_path, f"could not extract rootfs tarball: {e}")
        return False
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def scan_image(ref, img, work):
    """Scan a finished GPT .img: the offline apt pool + indexes, every squashfs
    layer, the rescue/mgmt rootfs tarballs, every present asset/vendor pool, the
    ESP's embedded udebs and any initrd.  Reads the data partition with debugfs
    (no root, no loop mount).  Enumerates before requiring, so optional
    architecture trees are not false positives; any extraction/listing/stderr
    error fails the gate."""
    for t in ("sfdisk", "debugfs", "findmnt"):
        if not need_tool(t):
            return 0
    if not os.path.isfile(img):
        fail("image", img, "image file does not exist")
        return 0
    # Resolve the scratch path BEFORE any staging so findmnt and mkdtemp agree.
    work = os.path.realpath(work)
    if not os.path.isdir(work):
        fail("image", work, "--work directory does not exist")
        return 0
    fs = run(
        ["findmnt", "-no", "FSTYPE", "-T", work], capture_output=True, text=True
    ).stdout.strip()
    if fs in ("tmpfs", "ramfs", "devtmpfs"):
        die(f"--work {work} is on {fs}; use local disk")
    # Owned, unique scratch: never rmtree a caller-supplied path.
    # Offline-source binding is per image: clear it and restore the caller's
    # prior state in finally, so one image can never authorize another.
    saved_bound = set(ref.bound_offline)
    ref.bound_offline.clear()
    owned = tempfile.mkdtemp(prefix="ncz-imgscan-", dir=work)
    try:
        j = json.loads(
            run(
                ["sfdisk", "-J", img], capture_output=True, text=True, check=True
            ).stdout
        )
        ptab = j["partitiontable"]
        sector = int(ptab.get("sectorsize", 512) or 512)
        parts = ptab["partitions"]
        data = max(parts, key=lambda x: x["size"])
        dev = f"{img}?offset={int(data['start']) * sector}"
        base = os.path.join(owned, "img")
        pl = os.path.join(base, "ncz-payload")
        os.makedirs(base, exist_ok=True)

        def dbg(*args, required=True, allow_chown=False):
            """Run a debugfs command; return stdout (or None on failure).  The
            normal version banner is ignored; any other stderr line, a non-zero
            exit or an ext2 lookup failure is a hard error for required trees.

            ``allow_chown`` is used ONLY for ``rdump``: a non-root debugfs
            cannot chown the dumped files and emits exactly
            ``... Operation not permitted while changing ownership`` per failed
            chown.  Those lines affect ownership only; content completeness is
            proven independently by ``check_complete()`` (which enumerates every
            path/type/size from the image BEFORE the dump and requires each in
            the extraction).  No other stderr line is tolerated, and a partial
            dump still fails in check_complete()."""
            r = run(
                ["debugfs", "-R", " ".join(args), dev], capture_output=True, text=True
            )
            err = [
                l
                for l in (r.stderr or "").splitlines()
                if l.strip() and not l.startswith("debugfs ")
            ]
            if allow_chown:
                err = [l for l in err if not CHOWN_PERM_RE.search(l.strip())]
            bad = (
                r.returncode != 0
                or bool(err)
                or "not found by ext2_lookup" in (r.stdout or "")
            )
            if bad and required:
                fail(
                    "image",
                    img,
                    f"debugfs {' '.join(args)} failed: "
                    f"{(r.stderr or r.stdout or '').strip()[:200]}",
                )
            return None if bad else (r.stdout or "")

        def walk(root):
            """Recursively enumerate an image source tree as {path: (kind,size)}
            BEFORE it is dumped, so a partial dump can be detected.  Returns None
            if a directory cannot be listed."""
            out = {}
            stack = [root]
            while stack:
                d = stack.pop()
                text = dbg("ls", "-p", d)
                if text is None:
                    return None
                for line in text.split("\n"):
                    line = line.strip()
                    if not line.startswith("/"):
                        continue
                    parts = line.strip("/").split("/")
                    if len(parts) < 5:
                        continue
                    name = parts[4]
                    if name in (".", ".."):
                        continue
                    try:
                        mode = int(parts[1], 8)
                    except ValueError:
                        fail("image", img, f"unparseable debugfs entry: {line!r}")
                        return None
                    full = d.rstrip("/") + "/" + name
                    if stat.S_ISDIR(mode):
                        out[full] = ("dir", 0)
                        stack.append(full)
                    elif stat.S_ISLNK(mode):
                        out[full] = ("link", 0)
                    else:
                        sz = int(parts[5]) if len(parts) >= 6 and parts[5] else 0
                        out[full] = ("file", sz)
            return out

        def check_complete(root, dest):
            """Every path the image actually contains under root must exist in the
            extraction (same type; regular files same size)."""
            enum = walk(root)
            if enum is None:
                fail("image", img, f"could not enumerate {root} in the image")
                return
            checked = 0
            for p, (kind, size) in enum.items():
                rel = p[len(root) :].lstrip("/")
                lp = os.path.join(dest, rel)
                if kind == "dir":
                    ok = os.path.isdir(lp)
                elif kind == "file":
                    ok = os.path.isfile(lp) and os.path.getsize(lp) == size
                else:
                    ok = os.path.lexists(lp)
                if not ok:
                    fail("image", p, "image entry missing/incomplete after extraction")
                checked += 1
            if checked == 0:
                fail("image", root, "image tree is present but empty")

        total = 0
        found_any = False

        for t in ("dists", "pool"):
            dbg("rdump", "/" + t, base, allow_chown=True)
            if not os.path.exists(os.path.join(base, t)):
                fail("image", img, f"required /{t} tree is missing or unreadable")
            else:
                found_any = True
                check_complete("/" + t, os.path.join(base, t))
        if os.path.isdir(os.path.join(base, "pool")):
            total += scan_debs(ref, os.path.join(base, "pool"), "image:pool")
        pkgidx = glob.glob(
            os.path.join(base, "dists", "**", "Packages*"), recursive=True
        )
        if not pkgidx:
            fail("image", img, "no Packages index found under /dists")
        for p in pkgidx:
            try:
                total += scan_packages(
                    ref, read_maybe_compressed(p), "image:" + os.path.relpath(p, base)
                )
            except Exception as e:  # noqa: BLE001
                fail("image", p, f"Packages index could not be read: {e}")

        # Completeness: every pool file named by an offline /dists Packages index
        # must actually exist after the dump (catches a partial rdump that
        # os.path.exists() alone would miss).
        referenced = set()
        for p in pkgidx:
            try:
                text = read_maybe_compressed(p)
            except Exception:  # noqa: BLE001,S112 - already reported when scanned
                continue
            for s in parse_stanzas(text):
                fn = s.get("Filename")
                if fn:
                    referenced.add(os.path.normpath(fn))
        for fn in sorted(referenced):
            if not os.path.isfile(os.path.join(base, fn)):
                fail(
                    "image",
                    fn,
                    "pool file referenced by /dists is missing after extraction",
                )

        # Dump the whole /ncz-payload subtree and verify it against a recursive
        # pre-dump enumeration (a partial rdump still leaves a directory behind).
        dbg("rdump", "/ncz-payload", base, allow_chown=True)
        if not os.path.isdir(pl):
            fail("image", img, "required /ncz-payload tree is missing or unreadable")
        else:
            found_any = True
            check_complete("/ncz-payload", pl)

        # Authorize and bind offline source roots BEFORE auditing any squashfs or
        # rootfs apt config.  /cdrom is the image DATA root (dists+pool live at
        # the partition root); /cdrom/ncz-payload/apt-repo is a separate flat
        # candidate pool.  Only a fully authenticated pool binds; a missing,
        # empty, partial, foreign or unapproved pool does not.
        if (
            authorize_pool(
                ref,
                base,
                ref.idx,
                "image:/cdrom",
                flat=False,
                orphan_root=os.path.join(base, "pool"),
            )
            is not None
        ):
            ref.bound_offline.add("/cdrom")
        else:
            fail(
                "image",
                img,
                "/cdrom pool is not fully authorized; file:///cdrom "
                "sources cannot be trusted",
            )
        aptrepo = os.path.join(pl, "apt-repo")
        if os.path.isdir(aptrepo):
            if (
                authorize_pool(
                    ref, aptrepo, ref.idx, "image:/ncz-payload/apt-repo", flat=True
                )
                is not None
            ):
                ref.bound_offline.add("/cdrom/ncz-payload/apt-repo")
            else:
                fail(
                    "image",
                    img,
                    "/ncz-payload/apt-repo present but not fully "
                    "authorized; its file: source cannot be trusted",
                )
        layers = sorted(glob.glob(os.path.join(pl, "**", "*.squashfs"), recursive=True))
        if not layers:
            fail("image", img, "no squashfs layers found in /ncz-payload")
        for f in layers:
            total += scan_squashfs(ref, f, "image:" + os.path.basename(f))

        rootfs_tars = glob.glob(
            os.path.join(pl, "**", "*rootfs*.tar.zst"), recursive=True
        )
        for required in ("rescue", "mgmt"):
            if not any(required in os.path.basename(p) for p in rootfs_tars):
                fail("image", img, f"required {required} rootfs tarball is missing")
        for tb in rootfs_tars:
            d = tb[: -len(".tar.zst")] + ".x"
            os.makedirs(d, exist_ok=True)
            if safe_extract_zst(tb, d, "image:" + os.path.basename(tb)):
                total += scan_rootfs(ref, d, "image:" + os.path.basename(tb))

        # Scan every present .deb/.udeb anywhere under the extracted payload,
        # regardless of directory name; require non-empty when a dir exists.
        for adir in sorted(
            {
                os.path.dirname(p)
                for p in glob.glob(os.path.join(pl, "**", "*.deb"), recursive=True)
                + glob.glob(os.path.join(pl, "**", "*.udeb"), recursive=True)
            }
        ):
            found_any = True
            total += scan_debs(ref, adir, "image:" + os.path.relpath(adir, pl))

        total += _scan_esp(ref, img, parts, sector, owned)

        if not found_any:
            fail("image", img, "no inspectable package tree found in the image")
        return total
    finally:
        shutil.rmtree(owned, ignore_errors=True)
        ref.bound_offline.clear()
        ref.bound_offline.update(saved_bound)


def _scan_esp(ref, img, parts, sector, owned):
    esp = None
    for p in parts:
        t = str(p.get("type", "")).lower()
        if "efi" in t or t.startswith("c12a7328"):
            esp = p
            break
    if esp is None:
        return 0
    if not need_tool("mdir") or not need_tool("mcopy"):
        return 0
    # mtools offsets use image@@BYTE-OFFSET (not debugfs ?offset=).
    dev = f"{img}@@{int(esp['start']) * sector}"
    total = 0
    lst = run(["mdir", "-i", dev, "-/", "-b", "::/"], capture_output=True, text=True)
    if lst.returncode != 0:
        fail("image", img, "EFI System Partition could not be listed")
        return 0
    entries = [l.strip() for l in lst.stdout.split("\n") if l.strip()]
    for ent in entries:
        # Normalise a possible '::/' prefix, then require a safe relative path.
        rel = ent.removeprefix("::/")
        rel = rel.lstrip("/")
        if rel.startswith("..") or ".." in rel.split("/") or rel == "":
            fail("image", img, f"unsafe ESP entry path: {ent!r}")
            continue
        if os.path.basename(rel).endswith((".deb", ".udeb")):
            dest = os.path.join(owned, "esp")
            os.makedirs(dest, exist_ok=True)
            cp = run(
                ["mcopy", "-i", dev, "-s", f"::/{rel}", dest + "/"],
                capture_output=True,
                text=True,
            )
            if cp.returncode != 0:
                fail("image", img, f"mcopy failed for ESP entry {rel}")
                continue
            total += scan_debs(ref, dest, "image:esp")
        if initrd_candidate(rel):
            dest = os.path.join(owned, "esp-initrd")
            os.makedirs(dest, exist_ok=True)
            cp = run(
                ["mcopy", "-i", dev, "-s", f"::/{rel}", dest + "/"],
                capture_output=True,
                text=True,
            )
            if cp.returncode != 0:
                fail("image", img, f"mcopy failed for ESP initrd {rel}")
                continue
            cand = os.path.join(dest, os.path.basename(rel))
            if not os.path.isfile(cand) or os.path.getsize(cand) == 0:
                fail("image", img, f"ESP initrd {rel} copied empty/incomplete")
                continue
            total += _scan_initrd(ref, cand, owned)
    return total


NEWC_MAGIC = (b"070701", b"070702")
INITRD_MAGIC = (
    (b"\x1f\x8b", ["gzip", "-dc"]),
    (b"\xfd7zXZ\x00", ["xz", "-dc"]),
    (b"\x28\xb5\x2f\xfd", ["zstd", "-dc"]),
    (b"\x04\x22\x4d\x18", ["lz4", "-dc"]),
    (b"BZh", ["bzip2", "-dc"]),
)
INITRD_NAME_RE = re.compile(r"^(initrd|initramfs)([.\-_].*)?$", re.IGNORECASE)


def initrd_candidate(name):
    return bool(INITRD_NAME_RE.match(os.path.basename(name)))


def _read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def _decompress(path, argv, src):
    if not need_tool(argv[0]):
        return None
    r = run(argv + [path], capture_output=True)
    if r.returncode != 0:
        fail("image", src, f"initrd decompression failed ({argv[0]})")
        return None
    return r.stdout


def _decompress_bytes(data, argv, src, scratch):
    """Decompress an in-memory byte slice (used for a compressed tail appended
    after an uncompressed cpio archive).  The staging file is always created in
    the caller's owned scratch directory -- never in the ambient TMPDIR, which a
    shipping caller does not control."""
    fd, tmp = tempfile.mkstemp(prefix=".nczcpio-", dir=scratch)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        return _decompress(tmp, argv, src)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def _safe_member(root, name):
    """Return a safe destination under root, or None if the member escapes."""
    if name.startswith("/"):
        return None
    np = os.path.normpath(name)
    if np == ".." or np.startswith("../") or ".." in np.split("/"):
        return None
    p = os.path.join(root, np)
    rr = os.path.realpath(root)
    rp = os.path.realpath(p)
    if rp != rr and not rp.startswith(rr + os.sep):
        return None
    return p


def _extract_newc(data, dest, src, allow_tail=False, written=None):
    """Safely extract every concatenated newc (070701) / crc (070702) archive in
    data.  Returns the number of bytes consumed (through the last trailer and
    block padding), or None on failure.

    Format notes (GNU cpio / FreeBSD cpio(5) / libarchive): each entry is a
    110-byte ASCII-hex header, then the pathname (namesize bytes incl. a NUL),
    padded so the TOTAL offset (header+pathname) is 4-aligned, then the file
    data padded to 4 bytes.  The 070702 checksum is the ADDITIVE byte sum of the
    file data (not a CRC32).

    Every archive must be terminated by a valid TRAILER!!! record; a truncated
    stream (missing trailer, EOF at an entry boundary, or a bad trailer) is a
    failure.  Hard-link groups are resolved after the whole archive is read
    (GNU emits the zero-sized link records before the data-bearing member), keyed
    by (devmajor, devminor, ino) and scoped to one archive so concatenated
    archives cannot copy earlier content into a later archive."""
    import stat as statmod

    if written is None:
        written = set()

    def write(path, content):
        if path in written:
            fail(
                "image",
                src,
                f"duplicate cpio pathname (would hide earlier "
                f"content): {os.path.relpath(path, dest)}",
            )
            return False
        os.makedirs(os.path.dirname(path) or dest, exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(content)
        written.add(path)
        return True

    off = 0
    n = len(data)
    groups = {}
    archive_open = False
    archives = 0

    def flush_hardlinks():
        for key, g in groups.items():
            if g["content"] is None:
                fail(
                    "image",
                    src,
                    f"unresolved cpio hard-link group "
                    f"(dev {key[0]}/{key[1]} ino {key[2]})",
                )
                return False
            for p in g["paths"]:
                if not write(p, g["content"]):
                    return False
        groups.clear()
        return True

    while off < n:
        if data[off] == 0:  # inter-archive / trailing block padding
            off += 1
            continue
        if off + 6 > n:
            fail("image", src, "truncated cpio header")
            return None
        magic = data[off : off + 6]
        if magic not in NEWC_MAGIC:
            if allow_tail and not archive_open and archives > 0:
                break  # a compressed tail follows; the caller sniffs and parses it
            fail(
                "image",
                src,
                f"unsupported/unknown cpio magic at offset {off}: {magic!r}",
            )
            return None
        if off + 110 > n:
            fail("image", src, "truncated cpio header")
            return None
        hdr = data[off + 6 : off + 110]
        try:
            vals = [int(hdr[i * 8 : (i + 1) * 8], 16) for i in range(13)]
        except ValueError:
            fail("image", src, "malformed newc header")
            return None
        (
            ino,
            mode,
            _uid,
            _gid,
            nlink,
            _mtime,
            filesize,
            dmaj,
            dmin,
            _rmaj,
            _rmin,
            namesize,
            check,
        ) = vals
        off += 110
        if namesize < 1 or off + namesize > n:
            fail("image", src, "truncated or zero-length cpio pathname")
            return None
        namebytes = data[off : off + namesize]
        if not namebytes.endswith(b"\0"):
            fail("image", src, "cpio pathname has no NUL terminator")
            return None
        name = namebytes[:-1].decode("utf-8", "replace")
        off += namesize
        off = (off + 3) & ~3  # align the TOTAL offset (header + pathname)
        if off + filesize > n:
            fail("image", src, f"truncated cpio data for {name}")
            return None
        fdata = data[off : off + filesize]
        off += filesize
        off = (off + 3) & ~3
        if name == "TRAILER!!!":
            if filesize != 0:
                fail("image", src, "cpio TRAILER record has non-zero file size")
                return None
            if not flush_hardlinks():
                return None
            archive_open = False
            archives += 1
            continue
        archive_open = True
        if magic == b"070702" and (sum(fdata) & 0xFFFFFFFF) != check:
            fail("image", src, f"crc cpio checksum mismatch for {name}")
            return None
        if statmod.S_ISDIR(mode):
            d = _safe_member(dest, name)
            if d is None:
                fail("image", src, f"cpio dir escapes the scratch root: {name}")
                return None
            os.makedirs(d, exist_ok=True)
            continue
        if statmod.S_ISLNK(mode):
            target = fdata.decode("utf-8", "replace")
            ok, _ = safe_symlink_target(name, target)
            if not ok:
                fail("image", src, f"cpio symlink escapes: {name} -> {target}")
                return None
            continue  # a safe symlink is recorded but never materialised; an
            # absolute target (/proc/mounts, /run) binds to the virtual archive
            # root, never the host, so it cannot be followed on extraction.
        if statmod.S_ISREG(mode):
            d = _safe_member(dest, name)
            if d is None:
                fail("image", src, f"cpio path escapes the scratch root: {name}")
                return None
            if nlink > 1:
                key = (dmaj, dmin, ino)
                g = groups.setdefault(key, {"content": None, "paths": []})
                g["paths"].append(d)
                if filesize > 0:
                    if g["content"] is None:
                        g["content"] = fdata
                    elif g["content"] != fdata:
                        fail(
                            "image",
                            src,
                            f"contradictory cpio hard-link data for ino {ino}",
                        )
                        return None
            else:
                if not write(d, fdata):
                    return None
            continue
        # device/fifo/socket: not needed to classify packages; skip safely
    if archive_open:
        fail("image", src, "cpio archive is not terminated by a TRAILER (truncated)")
        return None
    if archives == 0:
        fail("image", src, "no complete cpio archive found")
        return None
    return off


def _scan_initrd(ref, path, owned):
    """Drive an initrd by magic (never by filename): decompress and safely extract
    every concatenated cpio archive, including a mixed raw-newc + compressed-tail
    layout.  Scan embedded debs/udebs and dpkg status.  Fails closed on any
    unrecognised format or trailing bytes; never silently skips."""
    if not os.path.isfile(path):
        fail("image", path, "initrd could not be extracted")
        return 0
    out = tempfile.mkdtemp(prefix="ncz-initrd-", dir=owned)
    remaining = _read_bytes(path)
    saw = False
    written = set()  # shared across every section so a collision cannot hide content
    while True:
        stripped = remaining.lstrip(b"\x00")
        if not stripped:
            break
        off = len(remaining) - len(stripped)
        head = remaining[off : off + 8]
        if head[:6] in NEWC_MAGIC:
            consumed = _extract_newc(
                remaining[off:], out, path, allow_tail=True, written=written
            )
            if consumed is None:
                return 0
            if consumed == 0:
                fail("image", path, "cpio section parsed to zero bytes")
                return 0
            saw = True
            remaining = remaining[off + consumed :]
            continue
        for magic, argv in INITRD_MAGIC:
            if head.startswith(magic):
                dec = _decompress_bytes(remaining[off:], argv, path, out)
                if dec is None:
                    return 0
                saw = True
                remaining = dec
                break
        else:
            fail(
                "image",
                path,
                "initrd contains an unrecognised section (not "
                "gzip/xz/zstd/lz4/bzip2/newc cpio); refusing to skip it",
            )
            return 0
    if not saw:
        fail("image", path, "initrd has no parsable cpio/compressed archive")
        return 0
    total = 0
    pools = {
        os.path.dirname(p)
        for p in glob.glob(os.path.join(out, "**", "*.deb"), recursive=True)
        + glob.glob(os.path.join(out, "**", "*.udeb"), recursive=True)
    }
    for d in pools:
        total += scan_debs(ref, d, "image:initrd")
    for stf in glob.glob(
        os.path.join(out, "**", "var/lib/dpkg/status"), recursive=True
    ):
        total += scan_status(ref, slurp(stf, errors="replace"), "image:initrd-status")
    return total


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--ubuntu-only", action="store_true")
    ap.add_argument(
        "--index-dir",
        help="directory holding the verified snapshot index (required "
        "unless --ubuntu-only or --verify-mirror)",
    )
    ap.add_argument("--fetch-index", action="store_true")
    ap.add_argument(
        "--verify-mirror",
        help="verify an offline mirror root (dists/<codename>/...) and "
        "its referenced pool bytes against the pinned signed index",
    )
    ap.add_argument("--debs", action="append", default=[])
    ap.add_argument("--packages", action="append", default=[])
    ap.add_argument("--status", action="append", default=[])
    ap.add_argument("--rootfs", action="append", default=[])
    ap.add_argument("--squashfs", action="append", default=[])
    ap.add_argument("--image", action="append", default=[])
    ap.add_argument("--work", help="scratch dir for --image (not tmpfs)")
    a = ap.parse_args()

    # The offline lint mode must never be usable to downgrade a shipping scan.
    if a.ubuntu_only and (a.image or a.verify_mirror):
        ap.error(
            "--ubuntu-only cannot be combined with --image or --verify-mirror "
            "(the shipping scan must not be downgraded)"
        )

    if a.verify_mirror:
        if not a.index_dir:
            die(
                "--verify-mirror needs --index-dir for the verified upstream "
                "snapshot index that authorizes the candidate packages"
            )
        ref = Ref(a)
        ok = verify_candidate_mirror(ref, a.verify_mirror, a.index_dir, a.fetch_index)
        print(f"== verify-mirror {a.verify_mirror}: {'OK' if ok else 'FAIL'}")
        sys.exit(0 if ok else 1)

    if not (a.debs or a.packages or a.status or a.rootfs or a.squashfs or a.image):
        ap.error("nothing to scan")
    if not a.ubuntu_only and not a.index_dir:
        die(
            "no verified snapshot index (use --index-dir DIR, --fetch-index); failing closed"
        )

    ref = Ref(a)
    total = 0
    for d in a.debs:
        total += scan_debs(ref, d, d)
    for f in a.packages:
        if not os.path.isfile(f):
            fail(f, f, "requested Packages file is missing")
            continue
        if scan_packages(ref, read_maybe_compressed(f), f) == 0:
            fail(f, f, "requested Packages file has no records")
    for f in a.status:
        if not os.path.isfile(f):
            fail(f, f, "requested status file is missing")
            continue
        if scan_status(ref, slurp(f, errors="replace"), f) == 0:
            fail(f, f, "requested status file has no records")
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
    try:
        main()
    except SystemExit:
        raise
    except FileNotFoundError as e:
        die(f"missing tool or file: {e}")
    except Exception as e:  # noqa: BLE001 - deterministic nonzero, no traceback
        die(f"{type(e).__name__}: {e}")
