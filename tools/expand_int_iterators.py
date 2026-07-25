#!/usr/bin/env python3
"""Expand gcc 4.8's define_int_iterator / define_int_attr into plain patterns.

WHY THIS EXISTS
---------------
gcc 4.7 has no aarch64 backend; gcc 4.8 has one but requires a C++ compiler.
On aarch64 those are the same release, so the old-gcc/new-gcc ladder has no
rung. Moving 4.8's aarch64 backend into 4.7 closes that -- 4.7 is written in C
and yields a C++98 compiler (g++ 4.7) for free, which is exactly what 4.8 asks
for.

The transplant gets all the way to the generators. They then stop on:

    config/aarch64/iterators.md:664:
        unknown rtx code `define_int_iterator'

`define_int_iterator` and `define_int_attr` are machine-description constructs
ADDED IN 4.8. Everything else ports: configure succeeds, all six generators
build, and 264 objects compile with zero errors. The gap is the .md dialect,
not the backend's code.

WHY EXPAND RATHER THAN BACKPORT THE READER
------------------------------------------
4.7 already has the generic `iterator_group` abstraction (`modes`, `codes`), so
"add an `ints` group" looks like a handful of lines. It is not. 4.7 records
iterator uses with `struct map_value` and `htab_t`; 4.8 replaced that with

    static vec<mapping_ptr> current_iterators;
    static vec<iterator_use> iterator_uses;
    current_iterators.safe_push (iterator);
    FOR_EACH_VEC_ELT (attribute_uses, i, ause)

which is **C++**. Backporting it would drag the C++ boundary backwards into the
one release that does not need it -- defeating the entire reason for going to
4.7. Expanding the iterators instead touches only the backend we already vendor,
and produces output that can be diffed against its input.

WHAT EXPANSION MEANS
--------------------
    (define_int_iterator FMAXMINV [UNSPEC_FMAXV UNSPEC_FMINV])
    (define_int_attr fmaxminv [(UNSPEC_FMAXV "max") (UNSPEC_FMINV "min")])

    (define_insn "reduc_s<fmaxminv>_v4sf"
      [... (unspec:V4SF [...] FMAXMINV)] ...)

becomes two patterns, one per value, with the bare iterator token replaced by
the value and every <attr> replaced by that value's string:

    (define_insn "reduc_smax_v4sf"  ... UNSPEC_FMAXV ...)
    (define_insn "reduc_smin_v4sf"  ... UNSPEC_FMINV ...)

This is exactly what read-rtl.c does internally; doing it as a source-to-source
step is the same move `tools/drop_asm.py` makes for the stage-2 substitution:
a named, reviewable delta instead of a fork.

MODE AND CODE ITERATORS ARE LEFT ALONE -- 4.7 handles those natively.
"""

import argparse
import os
import re
import sys


# ---------------------------------------------------------------- parsing
def strip_comments(text):
    """Remove `;`-to-end-of-line comments, respecting string literals."""
    out, i, n, instr = [], 0, len(text), False
    while i < n:
        c = text[i]
        if instr:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                instr = False
        elif c == '"':
            instr = True; out.append(c)
        elif c == ';':
            while i < n and text[i] != '\n':
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)



def top_level_forms(text):
    """Yield (start, end) for every top-level (...) form.

    The .md files are not plain s-expressions. Three things break a naive
    scanner, and all three occur in aarch64's:

      * `;;` comments at top level that CONTAIN parens --
        `;;      a = (b < c) ? b : c;` starts a form that never closes.
        A first version of this stopped at 36% of aarch64-simd.md on it.
      * C strings with escaped quotes inside insn templates.
      * `{ ... }` C blocks holding arbitrary code, including parens in
        comments.
    """
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == ';':                      # comment to end of line
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c != '(':
            i += 1
            continue

        depth, j, instr, inbrace = 0, i, False, 0
        while j < n:
            c = text[j]
            if instr:
                if c == '\\':
                    j += 2
                    continue
                if c == '"':
                    instr = False
            elif inbrace:
                if c == '"':
                    instr = True
                elif c == '{':
                    inbrace += 1
                elif c == '}':
                    inbrace -= 1
            elif c == '"':
                instr = True
            elif c == '{':
                inbrace = 1
            elif c == ';':
                while j < n and text[j] != '\n':
                    j += 1
                continue
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    yield i, j + 1
                    i = j + 1
                    break
            j += 1
        else:
            raise SystemExit(f"unterminated form starting at offset {i}")


def load_definitions(path):
    """Return (iterators, attrs, spans) from a .md that defines them."""
    text = open(path).read()
    iterators, attrs, spans = {}, {}, []
    for a, b in top_level_forms(text):
        form = text[a:b]
        m = re.match(r'\(define_int_iterator\s+(\w+)\s*\[(.*?)\]\s*\)\s*$',
                     form, re.S)
        if m:
            iterators[m.group(1)] = m.group(2).split()
            spans.append((a, b))
            continue
        m = re.match(r'\(define_int_attr\s+(\w+)\s*\[(.*?)\]\s*\)\s*$',
                     form, re.S)
        if m:
            attrs[m.group(1)] = dict(
                re.findall(r'\((\w+)\s+"([^"]*)"\)', m.group(2)))
            spans.append((a, b))
    return text, iterators, attrs, spans


# -------------------------------------------------------------- expansion
def expand_form(form, iterators, attrs):
    """Return a list of expanded copies, or [form] if no int iterator is used."""
    used = [name for name in iterators
            if re.search(r'(?<![\w<])' + re.escape(name) + r'(?![\w>])', form)]
    if not used:
        return [form]
    if len(used) > 1:
        # gcc iterates same-group iterators in lockstep, not as a cross
        # product. aarch64 4.8.5 has no such pattern, so rather than guess at
        # semantics this refuses loudly.
        raise SystemExit(
            f"    form uses {len(used)} int iterators {used}; lockstep vs "
            f"cross-product semantics not implemented -- inspect by hand")

    name = used[0]
    out = []
    for value in iterators[name]:
        copy = re.sub(r'(?<![\w<])' + re.escape(name) + r'(?![\w>])',
                      value, form)
        for attr_name, table in attrs.items():
            if value in table:
                copy = copy.replace('<%s>' % attr_name, table[value])
        out.append(copy)
    return out


def process(path, iterators, attrs, strip_spans=None):
    text = open(path).read()
    pieces, last = [], 0
    n_expanded = n_copies = 0
    for a, b in top_level_forms(text):
        form = text[a:b]
        if strip_spans and (a, b) in strip_spans:
            pieces.append(text[last:a])
            pieces.append(';; [expand_int_iterators] definition removed: '
                          'consumed by expansion\n')
            last = b
            continue
        copies = expand_form(form, iterators, attrs)
        if len(copies) != 1 or copies[0] != form:
            pieces.append(text[last:a])
            pieces.append("\n".join(copies))
            last = b
            n_expanded += 1
            n_copies += len(copies)
    pieces.append(text[last:])
    return "".join(pieces), n_expanded, n_copies


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('mddir', help='gcc/config/<arch> directory to rewrite in place')
    ap.add_argument('--defs', default='iterators.md',
                    help='file defining the int iterators (default: iterators.md)')
    ap.add_argument('--check', action='store_true',
                    help='do not write; only report what would change')
    args = ap.parse_args()

    defs_path = os.path.join(args.mddir, args.defs)
    if not os.path.exists(defs_path):
        sys.exit(f"no {defs_path}")

    _, iterators, attrs, spans = load_definitions(defs_path)
    print(f"  int iterators : {len(iterators)} "
          f"({sum(len(v) for v in iterators.values())} values)")
    print(f"  int attrs     : {len(attrs)}")
    if not iterators:
        print("  nothing to do")
        return

    total_forms = total_copies = 0
    for name in sorted(os.listdir(args.mddir)):
        if not name.endswith('.md'):
            continue
        path = os.path.join(args.mddir, name)
        strip = set(spans) if path == defs_path else None
        new, n_forms, n_copies = process(path, iterators, attrs, strip)
        if n_forms or strip:
            print(f"    {name:<20} {n_forms:>3} form(s) -> {n_copies:>3} pattern(s)")
            total_forms += n_forms
            total_copies += n_copies
            if not args.check:
                open(path, 'w').write(new)

    print(f"  expanded {total_forms} form(s) into {total_copies} pattern(s)")

    if not args.check:
        # Verify: nothing 4.7 cannot read may remain.
        bad = []
        for name in sorted(os.listdir(args.mddir)):
            if not name.endswith('.md'):
                continue
            # Strip `;` comments before checking. aarch64-simd.md documents
            # instruction naming in comments like `;; <su><r>h<addsub>.`, and
            # those references survive expansion by design -- 4.7's reader
            # never sees a comment. A leftover in CODE is fatal; a leftover in
            # a comment is cosmetic, and conflating them fails a correct run.
            t = strip_comments(open(os.path.join(args.mddir, name)).read())
            for it in iterators:
                if re.search(r'(?<![\w<])' + re.escape(it) + r'(?![\w>])', t):
                    bad.append(f"{name}: iterator {it} still present")
            for at in attrs:
                if '<%s>' % at in t:
                    bad.append(f"{name}: <{at}> still present")
            if 'define_int_iterator' in t or 'define_int_attr' in t:
                bad.append(f"{name}: a define_int_* survived")
        if bad:
            print("  VERIFY FAILED:")
            for b in bad[:20]:
                print(f"    {b}")
            sys.exit(1)
        print("  verified: no int iterator, int attr or define_int_* remains")


if __name__ == '__main__':
    main()
