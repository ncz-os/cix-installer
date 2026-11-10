#!/usr/bin/env python3
"""kvm-console-saver-live.py -- live behavioural phase of
build/kvm-console-saver-gate.sh (04:40Z console-saver order, item 5).

Boots the installed server image under KVM, logs in on the serial console as
the KVM-gate account (nczuser/nczpassword123, made by the gate preseed in
build/kvm-install-gate-gpt.sh), and drives the Magnetar console saver:

  1. ncz-console-saver enabled + active
  2. idle_seconds=10 (conf edit + restart)
  3. within ~idle+20s: a ncz-bh-console saver appears AND the foreground VT
     moves off the baseline (the saver draws on a free VT)
  4. power budget over two samples: saver CPU <= 2.0% of a core, RSS < 16 MB
  5. monitor sendkey (a real evdev key event) within 5s: saver gone AND the
     baseline VT restored
  6. no leftovers 5s later (no respawn loop); the daemon is still active
  7. poweroff

Serial typing deliberately does not wake the saver (the daemon ignores
non-input-event activity): assertions run from the serial shell while the
stimulus comes only through the monitor's sendkey.

Exit 0 when every assertion passes, 1 otherwise. PASS/FAIL lines are printed
one per assertion so the gate log doubles as evidence.
"""

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import time

USER = "nczuser"
PASS = "nczpassword123"

RESULTS = {"pass": 0, "fail": 0}


def say(msg):
    print("  %s" % msg, flush=True)


def ok(msg):
    RESULTS["pass"] += 1
    print("  PASS %s" % msg, flush=True)


def no(msg):
    RESULTS["fail"] += 1
    print("  FAIL %s" % msg, flush=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Expect:
    """Minimal expect driver over a unix-server serial socket."""

    def __init__(self, path, timeout=30):
        self.buf = b""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        deadline = time.time() + 30
        while True:
            try:
                self.sock.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.2)
        self.sock.settimeout(1.0)
        self.default_timeout = timeout

    def read_until(self, pattern, timeout=None):
        """Return the accumulated text once `pattern` matches; None on timeout."""
        timeout = self.default_timeout if timeout is None else timeout
        rx = re.compile(pattern, re.S)
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = self.buf.decode("utf-8", "replace")
            m = rx.search(text)
            if m:
                self.buf = b""
                return text
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if chunk:
                self.buf += chunk
        return None

    def send(self, line):
        self.sock.sendall(line.encode() + b"\r")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Monitor:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        deadline = time.time() + 30
        while True:
            try:
                self.sock.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.2)
        self.sock.settimeout(2.0)
        try:
            self.sock.recv(4096)  # QEMU banner
        except socket.timeout:
            pass

    def cmd(self, line):
        self.sock.sendall((line + "\n").encode())
        time.sleep(0.2)
        try:
            return self.sock.recv(65536).decode("utf-8", "replace")
        except socket.timeout:
            return ""

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def shell(ex, line, timeout=20):
    """Run a command in the guest; return its output (echo + prompt stripped)."""
    ex.send(line)
    out = ex.read_until(r"\r?\n[^\r\n]*[$#] ", timeout)
    return out or ""


def budget_ok(cpu_s, rss_s):
    try:
        return float(cpu_s) <= 2.0 and float(rss_s) < 16384.0
    except ValueError:
        return False


def firmware_candidates(arch):
    if arch == "amd64":
        return [
            ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
            ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.4m.fd"),
        ]
    return [
        ("/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd"),
        ("/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw",
         "/usr/share/edk2/aarch64/vars-template-pflash.raw"),
        ("/usr/share/qemu-efi-aarch64/QEMU_EFI.fd", "/usr/share/qemu-efi-aarch64/QEMU_VARS.fd"),
    ]


def pick_firmware(arch):
    for code, vars_ in firmware_candidates(arch):
        if os.path.exists(code) and os.path.exists(vars_):
            return code, vars_
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--disk", required=True)
    ap.add_argument("--arch", choices=["amd64", "arm64"], default="amd64")
    ap.add_argument("--idle", type=int, default=10)
    ap.add_argument("--workdir", default="")
    ap.add_argument("--boot-timeout", type=int, default=300)
    args = ap.parse_args()

    work = args.workdir or os.path.join(
        "/tmp", "ncz-cs-live-%d" % os.getpid())
    os.makedirs(work, exist_ok=True)
    disk = os.path.join(work, "test.img")
    shutil.copyfile(args.disk, disk)

    code, vars_f = pick_firmware(args.arch)
    if not code:
        no("no EFI firmware found for %s (looked in the AAVMF/OVMF conventions)"
           % args.arch)
        return 1
    vars_work = os.path.join(work, "OVMF_VARS.fd")
    shutil.copyfile(vars_f, vars_work)

    serial_path = os.path.join(work, "serial.sock")
    monitor_path = os.path.join(work, "monitor.sock")
    for p in (serial_path, monitor_path):
        if os.path.exists(p):
            os.unlink(p)

    if args.arch == "amd64":
        qemu = ["qemu-system-x86_64", "-M", "q35", "-cpu", "host"]
    else:
        qemu = ["qemu-system-aarch64", "-M", "virt", "-cpu", "host"]
    qemu += [
        "-accel", "kvm", "-smp", "2", "-m", "2048",
        "-drive", "if=pflash,format=raw,unit=0,file=%s,readonly=on" % code,
        "-drive", "if=pflash,format=raw,unit=1,file=%s" % vars_work,
        "-drive", "file=%s,if=virtio,format=raw" % disk,
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0,romfile=",
        "-serial", "unix:%s,server,nowait" % serial_path,
        "-monitor", "unix:%s,server,nowait" % monitor_path,
        "-display", "none", "-no-reboot",
    ]
    say("booting %s (%s) from %s" % (os.path.basename(args.disk), args.arch, disk))
    err_path = os.path.join(work, "qemu.err")
    err_f = open(err_path, "wb")
    proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL, stderr=err_f)

    # QEMU creates its unix sockets asynchronously at startup; connecting before
    # they exist raises FileNotFoundError. Wait for the serial socket to appear,
    # and surface a QEMU startup failure instead of a raw traceback.
    deadline = time.time() + 15
    while not os.path.exists(serial_path):
        if proc.poll() is not None:
            err_f.close()
            tail = open(err_path, "rb").read()[-2000:].decode("utf-8", "replace")
            no("qemu exited rc=%d before creating %s" % (proc.returncode, serial_path))
            if tail.strip():
                say("qemu stderr tail: %s" % tail.strip()[-500:])
            return 1
        if time.time() > deadline:
            no("serial socket %s did not appear within 15s" % serial_path)
            return 1
        time.sleep(0.2)

    ex = mon = None
    try:
        ex = Expect(serial_path, timeout=args.boot_timeout)
        mon = Monitor(monitor_path)

        # 1. boot to the serial login prompt
        if ex.read_until(r"[Ll]ogin:") is None:
            no("boot: no serial login prompt within %ds" % args.boot_timeout)
            tail = ex.buf.decode("utf-8", "replace")[-800:]
            if tail.strip():
                say("serial tail: %s" % tail.strip()[-500:])
            return 1
        ok("boot: serial login prompt")

        # 2. log in as the KVM-gate account
        ex.send(USER)
        if ex.read_until(r"[Pp]assword:") is None:
            no("login: no password prompt")
            return 1
        ex.send(PASS)
        if ex.read_until(r"\r?\n[^\r\n]*[$#] ") is None:
            no("login: no shell prompt for %s" % USER)
            return 1
        ok("login: %s shell on the serial console" % USER)

        # 3. the service is enabled and active
        out = shell(ex, "systemctl is-enabled ncz-console-saver")
        if re.search(r"(?m)^enabled\s*$", out):
            ok("service: ncz-console-saver enabled")
        else:
            no("service: not enabled (%r)" % out.strip()[-60:])
        out = shell(ex, "systemctl is-active ncz-console-saver")
        if re.search(r"(?m)^active\s*$", out):
            ok("service: ncz-console-saver active")
        else:
            no("service: not active (%r)" % out.strip()[-60:])

        # 4. baseline VT + shorten the idle period
        out = shell(ex, "cat /sys/class/tty/tty0/active")
        baseline = (re.search(r"(tty\S+)", out) or [None, "tty1"])[1] if re.search(
            r"(tty\S+)", out) else "tty1"
        baseline = re.search(r"(tty\S+)", out).group(1) if re.search(r"(tty\S+)", out) else "tty1"
        say("baseline VT: %s" % baseline)
        shell(ex, "sudo -S sed -i 's/^idle_seconds=.*/idle_seconds=%d/; "
                  "s/^enabled=.*/enabled=1/' /etc/ncz/console-saver.conf"
                  % args.idle)
        # sudo -S prompts on the terminal; feed it once then re-run cleanly
        ex.send(PASS)
        ex.read_until(r"\r?\n[^\r\n]*[$#] ", 10)
        out = shell(ex, "grep ^idle_seconds /etc/ncz/console-saver.conf")
        if ("idle_seconds=%d" % args.idle) in out:
            ok("conf: idle_seconds=%d" % args.idle)
        else:
            no("conf: idle_seconds not applied (%r)" % out.strip()[-60:])
        shell(ex, "sudo -S systemctl restart ncz-console-saver")
        ex.send(PASS)
        ex.read_until(r"\r?\n[^\r\n]*[$#] ", 10)

        # 5. the saver arms: ncz-bh-console appears on a free VT
        deadline = time.time() + args.idle + 20
        armed = False
        while time.time() < deadline:
            out = shell(ex, "pgrep -x ncz-bh-console >/dev/null && echo YES")
            if re.search(r"(?m)^YES\s*$", out):
                armed = True
                break
            time.sleep(3)
        if armed:
            ok("saver: ncz-bh-console spawned after ~%ds idle" % args.idle)
        else:
            no("saver: no ncz-bh-console within %ds of idle" % (args.idle + 20))

        out = shell(ex, "cat /sys/class/tty/tty0/active")
        cur = re.search(r"(tty\S+)", out)
        cur = cur.group(1) if cur else ""
        if cur and cur != baseline:
            ok("saver: draws on a free VT (%s, baseline was %s)" % (cur, baseline))
        else:
            no("saver: foreground VT still %s (baseline %s)" % (cur, baseline))

        # 6. power budget: two samples 5s apart (CPU <= 2% of a core, RSS < 16 MB)
        if armed:
            budget_rows = []
            for _ in range(2):
                out = shell(ex, "ps -o %cpu=,rss= -p $(pgrep -x ncz-bh-console | head -1)")
                m = re.search(r"([\d.]+)\s+(\d+)", out)
                if m:
                    budget_rows.append((m.group(1), m.group(2)))
                time.sleep(5)
            if len(budget_rows) == 2 and all(budget_ok(c, r) for c, r in budget_rows):
                ok("budget: saver within CPU<=2%% and RSS<16MB (%s)"
                   % " ".join("%s%%/%skB" % (c, r) for c, r in budget_rows))
            else:
                no("budget: out of budget or unmeasurable (%r)" % budget_rows)

        # 7. a real key event restores the VT and leaves nothing behind
        mon.cmd("sendkey a")
        deadline = time.time() + 5
        gone = False
        while time.time() < deadline:
            out = shell(ex, "pgrep -x ncz-bh-console >/dev/null || echo GONE")
            if re.search(r"(?m)^GONE\s*$", out):
                gone = True
                break
            time.sleep(1)
        if gone:
            ok("restore: saver exited on the key event")
        else:
            no("restore: saver still running 5s after the key event")
        out = shell(ex, "cat /sys/class/tty/tty0/active")
        cur = re.search(r"(tty\S+)", out)
        cur = cur.group(1) if cur else ""
        if cur == baseline:
            ok("restore: foreground VT back on %s" % baseline)
        else:
            no("restore: foreground VT is %s, expected %s" % (cur, baseline))

        # 8. no leftovers, no respawn loop; the daemon survives
        time.sleep(5)
        out = shell(ex, "pgrep -x ncz-bh-console >/dev/null || echo CLEAN")
        if re.search(r"(?m)^CLEAN\s*$", out):
            ok("leftovers: none 5s after restore")
        else:
            no("leftovers: a saver reappeared (respawn loop?)")
        out = shell(ex, "systemctl is-active ncz-console-saver")
        if re.search(r"(?m)^active\s*$", out):
            ok("service: daemon still active after the cycle")
        else:
            no("service: daemon died during the cycle")

        shell(ex, "sudo poweroff")
        say("guest powered off")
    finally:
        if ex:
            ex.close()
        if mon:
            mon.close()
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    print("\nkvm-console-saver-live: %d passed, %d failed"
          % (RESULTS["pass"], RESULTS["fail"]))
    return 0 if RESULTS["fail"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
