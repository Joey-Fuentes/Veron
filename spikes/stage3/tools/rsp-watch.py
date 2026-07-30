#!/usr/bin/env python3
"""CATCH THE INSTRUCTION THAT WRITES AN ADDRESS, WITHOUT A DEBUGGER.

    sh spikes/stage3/tools/rsp-watch.py <addr> <labels> -- <qemu> <binary> [args]

WHY THIS EXISTS.

Every diagnosis in spikes/stage3 has been done by bisection with write()
markers: put a probe here, rebuild, run, see whether the value changed yet.
That works and it found several real bugs, but it can only ever bracket
BETWEEN probe points, and on the last hunt it hit its floor -- the window
narrowed to a few statements and stopped narrowing.

Worse, four separate instrument bugs in that hunt produced false negatives that
were acted on: a cached slot address that went stale when the array moved, a
`static` function called from another file, a watch that reset its baseline on
the first hit so every later probe compared against the corrupt value, and a
print taken before the field it printed was populated. Each one made innocent
code look innocent for the wrong reason. Sampling is not just slow here, it is
error-prone in a way that is hard to notice.

A WATCHPOINT ANSWERS THE QUESTION DIRECTLY: which instruction wrote this
address. qemu-aarch64-static already speaks the GDB Remote Serial Protocol --
`-g PORT` -- and implements the watchpoint packets. The only missing piece was
a client, and gdb-multiarch is a large dynamically-linked binary that would
have to be vendored with its shared libraries and a Python runtime.

The protocol needed here is small: connect, set a write watchpoint, continue,
read the program counter when it stops. That is this file. It is not a
debugger and does not try to be.

TURNING A PROGRAM COUNTER INTO A NAME. hex2 emits a bare ELF -- no sections, no
symbol table -- so a raw address means nothing on its own. The label map from
`HEX2_LABEL_MAP=file hex2 ...` (patches/mescc-tools/0001) is the addresses hex2
already computed, and this resolves against it by taking the nearest label at
or below the PC.

WHAT THIS CANNOT DO, AND IT IS THE MAIN THING.

qemu-user's gdbstub implements breakpoints and REFUSES watchpoints. Checked
packet by packet against the committed emulator:

    Z0 (sw breakpoint) -> OK
    Z1 (hw breakpoint) -> OK
    Z2 (write watch)   -> ''
    Z3 (read watch)    -> ''
    Z4 (access watch)  -> ''

Watchpoints live in QEMU's system-mode path, not linux-user. This is recorded
here because the obvious next move -- vendoring gdb-multiarch into the toolbox
-- would have been a large binary that connected to the same stub and got the
same refusal. It was nearly done before it was tested.

Watchpoint work therefore happens on the aarch64 runner, where mc-tcc executes
natively and gdb gets real hardware watchpoints:
.github/workflows/stage3-watchpoint.yml. This file remains useful for
BREAKPOINTS under emulation, which do work.

DETERMINISM IS WHAT MAKES THE TWO-PASS APPROACH WORK. The address to watch is
usually only known at runtime -- a heap pointer. Under qemu-user with the same
binary and arguments the layout repeats exactly: no ASLR, and M2libc's
allocator is a straight brk bump. So run once to learn the address, then run
again under the stub and watch it. If that ever stops holding, the symptom is
a watchpoint that never fires, which is loud rather than silent.
"""

import os
import socket
import subprocess
import sys
import time


def checksum(payload):
    return sum(payload.encode("latin1")) & 0xFF


def send(sock, payload):
    sock.sendall(("$%s#%02x" % (payload, checksum(payload))).encode("latin1"))


def recv(sock):
    """Read one packet. Acks are swallowed; we never resend, because a
    dropped packet against a local socket means something worse is wrong and
    retrying would hide it."""
    buf = b""
    while True:
        ch = sock.recv(1)
        if not ch:
            return None
        if ch == b"+" or ch == b"-":
            continue
        if ch == b"$":
            break
    while True:
        ch = sock.recv(1)
        if not ch:
            return None
        if ch == b"#":
            sock.recv(2)
            sock.sendall(b"+")
            return buf.decode("latin1")
        buf += ch


def rsp(sock, payload):
    send(sock, payload)
    return recv(sock)


def load_labels(path):
    out = []
    if not path or not os.path.exists(path):
        return out
    for line in open(path):
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            out.append((int(parts[0], 16), parts[1]))
        except ValueError:
            pass
    out.sort()
    return out


def resolve(labels, pc):
    """Nearest label at or below the PC. Reported with the offset, because a
    name alone invites reading 'in function F' when the evidence is only
    'after the start of F'."""
    best = None
    for addr, name in labels:
        if addr <= pc:
            best = (addr, name)
        else:
            break
    if best is None:
        return "?"
    return "%s+%d" % (best[1], pc - best[0])


def main():
    if "--" not in sys.argv:
        print(__doc__.strip().split("\n")[2])
        return 2
    cut = sys.argv.index("--")
    head, cmd = sys.argv[1:cut], sys.argv[cut + 1:]
    if len(head) < 1 or not cmd:
        print("usage: rsp-watch.py <addr> [labels] -- <qemu> <binary> [args]")
        return 2

    addr = int(head[0], 0)
    labels = load_labels(head[1] if len(head) > 1 else None)
    port = int(os.environ.get("RSP_PORT", "51234"))
    width = int(os.environ.get("RSP_WIDTH", "8"))

    qemu = [cmd[0], "-g", str(port)] + cmd[1:]
    proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)

    sock = None
    for _ in range(100):
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=30)
            break
        except OSError:
            time.sleep(0.05)
    if sock is None:
        proc.kill()
        print("FAIL: could not reach the gdbstub on port %d" % port)
        return 1

    try:
        rsp(sock, "qSupported")
        # Z2 is a WRITE watchpoint. If the stub refuses it, say so plainly --
        # a silent fall-through to "never fired" would look like the address
        # was simply never written, which is the wrong conclusion entirely.
        reply = rsp(sock, "Z2,%x,%x" % (addr, width))
        if reply != "OK":
            print("FAIL: the stub refused a write watchpoint (reply %r)" % reply)
            print("      Without it this tool has nothing to offer.")
            return 1
        print("  watching %d bytes at 0x%x" % (width, addr))

        hits = 0
        while True:
            stop = rsp(sock, "c")
            if stop is None:
                print("  the process ended without hitting the watchpoint")
                break
            if not stop.startswith("T"):
                print("  stopped: %s" % stop)
                break
            pcs = [v for k, v in
                   (f.split(":", 1) for f in stop[3:].split(";") if ":" in f)
                   if k == "20" or k == "pc"]
            pc = None
            if pcs:
                raw = pcs[0]
                pc = int.from_bytes(bytes.fromhex(raw[:16]), "little")
            hits += 1
            print("  HIT %d  pc=0x%x  %s" % (hits, pc or 0,
                                             resolve(labels, pc or 0)))
            if hits >= int(os.environ.get("RSP_HITS", "5")):
                break
    finally:
        try:
            sock.close()
        except OSError:
            pass
        proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
