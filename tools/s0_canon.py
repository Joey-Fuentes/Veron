#!/usr/bin/env python3
"""s0_canon.py -- reduce a source file OR a disassembly to one canonical text,
so the round-trip can be a plain `diff` instead of a semantic comparison.

    usage: s0_canon.py source <file.s>        > canon.txt
           s0_canon.py disasm <objdump-out>   > canon.txt

THE IDEA, AND WHY IT BEATS NORMALISING. Comparing source against disassembly by
normalising both sides means a tool decides what counts as "the same" -- and a
normaliser that is itself wrong manufactures findings, which happened twice in
this workflow's history (uppercase hex, character literals). The alternative is
to make the two files ACTUALLY equal and diff them.

That looks impossible, because a commented source contains things no
disassembler can recover. It becomes possible once the comment and the code are
separated: keep the commented file as the human artifact, strip it to a
canonical form, and round-trip THAT. Anywhere exactness costs readability --
writing `#65` where `#'A'` would read better -- the reason goes in a comment
directly above the line, which survives in the source and disappears from the
comparison.

So the compromise is documented where a reader will see it, and the check
becomes a diff of two files rather than an argument about equivalence.

WHAT IS REMOVED, AND WHY IT IS SAFE. Only things that emit no instruction:
comments, blank lines, and the directives that describe layout rather than
code (.text .global .align .balign .bss .equ .space .type .size). Data
directives (.byte .ascii) are dropped too -- a disassembler does not render
them as instructions, which is the same reason .text should eventually hold
only code.

WHAT IS NORMALISED, SYMMETRICALLY. Runs of whitespace become one space, on both
sides. Nothing else. In particular immediates and mnemonics are passed through
untouched: if the source says `#0` and the decoder says `#0x0`, that is a real
difference and must show up in the diff, to be fixed by a decoder flag or by
writing the source differently -- not hidden here.
"""

import re
import sys

DROP = (".text", ".global", ".globl", ".align", ".balign", ".bss", ".data",
        ".equ", ".set", ".space", ".type", ".size", ".section", ".byte",
        ".ascii", ".asciz", ".word", ".quad", ".org", ".p2align")

# objdump/llvm-objdump instruction line, with addresses and raw bytes already
# suppressed by --no-addresses / --no-leading-addr / --no-show-raw-insn.
DIS_INSN = re.compile(r"^\s+([a-z][a-z0-9._]*)\s*(.*)$")
DIS_LABEL = re.compile(r"^\s*(?:[0-9a-f]+\s+)?<([^>]+)>:\s*$")


def squash(text):
    return re.sub(r"\s+", " ", text).strip()


def from_source(path):
    equ = {}
    out = []
    for raw in open(path, encoding="utf-8"):
        line = raw.split("//")[0].rstrip()
        if not line.strip():
            continue
        m = re.match(r"\s*\.equ\s+([A-Za-z_]\w*)\s*,\s*(\S+)", line)
        if m:
            equ[m.group(1)] = m.group(2)
            continue
        body = line.strip()
        if body.startswith(DROP):
            continue
        # A LABEL MAY SHARE ITS LINE WITH A DIRECTIVE. `inbuf: .space 8` is one
        # line carrying both, and matching only a label ALONE on a line let the
        # directive through into the canonical text, where no disassembly could
        # ever match it. Split first, then apply the drop rules to the rest.
        m = re.match(r"^([A-Za-z_][\w.]*):\s*(.*)$", body)
        if m:
            label, rest = m.group(1), m.group(2).strip()
            if not rest or rest.startswith(DROP):
                # a label on a dropped directive is a data label: drop both,
                # since the instruction stream has neither
                if not rest:
                    out.append("%s:" % label)
                continue
            out.append("%s:" % label)
            body = rest
        for name, val in equ.items():
            body = re.sub(r"#%s\b" % re.escape(name), "#" + val, body)
        out.append(squash(body))
    return out


def from_disasm(path):
    out = []
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip()
        if not line.strip():
            continue
        m = DIS_LABEL.match(line)
        if m:
            out.append("%s:" % m.group(1))
            continue
        if line.lstrip().startswith(("Disassembly", "In archive", "file format")):
            continue
        m = DIS_INSN.match(line)
        if not m:
            continue
        mn, ops = m.group(1), m.group(2)
        ops = ops.split("//")[0].split(";")[0]
        # `4003c4 <inbuf>` and `<inbuf>` both become `inbuf`: the angle brackets
        # are the decoder's punctuation for "this is a symbol", and the source
        # writes the bare name. Purely syntactic, applied to one side only
        # because only one side has them.
        ops = re.sub(r"\b(?:0x)?[0-9a-f]+\s+<([^>]+)>", r"\1", ops)
        ops = re.sub(r"<([^>]+)>", r"\1", ops)
        out.append(squash("%s %s" % (mn, ops)))
    return out


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("source", "disasm"):
        print("usage: s0_canon.py source|disasm <file>", file=sys.stderr)
        return 2
    lines = (from_source if sys.argv[1] == "source" else from_disasm)(sys.argv[2])
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
