#!/usr/bin/env python3
"""Adapt gcc 4.8 middle-end API calls in a backported backend to 4.7 signatures.

WHY
---
Moving 4.8's aarch64 backend into 4.7 gets remarkably far: config.gcc accepts
the target, all six generator programs build, the generators read the machine
description (after tools/expand_int_iterators.py handles the 4.8-only
constructs), and 264 objects compile. What is left is genuine middle-end API
drift, and the measurement is small -- ONE function:

    16 error: too many arguments to function 'plus_constant'

`plus_constant` gained a leading mode parameter in 4.8:

    4.7   extern rtx plus_constant (rtx, HOST_WIDE_INT);
    4.8   extern rtx plus_constant (enum machine_mode, rtx, HOST_WIDE_INT);

In 4.7 the mode is taken from the rtx operand, so the adaptation is to drop the
explicit mode. That is only correct when the mode passed equals the operand's
own mode -- which holds for every call here: 21 pass Pmode with a pointer-valued
rtx, and one passes `mode` alongside `reg` of that same mode. The tool prints
each first argument it removes so that assumption stays visible in review
rather than buried.

This is a NAMED, REVIEWABLE DELTA in the same spirit as tools/drop_asm.py and
tools/expand_int_iterators.py -- not a fork of upstream.

DESIGN
------
The table below is meant to grow. Each entry is one upstream signature change,
with the arity check that proves the rewrite applied to the right thing. If a
later run turns up another drifted call, add a row rather than a special case.
"""

import argparse
import os
import re
import sys


# Each rule is one upstream change. Three kinds, because 4.8 drifted in three
# directions: it ADDED a parameter, REMOVED one, and RENAMED a field.
#
#   drop   4.8 has an extra argument 4.7 does not take
#   add    4.8 removed an argument 4.7 still requires
#   rename a plain token spelling changed
RULES = [
    dict(kind="drop", name="plus_constant", argc=3, index=0,
         note="4.8 added a leading mode; 4.7 infers it from the rtx operand"),

    dict(kind="add", name="assign_stack_temp", argc=2, index=2, value="0",
         note="4.8 REMOVED the trailing `int keep`; 4.7 still requires it. "
              "0 means the slot may be reused after free_temp_slots(), which "
              "is the behaviour 4.8 made unconditional -- ASSUMPTION, and the "
              "single call site (building a vector in memory, immediately "
              "loaded) is the case where it is safe"),

    dict(kind="rename", name="crtl->is_leaf", to="current_function_is_leaf",
         note="4.8 moved the flag into struct rtl_data; 4.7 has it as a "
              "standalone variable"),
]


def split_args(text, start):
    """Given text[start] == '(', return (args, end_index_after_close).

    Splits on top-level commas only: nested calls, bracketed subscripts and
    string literals all contain commas that must not be treated as separators.
    """
    assert text[start] == '('
    depth, i, n = 0, start, len(text)
    args, cur, instr = [], [], False
    while i < n:
        c = text[i]
        if instr:
            cur.append(c)
            if c == '\\' and i + 1 < n:
                cur.append(text[i + 1]); i += 2; continue
            if c == '"':
                instr = False
        elif c == '"':
            instr = True; cur.append(c)
        elif c in '([{':
            depth += 1
            if depth > 1:
                cur.append(c)
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                args.append("".join(cur))
                return args, i + 1
            cur.append(c)
        elif c == ',' and depth == 1:
            args.append("".join(cur)); cur = []
        else:
            cur.append(c)
        i += 1
    raise SystemExit(f"unterminated argument list at offset {start}")


def apply_rename(text, frm, to, path, verbose):
    n = text.count(frm)
    if n and verbose:
        print(f"      {os.path.basename(path)}: {frm} -> {to} x{n}")
    return text.replace(frm, to), n


def apply_rule(text, name, argc_48, index, path, verbose, add_value=None):
    """Rewrite calls to `name` that carry the 4.8 argument count.

    add_value None  -> drop argument `index`
    add_value set   -> insert it at position `index`
    """
    out, i, n, count = [], 0, len(text), 0
    pat = re.compile(r'\b' + re.escape(name) + r'\b\s*\(')
    while True:
        m = pat.search(text, i)
        if not m:
            out.append(text[i:])
            break
        open_paren = m.end() - 1
        try:
            args, after = split_args(text, open_paren)
        except SystemExit:
            out.append(text[i:m.end()]); i = m.end(); continue

        if len(args) != argc_48:
            # Already 4.7-shaped, or something this rule does not describe.
            out.append(text[i:after]); i = after; continue

        if add_value is None:
            shown = args[index].strip().replace('\n', ' ')
            shown = re.sub(r'\s+', ' ', shown)
            kept = [a for k, a in enumerate(args) if k != index]
            verb = "dropped"
        else:
            kept = list(args)
            kept.insert(index, ' ' + add_value)
            shown = add_value
            verb = "added"
        # The dropped argument often sat alone on the first line, leaving the
        # next one starting with a newline: `plus_constant (\n   base_rtx,...`.
        # Valid C, but ugly in a source someone has to review. Pull it up.
        if kept and kept[0][:1] in '\n\r':
            kept[0] = kept[0].lstrip()
        if verbose:
            print(f"      {os.path.basename(path)}: {verb} `{shown}`")
        out.append(text[i:m.start()])
        out.append(name + " (" + ",".join(kept) + ")")
        i = after
        count += 1
    return "".join(out), count


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dir', help='backend directory to rewrite in place')
    ap.add_argument('--check', action='store_true', help='report only')
    ap.add_argument('-q', '--quiet', action='store_true')
    args = ap.parse_args()

    total = 0
    for rule in RULES:
        name = rule["name"]
        if rule["kind"] == "drop":
            print(f"  {name}: {rule['argc']} args -> {rule['argc']-1}")
        elif rule["kind"] == "add":
            print(f"  {name}: {rule['argc']} args -> {rule['argc']+1}")
        else:
            print(f"  {name} -> {rule['to']}")
        print(f"    {rule['note']}")
        n_this = 0
        for fn in sorted(os.listdir(args.dir)):
            if not fn.endswith(('.c', '.h', '.md')):
                continue
            path = os.path.join(args.dir, fn)
            text = open(path).read()
            if name not in text:
                continue
            if rule["kind"] == "rename":
                new, cnt = apply_rename(text, name, rule["to"], path,
                                        not args.quiet)
            else:
                new, cnt = apply_rule(
                    text, name, rule["argc"], rule["index"], path,
                    not args.quiet,
                    rule.get("value") if rule["kind"] == "add" else None)
            if cnt:
                print(f"    {fn:<20} {cnt} site(s)")
                n_this += cnt
                if not args.check:
                    open(path, 'w').write(new)
        print(f"    total: {n_this} site(s) adapted")
        total += n_this

    if not args.check:
        # Verify nothing 4.8-shaped survives.
        bad = []
        for rule in RULES:
            name = rule["name"]
            for fn in sorted(os.listdir(args.dir)):
                if not fn.endswith(('.c', '.h', '.md')):
                    continue
                text = open(os.path.join(args.dir, fn)).read()
                if rule["kind"] == "rename":
                    if name in text:
                        bad.append(f"{fn}: {name} still present")
                    continue
                for m in re.finditer(r'\b' + re.escape(name) + r'\b\s*\(', text):
                    try:
                        a, _ = split_args(text, m.end() - 1)
                    except SystemExit:
                        continue
                    if len(a) == rule["argc"]:
                        bad.append(f"{fn}: {name} still has {rule['argc']} args")
        if bad:
            print("  VERIFY FAILED:")
            for b in bad[:10]:
                print(f"    {b}")
            sys.exit(1)
        print(f"  verified: no call retains a 4.8-only signature ({total} adapted)")


if __name__ == '__main__':
    main()
