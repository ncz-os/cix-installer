#!/usr/bin/env python3
"""test-boot-screens-testcopy.py -- the amd64 UI-check TEXT CHANNEL's test-copy plumbing, without QEMU.

build/kvm-installer-ui-check.sh judges amd64 by the text d-i draws on the UART, so it boots the ui-check copy with
console=ttyS0,115200 and with a first-stage preseed hook that turns the medium's preseed/early_command into a no-op
(build/boot-screens.py --serial-console). This test builds a synthetic raw-GPT image whose ESP carries a real
refind.conf and a real preseed/early_command, runs the RESULTING image through boot-screens.py far enough to stage
the test copy, then kills the harness and checks what landed on the image:

  1. the Install entry's options carry the UART as the LAST console= (d-i follows /dev/console) and ncz_ui_check=1;
  2. the other menu entries are untouched;
  3. ::/ncz-test/rules.py exists and carries the marker with ONE preseed/early_command question, whose value is the
     medium's own early_command with its `d-i ` prefix and backslash continuations removed (a backslash continuation
     split across two lines would otherwise make d-i parse the tail as a new question type);
  4. --ask-disk keeps ncz_disk/ncz_fs off the kernel command line;
  5. the SHIPPED image is byte-identical afterwards (only WORKDIR/screens-test.img is patched);
  6. no --serial-console: no hook, no rewritten console= (arm64 behaviour unchanged).

Needs sgdisk, mkfs.vfat, mcopy/mdir (mtools), pyte, and qemu-system-x86_64 (started and killed immediately).
Run it under an interpreter with pyte (NCZ_BOOT_SCREENS_PYTHON) or one of ~/pyte-venv/bin/python; exits 77 (skip)
when a tool is missing. Runs rootless. Part of `make test`.
"""
import hashlib, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
BS = os.path.join(HERE, "boot-screens.py")
# Short prefix, and a deep TMPDIR is fine: boot-screens.py keeps its qemu sockets in a short private dir.
WORK = tempfile.mkdtemp(prefix="ncz-tc-")

PRESEED = r"""
# ---- fixture preseed ----
d-i debian-installer/locale string en_US.UTF-8
d-i preseed/early_command string \
    set +e ; \
    echo marker-ran ; \
    exit 0
d-i partman/early_command string echo PARTMAN-MUST-NOT-RUN
d-i partman-auto/method string regular
"""

REFIND = """timeout 10
menuentry "NCZ-OS Installer -- Install" {
    icon /EFI/BOOT/icons/os_ncz.png
    loader /EFI/BOOT/grubx64.efi
    options "quiet loglevel=3 console=tty0"
}
menuentry "NCZ-OS Installer -- Diagnostics" {
    loader /EFI/BOOT/grubx64.efi
    options "quiet loglevel=3 console=tty0 ncz_diag=1"
}
menuentry "NCZ-OS Installer -- Rescue" {
    loader /EFI/BOOT/grubx64.efi
    options "quiet loglevel=3 console=tty0 rescue"
}
"""

fails = 0


def ok(cond, what, detail=""):
    global fails
    if cond:
        print("ok   " + what)
    else:
        fails += 1
        print("FAIL " + what)
        if detail:
            print("\n".join("     " + l for l in str(detail).splitlines()))


def mkimage(path):
    """raw-GPT disk with one EFI System partition holding refind.conf and the preseed."""
    esp = os.path.join(WORK, "esp.vfat")
    open(esp, "wb").write(b"\0" * (64 * 1024 * 1024))
    subprocess.run(["mkfs.vfat", "-n", "ESP", esp], check=True, capture_output=True)
    subprocess.run(["mmd", "-i", esp, "::/EFI"], capture_output=True)
    subprocess.run(["mmd", "-i", esp, "::/EFI/BOOT"], capture_output=True)
    for name, body in (("refind.conf", REFIND), ("preseed.cfg", PRESEED)):
        src = os.path.join(WORK, name)
        open(src, "w").write(body)
        subprocess.run(["mcopy", "-o", "-i", esp, src, "::/EFI/BOOT/" + name], check=True)
    open(path, "wb").write(b"\0" * 128 * 1024 * 1024)
    subprocess.run(["sgdisk", "-n", "1:2048:+64M", "-t", "1:ef00", "-c", "1:ESP", path],
                   check=True, capture_output=True)
    with open(path, "r+b") as fh:
        fh.seek(2048 * 512)
        fh.write(open(esp, "rb").read())


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def esp_file(img, name):
    lba = int(re.search(r"First sector:\s*(\d+)",
                        subprocess.check_output(["sgdisk", "-i", "1", img], text=True)).group(1))
    out = os.path.join(WORK, "readback-" + os.path.basename(name))
    subprocess.run(["mcopy", "-o", "-i", f"{img}@@{lba * 512}", "::" + name, out],
                   check=True, capture_output=True)
    return out


def run(work, image, extra):
    """Run boot-screens.py to completion (--secs 1: the capture loop exits on its own; QEMU is left with it)."""
    workdir = os.path.join(WORK, work)
    os.makedirs(workdir, exist_ok=True)
    # Same interpreter as this test: boot-screens.py imports pyte before it ever reaches qemu, so the test runs
    # under an interpreter that has it (NCZ_BOOT_SCREENS_PYTHON, else sys.executable).
    py = os.environ.get("NCZ_BOOT_SCREENS_PYTHON") or sys.executable
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    cmd = [py, BS, image, workdir, "--arch", "amd64", "--secs", "1", "--every", "1"] + extra
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180, env=env), workdir


def main():
    for tool in ("sgdisk", "mkfs.vfat", "mcopy", "mdir", "qemu-system-x86_64"):
        if not shutil.which(tool):
            print("test-boot-screens-testcopy: SKIP (%s not installed)" % tool)
            return 77
    image = os.path.join(WORK, "shipped.img")
    mkimage(image)
    shipped_sha = sha(image)

    pr, work = run("serial", image, ["--interactive", "--serial-console", "--ask-disk"])
    if pr.returncode != 0:
        ok(False, "boot-screens.py --serial-console stages the test copy", pr.stdout + pr.stderr)
        return 1
    test_img = os.path.join(work, "screens-test.img")
    ok(os.path.exists(test_img), "the test copy is a separate file in WORKDIR (never the shipped image)")

    # 1-2: the Install entry only
    conf = open(esp_file(test_img, "/EFI/BOOT/refind.conf")).read()
    inst = re.search(r'menuentry "NCZ-OS Installer -- Install" \{.*?\n\}', conf, re.S).group(0)
    opts = re.search(r'options "([^"]*)"', inst).group(1).split()
    consoles = [o for o in opts if o.startswith("console=")]
    ok(consoles == ["console=tty0", "console=ttyS0,115200"],
       "Install options carry console=ttyS0,115200 LAST (d-i draws where /dev/console points)", consoles)
    ok("ncz_ui_check=1" in opts, "Install options carry the ncz_ui_check=1 test-domain marker")
    ok(not [o for o in opts if o.startswith("ncz_disk=")] and not [o for o in opts if o.startswith("ncz_fs=")],
       "--ask-disk keeps ncz_disk/ncz_fs off the cmdline", opts)
    ok("debian-installer/locale=en_US.UTF-8" in opts, "the test answers are still appended")
    for entry in ("Diagnostics", "Rescue"):
        body = re.search(r'menuentry "NCZ-OS Installer -- %s" \{.*?\n\}' % entry, conf, re.S).group(0)
        ok("ttyS0" not in body and "ncz_ui_check" not in body,
           "the %s entry is untouched" % entry, body)

    # 3: the preseed hook
    rules = open(esp_file(test_img, "/ncz-test/rules.py")).read()
    ok("ncz_ui_check=1" in rules, "::/ncz-test/rules.py carries the marker the wrapper reads back")
    cmds = re.findall(r"^d-i (\S+) (\S+) (.*)$", rules, re.M)
    ok(len(cmds) == 1 and cmds and cmds[0][0] == "preseed/early_command" and cmds[0][1] == "string",
       "the hook re-applies exactly ONE question: preseed/early_command string", cmds)
    value = cmds[0][2] if cmds else ""
    ok("\\" not in value, "no backslash continuation in the hook value (d-i needs it on one line)", value)
    ok(re.sub(r"\s+", " ", value).startswith("set +e ; echo marker-ran ;"),
       "the hook value is the medium's own early_command", value)
    ok("marker-ran" in value and "PARTMAN-MUST-NOT-RUN" not in value,
       "the hook carries the early_command and not another question's value")
    ok(not re.search(r"(?m)^\s+(string|boolean|select)\s", rules), "no joined tail parsed as a type")
    readback = os.path.join(work, "rules.readback")
    ok(os.path.exists(readback) and "ncz_ui_check=1" in open(readback).read(),
       "boot-screens.py read its hook back out of the ESP")

    # 5: the shipped image is untouched
    ok(sha(image) == shipped_sha, "the SHIPPED image is byte-identical after the run")
    ok(sha(test_img) != shipped_sha, "the test copy differs (that is the point)")

    # 6: without --serial-console nothing is staged and console= is not rewritten
    image2 = os.path.join(WORK, "shipped2.img")
    shutil.copy(image, image2)
    sha2 = sha(image2)
    pr2, work2 = run("plain", image2, ["--interactive"])
    if pr2.returncode != 0:
        ok(False, "boot-screens.py without --serial-console completes", pr2.stdout + pr2.stderr)
        return 1
    t2 = os.path.join(work2, "screens-test.img")
    conf2 = open(esp_file(t2, "/EFI/BOOT/refind.conf")).read()
    ok("console=ttyS0,115200" not in conf2 and "ncz_ui_check=1" not in conf2,
       "no --serial-console: the Install entry keeps console=tty0 only")
    md = subprocess.run(["mdir", "-i", t2 + "@@" + str(2048 * 512), "::/"], capture_output=True, text=True)
    ok("ncz-test" not in (md.stdout or ""), "no --serial-console: no ::/ncz-test hook is staged", md.stdout)
    ok(sha(image2) == sha2, "no --serial-console: the shipped image is byte-identical too")

    if fails:
        print("test-boot-screens-testcopy: FAIL (%d)" % fails)
        return 1
    print("test-boot-screens-testcopy: OK")
    return 0


try:
    rc = main()
finally:
    shutil.rmtree(WORK, ignore_errors=True)
sys.exit(rc)
