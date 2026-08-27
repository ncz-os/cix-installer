#!/usr/bin/env python3
"""kernel-manifest.py — emit/verify the NCZ kernel build manifest.

The manifest (assets/kernel-manifest.json) is the contract between the BSP
producer (Yocto / kernel build) and the Debian installer integration layer.
It pins, per kernel variant (lts/edge):

  * KVER                       (uname -r of the shipped kernel)
  * Image-cixmini.bin          sha256 + size
  * modules-cixmini.tgz        sha256 + size
  * config-<KVER>              filename + sha256
  * NPU module                 filename + vermagic + sha256 + vermagic_matches_kver

Why: the proprietary out-of-tree NPU module (armchina_npu.ko) is vermagic-locked
to a specific KVER. If the kernel is bumped (e.g. edge 7.0.3 -> 7.0.12) but the
NPU .ko is not rebuilt, the module silently fails to load on target. This
manifest makes that drift a hard, visible build-time error instead of a field
failure. Yocto should emit a file in this same schema; `gen` here bootstraps it
and serves as the reference implementation, and `check` enforces it in CI / the
ISO + kernel-deb builds.

Usage:
  kernel-manifest.py gen            # (re)write assets/kernel-manifest.json
  kernel-manifest.py check          # verify live assets vs manifest + invariants
  kernel-manifest.py check --strict # also fail on NPU vermagic mismatch (default warns? no: always errors)
"""
import sys, os, json, hashlib, subprocess, glob, datetime, tarfile, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MANIFEST = os.path.join(ROOT, "assets", "kernel-manifest.json")
VARIANTS = {"edge": "assets/kernel/edge"}
SCHEMA = 1

# Prebuilt, vermagic-locked accelerator module overlays. Each is a directory of
# <KVER>/ subdirectories holding .ko files built against exactly that release.
# post-install/8x-*.sh installs the subdirectory matching the kernel it stages.
ACCEL_OVERLAYS = {
    "mali":    "assets/kernel/mali",
    "panthor": "assets/kernel/panthor",
}

# Accelerator drivers must be out-of-tree (DKMS / prebuilt overlay), never built
# into the shipped kernel: an in-tree copy wins over the overlay at modprobe time
# and silently masks the driver we actually validated. Value is the severity to
# report while a driver is still mid-migration -- flip an entry to "error" once
# that driver is fully out-of-tree so it can never regress back in.
INTREE_ACCEL_POLICY = {
    # panthor is NOT SHIPPED (2026-08-04): its CSF firmware dies on the first
    # user VM_BIND because the Sky1 IDM revokes the GPU's bus-master grant
    # (cixtech/cix-linux-main#59). There is no panthor menuentry and every
    # entry blacklists the module, so an in-tree copy masks nothing -- there is
    # no out-of-tree panthor to mask. Kept as "warn" rather than dropped so the
    # config stays visible; if panthor is ever shipped again this must go back
    # to "error" and the module must be built out-of-tree.
    "CONFIG_DRM_PANTHOR":  "warn",
    "CONFIG_ARMCHINA_NPU": "warn",   # still in-tree; needs 0121/0123 ported to the OOT tree first
    "CONFIG_VIDEO_LINLON": "warn",   # amvx still carried by the in-tree 0126+ patch series
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _vermagic_from_bytes(ko):
    """Read vermagic straight out of the module's .modinfo section.

    kmod stores .modinfo as NUL-separated key=value strings, so scanning for
    b"vermagic=" is sufficient and needs no ELF parsing. This exists because the
    gate must also run where modinfo does not: macOS dev boxes and minimal CI
    images. Without it the check reported "cannot read vermagic" as a hard error
    on every non-Linux host -- which is exactly the kind of false failure that
    gets a gate switched off, and this gate is the one standing between us and
    another silent no-GPU boot.

    Handles xz/gz/zstd-compressed modules where the stdlib can decompress them.
    """
    try:
        with open(ko, "rb") as f:
            blob = f.read()
    except OSError:
        return None
    if ko.endswith(".xz"):
        try:
            import lzma; blob = lzma.decompress(blob)
        except Exception:
            return None
    elif ko.endswith(".gz"):
        try:
            import gzip; blob = gzip.decompress(blob)
        except Exception:
            return None
    elif ko.endswith(".zst"):
        return None  # no stdlib zstd; fall back to modinfo
    key = b"vermagic="
    i = blob.find(key)
    if i < 0:
        return None
    end = blob.find(b"\x00", i)
    if end < 0:
        return None
    val = blob[i + len(key):end].decode("utf-8", "replace").strip()
    return val.split()[0] if val else None


def modinfo_vermagic(ko):
    for exe in ("modinfo", "/sbin/modinfo", "/usr/sbin/modinfo"):
        try:
            out = subprocess.run([exe, "-F", "vermagic", ko],
                                 capture_output=True, text=True, check=True)
            if out.stdout.strip():
                return out.stdout.strip().split()[0]
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    return _vermagic_from_bytes(ko)


def intree_npu(kver, modules_tgz):
    """If the kernel ships the NPU driver IN-TREE (built into modules-cixmini.tgz
    under lib/modules/<KVER>/), that is authoritative: it is compiled against this
    exact kernel tree so its vermagic matches by construction, and 80-npu.sh
    prefers it over any out-of-tree .ko. Returns a record or None."""
    if not modules_tgz or not os.path.isfile(modules_tgz):
        return None
    try:
        with tarfile.open(modules_tgz, "r:gz") as tf:
            for m in tf:
                n = m.name
                if (n.endswith("armchina_npu.ko") or n.endswith("armchina_npu.ko.xz")) and ("/modules/%s/" % kver) in n:
                    data = tf.extractfile(m).read()
                    if n.endswith(".xz"):
                        import lzma
                        data = lzma.decompress(data)
                    break
            else:
                return None
    except (tarfile.TarError, OSError):
        return None
    vm = None
    tmp = tempfile.NamedTemporaryFile(suffix=".ko", delete=False)
    try:
        tmp.write(data); tmp.close()
        vm = modinfo_vermagic(tmp.name)
    finally:
        os.unlink(tmp.name)
    vm = vm or kver  # path is authoritative for where modprobe loads it
    return {
        "source": "in-tree",
        "file": "%s:%s" % (os.path.relpath(modules_tgz, ROOT), n),
        "vermagic": vm,
        "sha256": hashlib.sha256(data).hexdigest(),
        "vermagic_matches_kver": (vm == kver),
    }


def npu_for_kver(kver):
    """Pick the out-of-tree NPU .ko matching this KVER by vermagic; fall back to
    first seen. Used only when the driver is NOT in-tree."""
    best = None
    for ko in sorted(glob.glob(os.path.join(ROOT, "assets/npu/armchina_npu-*.ko"))):
        if ko.endswith(".r57-bak"):
            continue
        vm = modinfo_vermagic(ko)
        rec = {
            "source": "out-of-tree",
            "file": os.path.relpath(ko, ROOT),
            "vermagic": vm,
            "sha256": sha256(ko),
            "vermagic_matches_kver": (vm == kver),
        }
        if vm == kver:
            return rec
        if best is None:
            best = rec
    return best


def scan_variant(label, reldir):
    d = os.path.join(ROOT, reldir)
    kverf = os.path.join(d, "KVER")
    if not os.path.isfile(kverf):
        return None
    kver = open(kverf).read().strip()
    img = os.path.join(d, "Image-cixmini.bin")
    mods = os.path.join(d, "modules-cixmini.tgz")
    cfgs = sorted(glob.glob(os.path.join(d, "config-*")))
    rec = {"kver": kver, "dir": reldir}
    if os.path.isfile(img):
        rec["image"] = {"file": os.path.relpath(img, ROOT),
                        "sha256": sha256(img), "size": os.path.getsize(img)}
    if os.path.isfile(mods):
        rec["modules"] = {"file": os.path.relpath(mods, ROOT),
                          "sha256": sha256(mods), "size": os.path.getsize(mods)}
    if cfgs:
        rec["config"] = {"file": os.path.relpath(cfgs[0], ROOT),
                         "sha256": sha256(cfgs[0])}
    rec["npu"] = intree_npu(kver, mods if os.path.isfile(mods) else None) \
        or npu_for_kver(kver)
    return rec


def kernel_debs():
    out = []
    for deb in sorted(glob.glob(os.path.join(ROOT, "build/kernel-debs/*.deb"))):
        out.append({"file": os.path.relpath(deb, ROOT), "sha256": sha256(deb)})
    return out


def build_live():
    variants = {}
    for label, reldir in VARIANTS.items():
        rec = scan_variant(label, reldir)
        if rec:
            variants[label] = rec
    return {
        "schema": SCHEMA,
        "generated_utc": datetime.datetime.now(datetime.timezone.utc)
                          .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": "build/kernel-manifest.py",
        "variants": variants,
        "kernel_debs": kernel_debs(),
    }


def cmd_gen():
    live = build_live()
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    with open(MANIFEST, "w") as f:
        json.dump(live, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {os.path.relpath(MANIFEST, ROOT)}")
    for label, v in live["variants"].items():
        npu = v.get("npu") or {}
        flag = "OK" if npu.get("vermagic_matches_kver") else "MISMATCH"
        print(f"  {label:4} kver={v['kver']:24} npu={npu.get('vermagic')} "
              f"({npu.get('source','?')}) [{flag}]")
    return 0



def overlay_vermagic_errors():
    """Every .ko under assets/kernel/<overlay>/<KVER>/ must carry vermagic ==
    <KVER>. This is the check that would have caught the rc5-on-rc6 regression:
    the directory said rc6 while every module inside was still stamped rc5, so
    modprobe refused them all and the board booted on software rendering with no
    /dev/mali0 and no error anyone was looking at."""
    errors = []
    for name, reldir in ACCEL_OVERLAYS.items():
        base = os.path.join(ROOT, reldir)
        if not os.path.isdir(base):
            continue
        for kver in sorted(os.listdir(base)):
            d = os.path.join(base, kver)
            # only <KVER>/ dirs hold modules; skip patches/, README.md, *.patch
            if not os.path.isdir(d) or kver in ("patches", "src"):
                continue
            kos = sorted(glob.glob(os.path.join(d, "*.ko")))
            if not kos:
                continue
            for ko in kos:
                vm = modinfo_vermagic(ko)
                if vm is None:
                    errors.append(f"[{name}] cannot read vermagic from "
                                  f"{os.path.relpath(ko, ROOT)} (modinfo missing?)")
                elif vm != kver:
                    errors.append(f"[{name}] {os.path.relpath(ko, ROOT)} vermagic "
                                  f"{vm} != directory {kver} — module will NOT load")
    return errors


def overlay_present_errors(live):
    """Each shipped variant needs an accelerator overlay matching its KVER.
    A missing overlay is a silent no-GPU boot, so make it a build-time failure."""
    errors = []
    for label, v in live.get("variants", {}).items():
        kver = v.get("kver")
        if not kver:
            continue
        base = os.path.join(ROOT, ACCEL_OVERLAYS["mali"])
        if not os.path.isdir(base):
            continue
        if not os.path.isdir(os.path.join(base, kver)):
            have = [k for k in sorted(os.listdir(base))
                    if os.path.isdir(os.path.join(base, k)) and k not in ("patches", "src")]
            errors.append(f"[{label}] no mali overlay for kver={kver} "
                          f"(assets/kernel/mali/{kver}/ missing; have: {', '.join(have) or 'none'})"
                          " — this board would boot with no /dev/mali0")
    return errors


def intree_accel_findings(live):
    """Accelerators must not be compiled into the shipped kernel config."""
    errors, warnings = [], []
    for label, v in live.get("variants", {}).items():
        cfg = (v.get("config") or {}).get("file")
        if not cfg:
            continue
        path = os.path.join(ROOT, cfg)
        if not os.path.isfile(path):
            continue
        try:
            text = open(path, errors="replace").read()
        except OSError:
            continue
        for sym, severity in INTREE_ACCEL_POLICY.items():
            for val in ("y", "m"):
                if f"\n{sym}={val}\n" in "\n" + text:
                    msg = (f"[{label}] {sym}={val} is IN-TREE in {cfg} — accelerators "
                           "must ship out-of-tree (an in-tree copy masks the validated "
                           "overlay/DKMS module at modprobe time)")
                    (errors if severity == "error" else warnings).append(msg)
                    break
    return errors, warnings


def npu_intree_enabled(v):
    """True if this variant's shipped config builds the NPU driver in-tree.

    Invariant 4 forbids accelerators in the kernel config; the NPU therefore
    ships as DKMS and is ABSENT from the modules tarball by design (meta-cix
    6f8b01e set "# CONFIG_ARMCHINA_NPU is not set"). Invariant 1 predates that
    and unconditionally demanded an NPU module, so the two contradicted each
    other and every DKMS-correct kernel failed the check.
    """
    cfg = (v.get("config") or {}).get("file")
    if not cfg:
        return False
    path = os.path.join(ROOT, cfg)
    if not os.path.isfile(path):
        return False
    try:
        text = "\n" + open(path, errors="replace").read()
    except OSError:
        return False
    return "\nCONFIG_ARMCHINA_NPU=y\n" in text or "\nCONFIG_ARMCHINA_NPU=m\n" in text


def cmd_check():
    errors, warnings = [], []
    live = build_live()

    # Invariant 1: every variant's NPU vermagic must equal its KVER.
    for label, v in live["variants"].items():
        npu = v.get("npu")
        if not npu:
            # Absent is CORRECT when the config does not build it: the NPU
            # ships as DKMS under invariant 4. Only a config that claims to
            # build the driver while shipping no module is a real defect.
            if npu_intree_enabled(v):
                errors.append(f"[{label}] config builds CONFIG_ARMCHINA_NPU but "
                              f"no NPU module found for kver={v['kver']}")
        elif not npu.get("vermagic_matches_kver"):
            errors.append(f"[{label}] NPU vermagic {npu.get('vermagic')} != kver "
                          f"{v['kver']} ({npu.get('file')}) — module will not load")

    # Invariant 2: every prebuilt overlay module's vermagic must equal its dir KVER.
    errors.extend(overlay_vermagic_errors())

    # Invariant 3: each shipped variant needs a mali overlay for its KVER.
    errors.extend(overlay_present_errors(live))

    # Invariant 4: no accelerator may be built into the shipped kernel config.
    _e, _w = intree_accel_findings(live)
    errors.extend(_e); warnings.extend(_w)

    # Invariant 5: live assets must match the committed manifest (no silent swap).
    if not os.path.isfile(MANIFEST):
        warnings.append("no committed manifest; run 'kernel-manifest.py gen'")
    else:
        committed = json.load(open(MANIFEST))
        for label, lv in live["variants"].items():
            cv = committed.get("variants", {}).get(label)
            if not cv:
                warnings.append(f"[{label}] present on disk but absent from manifest")
                continue
            if lv["kver"] != cv["kver"]:
                errors.append(f"[{label}] KVER drift: disk={lv['kver']} manifest={cv['kver']}")
            for part in ("image", "modules", "config", "npu"):
                ld, cd = lv.get(part) or {}, cv.get(part) or {}
                if ld.get("sha256") != cd.get("sha256"):
                    errors.append(f"[{label}] {part} sha256 drift vs manifest "
                                  f"(regenerate with 'kernel-manifest.py gen')")
        for label in committed.get("variants", {}):
            if label not in live["variants"]:
                warnings.append(f"[{label}] in manifest but missing on disk")

    for w in warnings:
        print(f"WARN: {w}")
    for e in errors:
        print(f"ERROR: {e}")
    if errors:
        print(f"manifest check FAILED ({len(errors)} error(s))")
        return 1
    print("manifest check OK" + (f" ({len(warnings)} warning(s))" if warnings else ""))
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "check"
    if cmd == "gen":
        return cmd_gen()
    if cmd == "check":
        return cmd_check()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
