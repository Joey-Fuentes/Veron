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
        # KEEP THE OFFSET. `<slurp+0x2c>` means "44 bytes past slurp", and the
        # old pattern captured only the symbol -- so every branch to an address
        # without its own label silently retargeted to the start of the
        # enclosing one. GNU as accepts `slurp+0x2c`, so pass the whole thing
        # through.
        ops = re.sub(r"\b(?:0x)?[0-9a-f]+\s+<([^>]+)>", r"\1", ops)
        ops = re.sub(r"<([^>]+)>", r"\1", ops)
        insns[addr] = ("%s %s" % (m.group(2), ops)).strip()

    # LABELS FROM THE SYMBOL TABLE, NOT ONLY FROM THE DISASSEMBLY. objdump -d
    # prints `<sym>:` headers only for sections it disassembles, so once the
    # strings moved to .rodata its labels for inover/rejmsg/rejnl vanished and
    # the adr references to them dangled:
    #   (.text+0x48): undefined reference to `inover'
    # The names were in `objdump -t` the whole time, already parsed and then
    # not used. Merge both sources, preferring the disassembly's spelling where
    # they overlap.
    for name, (val, sec, size) in syms.items():
        labels.setdefault(val, name)

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

    # PAD TO EACH SYMBOL'S ABSOLUTE OFFSET; DO NOT ACCUMULATE SIZES.
    # The first version emitted label-then-.space in address order and let the
    # offsets add up, which put inbuf eight bytes late:
    #   original    adr x19, 410de4 <inbuf>
    #   reassembled adr x19, 410dec <inbuf>
    # 11 .bss symbols were reported where the source declares four; the rest
    # are linker-generated (__bss_start, _end, _edata), several sharing an
    # address. Any one of them contributing a stray gap shifts everything
    # after it. Padding to an absolute offset cannot drift, and symbols that
    # share an address simply emit two labels and no padding.
    LINKER_MADE = ("__bss_start", "_end", "_edata", "__end__", "__bss_end__",
                   "__bss_start__", "_bss_end__")
    bss = sorted((v, n) for n, (v, sc, z) in syms.items()
                 if sc == ".bss" and n not in LINKER_MADE)
    if bss and ".bss" in sections:
        bbase, bsize = sections[".bss"]
        out.append(".bss")
        cur = 0
        for val, name in bss:
            want = val - bbase
            if want > cur:
                out.append("\t.space %d" % (want - cur))
                cur = want
            out.append("%s:" % name)
        if bsize > cur:
            out.append("\t.space %d" % (bsize - cur))

    with open(out_p, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    # PIN EVERY SECTION, NOT JUST .text. Passing only -Ttext let the linker
    # choose where .rodata and .bss landed, so every `adr x19, inbuf` and
    # `adr x1, inover` encoded a different displacement -- same instructions,
    # different immediates, .text differing at identical size. The original
    # addresses are in `objdump -h` and are written out here for the caller.
    with open(out_p + ".secs", "w", encoding="utf-8") as fh:
        for name in (".text", ".rodata", ".data", ".bss"):
            if name in sections:
                fh.write("-T%s=0x%x\n" % (name.lstrip("."), sections[name][0]))
    ro = [n for n, (v, sc, z) in syms.items() if sc == ".rodata"]
    print("  rebuilt %s: %d instructions, %d labels, %d globals, %d bss, %d rodata"
          % (out_p, len(insns), len(labels), len(globals_), len(bss), len(ro)))
    if ro:
        print("    .rodata symbols: %s" % " ".join(sorted(ro)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
