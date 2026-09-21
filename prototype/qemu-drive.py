#!/usr/bin/env python3
"""
qemu-drive.py — Drive a QEMU/OVMF instance through the HMP monitor.

Sends keystrokes to the EFI shell. Used by the Step 1 qualification test to
make OVMF boot our ESP's rEFInd instead of its own internal shell (which is
what happens with a fresh NVRAM because xorriso doesn't write boot entries
into the firmware volume; the operator picks one interactively in a real
machine; here we automate the pick).

QEMU's sendkey accepts these key names (verified by experiment on QEMU 11.1.1):
    a-z, 0-9 (single-char)
    esc, tab, ret, enter
    shift-<char>  e.g. shift-semicolon for ":"
    backslash, slash, dot, semicolon, comma, apostrophe
    f1-f12, up, down, left, right, home, end, pgup, pgdn
    shift, ctrl, alt, ctrl-alt-<char>, altgr

Names like "colon" are NOT accepted even though the keysym exists in
keymaps/en-us. Use "shift-semicolon" instead.

Usage:
    qemu-drive.py <host> <port> <command> [<command> ...]
    where each <command> is a QEMU HMP monitor command (e.g. "sendkey ret",
    "sendkey b", etc.). A 200ms pause is inserted between sends.

    Special commands:
        string TEXT   -- expand TEXT to per-character sendkey commands and
                         insert them inline. Spaces and punctuation are handled
                         automatically (e.g. space -> sendkey spc,
                         ":" -> sendkey shift-semicolon).
"""
import socket
import sys
import time


# Map printable ASCII to QEMU sendkey names.
CHAR_MAP = {
    " ": "spc",
    "\t": "tab",
    "\n": "ret",
    ":": "shift-semicolon",
    "\\": "backslash",
    "/": "slash",
    ".": "dot",
    ",": "comma",
    ";": "semicolon",
    "'": "apostrophe",
    "-": "minus",
    "_": "shift-minus",
    "=": "equal",
    "+": "shift-equal",
    "[": "bracket_left",
    "]": "bracket_right",
    "{": "shift-bracket_left",
    "}": "shift-bracket_right",
    "?": "shift-slash",
    "<": "shift-comma",
    ">": "shift-dot",
    "|": "shift-backslash",
    "~": "shift-grave_accent",
    "`": "grave_accent",
    "!": "shift-1",
    "@": "shift-2",
    "#": "shift-3",
    "$": "shift-4",
    "%": "shift-5",
    "^": "shift-6",
    "&": "shift-7",
    "*": "shift-8",
    "(": "shift-9",
    ")": "shift-0",
    "\"": "shift-apostrophe",
}


def char_to_sendkey(ch: str) -> str:
    if ch.islower() and ch.isalpha():
        return ch
    if ch.isupper() and ch.isalpha():
        return f"shift-{ch.lower()}"
    if ch.isdigit():
        return ch
    if ch in CHAR_MAP:
        return CHAR_MAP[ch]
    raise ValueError(f"no sendkey name for character {ch!r}")


def string_to_sendkeys(text: str) -> list[str]:
    out = []
    for ch in text:
        out.append(f"sendkey {char_to_sendkey(ch)}")
    return out


def send_line(sock: socket.socket, line: str) -> None:
    sock.sendall((line + "\n").encode("utf-8"))


def recv_for(sock: socket.socket, seconds: float) -> str:
    sock.settimeout(0.5)
    end = time.monotonic() + seconds
    buf = ""
    while time.monotonic() < end:
        try:
            chunk = sock.recv(4096).decode("utf-8", errors="replace")
            buf += chunk
        except socket.timeout:
            pass
    return buf


def main():
    if len(sys.argv) < 3:
        print("usage: qemu-drive.py <monitor-host> <monitor-port> <command|STRING 'text'> ...", file=sys.stderr)
        sys.exit(2)
    host, port = sys.argv[1], int(sys.argv[2])
    commands = sys.argv[3:]
    sock = socket.create_connection((host, port), timeout=10)
    recv_for(sock, 1.0)
    # Expand each command
    expanded: list[str] = []
    for cmd in commands:
        if cmd.startswith("STRING "):
            expanded.extend(string_to_sendkeys(cmd[len("STRING "):]))
        else:
            expanded.append(cmd)
    for i, cmd in enumerate(expanded):
        send_line(sock, cmd)
        # Wait for the monitor prompt to come back before sending the next
        # command. Each QEMU HMP command prints "(qemu) " on completion,
        # so we read until we see it.
        sock.settimeout(1.0)
        try:
            buf = b""
            deadline = time.monotonic() + 0.5
            while b"(qemu)" not in buf and time.monotonic() < deadline:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            pass
    out = recv_for(sock, 8.0)
    print(out)


if __name__ == "__main__":
    main()