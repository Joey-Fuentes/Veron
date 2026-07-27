#!/usr/bin/env python3
"""s0_roundtrip.py -- does the built binary disassemble back to its source?

    usage: s0_roundtrip.py <source.s> <objdump-output>

WHY THIS IS THE LOAD-BEARING CHECK. TRUST-BOUNDARY.md says the assembler is
untrusted by design, and README.md says the seed binary is "verified against its
source by round-trip disassembly rather than trusted". That verification is the
entire trust story for a committed seed -- and until now it had only ever been
run against spikes/stage0-arm64/stage0-handencoded.aarch64.s, eight `.inst`
words proving the METHOD. The 695-instruction assembler the ladder actually
stands on has never been round-tripped.

TWO CHECKS, BECAUSE THEY PROVE DIFFERENT THINGS.

  A. MECHANICAL   disassemble, reassemble, compare bytes. Proves the
                  disassembly is faithful to the binary. Done in the workflow,
                  not here -- it needs `as`, and it is unambiguous by
                  construction.
  B. AUDITABLE    normalised source text vs normalised disassembly text, line
                  by line. Proves a HUMAN reading the disassembly sees what the
                  source says. This is what "no ambiguity" means, and it is
                  what this script measures.

B is the one that can fail while A passes, and the reason is ALIASES. AArch64
encodes many instructions as aliases of others, and a disassembler prints its
preferred spelling, not ours:

    source                        objdump prints            1:1?
    mov  x0, #5                   mov x0, #0x5              yes
    mov  x0, x1                   mov x0, x1                yes  (ORR xzr)
    cmp  w0, #65                  cmp w0, #0x41             yes  (SUBS wzr)
    lsl  w0, w1, #4               lsl w0, w1, #4            yes  (UBFM)
    mul  w0, w1, w2               mul w0, w1, w2            yes  (MADD wzr)
    movz w0, #0x1234, lsl #16     mov w0, #0x12340000       TEXT DIFFERS

The last one is the shape to watch: one instruction either way, but the
disassembler folds the shift into the immediate, so a human comparing texts
sees something that is not what was written. That is exactly the ambiguity the
round-trip is supposed to exclude, and it is a reason to prefer source forms
whose disassembly is their own spelling.

DATA IN .text IS NOT CODE. stage0-as carries three `.ascii` strings in .text,
and a disassembler will decode them as instructions. Those bytes are located by
symbol and excluded rather than counted as mismatches.
"""

import re
import sys
from collections import Counter

# objdump line:  "  4000a4:\tmov\tx0, #0x2                   \t// comment"
DIS = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f ]+\t)?([a-z][a-z0-9.]*)\s*(.*)$")
SYM = re.compile(r"^\s*([0-9a-f]+)\s+<([^>]+)>:")
SRC = re.compile(r"^\s+([a-z][a-z0-9.]*)\s*(.*)$")


def norm(mn, ops):
    """Reduce one instruction to a comparable form."""
    o = ops.split("//")[0].split(";")[0].strip()
    # objdump renders a branch or adr target as "4003c4 <inbuf>". Keep the
    # SYMBOL and drop the address: the source names a label, and comparing it
    # against a link-time address would report every branch as a mismatch.
    # "<inbuf+0x8>" keeps only the symbol, which is the right granularity here.
    o = re.sub(r"\b[0-9a-f]+\s+<([A-Za-z_][\w.]*)(?:\+0x[0-9a-f]+)?>", r"\1", o)
    o = re.sub(r"<[^>]*>", "", o)            # any annotation left over
    o = o.replace(",", " ").replace("#", "")
    o = re.sub(r"\s+", " ", o).strip()
    out = []
    for t in o.split():
        if re.fullmatch(r"0x[0-9a-f]+", t):
            out.append(str(int(t, 16)))
        elif re.fullmatch(r"-?\d+", t):
            out.append(str(int(t)))
        elif re.fullmatch(r"'.'", t):
            out.append(str(ord(t[1])))
        else:
            out.append(t)
    return mn, " ".join(out)


def read_source(path, equ=None):
    equ = equ or {}
    for ln in open(path, encoding="utf-8"):
        raw = ln.split("//")[0].rstrip()
        if not raw.strip():
            continue
        m = re.match(r"\s*\.equ\s+([A-Za-z_]\w*)\s*,\s*(\S+)", raw)
        if m:
            equ[m.group(1)] = m.group(2)
            continue
        if re.match(r"^[A-Za-z_]\w*:\s*$", raw.strip()):
            continue
        if raw.strip().startswith("."):
            yield ("<data>", raw.strip())
            continue
        m = SRC.match(raw)
        if not m:
            continue
        mn, ops = m.group(1), m.group(2)
        for k, v in equ.items():
            ops = re.sub(r"#%s\b" % re.escape(k), "#" + v, ops)
        yield norm(mn, ops)


def read_objdump(path):
    cur = None
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = SYM.match(ln)
        if m:
            cur = m.group(2)
            continue
        m = DIS.match(ln)
        if not m:
            continue
        yield cur, norm(m.group(2), m.group(3))


def main():
    if len(sys.argv) != 3:
        print("usage: s0_roundtrip.py <source.s> <objdump-output>")
        return 2
    src = [x for x in read_source(sys.argv[1]) if x[0] != "<data>"]
    # Symbols whose contents are .ascii data, not code -- excluded by name.
    DATA_SYMS = {"inover", "rejmsg", "rejnl"}
    dis = [(s, x) for s, x in read_objdump(sys.argv[2]) if s not in DATA_SYMS]

    print("  source instructions : %d" % len(src))
    print("  disassembled words  : %d  (data symbols %s excluded)"
          % (len(dis), ", ".join(sorted(DATA_SYMS))))
    print()

    if len(src) != len(dis):
        print("  COUNT MISMATCH of %d. Every instruction must appear exactly"
              % abs(len(src) - len(dis)))
        print("  once in the disassembly; a difference means either data is")
        print("  being decoded as code or a source line emitted nothing.")
        print()

    n = min(len(src), len(dis))
    same, diff = 0, []
    for i in range(n):
        s_mn, s_ops = src[i]
        d_mn, d_ops = dis[i][1]
        if (s_mn, s_ops) == (d_mn, d_ops):
            same += 1
        else:
            diff.append((i, src[i], dis[i][1]))

    print("  %d of %d instructions round-trip to identical text (%.1f%%)"
          % (same, n, 100.0 * same / n if n else 0))
    print()
    if diff:
        by_form = Counter("%s -> %s" % (a[1][0], a[2][0]) for a in diff)
        print("  where the text differs, by mnemonic pair:")
        for k, c in by_form.most_common():
            print("    %-28s %4d" % (k, c))
        print()
        print("  first 12, source | disassembly:")
        for i, s, d in diff[:12]:
            print("    %-34s | %s" % ("%s %s" % s, "%s %s" % d))
        print()
        print("  A DIFFERENCE IS NOT AUTOMATICALLY A DEFECT. `mov x0 5` printed")
        print("  as `mov x0 5` is fine; `movz w0 4660 lsl 16` printed as")
        print("  `mov w0 305397760` is the disassembler folding a shift into an")
        print("  immediate, which is one instruction either way but NOT the")
        print("  text a human wrote. Forms in the second category are the ones")
        print("  to rewrite, because they are exactly the ambiguity the")
        print("  round-trip exists to exclude.")
    else:
        print("  Every instruction disassembles to its own source spelling.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
