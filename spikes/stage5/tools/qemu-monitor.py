#!/usr/bin/env python3
"""Send one command to a qemu HUMAN MONITOR over a unix socket.

WHY NOT socat: it is not on a GitHub runner and is not worth an apt-get.
WHY NOT QMP: the QMP screendump command needs a capabilities handshake and
JSON framing; the human monitor takes a line of text and is enough here.
"""
import socket, sys, time
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(20)
s.connect(sock)
time.sleep(0.5)
try:
    s.recv(65536)          # banner
except Exception:
    pass
s.sendall((cmd + "\n").encode())
time.sleep(2.0)
out = b""
try:
    while True:
        b = s.recv(65536)
        if not b:
            break
        out += b
except Exception:
    pass
s.close()
sys.stdout.write(out.decode("utf-8", "replace"))
