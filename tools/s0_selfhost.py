#!/usr/bin/env python3
"""s0_selfhost.py -- can stage0-as assemble its own source?

    usage: s0_selfhost.py census  <stage0-as.aarch64.s>          # the inventory
           s0_selfhost.py probes  <stage0-as.aarch64.s> <outdir> # one case per form
           s0_selfhost.py xlate   <stage0-as.aarch64.s> <out.s0> # the translation

WHY. stage0-as is a mnemonic assembler written in GNU `as` syntax, so `as` and
`ld` are needed to build it -- the last two host tools on Veron's build path. If
its source were rewritten in stage0-as's OWN input language, stage0-as could
assemble itself, and the only thing host tools would be needed for is birthing
the very first binary (which a hand-encoded seed then replaces).

The question is whether stage0-as's input language is expressive enough. A
mnemonic-level count says yes -- 27 distinct mnemonics, 25 of them in the
documented table. That count is MISLEADING and this tool exists because of it.
At OPERAND-FORM level the source uses 44 distinct (mnemonic, operand-shape)
pairs, and several use addressing and shift forms the table does not list:

    orr  w0, w1, w2, lsl #5           shifted-register operand
    movz w0, #0x1234, lsl #16         movz with a shift
    lsl  w0, w1, #4                   IMMEDIATE shift amount (table has register)
    ldr  w0, [x1, w2, uxtw #2]        extended-register addressing
    b.gt / b.le                       two condition codes
    cmp  w0, #'x'                     character-literal immediate
    add  x0, x0, #INBUF_SZ            .equ symbolic constant

DO NOT TRUST THIS FILE'S OPINION ABOUT WHAT IS SUPPORTED. The documented table
is documentation; what stage0-as actually accepts is a property of the binary.
`probes` emits one minimal test per form so CI can settle each by feeding it to
the real stage0-as and byte-comparing against GNU `as` -- the same method
stage2-mini-c-demo already uses for individual instruction encodings. The census
below only says what the source NEEDS, which is a fact about text and can be
computed here.
"""

import os
import re
import sys
from collections import Counter

INSTR = re.compile(r"^\s+([a-z][a-z0-9.]*)\s*(.*)$")
CHARLIT = re.compile(r"#'(\\?.)'")


def strip_comment(line):
    return line.split("//")[0].rstrip()


def equ_table(lines):
    """Collect `.equ NAME, value` definitions."""
    table = {}
    for ln in lines:
        m = re.match(r"\s*\.equ\s+([A-Za-z_][A-Za-z0-9_]*)\s*,\s*(\S+)", ln)
        if m:
            table[m.group(1)] = m.group(2)
    return table


def shape(operands):
    """Normalise an operand list to its FORM, keeping structure that matters."""
    o = operands
    # PLACEHOLDERS ARE NON-ALPHABETIC ON PURPOSE. An earlier version used
    # #IMM / #EQU / Xn, and the .equ rule `#[A-Za-z_]...` then matched the
    # #IMM it had just written, reclassifying every numeric immediate as a
    # symbolic constant -- 62 character literals and every hex constant landed
    # in the wrong bucket and the summary arithmetic went negative. A
    # substitution alphabet disjoint from the input cannot do that.
    o = CHARLIT.sub("#%c", o)
    o = re.sub(r"#0x[0-9a-fA-F]+", "#%i", o)
    o = re.sub(r"#-?\d+", "#%i", o)
    o = re.sub(r"#[A-Za-z_][A-Za-z0-9_]*", "#%e", o)
    o = re.sub(r"\bx\d+\b", "%X", o)
    o = re.sub(r"\bw\d+\b", "%W", o)
    # a bare identifier left over is a branch/adr target
    # (?<!%) so the label rule cannot eat the letter of a placeholder it has
    # already written -- without it, "#%i" became "#%%L".
    o = re.sub(r"(?<!%)\b(?!lsl|lsr|asr|uxtw|sxtw)[a-z_][a-z0-9_.]*\b", "%L", o)
    return o.strip()


# Forms the documented table covers. Deliberately conservative: anything not
# listed here is reported as UNKNOWN, not as unsupported, because only the
# binary can settle it.
DOCUMENTED = {
    ("mov", "%X, #%i"), ("mov", "%X, %X"),
    ("add", "%X, %X, #%i"), ("add", "%X, %X, %X"),
    ("sub", "%X, %X, #%i"), ("sub", "%X, %X, %X"),
    ("cmp", "%X, %X"), ("cmp", "%X, #%i"),
    ("b", "%L"), ("b.eq", "%L"), ("b.ne", "%L"),
    ("b.lt", "%L"), ("b.ge", "%L"),
    ("bl", "%L"), ("ret", ""), ("br", "%X"), ("blr", "%X"),
    ("orr", "%X, %X, %X"), ("and", "%X, %X, %X"), ("eor", "%X, %X, %X"),
    ("lsl", "%X, %X, %X"), ("lsr", "%X, %X, %X"), ("asr", "%X, %X, %X"),
    ("movk", "%X, #%i, lsl #%i"),
    ("mul", "%X, %X, %X"), ("udiv", "%X, %X, %X"),
    ("adr", "%X, %L"),
    ("ldrb", "%W, [%X, %X]"), ("strb", "%W, [%X, %X]"),
    ("ldr", "%W, [%X]"), ("str", "%W, [%X]"),
    ("ldr", "%X, [%X]"), ("str", "%X, [%X]"),
    ("svc", "#%i"),
    # ADDED WHEN THE PROBE SAID SO, NOT BEFORE. Every entry below was measured
    # against the real binary by the PROBE step -- 40 forms ok, 0 wrong,
    # 0 rejected, 802/802 source lines -- and only then written down. This
    # table is documentation; the file header says not to trust its opinion,
    # and xlate gating on it while it lagged the assembler is exactly the
    # failure that warning describes: 322 lines marked NEEDS for forms that
    # had been working for several commits.
    ('add', '%W, %W, %W'),
    ('and', '%W, %W, %W'),
    ('asr', '%W, %W, #%i'),
    ('b.gt', '%L'),
    ('b.le', '%L'),
    ('cmp', '%W, #%i'),
    ('lsl', '%W, %W, #%i'),
    ('lsr', '%W, %W, #%i'),
    ('mov', '%W, #%i'),
    ('mov', '%W, %W'),
    ('mov', '%X, #%e'),
    ('movk', '%W, #%i'),
    ('movk', '%W, #%i, lsl #%i'),
    ('mul', '%W, %W, %W'),
    ('orr', '%W, %W, %W'),
    ('orr', '%W, %W, %W, lsl #%i'),
    ('strb', '%W, [%X]'),
    ('sub', '%W, %W, #%i'),
    ('sub', '%W, %W, %W'),
}


def census(path):
    lines = [strip_comment(x) for x in open(path, encoding="utf-8")]
    equ = equ_table(open(path, encoding="utf-8"))
    forms = Counter()
    for ln in lines:
        m = INSTR.match(ln)
        if not m or m.group(1).startswith("."):
            continue
        forms[(m.group(1), shape(m.group(2)))] += 1
    return forms, equ


def cmd_census(path):
    forms, equ = census(path)
    total = sum(forms.values())
    documented = sum(v for k, v in forms.items() if k in DOCUMENTED)
    print("  %s" % path)
    print("  %d instruction lines, %d distinct (mnemonic, operand-form) pairs"
          % (total, len(forms)))
    print("  .equ constants: %s"
          % (", ".join("%s=%s" % kv for kv in equ.items()) or "none"))
    print()
    print("  %-6s %-34s %6s  %s" % ("MNEM", "OPERAND FORM", "USES", "vs TABLE"))
    for (mn, sh), n in sorted(forms.items(), key=lambda kv: -kv[1]):
        mark = "documented" if (mn, sh) in DOCUMENTED else "NOT LISTED"
        print("  %-6s %-34s %6d  %s" % (mn, sh, n, mark))
    print()
    ndoc = sum(1 for k in forms if k in DOCUMENTED)
    print("  %d of %d lines (%.0f%%) use forms the table documents;"
          % (documented, total, 100.0 * documented / total))
    print("  %d lines use the other %d forms. Those are what the probes"
          % (total - documented, len(forms) - ndoc))
    print("  must settle against the real binary -- the table is documentation,")
    print("  not the assembler.")
    return 0


# One minimal, self-contained test per form. GNU-as text and the .s0 text that
# should encode identically. Registers and immediates are concrete so the two
# can be byte-compared.
# GNU-as mnemonic -> stage0-as spelling. The two languages are NOT the same
# assembly with different punctuation, and treating them as such produced three
# false "REJECTED" rows:
#
#   movz Rd, #imm        .s0 has NO `movz`. h_mov tests char+3 for 'k' (movk)
#                        and otherwise treats the mnemonic as `mov`, so `movz`
#                        parses as `mov` and leaves a stray `z`. The ladder
#                        spells it `mov` -- 778 uses of `mov`, ZERO of `movz`.
#   svc #0               .s0 `svc` takes NO operand; h_svc advances x20 by 3 and
#                        emits D4000001. A trailing `0` is a stray line.
#   movk Rd, #imm        .s0 `movk` wants an explicit shift: `movk Rd imm 0`.
#
# movz-with-a-shift has no single .s0 spelling at all -- it needs `mov` plus
# `movk` -- so it is a TRANSLATION gap, not a missing encoding, and is reported
# as such rather than counted against the assembler.
NEEDS_TWO = "movz-with-shift needs mov+movk: no single .s0 instruction"


def to_s0(mn, ops):
    """Rewrite one GNU-as instruction into stage0-as's spelling."""
    if mn == "svc":
        return "svc", ""
    if mn == "movz":
        if "lsl" in ops:
            return None, NEEDS_TWO
        return "mov", ops
    if mn == "movk":
        # .s0 spells the shift as a bare third operand: `movk Rd imm shift`.
        # The `lsl` keyword is GNU-as punctuation and must go, or the line has
        # four tokens where the assembler expects three. Absent shift means 0.
        if "lsl" in ops:
            return "movk", ops.replace("lsl", "").replace("  ", " ").strip()
        return "movk", ops + " 0"
    if mn in ("orr", "and", "eor") and "lsl" in ops:
        # Shifted-register operand: .s0 spells the amount as a bare fourth
        # token, exactly as movk spells its shift, and absent means zero. The
        # `lsl` keyword is GNU-as punctuation -- leaving it in would give the
        # assembler five tokens where it expects four.
        return mn, ops.replace("lsl", "").replace("  ", " ").strip()
    return mn, ops


def probe_pair(mn, sh):
    """Return (gnu_as_text, s0_text) for a form, or None if not expressible."""
    subs_gnu = {
        "%X": ["x0", "x1", "x2"], "%W": ["w0", "w1", "w2"],
        # #%e IS A .equ CONSTANT, AND IN THIS SOURCE THEY ARE LARGE. Probing it
        # with 8 exercised only the low-halfword path, so `mov x2, #INBUF_SZ`
        # -- 0x4000000 -- reported ok while the assembler silently encoded
        # `mov x2, #0`. Twenty-nine lines, found by the self-host gate rather
        # than by the tool whose job it was. Probe with the value the source
        # actually uses.
        "#%i": ["#8"], "#%e": ["#0x4000000"], "#%c": ["#65"], "%L": ["t"],
    }
    subs_s0 = {
        "%X": ["x0", "x1", "x2"], "%W": ["w0", "w1", "w2"],
        "#%i": ["8"], "#%e": ["67108864"], "#%c": ["65"], "%L": ["t"],
    }
    # AArch64 constrains some immediates: movz/movk shifts must be 0/16/32/48
    # and uxtw scales must be 0 or 2. A probe case GNU `as` rejects proves
    # nothing about stage0-as, so pick values the encoding actually allows.
    if mn == "svc":
        # stage0-as encodes `svc` as svc #0 unconditionally, and #0 is the only
        # form the source uses. Probing it with #8 made a correct assembler look
        # wrong -- a probe case that does not match real usage is a false
        # positive, and false positives in a measurement tool are expensive.
        sh_g = "#0"
    elif "lsl #%i" in sh and mn in ("movz", "movk"):
        sh_g = sh.replace("lsl #%i", "lsl #16")
    elif "uxtw #%i" in sh:
        sh_g = sh.replace("uxtw #%i", "uxtw #2")
    else:
        sh_g = sh
    gnu, s0 = sh_g, sh_g
    for key in ("#%c", "#%e", "#%i", "%X", "%W", "%L"):
        i = 0
        while key in gnu:
            gnu = gnu.replace(key, subs_gnu[key][min(i, len(subs_gnu[key]) - 1)], 1)
            s0 = s0.replace(key, subs_s0[key][min(i, len(subs_s0[key]) - 1)], 1)
            i += 1
    g = ("\t%s %s" % (mn, gnu)).rstrip()
    # .s0 syntax: no commas, no brackets, no '#'
    body = s0.replace(",", " ").replace("[", " ").replace("]", " ")
    body = body.replace("#", "")          # .s0 has no '#' -- it starts a comment
    body = re.sub(r"\s+", " ", body).strip()
    s0mn, s0body = to_s0(mn, body)
    if s0mn is None:
        return None
    return g, ("%s %s" % (s0mn, s0body)).rstrip()


def cmd_probes(path, outdir):
    forms, _ = census(path)
    os.makedirs(outdir, exist_ok=True)
    index = []
    for i, ((mn, sh), n) in enumerate(
            sorted(forms.items(), key=lambda kv: -kv[1])):
        pair = probe_pair(mn, sh)
        if pair is None:
            continue
        gnu, s0 = pair
        name = "f%03d" % i
        with open(os.path.join(outdir, name + ".s"), "w") as fh:
            # LABELS ARE ONE CHARACTER. stage0-as's symtab is 512 bytes -- 128
            # entries of 4, indexed by the label character's own byte value --
            # so `:tgt` defines label `t` and leaves a stray line `gt`. Every
            # probe carried that stray line for four runs and nobody noticed,
            # because the old assembler silently dropped unrecognised lines.
            # The rejection fix caught it on its first run. Use `t`.
            fh.write(".text\n.global _start\n_start:\n%s\nt:\n\tnop\n" % gnu)
        with open(os.path.join(outdir, name + ".s0"), "w") as fh:
            fh.write("%s\n:t\n" % s0)
        index.append("%s\t%d\t%s\t%s" % (name, n, mn, sh))
    with open(os.path.join(outdir, "index.tsv"), "w") as fh:
        fh.write("\n".join(index) + "\n")
    print("  wrote %d probe pairs to %s" % (len(index), outdir))
    print("  each is one instruction, in GNU-as text and in .s0 text;")
    print("  CI assembles both and byte-compares the .text.")
    return 0


# LABELS ARE ONE CHARACTER. stage0-as's symbol table is 512 bytes -- 128 entries
# of four -- indexed by the byte value of a single character, so `nbuf` is not a
# long label, it is the label `n` followed by the stray token `buf`, which is
# why the whole-file translation died on `rejected: nbuf`.
#
# The characters to avoid are the ones the parser reads as something else:
#   '@'  introduces an absolute numeric target
#   '#'  comment    ':'  label definition    '.'  directive
#   0-9  would be parsed as a number, whitespace ends a token
# Register letters are fine: a branch operand is never a register.
# Digits ARE usable: only `@` followed by a digit is a numeric target, so a bare
# digit in operand position is read as a label like any other character.
# TWO characters, over the printable range. A single character indexed a
# 128-entry table of which ~90 were usable, and this source defines 102 labels
# -- it had outgrown its own assembler. A pair gives 94*94 = 8836 slots.
# The first character avoids the ones the parser reads as something else:
#   '@' introduces a numeric target, '#' comment, ':' label definition,
#   '.' directive. The SECOND character is unconstrained: by then the parser is
# already committed to reading a label.
# Neither character may be one the operand normaliser rewrites: `,` `[` `]` are
# turned into spaces and `#` is deleted outright, so a label containing them
# would be silently mangled rather than rejected. The first character
# additionally avoids what the line parser dispatches on.
_STRIPPED = ",[]#"
_C1 = [chr(c) for c in range(0x21, 0x7f) if chr(c) not in _STRIPPED + "@:."]
_C2 = [chr(c) for c in range(0x21, 0x7f) if chr(c) not in _STRIPPED]
LABEL_CHARS = [a + b for a in _C1 for b in _C2]


def label_map(src):
    """Assign each distinct label a unique single character.

    Deterministic -- labels in order of first definition -- so the translation
    is reproducible and a diff between two runs means a real change. Fails
    loudly rather than reusing a character: two labels sharing a symtab slot
    would silently branch to the wrong place, which is far worse than not
    translating at all.
    """
    seen = []
    for raw in src:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*$", strip_comment(raw).strip())
        if m and m.group(1) not in seen:
            seen.append(m.group(1))
    if len(seen) > len(LABEL_CHARS):
        raise SystemExit(
            "  %d labels but only %d slots -- stage0-as cannot address them "
            "all.\n  Reduce labels or widen the symbol table."
            % (len(seen), len(LABEL_CHARS)))
    return dict(zip(seen, LABEL_CHARS))


def data_layout(src, n_instr):
    """Place the data symbols the code refers to, and say where each landed.

    stage0-as's own source names six things that are not code: three .ascii
    strings and three .bss reservations. In the as+ld build ld places them --
    .rodata in its own section, .bss on a page boundary. `elf` has no sections;
    it writes one flat image, so the translation has to do the placing.

    The layout is the simplest one that works: code, then the strings 8-aligned
    after it, then the zero-filled reservations after those. `elf` reserves
    65 MiB of demand-zero memory past the image, which is where the
    reservations live -- they occupy address space, not file bytes.

    Returns (offset by name, [(name, bytes)] for the strings that need emitting).
    """
    pos = n_instr * 4
    pos = (pos + 7) & ~7
    offs, blobs = {}, []
    for raw in src:
        t = strip_comment(raw).strip()
        m = re.match(r'^([A-Za-z_]\w*):\s*\.ascii\s+"(.*)"\s*$', t)
        if m:
            body = (m.group(2).replace("\\n", "\n").replace("\\t", "\t")
                    .replace("\\0", "\0").replace("\\\\", "\\"))
            offs[m.group(1)] = pos
            blobs.append((m.group(1), body.encode("utf-8")))
            pos += len(body)
    pos = (pos + 7) & ~7
    for raw in src:
        t = strip_comment(raw).strip()
        m = re.match(r"^([A-Za-z_]\w*):\s*\.space\s+(\S+)\s*$", t)
        if m:
            offs[m.group(1)] = pos
            n = m.group(2)
            pos += int(n, 16) if n.lower().startswith("0x") else (
                int(n) if n.isdigit() else 0)
    return offs, blobs


def cmd_xlate(path, out):
    """Mechanical GNU-as -> .s0 translation of the parts that translate.

    Untranslatable lines are emitted as `### NEEDS: <reason> | <original>` so
    the output is never silently wrong -- a translator that quietly drops a
    line it did not understand would produce an assembler with a hole in it.
    """
    src = list(open(path, encoding="utf-8"))
    equ = equ_table(src)
    lmap = label_map(src)
    n_instr = sum(1 for r in src if INSTR.match(strip_comment(r)))
    dmap, blobs = data_layout(src, n_instr)
    out_lines, need = [], Counter()
    for raw in src:
        ln = strip_comment(raw)
        if not ln.strip():
            continue
        s = ln.strip()
        if s.startswith((".text", ".global", ".align", ".balign", ".equ")):
            continue
        if s.startswith(".bss"):
            # No longer a gap. elf reserves 65 MiB of demand-zero memory past
            # the image, and data_layout has already assigned every reservation
            # an address in it -- .bss is a section marker with nothing to emit.
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*$", s)
        if m:
            out_lines.append(":%s" % lmap[m.group(1)])
            continue
        if s.startswith((".byte", ".ascii")):
            out_lines.append(s)
            continue
        # The data lines themselves are consumed by data_layout: their bytes are
        # appended below and their addresses are already substituted above.
        if re.match(r'^[A-Za-z_]\w*:\s*\.(ascii|space)\b', s):
            continue
        if s.startswith((".section", ".data")):
            continue
        m = INSTR.match(ln)
        if not m:
            need["unparsed line"] += 1
            out_lines.append("### NEEDS: unparsed | %s" % s)
            continue
        mn, ops = m.group(1), m.group(2)
        for name, val in equ.items():
            ops = re.sub(r"#%s\b" % re.escape(name), "#" + val, ops)
        ops = CHARLIT.sub(lambda mm: "#%d" % ord(
            {"\\n": "\n", "\\t": "\t", "\\0": "\0", "\\\\": "\\"}
            .get(mm.group(1), mm.group(1))), ops)
        # SHAPE THE SUBSTITUTED OPERANDS, NOT THE ORIGINAL. Computing it from
        # m.group(2) marked `mov x2, #INBUF_SZ` as unsupported even though the
        # .equ had just been expanded to a plain immediate.
        sh = shape(ops)
        if (mn, sh) not in DOCUMENTED:
            need["%-6s %s" % (mn, sh)] += 1
            out_lines.append("### NEEDS: %s %s | %s" % (mn, sh, s))
            continue
        # DATA SYMBOLS BECOME ABSOLUTE POSITIONS. `adr x19, inbuf` cannot use
        # the label table -- inbuf is not code and has no entry there. The `@`
        # form takes a byte position directly, which is exactly what the layout
        # above computed.
        for name in sorted(dmap, key=len, reverse=True):
            ops = re.sub(r"\b%s\b" % re.escape(name), "@%d" % dmap[name], ops)
        # HEX IN THE SOURCE, DECIMAL IN THE .s0. The source writes immediates as
        # lowercase hex because that is what makes the round-trip diff against
        # objdump clean; stage0-as's parse_dec reads decimal only. Passing
        # `0x0` through meant parse_dec consumed the `0`, stopped at the `x`,
        # and left `x0` behind to be read as the next line -- `rejected: x0`.
        # Two conventions set for different reasons, never checked against each
        # other. Converted BEFORE the label rewrite, so a label that happens to
        # be named `0x` is substituted afterwards and survives.
        ops = re.sub(r"\b0[xX]([0-9a-fA-F]+)\b",
                     lambda mm: str(int(mm.group(1), 16)), ops)
        # Rewrite label REFERENCES with the same map used for definitions, so
        # the two cannot drift. Longest-first, or `h_l` would be rewritten by
        # the rule for `h`.
        # The replacement goes through a function, not a template: a label like
        # `\x` is a valid two-character name and re.sub would read the
        # backslash as an escape and raise. Nothing in the map is ever
        # interpreted.
        for name in sorted(lmap, key=len, reverse=True):
            ops = re.sub(r"\b%s\b" % re.escape(name),
                         (lambda v: lambda mm: v)(lmap[name]), ops)
        body = ops.replace(",", " ").replace("[", " ").replace("]", " ")
        body = body.replace("#", "")
        body = re.sub(r"\s+", " ", body).strip()
        s0mn, s0body = to_s0(mn, body)
        if s0mn is None:
            need[s0body] += 1
            out_lines.append("### NEEDS: %s | %s" % (s0body, s))
            continue
        out_lines.append(("%s %s" % (s0mn, s0body)).rstrip())
    # Pad to the 8-byte boundary the layout assumed, then emit the strings.
    pad = ((n_instr * 4 + 7) & ~7) - n_instr * 4
    for _ in range(pad):
        out_lines.append(".byte 0")
    for name, b in blobs:
        for ch in b:
            out_lines.append(".byte %d" % ch)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out_lines) + "\n")
    done = sum(1 for x in out_lines if not x.startswith("###"))
    todo = sum(need.values())
    print("  wrote %s: %d lines translated, %d marked NEEDS" % (out, done, todo))
    print("  %d labels mapped to two-character names (%d slots available)"
          % (len(lmap), len(LABEL_CHARS)))
    if need:
        print("  what is still missing, by form:")
        for k, v in need.most_common():
            print("    %-46s %4d" % (k, v))
    return 0


def cmd_lint(path):
    """Reject an arithmetic immediate the encoding cannot hold.

    ADD/SUB/CMP/CMN take a 12-bit immediate, optionally shifted left by 12 --
    so 0x2000 encodes as 2<<12 and 0x2400 encodes as nothing at all. Reading
    the source that distinction is invisible, and it broke a build: three
    selector values were chosen to match some opcode bits and only two of them
    happened to be comparable.

    GNU as catches it, but only after a push and only for the first offender.
    This catches the whole class before one.
    """
    pat = re.compile(r"\s*(cmp|cmn|add|sub|adds|subs)\s+[wx]\d+,\s*"
                     r"(?:[wx]\d+,\s*)?#(0x[0-9a-fA-F]+|\d+)\s*$")
    bad = 0
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        m = pat.match(raw.split("//")[0])
        if not m:
            continue
        t = m.group(2)
        v = int(t, 16) if t.lower().startswith("0x") else int(t)
        if v > 0xFFF and (v & 0xFFF):
            print("  %s:%d: 0x%x fits neither imm12 nor imm12<<12 -- %s"
                  % (path, n, v, raw.split("//")[0].strip()))
            bad += 1
    if bad:
        print("  %d unencodable immediate(s)." % bad)
        return 1
    print("  arithmetic immediates: all encodable.")
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().split("\n\n")[1])
        return 2
    cmd = sys.argv[1]
    if cmd == "census":
        return cmd_census(sys.argv[2])
    if cmd == "probes":
        return cmd_probes(sys.argv[2], sys.argv[3])
    if cmd == "xlate":
        return cmd_xlate(sys.argv[2], sys.argv[3])
    if cmd == "lint":
        return cmd_lint(sys.argv[2])
    print("unknown command: %s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
