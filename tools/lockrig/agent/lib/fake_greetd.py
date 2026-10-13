#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Fake greetd IPC server for the rig self-test (test-lockrig.sh).

usage: fake_greetd.py SOCKET BUSY_COUNT GOOD_SECRET
Refuses the first BUSY_COUNT create_session requests as "a session is already
being configured" (what the real greeter's pending session causes), then
authenticates against GOOD_SECRET. Serves until it is killed.
"""

import json
import os
import socket
import struct
import sys


def recv(conn):
    hdr = conn.recv(4)
    if len(hdr) < 4:
        return None
    (n,) = struct.unpack("=I", hdr)
    buf = b""
    while len(buf) < n:
        buf += conn.recv(n - len(buf))
    return json.loads(buf)


def send(conn, msg):
    data = json.dumps(msg).encode()
    conn.sendall(struct.pack("=I", len(data)) + data)


def main():
    path, busy, good = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(path)
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        while True:
            msg = recv(conn)
            if msg is None:
                break
            t = msg.get("type")
            if t == "create_session":
                if busy > 0:
                    busy -= 1
                    send(
                        conn,
                        {
                            "type": "error",
                            "error_type": "error",
                            "description": "a session is already being configured",
                        },
                    )
                else:
                    send(
                        conn,
                        {
                            "type": "auth_message",
                            "auth_message_type": "secret",
                            "auth_message": "Password:",
                        },
                    )
            elif t == "post_auth_message_response":
                if msg.get("response") == good:
                    send(conn, {"type": "success"})
                else:
                    send(
                        conn,
                        {
                            "type": "error",
                            "error_type": "auth_error",
                            "description": "pam_authenticate: AUTH_ERR",
                        },
                    )
            else:
                send(conn, {"type": "success"})
        conn.close()


if __name__ == "__main__":
    main()
