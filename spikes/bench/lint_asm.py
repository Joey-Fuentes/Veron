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
    errs=[]; sec=".text"
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
        # MOV wide-immediate must be an imm16 shifted by 0/16/32/48
        m3 = re.match(r'^mov\s+([wx])\d+,\s*#(0x[0-9a-fA-F]+|\d+)\s*$', s)
        if m3:
            v=int(m3.group(2),0)
            if v >= 0x10000 and not any((v >> sh) << sh == v and (v >> sh) < 0x10000
                                        for sh in (0,16,32,48)):
                errs.append((n, f"MOV immediate not a shifted imm16: {s[:50]}"))
    return errs
bad=0
for p in sys.argv[1:]:
    e=lint(p)
    print(f"{'FAIL' if e else 'ok  '}  {p}")
    for n,msg in e: print(f"        line {n}: {msg}"); bad+=1
sys.exit(1 if bad else 0)
