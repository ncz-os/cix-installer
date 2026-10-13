#!/usr/bin/env python3
"""verify-cix-mesa-repack.py <vendor.deb> <ncz.deb>

cix-mesa 24.0.4-ncz1 is the CIX vendor cix-mesa 24.0.4 with ONE change: its
/etc/ld.so.conf.d/01-cixgpu-compat.conf, which put a second glvnd + Mesa 24
stack on the system loader path (labwc/EGL "free(): invalid pointer", black
screen), is replaced by a comment, and the version is bumped to -ncz1.

This proves that, member by member: every payload file is byte-identical except
that conf file, the new conf file adds no loader path, and the control file
differs only in Version. Exit 0 = the repack is exactly that change.
"""
import hashlib, io, subprocess, sys, tarfile

CONF = "./etc/ld.so.conf.d/01-cixgpu-compat.conf"


def payload(deb):
    tar = subprocess.run(["dpkg-deb", "--fsys-tarfile", deb], capture_output=True, check=True).stdout
    out = {}
    with tarfile.open(fileobj=io.BytesIO(tar)) as t:
        for m in t:
            data = t.extractfile(m).read() if m.isfile() else b""
            out[m.name if m.name.startswith("./") else "./" + m.name] = (m.type, m.mode, m.linkname, hashlib.sha256(data).hexdigest(), data)
    return out


def control(deb):
    txt = subprocess.run(["dpkg-deb", "-f", deb], capture_output=True, check=True, text=True).stdout
    fields, key = {}, None
    for line in txt.splitlines():
        if line[:1] in (" ", "\t") and key:
            fields[key] += "\n" + line
        elif ":" in line:
            key, val = line.split(":", 1)
            fields[key] = val.strip()
    return fields


def main(vendor, ncz):
    bad = []
    a, b = payload(vendor), payload(ncz)
    if set(a) != set(b):
        bad.append(f"member sets differ: only vendor {sorted(set(a) - set(b))}, only ncz {sorted(set(b) - set(a))}")
    for k in sorted(set(a) & set(b)):
        if k == CONF:
            continue
        if a[k][:4] != b[k][:4]:
            bad.append(f"{k} differs")
    conf = b.get(CONF, (None, None, None, None, b""))[4].decode(errors="replace")
    live = [l for l in conf.splitlines() if l.strip() and not l.lstrip().startswith("#")]
    if live:
        bad.append(f"{CONF} still adds loader paths: {live}")
    ca, cb = control(vendor), control(ncz)
    diff = sorted(k for k in set(ca) | set(cb) if ca.get(k) != cb.get(k))
    if diff != ["Version"]:
        bad.append(f"control fields differ beyond Version: {diff}")
    if cb.get("Version") != ca.get("Version", "") + "-ncz1":
        bad.append(f"version {cb.get('Version')} is not {ca.get('Version')}-ncz1")
    for line in bad:
        print("FAIL", line)
    if not bad:
        print(f"OK {len(b)} members: identical except {CONF} (comment only); control differs only in Version {ca.get('Version')} -> {cb.get('Version')}")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
