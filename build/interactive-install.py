#!/usr/bin/env python3
# interactive-install.py — drive a FULL d-i install in QEMU through the
# INTERACTIVE disk-fs-chooser (no ncz_disk override), to genuinely validate
# the operator path end-to-end. Serial is a bidirectional unix socket we both
# read (to detect prompts) and write (to answer them).
import os, socket, subprocess, sys, time, re, threading

ISO = sys.argv[1]
BASE = ISO[:-4] if ISO.endswith('.iso') else ISO
DISK = BASE + "-target.qcow2"
VARS = BASE + "-vars.fd"
SERSOCK = BASE + "-serial.sock"
LOG = BASE + "-interactive.log"
EDK2 = "/usr/share/AAVMF/AAVMF_CODE.fd"

for p in (DISK, VARS, SERSOCK):
    try: os.remove(p)
    except FileNotFoundError: pass
subprocess.run(["qemu-img","create","-f","qcow2",DISK,"30G"], check=True,
               stdout=subprocess.DEVNULL)
subprocess.run(["truncate","-s","64m",VARS], check=True)

qemu = subprocess.Popen([
    "qemu-system-aarch64","-M","virt","-enable-kvm","-cpu","host",
    "-smp","4","-m","4096",
    "-drive",f"if=pflash,format=raw,readonly=on,file={EDK2}",
    "-drive",f"if=pflash,format=raw,file={VARS}",
    "-drive",f"if=virtio,file={DISK},format=qcow2",
    "-drive",f"if=none,id=isousb,format=raw,file={ISO},readonly=on",
    "-device","usb-ehci,id=usb0",
    "-device","usb-storage,bus=usb0.0,drive=isousb,removable=on",
    "-boot","d","-netdev","user,id=net0",
    "-device","virtio-net-pci,netdev=net0,romfile=",
    "-display","none",
    "-serial",f"unix:{SERSOCK},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# wait for the serial socket to appear
for _ in range(60):
    if os.path.exists(SERSOCK): break
    time.sleep(1)
time.sleep(2)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(SERSOCK)
sock.settimeout(1.0)

logf = open(LOG, "wb")
buf = bytearray()
strip = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x0f|\x0e')
def visible(b): return strip.sub(b'', b).replace(b'\r', b'\n')

# state machine: which prompts we've already answered (fire once each)
done = set()
t0 = time.time()
DEADLINE = 1500  # s
last_send = 0

def send(keys, tag):
    global last_send
    sock.sendall(keys)
    last_send = time.time()
    logf.write(b"\n<<<DRIVER SENT %s: %r>>>\n" % (tag.encode(), keys))
    logf.flush()
    print(f"[driver +{int(time.time()-t0)}s] sent {tag}", flush=True)

while True:
    if qemu.poll() is not None:
        print(f"[driver] qemu EXITED rc={qemu.returncode} at +{int(time.time()-t0)}s", flush=True)
        break
    if time.time() - t0 > DEADLINE:
        print("[driver] DEADLINE hit", flush=True); qemu.terminate(); break
    try:
        chunk = sock.recv(4096)
        if chunk:
            buf += chunk
            logf.write(chunk); logf.flush()
            if len(buf) > 65536: buf = buf[-65536:]
    except socket.timeout:
        chunk = b""
    win = bytes(visible(buf))[-4000:]

    # terminal states
    if b"Installation complete" in win or b"reboot: Restarting" in win \
       or b"Welcome to" in win and b"NCZ-OS" in win:
        print(f"[driver +{int(time.time()-t0)}s] INSTALL COMPLETE / rebooting", flush=True)
        time.sleep(20); qemu.terminate(); break
    if b'late.sh" failed' in win or b"Failed to run preseeded" in win \
       or b"install is NOT bootable" in win:
        print(f"[driver +{int(time.time()-t0)}s] *** LATE.SH FAILURE DETECTED ***", flush=True)
        time.sleep(5); qemu.terminate(); break

    # only act if the screen has been quiet ~2s (prompt fully drawn) and we
    # haven't just sent something
    quiet = time.time() - last_send > 3
    if not chunk and quiet:
        # TARGET DISK chooser — accept preselected disk (Enter)
        if b"TARGET DISK" in win and "disk" not in done:
            done.add("disk"); send(b"\r", "disk-select ENTER")
        # filesystem chooser (btrfs/ext4) — accept default (Enter)
        elif ("disk" in done and re.search(rb"(root filesystem|ext4|btrfs|FILESYSTEM)", win)
              and "fs" not in done):
            done.add("fs"); send(b"\r", "fs-select ENTER")
        # generic Continue/confirm dialogs after our choices
        elif b"<Continue>" in win and "cont" not in done and "fs" in done:
            done.add("cont"); send(b"\r", "continue ENTER")

logf.close()
try: sock.close()
except: pass
print(f"[driver] log: {LOG}", flush=True)
