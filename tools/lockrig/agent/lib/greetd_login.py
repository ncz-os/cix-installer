#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Log a user in through the greetd IPC socket (test hosts only).

usage: greetd_login.py USER [COMMAND...]   (secret on the first line of stdin; run as root)
Default command: /usr/local/bin/ncz-singularity. Used by the harness to script a
logout/login cycle and to recover a host that was left at the greeter.
"""

import glob
import json
import os
import socket
import struct
import sys
import time

BUSY_RETRIES = 5
BUSY_WAIT_S = 2


def is_busy(reply):
    return reply.get("type") == "error" and "already being configured" in reply.get(
        "description", ""
    )


def call(sock, msg):
    data = json.dumps(msg).encode()
    sock.sendall(struct.pack("=I", len(data)) + data)
    hdr = sock.recv(4)
    (n,) = struct.unpack("=I", hdr)
    buf = b""
    while len(buf) < n:
        buf += sock.recv(n - len(buf))
    return json.loads(buf)


def main():
    user = sys.argv[1]
    cmd = sys.argv[2:] or ["/usr/local/bin/ncz-singularity"]
    secret = sys.stdin.readline().rstrip("\n")
    path = os.environ.get("GREETD_SOCK") or next(
        iter(sorted(glob.glob("/run/greetd*.sock"))), "/run/greetd.sock"
    )
    # The greeter pre-selects the last user and keeps that greetd session
    # pending, so the first create_session can be refused as busy. Cancel the
    # pending session and retry; an authentication failure is never retried.
    for attempt in range(BUSY_RETRIES):
        sock = socket.socket(socket.AF_UNIX)
        sock.connect(path)
        reply = call(sock, {"type": "create_session", "username": user})
        if not is_busy(reply):
            break
        call(sock, {"type": "cancel_session"})
        sock.close()
        time.sleep(BUSY_WAIT_S)
    while reply.get("type") == "auth_message":
        answer = (
            secret if reply.get("auth_message_type") in ("secret", "visible") else ""
        )
        reply = call(sock, {"type": "post_auth_message_response", "response": answer})
    if reply.get("type") != "success":
        call(sock, {"type": "cancel_session"})
        print(
            "login failed:",
            reply.get("description", reply.get("type")),
            file=sys.stderr,
        )
        return 1
    reply = call(sock, {"type": "start_session", "cmd": cmd, "env": []})
    if reply.get("type") != "success":
        print("start_session failed:", reply, file=sys.stderr)
        return 1
    print("session started")
    return 0


if __name__ == "__main__":
    sys.exit(main())
