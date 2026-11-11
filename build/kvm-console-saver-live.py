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

    def __init__(self, path, timeout=30, log_path=None):
        self.buf = b""
        self.log_f = open(log_path, "ab") if log_path else None
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
                if self.log_f:
                    self.log_f.write(chunk)
                    self.log_f.flush()
                self.buf += chunk
        return None

    def send(self, line):
        self.sock.sendall(line.encode() + b"\r")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
        if self.log_f:
            self.log_f.close()


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


_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\\")
_MARK_N = 0


_BRACKET_RE = re.compile(r"\x1b\[\?2004[hl]|\x1b\\")
# OSC sequences (e.g. the guest PS1's shell-integration metadata
# \x1b]3008;...;pid=N;cwd=P\x1b\\) are terminal control, not content.
# 2026-11-10: they survived CSI stripping as multi-field lines and glued
# onto command output; strip whole OSC payloads (BEL or ST terminated).
_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
_PS1_LINE_RE = re.compile(r"([^;\r\n]*;)?pid=\d+;cwd=")
_PROMPT_PREFIX_RE = re.compile(r"^[^\s]*@[^:]*:[^$#]*[$#] ")


def slice_cmd_output(out, mark):
    """Wire text -> the command's clean output for marker `mark`."""
    # Materialize control-sequence boundaries as newlines BEFORE dropping
    # the sequences themselves (2026-11-10: PS1 fragments were gluing onto
    # command output).
    out = _OSC_RE.sub("\n", out)
    out = _BRACKET_RE.sub("\n", out)
    out = _ANSI_RE.sub("", out)
    # The echoed command carries the marker text literally (`:$?`); the real
    # marker line carries the exit status (`:<digits>`). Cut after the echo
    # line, then up to the real marker -- never split on the bare mark.
    anchor = out.find("%s:$?" % mark)
    if anchor >= 0:
        nl = out.find("\n", anchor)
        body = out[nl + 1:] if nl >= 0 else ""
    else:
        body = out
    body = re.split(r"%s:\d+" % re.escape(mark), body)[0]
    lines = []
    for ln in body.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        # The line may be echoed twice (readline redraw after the OSC 3008
        # mark); both echoes carry our literal `:$?` marker tail.
        if ("echo %s:$?" % mark) in ln:
            continue
        if _PS1_LINE_RE.search(ln):
            continue
        lines.append(_PROMPT_PREFIX_RE.sub("", ln))
    return "\n".join(lines).strip("\n")


def shell(ex, line, timeout=20):
    """Run a command in the guest; return its output (clean, no prompt).

    Marker-based capture: the guest shell's PS1 is two-line (pid=/cwd= then
    user@host) with bracketed-paste escapes, so prompt-stripping regexes are
    unreliable (2026-11-10 run: they matched the echoed command and the
    prompt itself, corrupting every assertion's input). Slice the wire text
    between the echoed command and an `echo <mark>:$?` marker instead.
    """
    global _MARK_N
    _MARK_N += 1
    mark = "CSX%dX" % _MARK_N
    ex.send("%s; echo %s:$?" % (line, mark))
    out = ex.read_until(r"%s:\d+" % re.escape(mark), timeout) or ""
    return slice_cmd_output(out, mark)


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


def sniff_format(path):
    """'qcow2' when the file carries the QFI\\xfb magic, else 'raw'."""
    with open(path, "rb") as f:
        return "qcow2" if f.read(4) == b"QFI\xfb" else "raw"


def make_boot_copy(src, work):
    """Return (boot_path, boot_format) for a scratch boot of `src`.

    Prefers a qcow2 overlay (instant, sparse, leaves the source bytes
    untouched even across writes) -- the kvm-install-gate keeps its installed
    target as target.qcow2, so a byte copy here would materialize 30G.
    Falls back to a full copy when qemu-img is unavailable.
    """
    fmt = sniff_format(src)
    overlay = os.path.join(work, "test-boot.qcow2")
    qemu_img = shutil.which("qemu-img") or "qemu-img"
    if os.path.exists(overlay):
        os.unlink(overlay)
    r = subprocess.run(
        [qemu_img, "create", "-f", "qcow2", "-b", os.path.abspath(src),
         "-F", fmt, overlay],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode == 0:
        return overlay, "qcow2"
    dst = os.path.join(work, "test.img")
    shutil.copyfile(src, dst)
    return dst, fmt


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
    disk, boot_format = make_boot_copy(args.disk, work)

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
        "-drive", "file=%s,if=virtio,format=%s" % (disk, boot_format),
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
        ex = Expect(serial_path, timeout=args.boot_timeout,
                    log_path=os.path.join(work, "serial.raw"))
        mon = Monitor(monitor_path)

        # 1. boot to the serial login prompt
        if ex.read_until(r"[Ll]ogin:") is None:
            no("boot: no serial login prompt within %ds" % args.boot_timeout)
            seen = ex.buf.decode("utf-8", "replace")
            if re.search(r"Debian.*installer|component-selector|cdebconf|"
                         r"ncz_unattended|disk-fs-chooser", seen, re.I):
                say("hint: this disk booted the d-i INSTALLER, not an "
                    "installed system -- pass the kept target.qcow2 from a "
                    "kvm-install-gate run, not the installer medium")
            tail = seen[-800:]
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

        # 3. the installed layout is the FULL tier, then the service state.
        # (2026-11-10: hook 48 ships a skeleton unit with no daemon; only the
        # ORPHANed hook 61 brings the binaries + conf. Assert the files, not
        # just the unit, or a skeleton install passes here.)
        out = shell(ex, "test -x /usr/local/bin/ncz-console-saver -a "
                        "-x /usr/local/bin/ncz-bh-console -a "
                        "-f /etc/ncz/console-saver.conf && echo FULLTIER")
        if re.search(r"(?m)^FULLTIER\s*$", out):
            ok("layout: daemon binaries + conf present (full tier)")
        else:
            no("layout: full console-saver tier missing (skeleton unit only?)")
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
        m = re.search(r"(tty\S+)", out)
        baseline = m.group(1) if m else "tty1"
        say("baseline VT: %s" % baseline)
        shell(ex, "echo %s | sudo -S sed -i 's/^idle_seconds *= *.*/idle_seconds=%d/; "
                  "s/^enabled *= *.*/enabled=1/' /etc/ncz/console-saver.conf"
                  % (PASS, args.idle))
        out = shell(ex, "grep ^idle_seconds /etc/ncz/console-saver.conf")
        if ("idle_seconds=%d" % args.idle) in out:
            ok("conf: idle_seconds=%d" % args.idle)
        else:
            no("conf: idle_seconds not applied (%r)" % out.strip()[-60:])
        shell(ex, "echo %s | sudo -S systemctl restart ncz-console-saver" % PASS)

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

        shell(ex, "echo %s | sudo -S poweroff" % PASS)
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
