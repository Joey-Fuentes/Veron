#!/usr/bin/env python3
"""
drop_asm.py -- emit a C file with every asm()-bodied function removed.

WHY. Stage 2 has no asm(). M2libc's per-arch bootstrap.c writes its syscall
wrappers as M1 mnemonics inside asm(), and our m53/m69 builtins already supply
those same syscalls with matching numbers and argument order. m71 handled this
by omitting the whole file, which worked because that pin split the arch file
(asm only) from a generic bootstrap.c (plain C).

At M2-Planet 1.13.1 there is no generic bootstrap.c: aarch64/linux/bootstrap.c
is the entire mini-libc -- fgetc, fputc, fputs, fwrite, open, fopen, close,
fclose, brk, malloc, strlen, memset, calloc, free, exit -- with asm() in only a
few of them. Omitting the file would throw away the plain-C functions we need.
So drop at FUNCTION granularity instead of file granularity.

The rule states itself: a function whose body contains asm() is removed and our
builtin stands in; everything else is compiled unpatched. A dropped name our
builtins do not supply appears immediately in the unresolved-symbol check, so a
wrong assumption fails loudly instead of silently resolving to zero.

All structural scanning happens on a masked copy in which comment and string
contents are blanked (length preserved), so a ';' or '{' inside a comment or a
string literal cannot confuse it. Output is sliced from the ORIGINAL text.

Usage:
    tools/drop_asm.py --list FILE      # report what would be dropped/kept
    tools/drop_asm.py FILE > out.c     # emit the patched source
"""
import sys
import re


def mask(text):
    """Copy of text with comment/string/char contents replaced by spaces.
    Newlines are preserved so line numbers and offsets still line up."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c in '"\'':
            q = c
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == q:
                    j += 1
                    break
                j += 1
            for k in range(i, min(j, n)):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


NAME = re.compile(r'([A-Za-z_]\w*)\s*\([^;{]*\)\s*$', re.S)


def functions(text):
    """Yield (start, end, name) for each top-level brace-delimited definition."""
    m = mask(text)
    n = len(m)
    i = 0
    prev_end = 0
    while i < n:
        if m[i] == '{':
            depth = 0
            j = i
            while j < n:
                if m[j] == '{':
                    depth += 1
                elif m[j] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            end = min(j + 1, n)
            # Declarator starts after the previous top-level terminator OR the
            # last blank line, whichever is later. The blank-line rule matters
            # for the first function in a file, where there is no preceding
            # ';' or '}' once comments are masked -- without it the licence
            # header gets swallowed along with the function.
            start = prev_end
            k = i
            while k > prev_end:
                if m[k] in ';}':
                    start = max(start, k + 1)
                    break
                k -= 1
            blank = m.rfind('\n\n', prev_end, i)
            if blank != -1:
                start = max(start, blank + 1)
            head = m[start:i].strip()
            mo = NAME.search(head)
            if mo:
                name = mo.group(1)
            elif head.startswith('enum') or ' enum' in head:
                name = '(enum block)'
            elif head.startswith('struct') or ' struct' in head:
                name = '(struct block)'
            else:
                name = '(non-function block)'
            yield (start, end, name)
            prev_end = end
            i = end
            continue
        i += 1


def main(argv):
    listing = '--list' in argv
    args = [a for a in argv[1:] if not a.startswith('--')]
    if not args:
        sys.stdout.write(__doc__)
        return 2
    text = open(args[0]).read()
    fns = list(functions(text))
    dropped, kept, cuts = [], [], []
    for start, end, name in fns:
        if 'asm(' in mask(text[start:end]) or 'asm(' in text[start:end]:
            dropped.append(name)
            cuts.append((start, end))
        else:
            kept.append(name)
    if listing:
        print("dropped (asm bodies -- our builtins must supply these):")
        for d in dropped:
            print("   ", d)
        print("kept (compiled unpatched):")
        for k in kept:
            print("   ", k)
        return 0
    out = []
    pos = 0
    for start, end in cuts:
        out.append(text[pos:start])
        # blank the body, preserving line count so diagnostics still line up
        out.append('\n' * text[start:end].count('\n'))
        pos = end
    out.append(text[pos:])
    sys.stdout.write(''.join(out))
    sys.stderr.write("drop_asm: dropped %d of %d functions: %s\n"
                     % (len(dropped), len(fns), ' '.join(dropped)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
