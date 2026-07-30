#!/usr/bin/env python3
"""Rewrite octal integer literals as decimal.

    octal_to_decimal.py <srcdir> <outdir> <file> [file ...]
    octal_to_decimal.py --list <srcdir> <outdir> <file> ...    report only

Runs in the AIRLOCK, like drop_asm.py and defines_to_enums.py. The box receives
the result through pins/ and never sees a python interpreter.

WHY. stage 2 does not implement octal. Its parseval checks for a leading `0x`
and otherwise reads the digits as decimal, so `0750` becomes 750 rather than
488. hex2.c:196 is

    if(0 != chmod(output_file, 0750))

and 750 as a mode is 0o1356 -- owner `--wx`, no read bit. hex2 linked gen1
correctly and then nothing could open it:

    /work/run.sh: line 9: can't open /out/gen1: Permission denied

WHY THIS ONE IS EXHAUSTIVE AND defines_to_enums IS NOT. A `#define` stage 2
cannot expand fails LOUDLY -- the name reaches stage 1 as an unresolved label
and the build stops. A misparsed octal literal fails SILENTLY: it is simply a
different number, and the program runs and does the wrong thing. So this tool
rewrites EVERY octal literal it finds and reports each one, rather than fixing
the one that happened to hurt. A tool that fixed `0750` alone would leave the
next one to be discovered by its consequences.

WHAT COUNTS AS ONE. A `0` followed by one or more octal digits, outside strings,
character literals and comments, and not part of a longer token. Plain `0` is
zero in any base and is left alone. `0x...` is hex, which stage 2 does handle.
A digit 8 or 9 after a leading zero is not a valid octal literal in C at all;
this REFUSES rather than guessing, because the two readings differ and picking
one silently is the failure being fixed.

Strings are masked before matching, so the `"01234567"` digit table in
hex2_linker.c is left exactly as it is -- which is the whole reason for masking
rather than a regex over raw text.
"""
import os
import re
import sys

OCTAL = re.compile(r'(?<![0-9A-Za-z_.])0[0-9]+[uUlL]*')


def mask(text):
    """Blank string bodies, char bodies and comments, preserving length."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            # NEWLINES SURVIVE MASKING. Blanking them too kept the byte offsets
            # right -- the rewrite was correct -- but every reported line number
            # after the first block comment was wrong, which made the report
            # point at a licence header.
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in text[i:j]))
            i = j
        elif c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c in '"\'':
            q = c
            out.append(q)
            i += 1
            while i < n:
                if text[i] == '\\' and i + 1 < n:
                    out.append('  ')
                    i += 2
                    continue
                if text[i] == q:
                    out.append(q)
                    i += 1
                    break
                out.append('\n' if text[i] == '\n' else ' ')
                i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def main():
    args = sys.argv[1:]
    list_only = False
    if args and args[0] == '--list':
        list_only, args = True, args[1:]
    if len(args) < 3:
        sys.stderr.write(__doc__)
        return 2
    root, outdir, files = args[0], args[1], args[2:]

    total, errors, report = 0, [], []
    for rel in files:
        try:
            text = open(os.path.join(root, rel), errors='replace').read()
        except OSError as e:
            sys.stderr.write("octal_to_decimal: %s: %s\n" % (rel, e))
            return 1

        masked = mask(text)
        edits = []
        for m in OCTAL.finditer(masked):
            lit = m.group(0)
            digits = lit.rstrip('uUlL')
            line = masked.count('\n', 0, m.start()) + 1
            if any(d in '89' for d in digits[1:]):
                errors.append("%s:%d  %s is not a valid octal literal"
                              % (rel, line, lit))
                continue
            val = int(digits, 8)
            edits.append((m.start(), m.end(), str(val)))
            report.append("%s:%d  %s -> %d" % (rel, line, lit, val))
            total += 1

        if not list_only:
            out = text
            for start, end, rep in reversed(edits):
                out = out[:start] + rep + out[end:]
            dest = os.path.join(outdir, rel)
            os.makedirs(os.path.dirname(dest) or '.', exist_ok=True)
            with open(dest, 'w') as f:
                f.write(out)

    for r in report:
        print("  " + r)
    if errors:
        sys.stderr.write("\noctal_to_decimal: REFUSING -- %d literal(s) this "
                         "tool must not guess at:\n" % len(errors))
        for e in errors:
            sys.stderr.write("    %s\n" % e)
        return 1
    print("  %d octal literal(s) rewritten across %d file(s)" % (total, len(files)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
