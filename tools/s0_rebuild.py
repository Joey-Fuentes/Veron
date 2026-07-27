#!/usr/bin/env python3
"""s0_rebuild.py -- reconstruct a full .s from a linked binary, so the ROUND
TRIP produces a whole ELF to compare, not just a .text section.

    usage: s0_rebuild.py <objdump -d out> <objdump -t out> <objdump -h out> \\
                         <rodata.bin> <out.s>

WHY. Until now the round trip compared the .text SECTION: original 2840 bytes
against two reassemblies, all three the same sha. That is a real result but it
is not the claim a committed seed needs, because the artifact that gets
committed is the whole file -- headers, entry point, symbol table and all. An
ELF whose .text is verified and whose e_entry is not has an unverified field
that decides what actually runs.

So reconstruct everything the disassembly can account for:

    REAL SYMBOL NAMES, not L<addr>.  objdump prints `<_start>:`, so the labels
      exist and the reassembled symbol table can carry the same names.
    .rodata contents, from the raw section bytes.
    .bss symbols and sizes, from the symbol table.
    .global bindings, from the g/l column.

WHAT CANNOT BE RECONSTRUCTED, AND IS REPORTED RATHER THAN FAKED. AArch64 `as`
emits $x/$d mapping symbols of its own, and `ld` may add notes; neither is
under the source's control. If the whole-file comparison fails on those, the
per-section report says so, and a section-level match with a named metadata
difference is a far more precise statement than "we only checked .text".
"""

import re
import sys

DIS = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2}(?:[0-9a-f ]*)?[\t ]+)?"
                 r"([a-z][a-z0-9._]*)[\t ]*(.*)$")
LBL = re.compile(r"^\s*([0-9a-f]+)\s+<([^>]+)>:")
# objdump -t:  0000000000410dd4 l    O .bss  0000000004000000 inbuf
SYM = re.compile(r"^([0-9a-f]+)\s+(.)\s*\S*\s+(\S+)\s+([0-9a-f]+)\s+(\S+)\s*$")
SEC = re.compile(r"^\s*\d+\s+(\.\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)")
# groups: 1 = name, 2 = SIZE, 3 = VMA


def main():
    if len(sys.argv) != 6:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    dis_p, sym_p, hdr_p, rodata_p, out_p = sys.argv[1:]

    sections = {}
    for ln in open(hdr_p, encoding="utf-8", errors="replace"):
        m = SEC.match(ln)
        if m:
            # objdump -h columns are:  Idx Name SIZE VMA LMA File-off Algn.
            # Reading them as (VMA, Size) instead of (Size, VMA) made .text
            # start at 0xc and run for 4 MB -- a four-million-line output file
            # from a twelve-byte section. Order matters and the test caught it.
            sections[m.group(1)] = (int(m.group(3), 16), int(m.group(2), 16))

    syms, globals_ = {}, set()
    for ln in open(sym_p, encoding="utf-8", errors="replace"):
        m = SYM.match(ln.rstrip())
        if not m:
            continue
        val, bind, sec, size, name = m.groups()
        if name.startswith("$") or name.startswith("."):
            continue
        syms[name] = (int(val, 16), sec, int(size, 16))
        if bind == "g":
            globals_.add(name)

    labels, insns = {}, {}
    for ln in open(dis_p, encoding="utf-8", errors="replace"):
        m = LBL.match(ln)
        if m:
            labels.setdefault(int(m.group(1), 16), m.group(2))
            continue
        m = DIS.match(ln)
        if not m:
            continue
        addr = int(m.group(1), 16)
        ops = m.group(3).split("//")[0].split(";")[0].strip()
        # keep the SYMBOL, drop the address objdump prints beside it
        ops = re.sub(r"\b(?:0x)?[0-9a-f]+\s+<([^>+]+)(?:\+0x[0-9a-f]+)?>", r"\1", ops)
        ops = re.sub(r"<([^>]+)>", r"\1", ops)
        insns[addr] = ("%s %s" % (m.group(2), ops)).strip()

    out = []
    for g in sorted(globals_):
        out.append(".global %s" % g)

    tbase, tsize = sections.get(".text", (min(insns) if insns else 0, 0))
    out.append(".text")
    addr = tbase
    end = tbase + tsize
    while addr < end:
        if addr in labels:
            out.append("%s:" % labels[addr])
        if addr in insns:
            out.append("\t%s" % insns[addr])
            addr += 4
        else:
            # .text should hold only code; if it does not, say so loudly
            out.append("\t.byte 0  // UNDECODED BYTE AT 0x%x" % addr)
            addr += 1

    if ".rodata" in sections:
        rbase, rsize = sections[".rodata"]
        data = open(rodata_p, "rb").read()
        out.append(".section .rodata")
        for off in range(min(rsize, len(data))):
            a = rbase + off
            if a in labels:
                out.append("%s:" % labels[a])
            out.append("\t.byte 0x%02x" % data[off])

    bss = sorted((v, n) for n, (v, s, z) in syms.items() if s == ".bss")
    if bss:
        out.append(".bss")
        for i, (val, name) in enumerate(bss):
            out.append("%s:" % name)
            size = syms[name][2]
            if size:
                out.append("\t.space %d" % size)
            elif i + 1 < len(bss):
                out.append("\t.space %d" % (bss[i + 1][0] - val))

    with open(out_p, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print("  rebuilt %s: %d instructions, %d labels, %d globals, %d bss symbols"
          % (out_p, len(insns), len(labels), len(globals_), len(bss)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
