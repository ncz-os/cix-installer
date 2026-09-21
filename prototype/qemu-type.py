#!/usr/bin/env python3
"""
qemu-type.py — Type a string into a QEMU/OVMF EFI shell, one keystroke at a
time, waiting for the (qemu) prompt between each.

Use this instead of the multi-keystroke STRING expansion when you need to be
absolutely sure the shell has accepted the previous line before sending the
next one.
"""
import socket
import sys
import time


SENDKEY_NAMES = {
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
}


def char_to_sendkey(ch: str) -> str:
    if ch.islower() and ch.isalpha():
        return ch
    if ch.isupper() and ch.isalpha():
        return f"shift-{ch.lower()}"
    if ch.isdigit():
        return ch
    if ch in SENDKEY_NAMES:
        return SENDKEY_NAMES[ch]
    raise ValueError(f"no sendkey name for character {ch!r}")


def send_line(sock: socket.socket, line: str) -> None:
    sock.sendall((line + "\n").encode("utf-8"))


def wait_for_prompt(sock: socket.socket, timeout: float = 2.0) -> str:
    sock.settimeout(0.2)
    end = time.monotonic() + timeout
    buf = b""
    while time.monotonic() < end:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            pass
        if b"(qemu)" in buf:
            break
    return buf.decode("utf-8", errors="replace")


def main():
    if len(sys.argv) < 4:
        print("usage: qemu-type.py <host> <port> <text> [--no-final-ret]", file=sys.stderr)
        sys.exit(2)
    host, port, text = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    final_ret = "--no-final-ret" not in sys.argv
    sock = socket.create_connection((host, port), timeout=10)
    initial = wait_for_prompt(sock, 2.0)
    sys.stderr.write(f"[initial banner] {initial[-200:]}\n")
    for ch in text:
        k = char_to_sendkey(ch)
        send_line(sock, f"sendkey {k}")
        resp = wait_for_prompt(sock, 1.0)
        sys.stderr.write(f"[{ch!r} -> {k}] {resp[-80:]!r}\n")
    if final_ret:
        send_line(sock, "sendkey ret")
        resp = wait_for_prompt(sock, 2.0)
        sys.stderr.write(f"[ret] {resp[-200:]!r}\n")
    sock.close()


if __name__ == "__main__":
    main()