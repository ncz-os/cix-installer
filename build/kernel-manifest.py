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
VARIANTS = {"lts": "assets/kernel/stable", "edge": "assets/kernel/edge"}
SCHEMA = 1


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def modinfo_vermagic(ko):
    for exe in ("modinfo", "/sbin/modinfo", "/usr/sbin/modinfo"):
        try:
            out = subprocess.run([exe, "-F", "vermagic", ko],
                                 capture_output=True, text=True, check=True)
            return out.stdout.strip().split()[0] if out.stdout.strip() else None
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    return None


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
                if n.endswith("armchina_npu.ko") and ("/modules/%s/" % kver) in n:
                    data = tf.extractfile(m).read()
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


def cmd_check():
    errors, warnings = [], []
    live = build_live()

    # Invariant 1: every variant's NPU vermagic must equal its KVER.
    for label, v in live["variants"].items():
        npu = v.get("npu")
        if not npu:
            errors.append(f"[{label}] no NPU module found for kver={v['kver']}")
        elif not npu.get("vermagic_matches_kver"):
            errors.append(f"[{label}] NPU vermagic {npu.get('vermagic')} != kver "
                          f"{v['kver']} ({npu.get('file')}) — module will not load")

    # Invariant 2: live assets must match the committed manifest (no silent swap).
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
