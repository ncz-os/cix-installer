#!/usr/bin/env python3
"""boot-speed-scan.py -- static detector for boot-blocking systemd units.

Part of docs/BOOT-SPEED.md item F (2026-10-04). A systemd unit with
``Type=oneshot`` that is pulled into ``multi-user.target`` (or any target on
the way to it, or ``graphical.target``) is NOT fire-and-forget: the target's
start job does not complete until the oneshot process exits. If that process
waits on the network, waits on NTP to synchronise, or polls with ``sleep``, the
whole boot -- and the login screen behind ``graphical.target`` -- waits too.
That is the measured O6N 37.3 s boot in docs/BOOT-SPEED.md: ``ncz-rtc-sync``
sat behind ``systemd-time-wait-sync`` and held multi-user/graphical for ~30 s.

The detector scans both standalone ``*.service`` files and service units
embedded in shell/python heredocs (``cat > /etc/systemd/system/X.service
<<'UNIT' ... UNIT``). For each unit it resolves the ExecStart *script* -- the
heredoc that writes that path in the same source file, or a repo file whose
basename matches -- so a unit is only flagged when the code it actually runs
polls/waits, not merely because an unrelated helper in the same file sleeps.

A finding is exempt only when its unit name is in ``ALLOW`` below with a
written justification.

Exit 0 = clean, 1 = unallowlisted finding(s), 2 = usage/IO error.
"""

from __future__ import annotations

import os
import re
import sys

# Boot targets whose start can be delayed by a oneshot they Want. A unit that
# only fixes up the graphical session (WantedBy=default.target, timers.target,
# sockets.target, ...) is not in this class.
BOOT_TARGETS = (
    "multi-user.target",
    "graphical.target",
    "sysinit.target",
    "basic.target",
)

# The waits that make a boot-target oneshot a blocker. Keep this deliberately
# narrow: bounded hardware ordering (After=systemd-udev-settle) is audited in
# docs/BOOT-SPEED.md but is not what this gate fails on.
RISK_PATTERNS = (
    (re.compile(r"(^|[^A-Za-z0-9_])sleep([^A-Za-z0-9_]|$)"), "sleep"),
    (re.compile(r"timedatectl"), "timedatectl"),
    (re.compile(r"network-online\.target"), "network-online.target"),
    (re.compile(r"systemd-time-wait-sync"), "systemd-time-wait-sync"),
    (re.compile(r"(^|[^A-Za-z0-9_-])time-sync\.target"), "time-sync.target"),
)

# Reviewed, justified exemptions. Every entry needs a reason that names why the
# ordering is load-bearing; anything without a reason is a bug in this file.
ALLOW = {
    # Sky1 USB2 keyboard recovery: the rebind can take ~6 s, but greetd is
    # explicitly After=/Wants= it so the first keyboard works at the greeter.
    # Making it async would start the compositor before input exists.
    "ncz-usb2-rescan.service": "load-bearing input recovery; greetd.service is After= it",
    # Sky1 connected-DRM detection: greetd's drop-in is After=/Wants= it so the
    # compositor never starts before the connected card is known.
    "cix-detect-display.service": "load-bearing DRM detection; greetd.service is After= it",
    # KMS splash owns DRM until the greeter handoff marker; bounded by
    # TimeoutStartSec=22s and Conflicts= against the greeter's TTY.
    "singularity-boot-splash.service": "owns DRM until greeter handoff; bounded 22 s",
    # Pins Sky1 interactive performance before greetd so the first keystroke is
    # not lost to deep idle; arch-gated to arm64.
    "ncz-performance-mode.service": "load-bearing Sky1 latency pin; Before=greetd.service",
    # First-boot gates: they must complete before the desktop exists, or a fresh
    # install boots half-configured.
    "ncz-firstboot.service": "first-boot gate (dpkg --configure -a + identity)",
    "ncz-firstboot-identity.service": "first-boot identity gate (ssh host keys, machine-id)",
    # Rescue / offline images: guaranteed reachability is the whole point of
    # these units; they are TimeoutStartSec-bounded by design.
    "ncz-rescue-net.service": "rescue network bring-up; TimeoutStartSec=25 on purpose",
    "ncz-rescue-net-fallback.service": "rescue static-IP fallback; TimeoutStartSec=15 on purpose",
    # Recovery-container parent-NIC resolver: must run Before= the container.
    "ncz-recovery-netparent.service": "recovery container bring-up; Before=systemd-nspawn@",
}

# ExecStart tokens that are interpreters/utilities, not the repo's own scripts.
NON_SCRIPT_BASENAMES = {
    "sh",
    "bash",
    "dash",
    "python",
    "python3",
    "env",
    "timeout",
    "hwclock",
    "systemctl",
    "busybox",
    "true",
    "false",
}


def is_test_path(rel: str) -> bool:
    """Test fixtures deliberately contain bad unit shapes; do not scan them."""
    return bool(re.search(r"(^|/)(tests?|fixtures?)/", rel)) or bool(
        re.search(r"(^|/)test[-_]", rel)
    )


def list_scan_files(root: str) -> list[str]:
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for name in filenames:
            if not name.endswith((".sh", ".py", ".service")):
                continue
            path = os.path.join(dirpath, name)
            if is_test_path(os.path.relpath(path, root)):
                continue
            out.append(path)
    return sorted(out)


def read_text(path: str) -> str | None:
    try:
        with open(path, "r", encoding="utf-8", errors="strict") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return None


# A heredoc start: `<<` (not here-string `<<<`), optional `-`, an uppercase
# delimiter. Requiring `>` somewhere on the line keeps shell/Python bit-shift
# (`x << MASK`) from being mistaken for a redirect.
HEREDOC_RE = re.compile(r"<<(?![<])(-?)\s*['\"]?([A-Z][A-Z0-9_]*)['\"]?")


def extract_heredocs(text: str):
    """Yield (command_line, delimiter, body_lines) for each heredoc."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = HEREDOC_RE.search(line)
        if m and ">" in line:
            delim = m.group(2)
            body: list[str] = []
            j = i + 1
            while j < len(lines):
                if lines[j].strip() == delim:
                    break
                body.append(lines[j])
                j += 1
            yield line, delim, body
            i = j + 1
        else:
            i += 1


def is_unit_body(body: str) -> bool:
    return bool(re.search(r"^\s*\[(Unit|Service|Install)\]\s*$", body, re.MULTILINE))


def unit_candidates(path: str, text: str):
    """Yield (source_path, command_line, body) for each software unit definition."""
    if path.endswith(".service"):
        yield path, "", text.splitlines()
        return
    for line, _delim, body in extract_heredocs(text):
        if is_unit_body("\n".join(body)):
            yield path, line, body


def target_service_name(command_line: str) -> str | None:
    m = re.findall(r"([^\s'\"]+\.service)", command_line)
    if not m:
        return None
    return os.path.basename(m[-1])


def exec_paths(body: str) -> list[str]:
    out: list[str] = []
    for line in body.splitlines():
        if not re.match(r"\s*ExecStart\s*=", line):
            continue
        out.extend(re.findall(r"/[^\s'\"]+", line.split("=", 1)[1]))
    return out


def boot_target(body: str, source_text: str, unit_name: str) -> bool:
    for line in re.findall(
        r"^\s*(?:WantedBy|RequiredBy)\s*=\s*(.*)$", body, re.MULTILINE
    ):
        if any(t in line for t in BOOT_TARGETS):
            return True
    for t in BOOT_TARGETS:
        if f"{t}.wants/{unit_name}" in source_text:
            return True
    return False


def risky_in(text: str) -> str | None:
    for pat, label in RISK_PATTERNS:
        if pat.search(text):
            return label
    return None


def heredoc_target_basename(command_line: str) -> str | None:
    # The path written by a `cat >/install ... /path <<'MARK'` line.
    m = re.findall(r"([^\s'\"]+)", command_line)
    paths = [t for t in m if "/" in t]
    if not paths:
        return None
    return os.path.basename(paths[-1])


def resolve_script(
    exec_tok: str, source_text: str, repo_basenames: dict[str, str]
) -> str | None:
    base = os.path.basename(exec_tok)
    if base in NON_SCRIPT_BASENAMES or not base:
        return None
    # 1. A heredoc in the same source file that writes this exact path.
    for line, _delim, body in extract_heredocs(source_text):
        if heredoc_target_basename(line) == base:
            return "\n".join(body)
    # 2. A repo file with the same basename (accept the `ncz-`-prefixed asset).
    for candidate in (base, "ncz-" + base):
        if candidate in repo_basenames:
            return read_text(repo_basenames[candidate])
    return None


def scan(root: str):
    repo_basenames: dict[str, str] = {}
    for path in list_scan_files(root):
        repo_basenames.setdefault(os.path.basename(path), path)

    findings: list[tuple[str, str, str]] = []
    for path in list_scan_files(root):
        text = read_text(path)
        if text is None:
            continue
        rel = os.path.relpath(path, root)
        for src, command_line, body_lines in unit_candidates(path, text):
            body = "\n".join(body_lines)
            if not is_unit_body(body):
                continue
            if not re.search(r"^\s*Type\s*=\s*oneshot\s*$", body, re.MULTILINE):
                continue
            name = (
                target_service_name(command_line)
                if command_line
                else os.path.basename(src)
            )
            if not name:
                continue
            if not boot_target(body, text, name):
                continue
            risk_text = body
            for tok in exec_paths(body):
                script = resolve_script(tok, text, repo_basenames)
                if script:
                    risk_text += "\n" + script
            risk = risky_in(risk_text)
            if risk:
                findings.append((name, rel, risk))
    return findings


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} <repo-root>", file=sys.stderr)
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        print(f"boot-speed-scan: not a directory: {root}", file=sys.stderr)
        return 2
    findings = scan(root)
    unexpected = [f for f in findings if f[0] not in ALLOW]
    for name, rel, risk in sorted(findings):
        tag = "ALLOW" if name in ALLOW else "FAIL "
        print(f"{tag} {name} ({rel}): {risk}")
        if name in ALLOW:
            print(f"       justification: {ALLOW[name]}")
    if unexpected:
        print(
            f"\nboot-speed-scan: {len(unexpected)} boot-blocking oneshot(s) "
            f"not on the allowlist",
            file=sys.stderr,
        )
        return 1
    print(f"\nboot-speed-scan: clean ({len(findings)} allowlisted)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
