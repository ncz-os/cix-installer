#!/usr/bin/env python3
"""boot-timeline.py -- wall-clock timeline of an NCZ installer boot under KVM.

Boots a raw-GPT installer image (arm64 or amd64) exactly as shipped except that
ONE serial console is appended to the Install entry's kernel options (so the UI
stream can be observed) plus the unattended answers the KVM gate uses. The
rEFInd timeout is left untouched, so the menu wait is part of the measurement.
While qemu runs, a watcher records (monotonic time, serial log size); markers
are then located in the normalized log and converted to wall-clock offsets.

  boot-timeline.py IMAGE WORKDIR [--max-secs N] [--stop-at REGEX] [--extra-opts "..."]

Output: WORKDIR/timeline.tsv (marker, seconds since qemu start, delta) and the
largest silent gaps (no serial output), with the text preceding each.
"""
import argparse, os, re, shutil, subprocess, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("image"); ap.add_argument("workdir")
ap.add_argument("--max-secs", type=int, default=5400)
ap.add_argument("--stop-at", default=None, help="regex; stop qemu once it appears in the serial log")
ap.add_argument("--extra-opts", default="")
ap.add_argument("--offline", action="store_true", help="restrict the user-mode network: the guest reaches nothing outside")
ap.add_argument("--arch", default="arm64")
ap.add_argument("--disk-gb", type=int, default=30)
ap.add_argument("--mem", type=int, default=4096)
ap.add_argument("--smp", type=int, default=4)
a = ap.parse_args()

W = os.path.abspath(a.workdir); os.makedirs(W, exist_ok=True)
img = os.path.join(W, "timeline-test.img")
if os.path.exists(img): os.remove(img)
subprocess.check_call(["cp", "--reflink=auto", a.image, img])
IS_ISO = a.image.endswith(".iso")

if not IS_ISO:
    def sh(*c): return subprocess.check_output(c, text=True)
    lba = int(re.search(r"First sector:\s*(\d+)", sh("sgdisk", "-i", "1", img)).group(1))
    off = lba * 512
    cfg = os.path.join(W, "refind.conf")
    subprocess.check_call(["mcopy", "-o", "-n", "-i", f"{img}@@{off}", "::/EFI/BOOT/refind.conf", cfg])
    text = open(cfg).read()
    params = ("passwd/username=nczuser passwd/user-fullname=NCZTestUser passwd/user-password=nczpassword123 "
              "passwd/user-password-again=nczpassword123 ncz_disk=/dev/vda ncz_fs=ext4 ncz_unattended=1 "
              "ncz_components=desktop,mgmt-container,rescue-partition debian-installer/locale=en_US.UTF-8 "
              "keyboard-configuration/xkb-keymap=us clock-setup/ntp=false time/zone=UTC")
    marker = 'menuentry "NCZ-OS Installer -- Install" {'
    head, _, rest = text.partition(marker)
    end = rest.index("\n}")
    body, tail = rest[:end], rest[end:]
    body = re.sub(r'(options\s+")([^"]*)(")',
                  lambda m: m.group(1) + m.group(2) + " console=ttyS0,115200 " + params + (" " + a.extra_opts if a.extra_opts else "") + m.group(3),
                  body, count=1)
    open(cfg, "w").write(head + marker + body + tail)
    subprocess.check_call(["mcopy", "-o", "-i", f"{img}@@{off}", cfg, "::/EFI/BOOT/refind.conf"])
    timeout_line = re.search(r"(?m)^timeout\s+(\d+)", text)
    print("rEFInd timeout left as shipped:", timeout_line.group(1) if timeout_line else "none", file=sys.stderr)


if a.arch == "arm64":
    qemu, machine, code, srcvars = "qemu-system-aarch64", "virt,gic-version=3", "/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd"
    cpu, gpu = "host", ["-device", "virtio-gpu-pci"]
else:
    qemu, machine, code, srcvars = "qemu-system-x86_64", "q35", "/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"
    cpu, gpu = "host", ["-vga", "std"]
disk = os.path.join(W, "target.qcow2"); vars_ = os.path.join(W, "VARS.fd"); s0 = os.path.join(W, "serial0.log")
for f in (disk, vars_, s0):
    if os.path.exists(f): os.remove(f)
subprocess.check_call(["qemu-img", "create", "-f", "qcow2", disk, f"{a.disk_gb}G"], stdout=subprocess.DEVNULL)
shutil.copy(srcvars, vars_)
cmd = [qemu, "-M", machine, "-accel", "kvm", "-cpu", cpu, "-smp", str(a.smp), "-m", str(a.mem),
       "-drive", f"if=pflash,format=raw,unit=0,file={code},readonly=on",
       "-drive", f"if=pflash,format=raw,unit=1,file={vars_}",
       "-drive", f"file={disk},if=virtio,format=qcow2",
       "-drive", f"file={img},if=none,id=usbstick,format=raw" + (",readonly=on" if IS_ISO else ""),
       "-device", "qemu-xhci,id=xhci", "-device", "usb-storage,bus=xhci.0,drive=usbstick,bootindex=1",
       "-netdev", "user,id=n0" + (",restrict=yes" if a.offline else ""), "-device", "virtio-net-pci,netdev=n0,romfile=",
       "-object", "rng-random,filename=/dev/urandom,id=rng0", "-device", "virtio-rng-pci,rng=rng0",
       "-serial", f"file:{s0}", "-display", "none", "-no-reboot"] + gpu
samples = []   # (t, size)
stop = threading.Event()
t0 = time.monotonic()
def watch():
    last = -1
    while not stop.is_set():
        try: sz = os.path.getsize(s0)
        except OSError: sz = 0
        if sz != last:
            samples.append((time.monotonic() - t0, sz)); last = sz
        time.sleep(0.2)
th = threading.Thread(target=watch, daemon=True); th.start()
p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
stop_re = re.compile(a.stop_at) if a.stop_at else None
try:
    while p.poll() is None and time.monotonic() - t0 < a.max_secs:
        time.sleep(2)
        if stop_re and os.path.exists(s0):
            raw = open(s0, "rb").read().decode("latin1")
            if stop_re.search(re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\r", " ", raw)): break
finally:
    if p.poll() is None: p.terminate()
    time.sleep(1); stop.set(); th.join()
total = time.monotonic() - t0

raw = open(s0, "rb").read().decode("latin1")
def t_of(offset):
    for t, sz in samples:
        if sz > offset: return t
    return None

# normalized copy that keeps a map back to raw offsets
norm, idx = [], []
i = 0
esc = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]")
while i < len(raw):
    m = esc.match(raw, i)
    if m: i = m.end(); continue
    ch = raw[i]
    norm.append(" " if ch == "\r" else ch); idx.append(i); i += 1
ntext = "".join(norm)

MARKERS = [
    ("firmware -> boot manager starts", r"BdsDxe: starting"),
    ("boot manager launches kernel (rEFInd timeout elapsed)", r"Using load options"),
    ("kernel start (dmesg 0.000000)", r"Linux version "),
    ("kernel runs /init", r"Run /init as init"),
    ("d-i initrd up (syslog daemon)", r"Starting system log daemon"),
    ("early_command diagnostics", r"NCZ CONSOLE DIAG"),
    ("d-i first UI (Detecting hardware)", r"Detecting hardware"),
    ("Loading additional components", r"Loading additional components"),
    ("Partitions formatting", r"Partitions formatting"),
    ("Installing the base system", r"Installing the base system"),
    ("Select and install software", r"Select and install software"),
    ("Finishing the installation", r"Finishing the installation"),
    ("late.sh starts", r"Preparing NCZ-OS"),
    ("reboot / poweroff", r"reboot: |Restarting system|Power down|System halted"),
]
rows = []
for name, rx in MARKERS:
    m = re.search(rx, ntext)
    if m:
        t = t_of(idx[m.start()])
        rows.append((name, t))
    else:
        rows.append((name, None))
out = os.path.join(W, "timeline.tsv")
with open(out, "w") as f:
    prev = 0.0
    f.write("marker\tt_seconds\tdelta_seconds\n")
    for name, t in rows:
        if t is None: f.write(f"{name}\t-\t-\n"); continue
        f.write(f"{name}\t{t:.1f}\t{t - prev:.1f}\n"); prev = t
    f.write(f"(run ended)\t{total:.1f}\t{total - prev:.1f}\n")
print(open(out).read())
# silent gaps
gaps = []
for (t1, s1), (t2, s2) in zip(samples, samples[1:]):
    if t2 - t1 >= 4:
        tail = re.sub(r"\s+", " ", "".join(norm[max(0, len([1 for x in idx if x < s1]) - 120):len([1 for x in idx if x < s1])]))[-100:]
        gaps.append((t2 - t1, t1, tail))
gaps.sort(reverse=True)
print("largest silent gaps on the serial console (>=4 s):")
for g, t1, tail in gaps[:12]:
    print(f"  {g:6.1f}s  starting at {t1:6.1f}s  after: ...{tail}")
