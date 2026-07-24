#!/usr/bin/env python3
"""
backtrace.py -- run a C program through the ladder and, on a fault, print the
last N instructions executed with every PC mapped back to a function label.

WHY. Differential testing (mutate the source, diff the exit code) only ever
yields correlations, and on this ladder they dissolve: four separate "root
causes" for the m75 flag-clobber -- alignment, a second local, a global write,
scalar-vs-array emission -- each looked solid and each evaporated on the next
run, because changing the source changes emitted layout and symbol-table state
at the same time. What finally worked was watching the machine: trap the store,
map the PC, read the emitted instruction, then read the compiler's own branch.
This tool is that loop, packaged.

It works where qemu cannot help much: interp.py raises a Python exception at the
faulting instruction, so the ring buffer still holds everything that led there,
and no 7 GB `-d cpu` trace is needed.

Usage:
    tools/backtrace.py prog.c [N]        # N instructions of history, default 32

Reads the ladder from spikes/, so run it from the repo root. Output columns are
    label+offset | decoded instruction | non-zero watched registers
with x9 (value stack), x10 (frame base), x11 (frame stack), x16 (call-through)
and x30 (link) always shown -- the registers that carry the calling convention.

WORKED EXAMPLE (the phantom-parameter bug this tool found):

    int inc(int x){return x+1;}
    int ap(int f(int), int v){return f(v);}
    int main(){int s; s=0; s=ap(inc,s); return s;}

    FAULT: KeyError: 568
      main+48   adr 0 96        <- &inc = 0x60, correct
      main+52   str 0 9         <- push it
      main+68   str 0 9         <- push s;  TWO values pushed
      ap+20     sub 9 9 8 ...   -> slot 2
      ap+36     sub 9 9 8 ...   -> slot 1
      ap+52     sub 9 9 8 ...   -> slot 0   <- THREE pops, reads below the pushes
      ap+92     blr 16          <- x16 = 0x238, past the 552-byte image

    i.e. `int f(int)` was counted as two parameters. Nothing in the exit code
    said that; the trace said it in six lines.
"""
import sys, os, bisect, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BENCH = os.path.join(ROOT, 'spikes', 'bench')
sys.path.insert(0, BENCH)

CODE_BASE = 0x400078          # must match tools/pcmap.py
WATCHREG = (0, 1, 2, 9, 10, 11, 16, 30)


def _tracing_interp():
    """interp.py with a ring buffer of executed instructions."""
    import types
    src = open(os.path.join(BENCH, 'interp.py')).read()
    src = src.replace(
        "NULLFLOOR = 16",
        "NULLFLOOR = 16\nimport collections as _c\nHIST = _c.deque(maxlen=4000)", 1)
    src = src.replace(
        "        o,ins=seq[i]; op=ins[0]\n        nxt=i+1",
        "        o,ins=seq[i]; op=ins[0]\n"
        "        HIST.append((o, ins, tuple(R[k] for k in " + repr(WATCHREG) + ")))\n"
        "        nxt=i+1", 1)
    mod = types.ModuleType('interp_traced')
    mod.__dict__['__file__'] = os.path.join(BENCH, 'interp.py')
    exec(compile(src, 'interp_traced', 'exec'), mod.__dict__)
    return mod


def _labelmap(s1path):
    out = subprocess.run(
        [sys.executable, os.path.join(HERE, 'pcmap.py'), s1path, '--list'],
        capture_output=True, text=True).stdout
    m = []
    for line in out.split('\n'):
        p = line.split()
        if len(p) == 2 and p[0].startswith('0x'):
            m.append((int(p[0], 16) - CODE_BASE, p[1]))
    m.sort()
    return m


def _name(m, off):
    i = bisect.bisect_right(m, (off, '\xff')) - 1
    return f'{m[i][1]}+{off - m[i][0]}' if i >= 0 else f'+0x{off:x}'


def main(argv):
    if len(argv) < 2:
        sys.stdout.write(__doc__)
        return 2
    src = open(argv[1]).read()
    n = int(argv[2]) if len(argv) > 2 else 32

    from s0as import assemble
    from interp import run as clean_run
    traced = _tracing_interp()

    sp = os.path.join(ROOT, 'spikes')
    s1 = assemble(open(os.path.join(sp, 'stage1-as', 'stage1-as.s0')).read())[1]
    _, s2asm = clean_run(s1, stdin=open(
        os.path.join(sp, 'stage2-mini-c', 'stage2-mini-c.s1')).read().encode(),
        timeout_s=600)
    s2 = assemble(s2asm.decode())[1]

    _, emitted = clean_run(s2, stdin=src.encode(), timeout_s=300)
    tmp = '/tmp/backtrace.s1'
    open(tmp, 'w').write(emitted.decode())
    _, resolved = clean_run(s1, stdin=emitted, timeout_s=300)
    prog = assemble(resolved.decode())[1]
    lm = _labelmap(tmp)

    traced.HIST.clear()
    try:
        rc, _out = traced.run(prog, timeout_s=300)
        print(f"ran to completion, exit={rc}")
        return 0
    except Exception as e:
        print(f"FAULT: {type(e).__name__}: {e}")
        print(f"--- last {n} instructions (most recent last) ---")
        for off, ins, regs in list(traced.HIST)[-n:]:
            r = ' '.join(f'x{k}={v:#x}'
                         for k, v in zip(WATCHREG, regs) if v)
            print(f"  {_name(lm, off):26} {' '.join(map(str, ins)):24} {r[:92]}")
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
