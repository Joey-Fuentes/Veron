#!/usr/bin/env python3
"""
vstack.py -- find value-stack imbalance by READING stage 2's emitted assembly.

WHY. A one-slot-per-call drift in x9 is a STATIC property of the emitted code,
so it can be found without running anything. That matters because reaching the
fault costs a 97s qemu run plus a 7 GB trace, and only tells you where it landed
-- not which construct leaked.

THE CONTRACT (from stage2-mini-c.s1's own header):
  push  = `str xN x9` then `add x9 x9 8`
  pop   = `sub x9 x9 8` then `ldr xN x9`
  a call evaluates args L->R onto the value stack, `bl f`; the callee pops P
  params (reverse) into its frame; `return e` leaves ONE result on the stack.

So for a function with P parameters, walking from `:name` to each `ret`:
      net = (pushes - pops)  must equal  1 - P
i.e. it consumes its P arguments and leaves exactly one result. Every path
through the function must agree; if two `ret`s disagree, one of them leaks.

STATUS. Validated against the m76 phantom-parameter bug, which it finds exactly
(`main bl ap pushed=2 but ap pops 3`) with no execution. On LARGE functions the
path reconstruction is not yet faithful -- it follows edges into local labels
that are unreachable from entry, so modelled depths go negative and the arity
check must be suppressed there. Trust it on reducers; treat whole-compiler runs
as a lead to confirm, never as a verdict.

Usage:
    tools/vstack.py emitted.s1              # report every function
    tools/vstack.py emitted.s1 --bad        # only functions that violate
    tools/vstack.py emitted.s1 --params f=2 # override a param count

Reports are per-path, so an `if` whose arms disagree is visible even when the
fall-through path happens to be correct.
"""
import sys
import re
from collections import defaultdict

PUSH_ADD = 'add x9 x9 8'
POP_SUB = 'sub x9 x9 8'
LABEL = re.compile(r'^:([A-Za-z_]\w*)$')
BRANCH = re.compile(r'^b(?:\.\w+)?\s+(\S+)$')


def parse(path):
    """-> {func: [(index, line)]} in emission order, plus the flat listing."""
    lines = [l.strip() for l in open(path).read().split('\n')]
    funcs, cur = {}, None
    for i, l in enumerate(lines):
        m = LABEL.match(l)
        if m and not m.group(1).startswith('__') and not m.group(1).startswith('g_'):
            cur = m.group(1)
            funcs[cur] = []
            continue
        if cur is not None:
            funcs[cur].append((i, l))
    return funcs, lines


def arity(body):
    """Params = leading pops in the prologue, before any push."""
    p = 0
    for _, l in body[:60]:
        if l == POP_SUB:
            p += 1
        elif l == PUSH_ADD:
            break
    return p


def paths(body, limit=4000, ar=None, viol=None):
    """Walk the straight-line + branch structure, yielding (net, endkind).

    Local labels (__L…) inside a function are branch targets; we follow both
    the taken and not-taken edge of each conditional, bounded, and stop at
    `ret` or an unconditional branch out of the body.
    """
    idx = {}
    for k, (_, l) in enumerate(body):
        m = LABEL.match(l)
        if m:
            idx[m.group(1)] = k
    out = []
    seen = set()
    budget = 200000
    stack = [(0, 0, 0)]          # (pc, net, depth)
    while stack:
        pc, net, depth = stack.pop()
        if depth > limit:
            continue
        while pc < len(body):
            l = body[pc][1]
            key = (pc, net)
            if key in seen or len(seen) > budget:
                break
            seen.add(key)
            if l == PUSH_ADD:
                net += 1
            elif l == POP_SUB:
                net -= 1
            elif l == 'ret':
                out.append(net)
                break
            if l.startswith('bl ') and ar is not None:
                callee = l[3:].strip()
                p = ar.get(callee)
                if p is not None:
                    # THE CROSS-CHECK: the caller must have pushed at least as
                    # many arguments as the callee is about to pop. If it has
                    # not, the callee reads BELOW the arguments -- which is the
                    # one-extra-pop-per-call drift, seen statically.
                    # Only trust the check when the modelled depth is sane.
                    # A negative depth means the path walker reached here by an
                    # edge that is not reachable from entry -- large functions
                    # with many local labels reconstruct badly, so suppress
                    # rather than report a false mismatch.
                    if 0 <= net < p and viol is not None:
                        viol.append((body[pc][0] + 1, callee, net, p))
                    net = net - p + 1
            m = BRANCH.match(l)
            if m:
                tgt = m.group(1)
                if l.startswith('b.'):           # conditional: both edges
                    if tgt in idx:
                        stack.append((idx[tgt], net, depth + 1))
                    pc += 1
                    continue
                if tgt in idx:                   # unconditional, stays local
                    pc = idx[tgt]
                    continue
                break                            # tail-branch out of the body
            pc += 1
    return sorted(set(out))


def main(argv):
    if len(argv) < 2:
        sys.stdout.write(__doc__)
        return 2
    path = argv[1]
    only_bad = '--bad' in argv
    over = {}
    for a in argv:
        if a.startswith('--params'):
            for kv in a.split('=', 1)[1].split(','):
                k, v = kv.split('=') if '=' in kv else (kv, '0')
                over[k] = int(v)

    funcs, _ = parse(path)
    AR = {n: arity(b) for n, b in funcs.items()}
    VIOL = {}
    print(f"{path}: {len(funcs)} functions")
    print(f"  {'function':28} {'params':>6} {'net per path':>22}  verdict")
    bad = 0
    for name, body in funcs.items():
        # param count = leading pops in the prologue, before any push
        p = over.get(name, AR[name])
        nets = paths(body, ar=AR, viol=VIOL.setdefault(name, []))
        want = 1 - p
        ok = nets == [want]
        if not ok:
            bad += 1
        if only_bad and ok:
            continue
        verdict = 'ok' if ok else ('INCONSISTENT PATHS' if len(nets) > 1
                                   else f'net {nets} want [{want}]')
        print(f"  {name:28} {p:6} {str(nets):>22}  {verdict}")
    calls = [(f, v) for f, vs in VIOL.items() for v in vs]
    if calls:
        print(f"\n  ARITY MISMATCH -- caller pushed fewer args than callee pops:")
        for f, (line, callee, pushed, pops) in calls:
            print(f"    {f}:{line}  bl {callee}  pushed={pushed} but {callee} pops {pops}")
    else:
        print("\n  no caller/callee arity mismatch found")
    print(f"  {bad} function(s) inconsistent with 1-P")
    return 1 if (bad or calls) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
