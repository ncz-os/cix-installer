#!/usr/bin/env python3
"""boot-screens.py -- capture the installer's PRIMARY CONSOLE (qemu screendump) at intervals under KVM.

  boot-screens.py IMAGE WORKDIR [--arch arm64|amd64] [--secs N] [--every S] [--interactive] [--extra-opts "..."]

Boots the raw-GPT installer image as shipped (the Install entry) with the unattended answers EXCEPT
ncz_components/ncz_unattended when --interactive is given, so the component chooser and other prompts really appear.
Writes WORKDIR/screens/NNNN-<t>s.ppm (+ .png when ImageMagick exists) and WORKDIR/serial0.log. The screens are
what the operator sees on the monitor; build/check-installer-screens.py asserts on them.
"""
import argparse, os, re, shutil, socket, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("image"); ap.add_argument("workdir")
ap.add_argument("--arch", default="arm64")
ap.add_argument("--secs", type=int, default=240)
ap.add_argument("--every", type=float, default=4.0)
ap.add_argument("--interactive", action="store_true")
ap.add_argument("--extra-opts", default="")
ap.add_argument("--telnet-port", type=int, default=12323)
ap.add_argument("--probe", default="")
ap.add_argument("--answer", action="append", default=[], help="REGEX=KEYS: when the serial console screen matches REGEX send KEYS once (\\r = Enter)")
ap.add_argument("--vt", action="store_true", help="also read the fbcon VTs over the diag telnet (slow)")
ap.add_argument("--rows", type=int, default=24); ap.add_argument("--cols", type=int, default=80)
ap.add_argument("--mem", type=int, default=4096)
ap.add_argument("--smp", type=int, default=4)
a = ap.parse_args()

W = os.path.abspath(a.workdir); os.makedirs(W, exist_ok=True)
S = os.path.join(W, "screens"); shutil.rmtree(S, ignore_errors=True); os.makedirs(S)
img = os.path.join(W, "screens-test.img")
if os.path.exists(img): os.remove(img)
subprocess.check_call(["cp", "--reflink=auto", a.image, img])
def sh(*c): return subprocess.check_output(c, text=True)
lba = int(re.search(r"First sector:\s*(\d+)", sh("sgdisk", "-i", "1", img)).group(1)); off = lba * 512
cfg = os.path.join(W, "refind.conf")
subprocess.check_call(["mcopy", "-o", "-n", "-i", f"{img}@@{off}", "::/EFI/BOOT/refind.conf", cfg])
text = open(cfg).read()
params = ("passwd/username=nczuser passwd/user-fullname=NCZTestUser passwd/user-password=nczpassword123 "
          "passwd/user-password-again=nczpassword123 ncz_diag_pw=parity-screen-test ncz_disk=/dev/vda ncz_fs=ext4 "
          "debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us clock-setup/ntp=false time/zone=UTC")
if not a.interactive:
    params += " ncz_unattended=1 ncz_components=desktop,mgmt-container,rescue-partition"
marker = 'menuentry "NCZ-OS Installer -- Install" {'
head, _, rest = text.partition(marker)
end = rest.index("\n}")
body, tail = rest[:end], rest[end:]
body = re.sub(r'(options\s+")([^"]*)(")',
              lambda m: m.group(1) + m.group(2) + " " + params + (" " + a.extra_opts if a.extra_opts else "") + m.group(3),
              body, count=1)
open(cfg, "w").write(head + marker + body + tail)
subprocess.check_call(["mcopy", "-o", "-i", f"{img}@@{off}", cfg, "::/EFI/BOOT/refind.conf"])

if a.arch == "arm64":
    qemu, machine, code, srcvars, gpu = "qemu-system-aarch64", "virt,gic-version=3", "/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd", ["-device", "ramfb", "-device", "usb-kbd"]
else:
    qemu, machine, code, srcvars, gpu = "qemu-system-x86_64", "q35", "/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd", ["-vga", "std"]
ser = os.path.join(W, "serial.sock"); disk = os.path.join(W, "target.qcow2"); vars_ = os.path.join(W, "VARS.fd"); s0 = os.path.join(W, "serial0.log"); mon = os.path.join(W, "mon.sock")
for f in (disk, vars_, s0, mon, ser):
    if os.path.exists(f): os.remove(f)
subprocess.check_call(["qemu-img", "create", "-f", "qcow2", disk, "30G"], stdout=subprocess.DEVNULL)
shutil.copy(srcvars, vars_)
cmd = [qemu, "-M", machine, "-accel", "kvm", "-cpu", "host", "-smp", str(a.smp), "-m", str(a.mem),
       "-drive", f"if=pflash,format=raw,unit=0,file={code},readonly=on",
       "-drive", f"if=pflash,format=raw,unit=1,file={vars_}",
       "-drive", f"file={disk},if=virtio,format=qcow2",
       "-drive", f"file={img},if=none,id=usbstick,format=raw",
       "-device", "qemu-xhci,id=xhci", "-device", "usb-storage,bus=xhci.0,drive=usbstick,bootindex=1",
       "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:%d-:23" % a.telnet_port, "-device", "virtio-net-pci,netdev=n0,romfile=",
       "-object", "rng-random,filename=/dev/urandom,id=rng0", "-device", "virtio-rng-pci,rng=rng0",
       "-serial", f"unix:{ser},server=on,wait=off", "-monitor", f"unix:{mon},server,nowait", "-display", "none", "-no-reboot"] + gpu
p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t0 = time.monotonic()
for _ in range(50):
    if os.path.exists(mon): break
    time.sleep(0.2)
c = socket.socket(socket.AF_UNIX); c.connect(mon); c.settimeout(3)
try: c.recv(4096)
except Exception: pass
import threading
try:
    import pyte
except ImportError:
    sys.exit("boot-screens.py needs pyte (python3 -m venv V && V/bin/pip install pyte)")
for _ in range(50):
    if os.path.exists(ser): break
    time.sleep(0.2)
sc = socket.socket(socket.AF_UNIX); sc.connect(ser); sc.settimeout(0.5)
screen = pyte.Screen(a.cols, a.rows); stream = pyte.Stream(screen)
import codecs
dec = codecs.getincrementaldecoder("utf-8")("replace")
lock = threading.Lock(); rawlog = open(s0, "wb"); done = threading.Event()
answered = set()
rules = [(re.compile(x.split("=", 1)[0], re.S), x.split("=", 1)[1].encode().decode("unicode_escape").encode()) for x in a.answer]
TS = os.path.join(W, "serial-screens"); shutil.rmtree(TS, ignore_errors=True); os.makedirs(TS)
def screen_text():
    return "\n".join(l.rstrip() for l in screen.display).rstrip("\n")
def pump():
    last, changed, nsnap, lastsnap = "", time.monotonic(), 0, None
    while not done.is_set():
        try: d = sc.recv(65536)
        except socket.timeout: d = b""
        except OSError: break
        with lock:
            if d:
                rawlog.write(d); rawlog.flush(); stream.feed(dec.decode(d))
            txt = screen_text()
        now = time.monotonic()
        if txt != last: last, changed = txt, now
        elif txt.strip() and now - changed > 2.0 and txt != lastsnap:
            lastsnap = txt
            open(os.path.join(TS, f"{nsnap:04d}-{int(now - t0):04d}s.txt"), "w").write(f"# t={int(now - t0)}s\n{txt}\n"); nsnap += 1
        for i, (rx, keys) in enumerate(rules):
            if i not in answered and txt and rx.search(txt) and now - changed > 1.0:
                answered.add(i); sc.sendall(keys)
                open(os.path.join(W, "answers.log"), "a").write(f"t={int(now - t0)}s rule {i} matched -> {keys!r}\n")
threading.Thread(target=pump, daemon=True).start()

T = os.path.join(W, "texts"); shutil.rmtree(T, ignore_errors=True); os.makedirs(T)

def tn_read(sock, until, timeout=8):
    """read from a busybox telnetd, dropping IAC negotiation, until the regex matches"""
    buf = b""; end = time.monotonic() + timeout
    while time.monotonic() < end:
        try: d = sock.recv(4096)
        except socket.timeout: d = b""
        if not d and re.search(until.encode(), buf): break
        i = 0
        while i < len(d):
            if d[i] == 255 and i + 2 < len(d) + 0 and d[i+1] in (251, 252, 253, 254):
                cmd, opt = d[i+1], d[i+2]
                # refuse everything
                sock.sendall(bytes([255, 252 if cmd in (253, 254) else 254, opt])); i += 3
            elif d[i] == 255: i += 2
            else: buf += d[i:i+1]; i += 1
        if re.search(until.encode(), buf): break
    return buf.decode("latin1", "replace")

def probe(cmd):
    try:
        s = socket.create_connection(("127.0.0.1", a.telnet_port), timeout=4); s.settimeout(1.0)
        tn_read(s, r"login: ?$", 6); s.sendall(b"root\r\n")
        tn_read(s, r"[Pp]assword: ?$", 6); s.sendall(b"parity-screen-test\r\n")
        tn_read(s, r"# ?$", 6)
        s.sendall((cmd + "; echo __E''ND__\r\n").encode())
        out = tn_read(s, r"\n__END__", 8); s.close()
        return out.replace("\r", "")
    except Exception as e:
        return "(telnet not ready: %s)\n" % e

def grab_vt(vt=1):
    """text of a virtual console (what the operator sees), via the installer's diagnostic telnet"""
    try:
        s = socket.create_connection(("127.0.0.1", a.telnet_port), timeout=4); s.settimeout(1.0)
        tn_read(s, r"login: ?$", 6); s.sendall(b"root\r\n")
        tn_read(s, r"[Pp]assword: ?$", 6); s.sendall(b"parity-screen-test\r\n")
        tn_read(s, r"# ?$", 6)
        s.sendall(("stty size </dev/tty%d; cat /dev/vcs%d; echo; echo __E''ND__\r\n" % (vt, vt)).encode())
        out = tn_read(s, r"\n__END__", 8)
        s.close()
        out = out.replace("\r", "")
        body = out.split("__END__")[0]
        i = body.rfind("ND__"); body = body[body.find("\n", i) + 1:] if i >= 0 else body
        m = re.match(r"\s*(\d+) (\d+)\n", body)
        if not m: return "(no console size in: %r)\n" % body[:80]
        cols = int(m.group(2)); raw = body[m.end():].replace("\n", "")
        rows = [raw[i:i + cols].rstrip() for i in range(0, len(raw), cols)]
        while rows and not rows[-1]: rows.pop()
        return "\n".join(rows) + "\n"
    except Exception as e:
        return "(telnet not ready: %s)\n" % e

n = 0
try:
    while p.poll() is None and time.monotonic() - t0 < a.secs:
        t = int(time.monotonic() - t0)
        f = os.path.join(S, f"{n:04d}-{t:04d}s.ppm")
        c.sendall(f"screendump {f}\n".encode())
        try: c.recv(4096)
        except Exception: pass
        if t > 20 and a.vt:
            open(os.path.join(T, f"{n:04d}-{t:04d}s-tty1.txt"), "w").write(grab_vt(1))
            open(os.path.join(T, f"{n:04d}-{t:04d}s-tty3.txt"), "w").write(grab_vt(3))
        if t > 20 and a.probe:
            open(os.path.join(T, f"{n:04d}-{t:04d}s-probe.txt"), "w").write(probe(a.probe))
        n += 1
        time.sleep(a.every)
finally:
    done.set()
    if p.poll() is None: p.terminate()
    time.sleep(1)
if shutil.which("convert"):
    for f in sorted(os.listdir(S)):
        if f.endswith(".ppm") and os.path.getsize(os.path.join(S, f)) > 0:
            subprocess.call(["magick", os.path.join(S, f), os.path.join(S, f[:-4] + ".png")])
print(f"{n} screendumps in {S}")
