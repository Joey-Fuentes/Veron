#!/usr/bin/env python3
"""
pcmap.py -- map a faulting PC back to the function label that contains it.

Our binaries carry no symbol table, so a segfault under qemu gives a bare
address and nothing else. But stage 1 already computes every label's assembled
byte position (spikes/bench/stage1_ref.py, PASS 1), and spikes/elf places code
at a fixed address. Put those together and a PC becomes a function name.

    code base = 0x400078   (BASE 0x400000 + ELF64 header 64 + phdr 56)
    offset    = PC - base
    label     = the last ':name' whose position <= offset

Usage:
    tools/pcmap.py m2.s1 0x42c0cc 0x4127dc
    tools/pcmap.py m2.s1 --list | head        # dump the whole map
    qemu-aarch64 -d in_asm,cpu -D f.log ./prog ...
    tools/pcmap.py m2.s1 $(grep -o 'PC=[0-9a-f]*' f.log | tail -1 | cut -d= -f2)

The sizing rules MUST match stage1_ref._size or the offsets drift:
instruction 4 bytes, .byte 1, .ascii the decoded length, label/comment/blank 0.
"""
import sys

CODE_BASE = 0x400078


def _ascii_len(raw):
    """Bytes emitted by .ascii "raw" -- an escape sequence is one byte."""
    n = i = 0
    while i < len(raw):
        if raw[i] == '\\':
            n += 1
            i += 2
        else:
            n += 1
            i += 1
    return n


def _size(st):
    if st == '' or st.startswith('#') or st.startswith(':'):
        return 0
    if st.startswith('.byte'):
        return 1
    if st.startswith('.ascii'):
        raw = st[st.index('"') + 1:st.rindex('"')]
        return _ascii_len(raw)
    return 4


def label_map(text):
    """[(position, name)] in assembled order."""
    pos = 0
    out = []
    for line in text.split('\n'):
        st = line.strip()
        if st.startswith(':'):
            out.append((pos, st[1:].split('#', 1)[0].strip()))
        else:
            pos += _size(st)
    return out, pos


def is_generated(name):
    """Labels stage 2 invents (control flow, data, runtime) rather than
    function names carried over from the C source."""
    if name.startswith('__L') or name.startswith('__ds'):
        return True
    if name.startswith('__') and name[2:].isdigit():
        return True
    return name in ('__mp',)


def locate(labels, total, off):
    if off < 0:
        return None, None, 'PC is below the code base'
    if off >= total:
        return None, None, 'PC is past the end of the image (%d bytes)' % total
    lo, hi = 0, len(labels) - 1
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        if labels[mid][0] <= off:
            best = mid
            lo = mid + 1
        else:
            hi = mid - 1
    if best is None:
        return None, None, 'before the first label'
    pos, name = labels[best]
    nxt = labels[best + 1][0] if best + 1 < len(labels) else total
    note = 'spans %d bytes' % (nxt - pos)
    if is_generated(name):
        # walk back to the nearest real function label -- a generated control
        # flow label tells you nothing about WHICH function you are in.
        j = best
        while j >= 0 and is_generated(labels[j][1]):
            j -= 1
        if j >= 0:
            note = 'in %s + %d, %s' % (labels[j][1], off - labels[j][0], note)
    return name, off - pos, note


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    text = open(argv[1]).read()
    labels, total = label_map(text)
    print('%s: %d labels, %d bytes of code, base 0x%x'
          % (argv[1], len(labels), total, CODE_BASE))

    if '--list' in argv[2:]:
        for pos, name in labels:
            print('  0x%08x  %s' % (CODE_BASE + pos, name))
        return 0

    rc = 0
    for a in argv[2:]:
        try:
            pc = int(a, 16) if a.lower().startswith('0x') else int(a, 0)
        except ValueError:
            print('  %-12s not a number' % a)
            rc = 1
            continue
        name, delta, note = locate(labels, total, pc - CODE_BASE)
        if name is None:
            print('  0x%-10x %s' % (pc, note))
            rc = 1
        else:
            print('  0x%-10x %s + %d  (%s)' % (pc, name, delta, note))
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv))
