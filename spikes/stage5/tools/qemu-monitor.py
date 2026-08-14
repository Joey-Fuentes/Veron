#!/usr/bin/env python3
"""Send commands to a qemu HUMAN MONITOR over a unix socket.

WHY NOT socat: it is not on a GitHub runner and is not worth an apt-get.
WHY NOT QMP: the QMP screendump command needs a capabilities handshake and
JSON framing; the human monitor takes a line of text and is enough here.

SEVERAL COMMANDS, ONE CONNECTION, AND THAT IS THE WHOLE POINT OF THIS
REWRITE.

This took one command per invocation, and slept 0.5s before it and 2.0s
after. Typing a 40-character line with `sendkey` therefore meant forty
processes, forty connections and a hundred seconds of sleeping -- for
keystrokes that produce no output at all. A desktop test that had taken
under five minutes took fifteen, and the monitor echoed the command back
one character at a time while it happened:

    sscscrscrescreescreenscreendscreendu...

THE SLEEPS EXIST FOR screendump, NOT FOR sendkey. screendump writes a file
and the caller reads it immediately afterwards, so there has to be a moment
for qemu to finish writing. sendkey returns nothing worth waiting for. So
the wait is now per-command and defaults to none.
"""
import socket, sys, time

sock = sys.argv[1]
cmds = sys.argv[2:]

# --wait=N BEFORE A COMMAND applies to that command and every one after it,
# so a batch of keystrokes can end with a screendump that gets its pause.
wait = 0.0

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(20)
s.connect(sock)

# THE BANNER IS READ WITH A TIMEOUT, NOT WAITED FOR WITH A SLEEP. qemu writes
# it as soon as the connection is accepted; half a second of sleep was half a
# second added to every call, and the polling loop makes every call count.
s.settimeout(0.3)
try:
    s.recv(65536)          # banner
except Exception:
    pass
s.settimeout(20)

for cmd in cmds:
    if cmd.startswith("--wait="):
        wait = float(cmd.split("=", 1)[1])
        continue

    # --keys=a,b,c SENDS ONE sendkey PER NAME, FROM A SINGLE ARGUMENT.
    #
    # The obvious spelling -- building "sendkey v sendkey e ..." in the shell
    # and passing it unquoted -- word-splits into separate argv entries, so
    # `sendkey` and `v` arrive as two commands and qemu rejects both. Keeping
    # the whole key list inside one argument removes the shell from the
    # question entirely. Comma-separated because no qemu key name contains a
    # comma.
    if cmd.startswith("--keys="):
        for key in cmd.split("=", 1)[1].split(","):
            if key:
                s.sendall(("sendkey " + key + "\n").encode())
                # A HUMAN TYPES WITH GAPS AND SO MUST THIS. foot drops keys
                # delivered faster than it reads them; 30ms is imperceptible
                # across a 40-character line and is the difference between a
                # complete command and a truncated one.
                time.sleep(0.03)
        continue

    s.sendall((cmd + "\n").encode())
    if wait:
        time.sleep(wait)

# THE READ IS ONCE, AT THE END. Draining after every command was most of the
# remaining cost: recv blocks until the 20s timeout when the monitor has
# nothing more to say, and the monitor has nothing to say about a keystroke.
# THE DRAIN TIMEOUT IS SHORT BECAUSE IT IS PAID ON EVERY CALL.
#
# recv keeps reading until the monitor goes quiet, and the monitor goes quiet
# by saying nothing -- so the timeout IS the cost, every time. At 3 seconds a
# polling loop that grabs 45 frames spends over two minutes doing nothing but
# waiting for a socket that has already told us everything. The monitor's
# reply to any of these commands is a prompt and at most one line, and both
# arrive immediately.
time.sleep(0.2)
out = b""
s.settimeout(0.6)
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
