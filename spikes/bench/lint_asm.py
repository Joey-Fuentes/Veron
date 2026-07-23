#!/usr/bin/env python3
"""Lint the hand-written GNU-as sources (stage0-as, elf, hello, ...).

WHY THIS EXISTS.  The bench models *our* assembler (s0as.py models stage0-as's
own language).  It does NOT model GNU `as`, so every edit to a .s file that real
`as` assembles is completely unguarded until CI -- and this sandbox has no
aarch64 assembler to check against.  A pushed commit failed CI with

    Error: attempt to store non-empty string in section `.bss'

because a diagnostic string was placed next to the buffer it describes, which
lives in .bss (NOBITS -- it cannot hold initialised data).  Cheap, mechanical,
and exactly the class a lint catches.  Run it before pushing any .s change.
"""
import re, sys, os
def lint(path):
    errs=[]; sec=".text"; off={}; syms={}; adrs=[]; equ={}
    for n,line in enumerate(open(path), 1):
        s=line.split('//')[0].strip()
        if not s: continue
        m=re.match(r'^\.(text|data|bss|section\s+([\w.]+))\b', s)
        if m:
            sec = m.group(2) if m.group(2) else "."+m.group(1)
            continue
        # initialised data is illegal in NOBITS sections
        if sec in (".bss",) or sec.startswith(".bss"):
            if re.match(r'^\w*:?\s*\.(ascii|asciz|string|word|quad|hword|xword|4byte|8byte)\b', s):
                errs.append((n, f"initialised data in {sec}: {s[:50]}"))
            m2 = re.match(r'^\w*:?\s*\.byte\s+(.*)$', s)
            if m2 and any(v.strip() not in ('0','0x0') for v in m2.group(1).split(',')):
                errs.append((n, f"non-zero .byte in {sec}: {s[:50]}"))
        # ADR reaches only +-1 MiB. A large .space in a section pushes every
        # LATER symbol out of adr range -- and it links fine until the reserve
        # grows, so it fails only at scale. Track the running section offset and
        # flag any adr-referenced symbol beyond the limit.
        m4 = re.match(r'^(\w+):\s*\.(space|zero)\s+([\w+*x]+)', s)
        if m4:
            syms.setdefault(sec, []).append((m4.group(1), off.get(sec, 0), n))
            sz = equ.get(m4.group(3))
            if sz is None:
                try: sz = int(m4.group(3), 0)
                except ValueError: sz = 0
            off[sec] = off.get(sec, 0) + sz
        else:
            m5 = re.match(r'^(\w+):\s*$', s)
            if m5:
                syms.setdefault(sec, []).append((m5.group(1), off.get(sec, 0), n))
        m6 = re.match(r'^\.equ\s+(\w+),\s*(0x[0-9a-fA-F]+|\d+)', s)
        if m6:
            equ[m6.group(1)] = int(m6.group(2), 0)
        m7 = re.search(r'\badr\s+[wx]\d+,\s*(\w+)', s)
        if m7:
            adrs.append((m7.group(1), n))
        # MOV wide-immediate must be an imm16 shifted by 0/16/32/48
        m3 = re.match(r'^mov\s+([wx])\d+,\s*#(0x[0-9a-fA-F]+|\d+)\s*$', s)
        if m3:
            v=int(m3.group(2),0)
            if v >= 0x10000 and not any((v >> sh) << sh == v and (v >> sh) < 0x10000
                                        for sh in (0,16,32,48)):
                errs.append((n, f"MOV immediate not a shifted imm16: {s[:50]}"))
    # resolve adr targets against their section offsets
    where = {nm: (sc, o) for sc, lst in syms.items() for nm, o, _ln in lst}
    for nm, ln in adrs:
        if nm in where and where[nm][1] > (1 << 20):
            errs.append((ln, f"adr {nm} is {where[nm][1] >> 20} MiB into {where[nm][0]}"
                             f" -- beyond adr's +-1 MiB reach (move the big .space last)"))
    return errs
bad=0
for p in sys.argv[1:]:
    e=lint(p)
    print(f"{'FAIL' if e else 'ok  '}  {p}")
    for n,msg in e: print(f"        line {n}: {msg}"); bad+=1
sys.exit(1 if bad else 0)
