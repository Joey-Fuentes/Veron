#!/usr/bin/env python3
"""Re-validate the dev bench against CI-confirmed ground truth.

The bench (s0as.py + interp.py) is a *model* of stage0-as plus a small ARM64
interpreter. It is NOT authoritative — CI (real aarch64-linux-gnu-as + qemu) is.
This script pins the bench to results we have actually seen green in CI, so a
drift between the model and the real assembler is caught here.

RUN THIS whenever stage0-as changes (or the bench does). If any check fails, the
bench no longer matches reality and must be fixed before trusting it.

Known-good facts (all confirmed green in CI):
  - byte output for the subroutine + ALU op tests
  - exit codes for the runtime programs
  - stage 1 resolves multi-char labels consistently (the cmp-x/w bug is caught)
"""
import sys
from s0as import assemble
from interp import run, asm_run, OOBAccess

FAILS = []
def check(name, got, want):
    ok = got == want
    print(f"  [{'OK ' if ok else 'XX '}] {name:34} got={got!r} want={want!r}")
    if not ok: FAILS.append(name)

def hexb(text):
    b,_,_ = assemble(text); return b.hex()

print("== byte-level (vs real `as`, confirmed in CI) ==")
check("subroutines bl/ret/br/blr",
      hexb("bl f\nret\nbr x16\nblr x17\n:f\nret\n"),
      "04000094c0035fd600021fd620023fd6c0035fd6")
check("alu orr/and/lsl/lsr/asr/movk",
      hexb("orr x9 x9 x1\nand x9 x9 x1\nlsl x9 x0 x2\nlsr x9 x0 x2\nasr x1 x1 x2\nmovk x9 53888 16\n"),
      "290101aa2901018a0920c29a0924c29a2128c29a0950baf2")
# 64-bit ldr x/str x set the size bit (0xF9…); w-forms stay 32-bit (0xB9…).
check("ldr/str x 64-bit + w unchanged",
      hexb("ldr x0 x1\nstr x0 x1\nldr x5 x3\nldr w0 x1\nstr w0 x1\n"),
      "200040f9200000f9650040f9200040b9200000b9")

print("== runtime exit codes (confirmed in CI) ==")
for name, prog, want in [
    ("loop -> 5",  "mov x0 0\nmov x1 5\n:a\nadd x0 x0 1\ncmp x0 x1\nb.ne a\nmov x8 93\nsvc\n", 5),
    ("mem  -> 7",  "mov x0 7\nadr x1 d\nmov x2 0\nstrb w0 x1 x2\nmov x0 0\nldrb w0 x1 x2\nmov x8 93\nsvc\n:d\n.byte 0\n", 7),
    ("call -> 7",  "mov x0 5\nbl a\nmov x8 93\nsvc\n:a\nadd x0 x0 2\nret\n", 7),
    ("shl  -> 8",  "mov x0 1\nmov x2 3\nlsl x0 x0 x2\nmov x8 93\nsvc\n", 8),
]:
    rc,_ = asm_run(prog); check(name, rc, want)

print("== stage0-as 64-bit ldr x / str x (call-stack enabler) ==")
# str x/ldr x must move all 64 bits. Each program builds a value whose HIGH word
# is nonzero, round-trips it through a memory slot, shifts the high word down, and
# exits it. A 32-bit store/load would drop the high word (exit 0), so a nonzero
# exit is a genuine end-to-end proof of 64-bit width.
_slot = "\n".join([":d"] + [".byte 0"]*8) + "\n"
_rt = ("mov x0 0\nmovk x0 7 32\nadr x1 d\nstr x0 x1\n"
       "mov x0 0\nldr x0 x1\nmov x2 32\nlsr x0 x0 x2\nmov x8 93\nsvc\n") + _slot
check("ldr x/str x round-trip 7<<32 -> 7", asm_run(_rt)[0], 7)
# control: the SAME shape with word str/ldr truncates the high word to 0
_wt = ("mov x0 0\nmovk x0 7 32\nadr x1 d\nstr w0 x1\n"
       "mov x0 0\nldr w0 x1\nmov x2 32\nlsr x0 x0 x2\nmov x8 93\nsvc\n") + _slot
check("word str/ldr truncates high word -> 0", asm_run(_wt)[0], 0)
# call-stack style: save a 64-bit frame value across a nested bl, then restore it
_cs = ("mov x0 0\nmovk x0 5 32\nmovk x0 3 0\nadr x19 d\nstr x0 x19\n"
       "mov x0 0\nbl f\nldr x0 x19\nmov x2 32\nlsr x0 x0 x2\nmov x8 93\nsvc\n"
       ":f\nmov x0 999\nret\n") + _slot
check("save/restore 64-bit across bl -> 5", asm_run(_cs)[0], 5)

print("== stage0-as numeric PC-relative branch  b/b.cond @<pos> ==")
# @<digits> assembles a branch to an absolute output byte-position; stage0-as
# computes the relative offset itself (no label). This is the enabler for stage-2
# branch-offset backpatching (removes the per-if/while label). It must encode
# BYTE-IDENTICALLY to the equivalent label branch, forward and backward.
for lab, num, note in [
    (":X\nmov x0 5\nb X\n",                 "mov x0 5\nb @0\n",                 "b backward"),
    ("b Y\nmov x0 5\n:Y\nmov x0 7\n",       "b @8\nmov x0 5\nmov x0 7\n",       "b forward"),
    ("b.eq Y\nmov x0 5\n:Y\nmov x0 7\n",    "b.eq @8\nmov x0 5\nmov x0 7\n",    "b.eq forward"),
    (":X\nmov x0 5\nmov x0 6\nb.ne X\n",    "mov x0 5\nmov x0 6\nb.ne @0\n",    "b.ne backward"),
]:
    lb,_,_ = assemble(lab); nb,_,_ = assemble(num)
    check(f"numeric @pos == label branch ({note})", nb.hex(), lb.hex())
# behavioural: a countdown loop wired entirely with numeric branches
_loop = ("mov x0 5\nmov x1 0\nsub x0 x0 1\nadd x1 x1 1\ncmp x0 0\nb.ne @8\n"
         "mov x0 x1\nmov x8 93\nsvc\n")
check("numeric-branch loop counts to 5", asm_run(_loop)[0], 5)
# the pool label '@' must STILL work (bare '@' is a label, only '@'+digit is numeric)
_at = "mov x0 0\nmov x1 5\n:@\nadd x0 x0 1\ncmp x0 x1\nb.ne @\nmov x8 93\nsvc\n"
check("pool label '@' still resolves (not numeric)", asm_run(_at)[0], 5)
# bl @<pos> too: the resolver rewrites 'bl <label>' (helper calls) to numeric, so
# stage0-as must encode bl @<pos> exactly like the label form (base 0x94000000).
for filler, note in ((0, "adjacent"), (40, "far")):
    pad = "".join("mov x0 0\n" for _ in range(filler // 4))
    lab = f"mov x0 0\n{pad}bl T\nmov x8 93\nsvc\n:T\nadd x0 x0 2\nret\n"
    lb, _, ll = assemble(lab); tp = ll['T']
    nb, _, _ = assemble(lab.replace("bl T", f"bl @{tp}"))
    check(f"numeric @pos bl == label bl ({note})", nb.hex(), lb.hex())
# behavioural: a call wired with a numeric bl returns and runs
_blp = "mov x0 5\nbl @16\nmov x8 93\nsvc\nmov x9 0\nadd x0 x0 2\nret\n"
check("numeric-bl call+return runs", asm_run(_blp)[0], 7)

print("== stage0-as numeric PC-relative adr  adr xR @<pos> ==")
# adr xR @<pos> computes a PC-relative address to an absolute output byte-position,
# exactly like the numeric branch. This lets stage 1 resolve adr-to-data references
# numerically (retiring the pool). @<pos> must be byte-identical to the label form.
for filler, note in ((0, "adjacent"), (40, "near"), (400, "far")):
    pad = "\n".join(["mov x0 0"] * (filler // 4))
    lab = f"mov x9 0\n{pad}\nadr x1 T\nldrb w0 x1 x9\nmov x8 93\nsvc\n:T\n.byte 7\n" if pad \
          else "mov x9 0\nadr x1 T\nldrb w0 x1 x9\nmov x8 93\nsvc\n:T\n.byte 7\n"
    lb, _, ll = assemble(lab); tp = ll['T']
    num = lab.replace("adr x1 T", f"adr x1 @{tp}")
    nb, npg, _ = assemble(num)
    check(f"numeric @pos adr == label adr ({note})", nb.hex(), lb.hex())
    check(f"numeric adr loads right data ({note})", run(npg)[0], 7)
# the pool label '@' must still work for adr too (bare '@' = label, '@'+digit = numeric)
_ata = "mov x9 0\nadr x1 @\nldrb w0 x1 x9\nmov x8 93\nsvc\n:@\n.byte 5\n"
check("adr to pool label '@' still resolves (not numeric)", run(assemble(_ata)[1])[0], 5)

print("== faithfulness guards (bench must model stage0-as's limits) ==")
# stage0-as labels are single-char: multi-char defs must be REJECTED
try:
    assemble(":multichar\n"); check("rejects multi-char label", "accepted", "rejected")
except ValueError:
    check("rejects multi-char label", "rejected", "rejected")
# stage0-as cmp reg-form is x-only: 'cmp w4 w5' must assemble as cmp-imm (#0),
# NOT as a register compare (this is the bug that bit stage 1).
_,prog,_ = assemble("cmp w4 w5\n")
check("cmp w4 w5 is NOT reg-compare", prog[0][0], "cmp_i")


print("== stage 1 handles large inputs (no read truncation) ==")
import os
s1p = os.path.join(os.path.dirname(__file__), "..", "stage1-as", "stage1-as.s0")
if os.path.exists(s1p):
    _,s1prog,_ = assemble(open(s1p).read())
    big = ("mov x0 0\n"*1200) + "mov x8 93\nsvc\n"  # ~10 KB input
    _,out = run(s1prog, stdin=big.encode())
    # resolved output should be about as long as input (not truncated to ~500)
    check("stage1 not truncating ~10KB input", len(out) > 9000, True)

print("== stage 1 is a NUMERIC label resolver (no pool, no ceiling) ==")
# stage 1 is now a two-pass resolver: it computes each label's assembled position
# and rewrites every branch/adr reference to a numeric @<pos>, DROPPING the ':label'
# definitions. Output is label-free, so stage-0-as's 128-symtab is never in the path
# and label count is bounded only by memory. Guard: an N-distinct-label program must
# resolve to LABEL-FREE output and assemble+run to the right exit code, for N well
# past the old 88-slot pool cap.
if os.path.exists(s1p):
    _, s1prog, _ = assemble(open(s1p).read())
    def _chain(n):                       # fall-through chain: exit code == n iff
        L = ["mov x0 0"]                 # every label resolved to the right offset
        for i in range(n):
            L += [f"b LBL{i:04}", f":LBL{i:04}", "add x0 x0 1"]
        return "\n".join(L + ["mov x8 93", "svc"]) + "\n"
    for n in (62, 88, 89, 150):          # 89+ was IMPOSSIBLE with the 88-slot pool (300+ verified too, slow in interp)
        _, res = run(s1prog, stdin=_chain(n).encode())
        out = res.decode()
        check(f"stage1 resolves {n} labels: output is label-free",
              any(l.strip().startswith(":") for l in out.split("\n")), False)
        rc, _ = run(assemble(out)[1])
        check(f"stage1 resolves {n} labels -> ladder exit {n & 0xFF}", rc, n & 0xFF)
    # references become numeric @<pos>
    _, res = run(s1prog, stdin=_chain(4).encode())
    check("stage1 emits numeric branch refs (b @<pos>)", "b @" in res.decode(), True)
    # adr-to-data resolves numerically too (uses the m31 numeric adr)
    _, res = run(s1prog, stdin="mov x9 0\nadr x1 dat\nldrb w0 x1 x9\nmov x8 93\nsvc\n:dat\n.byte 42\n".encode())
    out = res.decode()
    check("stage1 resolves adr-to-data numerically (adr @<pos>)", "adr x1 @" in out, True)
    check("stage1 numeric adr program runs", run(assemble(out)[1])[0], 42)
    # backward branch through a big-label program (way past the old pool)
    fill = "\n".join(f"b FWD{i:04}\n:FWD{i:04}" for i in range(120))
    loop = fill + "\nmov x0 0\nmov x1 5\n:LOOP\nadd x0 x0 1\ncmp x0 x1\nb.ne LOOP\nmov x8 93\nsvc\n"
    _, res = run(s1prog, stdin=loop.encode())
    rc, _ = run(assemble(res.decode())[1])
    check("stage1 backward branch through 120-label program -> 5", rc, 5)

print("== stage 1 resolves register-lookalike label/function names (m47) ==")
# Pass 2 is MNEMONIC-DRIVEN, not spelling-driven. It already knows the mnemonic, so:
#   b / bl / b.cond  -> the single operand is ALWAYS a label -> resolve it
#   adr xR name      -> slot 1 is ALWAYS a register (copied verbatim), slot 2 a label
#   br / blr         -> whole line passes through (register operand, never resolved)
# So a function/label name is resolved by POSITION regardless of how it is spelled --
# 'walk', 'w0helper', 'x9foo', even a label literally named 'x0' all resolve in a
# branch's label slot, while 'x0' in a register slot stays untouched. This is how a
# real assembler disambiguates (grammar + exact-match register set), and it means
# stage 2 / M2-Planet may use the full C identifier space for function names.
# (Pre-m47 the resolver sniffed the operand's first letters and misread any x/w-initial
# name as a register, emitting e.g. 'bl walk @000000' which stage0-as rejects.)
if os.path.exists(s1p):
    _, s1prog, _ = assemble(open(s1p).read())
    def _resolve(src):
        _, r = run(s1prog, stdin=src.encode()); return r.decode()
    def _rc(src):
        rc, _ = run(assemble(_resolve(src))[1]); return rc
    # register-lookalike function names must resolve to numeric refs and run.
    for nm, val in (("walk", 41), ("w0helper", 42), ("x9foo", 43), ("write", 44), ("w1", 45)):
        src = f"mov x0 0\nbl {nm}\nmov x8 93\nsvc\n:{nm}\nmov x0 {val}\nret\n"
        r = _resolve(src)
        check(f"stage1 resolves 'bl {nm}' (numeric, no unresolved 'bl {nm}')",
              ("bl @" in r) and (f"bl {nm}" not in r), True)
        check(f"stage1 '{nm}()' runs -> {val}", _rc(src), val)
    # a label literally named 'x0' still resolves in a branch's LABEL slot,
    # while 'x0' in a register slot (mov/adr-slot1) is untouched.
    x0src = "mov x0 0\nbl x0\nmov x8 93\nsvc\n:x0\nmov x0 17\nret\n"
    x0r = _resolve(x0src)
    check("stage1 'bl x0' resolves (label slot), not left literal", "bl x0" in x0r, False)
    check("stage1 'bl x0' -> numeric, runs -> 17", _rc(x0src), 17)
    # adr: register slot kept verbatim, label slot resolved -- even a register-lookalike
    # LABEL ('w0lbl') in the label slot resolves; the register 'x0' is untouched.
    adr = "mov x9 0\nadr x0 w0lbl\nldrb w1 x0 x9\nmov x0 x1\nmov x8 93\nsvc\n:w0lbl\n.byte 33\n"
    ar = _resolve(adr)
    check("stage1 adr keeps register x0 verbatim", "adr x0 " in ar, True)
    check("stage1 adr resolves register-lookalike label 'w0lbl'", "w0lbl" in ar, False)
    check("stage1 'adr x0 w0lbl' runs -> 33", _rc(adr), 33)
    # REGRESSION: plain data adr still resolves; blr register passes through untouched.
    dadr = "mov x9 0\nadr x1 dat\nldrb w0 x1 x9\nmov x8 93\nsvc\n:dat\n.byte 42\n"
    check("stage1 adr x1 dat still resolves+runs -> 42", _rc(dadr), 42)
    blrp = "mov x0 0\nadr x5 tgt\nblr x5\nmov x8 93\nsvc\n:tgt\nmov x0 3\nret\n"
    check("stage1 blr x5 passes through unchanged", "blr x5" in _resolve(blrp), True)

print("== stage 2 uses WORD variable slots (through the real assembled ladder) ==")
# Regression guard for the byte->word slot upgrade. Variables are 4-byte slots
# loaded/stored with word ldr/str (not ldrb/strb). NOTE: with only + - * and a
# mod-256 exit code, byte vs word storage is behaviourally INDISTINGUISHABLE by
# exit code (mod-256 is a +,-,* homomorphism), so this guard is STRUCTURAL:
# it checks the emitted instruction forms, plus exit codes for no regression.
s2p = os.path.join(os.path.dirname(__file__), "..", "stage2-mini-c", "stage2-mini-c.s1")
if os.path.exists(s1p) and os.path.exists(s2p):
    _, s1prog, _ = assemble(open(s1p).read())
    _, s2asm = run(s1prog, stdin=open(s2p).read().encode())     # resolve via REAL stage1
    _, s2prog, _ = assemble(s2asm.decode())
    def _emit(csrc):
        _, out = run(s2prog, stdin=csrc.encode()); return out.decode()
    def _exit(csrc):
        # A2 emits :func labels (calls/recursion) mixed with numeric @ if/while
        # branches, so the compiled program is resolved through the REAL stage1
        # before assembling: prog.c | stage2 | stage1 | stage0-as.
        _, resolved = run(s1prog, stdin=_emit(csrc).encode())
        rc, _ = run(assemble(resolved.decode())[1]); return rc
    em = _emit("int main(){int a=5;int b=a+2;return b;}")
    check("stage2 var load is 64-bit word (ldr x0 x1)",  "ldr x0 x1" in em, True)
    check("stage2 var store is 64-bit word (str x0 x1)", "str x0 x1" in em, True)
    check("stage2 value push is 64-bit (str x0 x9)", "str x0 x9" in em, True)
    check("stage2 value pop is 64-bit (ldr x0 x9)", "ldr x0 x9" in em, True)
    # Variables are word-sized and 4 bytes apart in the frame: var 'b' (index 1)
    # sits at offset 4 after 'a' (index 0). (The old labeled 4x.byte slot table is
    # gone — variables are frame-relative now; see the frame-relative section.)
    check("stage2 frame stride is 8 (a@0000, b@0008)",
          ("add x1 x10 0000" in em) and ("add x1 x10 0008" in em), True)
    for cs, want in [("int main(){int a=5;int b=a+2;return b;}", 7),
                     ("int main(){int a=10;return a*a;}", 100),
                     ("int main(){int x=7;return (x+1)*2;}", 16)]:
        check(f"stage2 exit {cs[:34]}", _exit(cs), want)

    print("== stage 2 control flow: if / while / reassignment ==")
    # A2: functions carry :name labels (resolved by stage1) and every program is
    # entered via 'bl main'. if/while control flow stays NUMERIC (backpatched
    # b.eq/b @<pos>), which stage1 passes through untouched. So a labelled entry
    # coexists with label-free intra-function branches.
    emif = _emit("int main(){int a=1;if(a){a=a+1;}return a;}")
    check("stage2 if emits zero-test",              "cmp x0 0" in emif, True)
    check("stage2 if skips on false (b.eq @)",      "b.eq @" in emif, True)
    check("stage2 program entered via bl main",     "bl main" in emif, True)
    check("stage2 main is a resolvable label (:main)", ":main" in emif, True)
    emwh = _emit("int main(){int a=3;while(a){a=a-1;}return a;}")
    check("stage2 while branches back (b @)",        "\nb @" in emwh, True)
    check("stage2 while exits on false (b.eq @)",    "b.eq @" in emwh, True)
    # the only labels are function definitions; the loop's own branches are numeric
    check("stage2 while loop branches are numeric (only :func labels)",
          [l for l in emwh.split("\n") if l.startswith(":")] == [":main"], True)
    # Behavioural: exit codes through the real assembled ladder. These DO exercise
    # loop counting + reassignment + nesting, so they are genuine end-to-end checks.
    for cs, want in [
        ("int main(){int n=10;int s=0;while(n){s=s+n;n=n-1;}return s;}", 55),
        ("int main(){int n=4;int f=1;while(n){f=f*n;n=n-1;}return f;}", 24),
        ("int main(){int a=5;a=a+3;return a;}", 8),
        ("int main(){int a=0;if(a){a=99;}return a+7;}", 7),
        ("int main(){int i=3;int t=0;while(i){int j=2;while(j){t=t+1;j=j-1;}i=i-1;}return t;}", 6),
        ("int main(){int a=1;int b=1;int r=0;if(a){if(b){r=5;}}return r;}", 5),
    ]:
        check(f"stage2 cf exit -> {want}", _exit(cs), want)

    print("== stage 2 relational operators: < > (unsigned-32, branchless) ==")
    # Structural: a<b emits the branchless sign-bit extract of (a-b); a>b of (b-a).
    # Unlike the arithmetic ops, comparisons ARE distinguishable by exit code, so
    # the behavioural checks below are the real test; these pin the codegen shape.
    emlt = _emit("int main(){int a=3;int b=5;return a<b;}")
    check("stage2 '<' subtracts a-b (sub x0 x1 x0)", "sub x0 x1 x0" in emlt, True)
    check("stage2 '<' extracts sign bit (mov x2 63)", "mov x2 63" in emlt, True)
    check("stage2 '<' logical shift (lsr x0 x0 x2)", "lsr x0 x0 x2" in emlt, True)
    emgt = _emit("int main(){int a=3;int b=5;return a>b;}")
    check("stage2 '>' subtracts b-a (sub x0 x0 x1)", "sub x0 x0 x1" in emgt, True)
    # Behavioural: exit codes through the real assembled ladder. Count-up loops,
    # relational guards, precedence, and 0/1 results feeding arithmetic.
    for cs, want in [
        ("int main(){int i=0;int s=0;while(i<10){s=s+i;i=i+1;}return s;}", 45),
        ("int main(){int i=1;int f=1;while(i<5){f=f*i;i=i+1;}return f;}", 24),
        ("int main(){int n=5;int s=0;while(n>0){s=s+n;n=n-1;}return s;}", 15),
        ("int main(){int a=3;int b=5;if(a<b){return 1;}return 0;}", 1),
        ("int main(){int a=5;int b=5;if(a<b){return 1;}return 0;}", 0),
        ("int main(){int a=7;int b=2;if(a>b){return 9;}return 0;}", 9),
        ("int main(){int a=3;int b=4;return (a<b)+(b<a);}", 1),
        ("int main(){return 2*2<3;}", 0),
        ("int main(){int i=0;int t=0;while(i<3){int j=0;while(j<2){t=t+1;j=j+1;}i=i+1;}return t;}", 6),
    ]:
        check(f"stage2 rel exit -> {want}", _exit(cs), want)

    print("== stage 2 equality / relational-eq: == != <= >= (unsigned-32, branchless) ==")
    # Structural: != is (d|-d)>>63 (an OR of a value and its negation); == is that
    # then flipped (1-x); <= is '>' flipped; >= is '<' flipped. The flip is the
    # tell-tale reversed-operand subtract 'sub x0 x2 x0'. All still branchless.
    emne = _emit("int main(){int a=3;int b=5;return a!=b;}")
    check("stage2 '!=' ORs d with -d (orr x0 x0 x2)", "orr x0 x0 x2" in emne, True)
    check("stage2 '!=' negates d (sub x2 x2 x0)",     "sub x2 x2 x0" in emne, True)
    check("stage2 '!=' has no flip (no sub x0 x2 x0)","sub x0 x2 x0" in emne, False)
    check("stage2 '!=' is branchless (no b.)",        "\nb." in emne,        False)
    emeq = _emit("int main(){int a=3;int b=5;return a==b;}")
    check("stage2 '==' reuses != then flips (sub x0 x2 x0)", "sub x0 x2 x0" in emeq, True)
    emle = _emit("int main(){int a=3;int b=5;return a<=b;}")
    check("stage2 '<=' is '>' (sub x0 x0 x1) flipped", ("sub x0 x0 x1" in emle) and ("sub x0 x2 x0" in emle), True)
    emge = _emit("int main(){int a=3;int b=5;return a>=b;}")
    check("stage2 '>=' is '<' (sub x0 x1 x0) flipped", ("sub x0 x1 x0" in emge) and ("sub x0 x2 x0" in emge), True)
    # Behavioural: exit codes through the real assembled ladder. Cover each op, the
    # == < >= precedence ordering, arithmetic feeding a comparison, and <=/>= loop guards.
    for cs, want in [
        ("int main(){int a=5;int b=5;return a==b;}", 1),
        ("int main(){int a=5;int b=6;return a==b;}", 0),
        ("int main(){int a=5;int b=6;return a!=b;}", 1),
        ("int main(){int a=5;int b=5;return a!=b;}", 0),
        ("int main(){int a=4;int b=5;return a<=b;}", 1),
        ("int main(){int a=6;int b=5;return a<=b;}", 0),
        ("int main(){int a=5;int b=5;return a>=b;}", 1),
        ("int main(){int a=4;int b=5;return a>=b;}", 0),
        ("int main(){return 2+3==5;}", 1),               # arithmetic binds tighter than ==
        ("int main(){int a=1;int b=2;int c=3;return a==b<c;}", 1),  # == below < : a==(b<c)
        ("int main(){int i=1;int s=0;while(i<=5){s=s+i;i=i+1;}return s;}", 15),
        ("int main(){int i=10;int s=0;while(i>=1){s=s+i;i=i-1;}return s;}", 55),
        ("int main(){int a=7;if(a==7){return 3;}return 9;}", 3),
        ("int main(){int a=7;if(a!=7){return 3;}return 9;}", 9),
        ("int main(){int a=8;int b=8;int c=0;if(a==b){if(a>=b){c=42;}}return c;}", 42),
    ]:
        check(f"stage2 eq exit -> {want}", _exit(cs), want)

    print("== stage 2 frame-relative variables (declaration-order slots) ==")
    # Variables live at x10+off in a per-call frame on the frame stack (x11). The
    # allocator is DECLARATION-ORDER now (params first, then locals): the i-th name
    # declared gets off=i*4, resolved by a live symbol table (multi-char names work).
    # The prologue opens the frame and points x10 past the 16-byte save area.
    emfr = _emit("int main(){int a=5;int b=7;return a+b;}")
    check("stage2 prologue opens frame base (add x10 x11 16)", "add x10 x11 16" in emfr, True)
    check("stage2 var access is frame-relative (add x1 x10)", "add x1 x10 " in emfr, True)
    check("stage2 no :a slot label", ":a\n" in emfr, False)
    check("stage2 no adr-to-var (adr x1 a)", "adr x1 a" in emfr, False)
    check("stage2 1st decl 'a' -> offset 0000", "add x1 x10 0000" in emfr, True)
    check("stage2 2nd decl 'b' -> offset 0008", "add x1 x10 0008" in emfr, True)
    # Declaration order, not name: a lone var (whatever its letter) is index 0 -> 000.
    emz = _emit("int main(){int z=25;return z*4;}")
    check("stage2 lone var 'z' -> offset 0000 (decl order, not c-'a')", "add x1 x10 0000" in emz, True)
    check("stage2 lone var 'z' has no 0100 offset (retired letter map)", "add x1 x10 0100" in emz, False)
    # multi-char names resolve by the symbol table, still declaration-order
    emmc = _emit("int main(){int count=6;int total=0;return count+total;}")
    check("stage2 multi-char 'count'@0000 'total'@0008", ("add x1 x10 0000" in emmc) and ("add x1 x10 0008" in emmc), True)
    # Every emitted program is entered via 'bl main' and carries a :main label.
    emcf = _emit("int main(){int a=1;if(a){a=a+1;}return a;}")
    check("stage2 entry is bl main + :main label", ("bl main" in emcf) and (":main" in emcf), True)
    # Behavioural: exit codes through the real assembled ladder. A program that
    # uses MANY distinct variables would have needed many labels before; now it
    # needs none. Plus the full existing behaviour set as a regression sweep.
    for cs, want in [
        ("int main(){int a=1;int b=2;int c=3;int d=4;int e=5;return a+b+c+d+e;}", 15),
        ("int main(){int z=9;int y=8;return z*y;}", 72),
        ("int main(){int z=25;return z*4;}", 100),
        ("int main(){int a=5;int b=a+2;return b;}", 7),
        ("int main(){int a=5;a=a+3;return a;}", 8),
        ("int main(){int n=10;int s=0;while(n){s=s+n;n=n-1;}return s;}", 55),
        ("int main(){int i=0;int s=0;while(i<10){s=s+i;i=i+1;}return s;}", 45),
        ("int main(){int i=1;int s=0;while(i<=5){s=s+i;i=i+1;}return s;}", 15),
        ("int main(){int a=8;int b=8;int c=0;if(a==b){if(a>=b){c=42;}}return c;}", 42),
        ("int main(){int i=0;int t=0;while(i<3){int j=0;while(j<=2){t=t+1;j=j+1;}i=i+1;}return t;}", 9),
    ]:
        check(f"stage2 frame-rel exit -> {want}", _exit(cs), want)

    print("== stage 2 backpatched control flow (numeric if/while, labelled funcs) ==")
    # if/while branches are emitted as numeric b.eq @<pos> / b @<pos>, backpatched
    # when the block closes; stage1 passes these through. Function boundaries DO use
    # labels (:name / bl name) which stage1 resolves. So the only labels an emitted
    # program contains are function names — never per-if/while or per-variable labels.
    emif = _emit("int main(){int a=0;if(a){return 7;}return 9;}")
    check("stage2 only-labels-are-funcs (:main)",
          [l for l in emif.split("\n") if l.startswith(":")] == [":main"], True)
    check("stage2 if uses numeric branch (b.eq @)", "b.eq @" in emif, True)
    check("stage2 no label-based branch (b.eq A)", "b.eq A" in emif, False)
    emwh = _emit("int main(){int i=0;int s=0;while(i<3){s=s+1;i=i+1;}return s;}")
    check("stage2 while uses backward numeric branch (b @)", "\nb @" in emwh, True)
    check("stage2 while's only label is :main (loop branches numeric)",
          [l for l in emwh.split("\n") if l.startswith(":")] == [":main"], True)
    # forward branch backpatched to the instruction AFTER the if-body (byte pos = idx*4)
    lines = [l for l in emif.split("\n") if l.strip()]
    br = next(l for l in lines if l.startswith("b.eq @"))
    tgt = int(br.split("@")[1])
    check("stage2 backpatch target is 4-aligned", tgt % 4, 0)
    check("stage2 backpatch target in range", 0 < tgt <= len(lines)*4, True)
    # behavioural: control flow through the real assembled ladder, incl. deep nesting,
    # if-in-while, sequential blocks, and a long loop that stresses the position counter.
    for cs, want in [
        ("int main(){int a=7;if(a==7){return 3;}return 9;}", 3),
        ("int main(){int a=7;if(a!=7){return 3;}return 9;}", 9),
        ("int main(){int i=0;int s=0;while(i<10){s=s+i;i=i+1;}return s;}", 45),
        ("int main(){int i=1;int s=0;while(i<=5){s=s+i;i=i+1;}return s;}", 15),
        ("int main(){int i=10;int s=0;while(i>=1){s=s+i;i=i-1;}return s;}", 55),
        ("int main(){int i=0;int t=0;while(i<3){int j=0;while(j<=2){t=t+1;j=j+1;}i=i+1;}return t;}", 9),
        ("int main(){int a=8;int b=8;int c=0;if(a==b){if(a>=b){c=42;}}return c;}", 42),
        ("int main(){int i=0;int s=0;while(i<10){if(i==5){s=s+100;}s=s+1;i=i+1;}return s;}", 110),
        ("int main(){int a=1;if(a){a=a+1;}if(a){a=a+1;}if(a){a=a+1;}return a;}", 4),
        ("int main(){int s=0;int i=0;while(i<3){s=s+1;i=i+1;}int j=0;while(j<4){s=s+1;j=j+1;}return s;}", 7),
        ("int main(){int i=0;int s=0;while(i<20){int j=0;while(j<i){s=s+1;j=j+1;}i=i+1;}return s;}", 190),
    ]:
        check(f"stage2 backpatch exit -> {want}", _exit(cs), want)

    print("== stage 2 is a 64-bit machine-word model (int == pointer width) ==")
    # A3 widens the value stack and frame slots to 64-bit words: push/pop use
    # str x/ldr x (8-byte), frame slots are 8 bytes apart, int is the full machine
    # word. This is the foundation the pointer/char/array work (A3b) needs. Small
    # values exit identically to the old 32-bit compiler, so the guard below is the
    # distinguisher: a product that overflows 32 bits then divides — 32-bit vs
    # 64-bit give different low bytes, so a correct exit proves the width.
    emw = _emit("int main(){int a=2000;return a*a*a/1000;}")
    check("stage2 push/pop are 64-bit (str x0 x9 / ldr x0 x9)",
          ("str x0 x9" in emw) and ("ldr x0 x9" in emw), True)
    check("stage2 no 32-bit value push (no str w0 x9)", "str w0 x9" in emw, False)
    for cs, want in [
        ("int main(){int a=2000;return a*a*a/1000;}", 0),      # 8e9/1000; 32-bit would give 200
        ("int main(){int a=3000;int b=3000;return a*b/7;}", (9000000 // 7) & 0xFF),
        ("int main(){int a=5;int b=7;return a+b;}", 12),        # small values unchanged
        ("int f(int n){if(n){return n*f(n-1);}return 1;} int main(){return f(5);}", 120),
    ]:
        check(f"stage2 word-model exit -> {want}", _exit(cs), want)

    print("== stage 2 unsigned division: / and % (udiv) ==")
    # '/' lowers to a single udiv; '%' to udiv;mul;sub (a - (a/b)*b). Both bind at
    # the multiplicative level (with '*'), left-associative. Unsigned-32, matching
    # the value stack; udiv is a NEW stage0-as instruction (0x9AC00800 family) — the
    # bench model encodes it and the demo byte-anchors it against real `as`.
    check("stage0-as encodes udiv x0 x1 x0 -> 9AC00820",
          assemble("udiv x0 x1 x0\n")[0].hex(), "2008c09a")
    emdiv = _emit("int main(){return 17/5;}")
    check("stage2 '/' emits udiv (udiv x0 x1 x0)", "udiv x0 x1 x0" in emdiv, True)
    emmod = _emit("int main(){return 17%5;}")
    check("stage2 '%' emits udiv;mul;sub", ("udiv x2 x1 x0" in emmod) and ("mul x2 x2 x0" in emmod) and ("sub x0 x1 x2" in emmod), True)
    for cs, want in [
        ("int main(){return 17/5;}", 3),
        ("int main(){return 17%5;}", 2),
        ("int main(){return 100/7;}", 14),
        ("int main(){return 100%7;}", 2),
        ("int main(){int a=84;int b=4;return a/b;}", 21),
        ("int main(){return 2+10/2;}", 7),               # * / bind above + -
        ("int main(){return 20/4/5;}", 1),               # left-associative
        ("int main(){return 3*4/2;}", 6),                # * and / same level
        ("int main(){return 17%5+1;}", 3),
        ("int main(){int n=20;int d=6;return n/d*d+n%d;}", 20),   # (n/d)*d + n%d == n
        ("int gcd(int a,int b){while(b){int t=a%b;a=b;b=t;}return a;} int main(){return gcd(48,36);}", 12),
        ("int main(){int x=9;return x/0;}", 0),          # aarch64: divide-by-zero -> 0
    ]:
        check(f"stage2 div exit -> {want}", _exit(cs), want)

    print("== stage 2 functions + call stack + recursion (A2) ==")
    # A2 adds real functions: the program is one-or-more int name(params){body};
    # a call f(a,b) is a primary in any expression. Emitted output carries :name /
    # bl name (resolved by stage1) plus a runtime calling convention: x9 value
    # stack, x10 frame base, x11 frame stack (frames nest -> recursion). Structural
    # checks pin the convention; behavioural checks run the whole ladder incl. stage1.
    emfn = _emit("int add(int a,int b){return a+b;} int main(){return add(2,3);}")
    check("stage2 defines :add function label",        ":add" in emfn, True)
    check("stage2 call emits bl add",                  "bl add" in emfn, True)
    check("stage2 prologue saves caller frame (str x10 x11)", "str x10 x11" in emfn, True)
    check("stage2 prologue saves return addr (str x30 x1)",   "str x30 x1" in emfn, True)
    check("stage2 opens a frame (add x11 x11)",        "add x11 x11 " in emfn, True)
    check("stage2 epilogue restores + returns (ldr x30 x1 .. ret)",
          ("ldr x30 x1" in emfn) and ("\nret\n" in emfn), True)
    check("stage2 pops args into param slots (str x0 x1 after ldr x0 x9)",
          "ldr x0 x9\nadd x1 x10 0008\nstr x0 x1" in emfn, True)
    # nested call as an argument -> two bl's, inner evaluated before outer's bl
    emnest = _emit("int f(int x){return x;} int main(){return f(f(3));}")
    check("stage2 nested call emits two bl f", emnest.count("bl f") == 2, True)
    # Behavioural: exit codes through prog.c | stage2 | stage1 | stage0-as.
    for cs, want in [
        ("int add(int a,int b){return a+b;} int main(){return add(2,3);}", 5),
        ("int sq(int x){int y=x*x;return y;} int main(){return sq(9);}", 81),
        ("int inc(int a){return a+1;} int dbl(int a){return a*2;} int main(){return dbl(inc(4));}", 10),
        ("int add(int a,int b){return a+b;} int main(){return add(add(1,2),add(3,4));}", 10),
        ("int f(int aa,int bb,int cc){return aa*100+bb*10+cc;} int main(){return f(1,2,3);}", 123),
        ("int f(int n){n=n+5;return n*2;} int main(){return f(10);}", 30),
    ]:
        check(f"stage2 fn exit -> {want}", _exit(cs), want)
    # Recursion: linear, tree, tail-with-accumulator, mutual, and Ackermann.
    for cs, want in [
        ("int fact(int n){if(n){return n*fact(n-1);}return 1;} int main(){return fact(5);}", 120),
        ("int sum(int n){if(n){return n+sum(n-1);}return 0;} int main(){return sum(10);}", 55),
        ("int fib(int n){if(n<2){return n;}return fib(n-1)+fib(n-2);} int main(){return fib(10);}", 55),
        ("int pw(int b,int e){if(e){return b*pw(b,e-1);}return 1;} int main(){return pw(2,7);}", 128),
        ("int tri(int n){int s=0;int i=1;while(i<=n){s=s+i;i=i+1;}return s;} int main(){return tri(10);}", 55),
        ("int ev(int n){if(n){return od(n-1);}return 1;}int od(int n){if(n){return ev(n-1);}return 0;}int main(){return ev(10);}", 1),
        ("int ack(int m,int n){if(m){if(n){return ack(m-1,ack(m,n-1));}return ack(m-1,1);}return n+1;} int main(){return ack(2,3);}", 9),
    ]:
        check(f"stage2 recursion exit -> {want}", _exit(cs), want)
    # multi-char names across params + locals (declaration-order symbol table)
    check("stage2 multi-char params/locals",
          _exit("int compute(int count,int step){int total=count*step;return total+count;} int main(){return compute(6,4);}"), 30)

    print("== stage 2 pointers: & (address-of), * (deref), *p = e (store-through) (A3b) ==")
    # A3b adds single-level pointers on the 64-bit word model: &name pushes a
    # variable's address (add x0 x10 off, no load), *name loads through a pointer
    # (ldr x1 x1 then ldr x0 x1), and *name = e stores through it. Unary * is
    # disambiguated from binary multiply by operand position, so a*b and *p coexist.
    emp = _emit("int main(){int x=5;int* p;p=&x;return *p;}")
    check("stage2 &name emits address-of (add x0 x10)", "add x0 x10" in emp, True)
    check("stage2 *name deref emits pointer load (ldr x1 x1)", "ldr x1 x1" in emp, True)
    emst = _emit("int main(){int x=0;int* p;p=&x;*p=42;return x;}")
    check("stage2 *p = e stores through pointer (str x0 x1 after ldr x1 x1)",
          "ldr x1 x1\nsub x9 x9 8\nldr x0 x9\nstr x0 x1" in emst, True)
    emmul = _emit("int main(){int a=3;int b=4;int* p;p=&a;return *p*b;}")
    check("stage2 unary * and binary * coexist (deref + mul both present)",
          ("ldr x1 x1" in emmul) and ("mul x0 x1 x0" in emmul), True)
    for cs, want in [
        ("int main(){int x=5;int* p;p=&x;return *p;}", 5),                              # deref
        ("int main(){int x=0;int* p;p=&x;*p=42;return x;}", 42),                         # store-through
        ("int main(){int x=3;int y=4;int* p;p=&x;*p=*p+y;return x;}", 7),                # read+write via ptr
        ("int set(int* q){*q=9;return 0;} int main(){int x=0;set(&x);return x;}", 9),    # pass-by-reference
        ("int swap(int* a,int* b){int t=*a;*a=*b;*b=t;return 0;} int main(){int x=3;int y=8;swap(&x,&y);return x*10+y;}", 83),
        ("int inc(int* q){*q=*q+1;return 0;} int main(){int c=41;inc(&c);inc(&c);return c;}", 43),
        ("int main(){int x=8;int* p;int* q;p=&x;q=p;*q=99;return x;}", 99),              # pointer copy
    ]:
        check(f"stage2 pointer exit -> {want}", _exit(cs), want)

    print("== stage 2 arrays: int a[N], subscript a[i] (rvalue+lvalue), decay (A3c) ==")
    # A3c adds int arrays on the word model. Frame slots become variable-size (an
    # int a[N] reserves N words, not 1), which forces the symbol table to store each
    # variable's frame offset explicitly rather than deriving it from its index.
    # a[i] scales the index by 8 (lsl x2 x2 x3) and loads/stores at base+i*8; a bare
    # array name decays to &a[0]; a[i] on a pointer loads the pointer first.
    ema = _emit("int main(){int a[3];int i;i=0;while(i<3){a[i]=i;i=i+1;}return a[2];}")
    check("stage2 subscript scales index by 8 (lsl x2 x2 x3)", "lsl x2 x2 x3" in ema, True)
    check("stage2 subscript adds scaled index to base (add x1 x1 x2)", "add x1 x1 x2" in ema, True)
    emd = _emit("int main(){int a[2];a[0]=7;int* p;p=a;return p[0];}")
    check("stage2 bare array name decays to address (add x0 x10)", "add x0 x10" in emd, True)
    for cs, want in [
        ("int main(){int a[3];a[0]=5;a[1]=7;return a[0]+a[1];}", 12),                    # store + load
        ("int main(){int a[5];int i;i=0;while(i<5){a[i]=i*i;i=i+1;}return a[3];}", 9),    # indexed loop
        ("int main(){int a[3];a[2]=99;int* p;p=a;return p[2];}", 99),                    # decay -> pointer subscript
        ("int main(){int a[3];a[0]=10;a[1]=20;a[2]=30;int* p;p=&a[1];return *p;}", 20),  # &a[i]
        ("int sum(int* p,int n){int s;int i;s=0;i=0;while(i<n){s=s+p[i];i=i+1;}return s;} int main(){int a[4];a[0]=1;a[1]=2;a[2]=3;a[3]=4;return sum(a,4);}", 10),
        ("int dot(int* a,int* b,int n){int s;int i;s=0;i=0;while(i<n){s=s+a[i]*b[i];i=i+1;}return s;} int main(){int x[3];int y[3];x[0]=1;x[1]=2;x[2]=3;y[0]=4;y[1]=5;y[2]=6;return dot(x,y,3);}", 32),
        ("int main(){int a[6];int i;i=0;while(i<6){a[i]=i;i=i+1;}return a[a[2]]+a[5];}", 7),  # nested subscript
    ]:
        check(f"stage2 array exit -> {want}", _exit(cs), want)

    print("== stage 2 char: byte access (ldrb/strb), char* / char[] , char literals (A3d) ==")
    # A3d adds `char`. A char scalar is word-stored like int (char promotes to int),
    # but a char* deref and a char[] subscript use BYTE access (ldrb/strb, no ×8
    # scale). char[N] is byte-packed (N bytes, 8-aligned). Because a small char[N]
    # rounds up to size 8 and collides with a scalar's size, the symbol table now
    # carries an explicit flags word (is_char, is_array) rather than inferring array
    # from size. Single-char literals 'x' tokenize to their ASCII value.
    emb = _emit("int main(){char s[4];char* p;p=s;s[0]=88;return p[0];}")
    check("stage2 char subscript loads a byte (ldrb w0 x1 x2)", "ldrb w0 x1 x2" in emb, True)
    ems = _emit("int main(){char s[4];s[0]=65;return s[0];}")
    check("stage2 char store is a byte (strb w0 x1 x2)", "strb w0 x1 x2" in ems, True)
    eml = _emit("int main(){char c;c='A';return c;}")
    check("stage2 char literal 'A' emits its value (mov x0 0065)", "mov x0 0065" in eml, True)
    for cs, want in [
        ("int main(){char c;c=65;return c;}", 65),                                        # char scalar (word)
        ("int main(){char c;c='A';return c;}", 65),                                       # char literal
        ("int main(){char s[4];s[0]=72;s[1]=105;return s[0]+s[1];}", 177),                # byte array
        ("int main(){char s[4];char* p;s[0]=88;p=s;return *p;}", 88),                     # char* deref (byte)
        ("int main(){char s[4];char* p;p=s;*p=90;return s[0];}", 90),                     # char* store-through
        ("int main(){char s[8];int i;i=0;while(i<8){s[i]=i+65;i=i+1;}return s[3];}", 68),  # byte fill loop
        ("int main(){char a[3];a[0]=250;a[1]=250;return a[0]+a[1];}", 244),               # byte value wrap
        ("int len(char* p){int n;n=0;while(p[n]){n=n+1;}return n;} int main(){char s[8];s[0]=97;s[1]=98;s[2]=99;s[3]=0;return len(s);}", 3),  # strlen via char* param
    ]:
        check(f"stage2 char exit -> {want}", _exit(cs), want)

    print("== stage 2 string literals + static data section (A4a) ==")
    # A4a adds a real static data section: the compiler now carries a second output
    # buffer, emitted AFTER all code, holding string-literal bytes under generated
    # labels (__dN) reached by `adr`. A "..." literal is a char* into that section,
    # so it flows straight into the byte-access machinery (p[i], strlen). This is
    # the same data-section infrastructure globals will reuse.
    emq = _emit('int main(){char* s;s="hi";return s[0];}')
    check("stage2 string literal takes its address (adr x0 __d)", "adr x0 __d" in emq, True)
    check("stage2 string literal emits a data section (:__d label)", ":__d" in emq, True)
    check("stage2 data section stores bytes (.byte)", ".byte" in emq.split(":__d",1)[1], True)
    for cs, want in [
        ('int main(){char* s;s="A";return s[0];}', 65),                                          # "A"[0]
        ('int main(){char* s;s="abc";return s[2];}', 99),                                         # "abc"[2]
        ('int main(){char* s;s="hi";char* t;t="yz";return s[0]+t[1];}', 226),                     # two literals
        ('int len(char* p){int n;n=0;while(p[n]){n=n+1;}return n;} int main(){return len("hello");}', 5),  # strlen literal via param
        ('int len(char* p){int n;n=0;while(p[n]){n=n+1;}return n;} int main(){return len("");}', 0),        # empty string
        ('int sum(char* p){int s;int i;s=0;i=0;while(p[i]){s=s+p[i];i=i+1;}return s;} int main(){return sum("AB");}', 131),  # 65+66
        ('int f(char* a,char* b){return a[0]+b[0];} int main(){return f("MN","XY");}', 165),       # two string args
    ]:
        check(f"stage2 string-literal exit -> {want}", _exit(cs), want)

    print("== stage 2 globals: file-scope variables in the data section (A4b) ==")
    # A4b adds global variables, reusing the A4a data section (named g_<name> labels
    # instead of anonymous __dN). Name resolution is frame-first, then globals; an
    # address is emitted as `add xN x10 off` for a local or `adr xN g_name` for a
    # global. Globals are shared across all functions — the thing M2-Planet's own
    # source leans on hardest. (.s1 supports uninitialised globals; initialise in code.)
    emg = _emit("int g; int main(){g=5;return g;}")
    check("stage2 global takes its address (adr x1 g_)", "adr x1 g_" in emg, True)
    check("stage2 global emits a data-section label (:g_)", ":g_" in emg, True)
    for cs, want in [
        ("int g; int main(){g=5;return g;}", 5),                                                              # global scalar
        ("int g; int set(){g=9;return 0;} int main(){set();return g;}", 9),                                    # shared across functions
        ("int a[3]; int main(){a[0]=4;a[1]=6;return a[0]+a[1];}", 10),                                         # global int array
        ("char buf[4]; int main(){buf[0]=65;buf[1]=66;return buf[0]+buf[1];}", 131),                          # global char array (byte)
        ("int counter; int inc(){counter=counter+1;return 0;} int main(){inc();inc();inc();return counter;}", 3),  # global counter
        ("int g; int main(){int* p; p=&g; *p=42; return g;}", 42),                                            # address-of global
        ("int total; int addto(int x){total=total+x;return 0;} int main(){addto(10);addto(20);addto(5);return total;}", 35),  # accumulate via global
    ]:
        check(f"stage2 global exit -> {want}", _exit(cs), want)

    print("== stage 2 operators: unary !/-/~ and bitwise &/| and shifts <<,>> (A5a) ==")
    # A5a rounds out the expression compiler. Unary prefix operators (! - ~) are pushed
    # as highest-precedence markers on the operator stack and applied by emitapply with a
    # pop-one/push-one codegen (u- = 0-x, u~ = -x-1, u! = (x==0)); binary bitwise & | and
    # shifts << >> map straight onto stage0-as and, orr, lsl, lsr. Binary & is disambiguated
    # from unary address-of by operand position (like * / deref). The old hand-coded
    # precedence ladder was replaced by a small `prec` table so all fifteen operators sit
    # at their correct C precedence levels (| < & < == < relational < shift < + < *).
    emu = _emit("int main(){int x;x=5;return -x;}")
    check("stage2 unary minus emits pop-one negate (sub x0 x2 x0)", "sub x0 x2 x0" in emu, True)
    emb = _emit("int main(){return 12&10;}")
    check("stage2 bitwise-and emits and x0 x1 x0", "and x0 x1 x0" in emb, True)
    ems = _emit("int main(){return 1<<4;}")
    check("stage2 left-shift emits lsl x0 x1 x0", "lsl x0 x1 x0" in ems, True)
    for cs, want in [
        ("int main(){int x;x=5;return -x+8;}", 3),        # unary minus binds tighter than +
        ("int main(){return !0;}", 1),                    # logical not
        ("int main(){return !5;}", 0),
        ("int main(){int x;x=0;return !!x;}", 0),          # double not
        ("int main(){return ~0;}", 255),                  # ~0 = -1 (low byte)
        ("int main(){return ~5;}", 250),
        ("int main(){return 12&10;}", 8),                 # bitwise and
        ("int main(){return 12|3;}", 15),                 # bitwise or
        ("int main(){return 1<<4;}", 16),                 # left shift
        ("int main(){return 64>>2;}", 16),                # right shift
        ("int main(){int a;a=6;return a&3|8;}", 10),       # (a&3)|8, & tighter than |
        ("int main(){int x;x=3;return -x*-2;}", 6),        # unary minus on both factors
        ("int main(){return !(3>5);}", 1),                # ! applied to a comparison
        ("int main(){return 2+3<<1;}", 10),               # (2+3)<<1, shift below additive
        ("int g;int main(){int* p;p=&g;*p=42;return g;}", 42),  # & still means address-of
        ("int main(){int i;int s;s=0;i=0;while(i<8){s=s|1<<i;i=i+1;}return s;}", 255),  # or/shift loop
    ]:
        check(f"stage2 operator exit -> {want}", _exit(cs), want)

    print("== stage 2 control flow: if / else (A6a) ==")
    # A6a adds the else clause. The then-block's closing brace peeks for `else`: if present,
    # it emits an unconditional branch to skip the else-body, retargets the if-condition
    # branch to the else-body start, and pushes an `else` block record (type 2) whose own
    # closing brace backpatches the skip branch. Nested and while-embedded else both work;
    # braces are required (same as if/while). No stage0-as change.
    eie = _emit("int main(){if(0){return 1;}else{return 2;}return 3;}")
    check("stage2 else emits a skip branch (b @) after the then-block",
          eie.count("b @") >= 1 and "b.eq @" in eie, True)
    for cs, want in [
        ("int main(){if(0){return 5;}else{return 7;}return 9;}", 7),
        ("int main(){if(1){return 5;}else{return 7;}return 9;}", 5),
        ("int max(int a,int b){if(a>b){return a;}else{return b;}} int main(){return max(3,8);}", 8),
        ("int max(int a,int b){if(a>b){return a;}else{return b;}} int main(){return max(9,2);}", 9),
        ("int sign(int x){if(x>0){return 1;}else{if(x<0){return 2;}else{return 0;}}} int main(){return sign(0)*100+sign(5)*10+sign(-3);}", 12),  # nested else
        ("int main(){int i; int s; s=0; i=0; while(i<5){if(i>2){s=s+i;}else{s=s+1;} i=i+1;} return s;}", 10),  # else inside while
    ]:
        check(f"stage2 if/else exit -> {want}", _exit(cs), want)

    print("== stage 2 large programs (enlarged input/output/stack buffers) ==")
    # The compiler's buffers were raised (input 64KB, output 256KB, bigger stacks),
    # so large programs no longer overflow the old ~4.4KB output buffer. Combined
    # with label-free codegen, control-flow count is now bounded only by memory.
    # A program with 150 sequential if-blocks emits ~65KB and must still run.
    def _many_ifs(n):
        return "int main(){int a=0;" + "".join("if(a<10000){a=a+1;}" for _ in range(n)) + "return a;}"
    big80 = _emit(_many_ifs(80))
    check("stage2 80-block program emits >30KB", len(big80) > 30000, True)
    check("stage2 80-block program: only label is :main (if-blocks numeric)",
          [l for l in big80.split("\n") if l.startswith(":")] == [":main"], True)
    for n in (20, 40, 80, 150):
        check(f"stage2 {n} sequential if-blocks -> exit {n & 0xFF}", _exit(_many_ifs(n)), n & 0xFF)
    # a long-running loop with a big body (stresses output size a different way)
    bigbody = "int main(){int s=0;int i=0;while(i<200){" + "s=s+1;"*20 + "i=i+1;}return s;}"
    check("stage2 big-body loop (200x20) -> 160", _exit(bigbody), 4000 & 0xFF)

    print("== stage 2 tokenizer (A1): keywords vs identifiers, whitespace ==")
    # A1 rebuilt the front end into ONE tokenizer (next_token) consumed by both the
    # statement loop and compile_expr, replacing the old 2nd-char statement dispatch
    # and the inline expression char-scanner. Keyword recognition is now a real
    # full-word match. Emitted bytes are UNCHANGED (this milestone is byte-identical
    # to the pre-A1 compiler), so these lock the tokenizer's behavior end-to-end:
    #  - a single-char var whose name starts like a keyword (i/w/r) must tokenize as
    #    an IDENTIFIER (reassignment), never as if/int/while/return;
    #  - arbitrary whitespace/newlines between tokens must not change the result.
    check("stage2 var 'w' is identifier not 'while'",  _exit("int main(){int w=1;w=w+4;return w;}"), 5)
    check("stage2 var 'r' is identifier not 'return'", _exit("int main(){int r=2;r=r*3;return r;}"), 6)
    check("stage2 var 'i' is identifier not 'if'/'int'", _exit("int main(){int i=9;i=i-1;return i;}"), 8)
    check("stage2 tokenizer ignores whitespace/newlines",
          _exit("int main(){\n  int a = 5 ;\n  int b = a + 2 ;\n  return b ;\n}"), 7)
    check("stage2 tokenizer: spaced keywords and parens",
          _exit("int main(){int n=3;int s=0;while ( n ) { s = s + n ; n = n - 1 ; } return s ;}"), 6)

    print("== stage 2 pointer-arithmetic scaling (A7a) ==")
    # A7a threads a per-operand TYPE through the expression compiler (a compile-time
    # type stack mirroring the runtime value stack). Symtab entries gained an is_ptr
    # flag (bit2 of the flags word), recorded at all three decl sites (globals/params/
    # locals). In `p + n` / `n + p` / `p - n`, the integer operand is now scaled by the
    # pointee size (8 for int*, 1 for char*) before the add/sub; `p - q` between two
    # pointers subtracts then divides by the element size. `p[n]` on a pointer already
    # scaled (m39), and this makes bare pointer arithmetic consistent with it.
    #
    # Structural: `int* p; p=p+2;` must emit the pointee scaling of the int operand
    # (x0) — `lsl x0 x0 x3` — which no other codegen shape emits (comparisons shift by
    # x2=63; subscripts scale x2, not x0). char* must NOT emit it (scale 1).
    eptr = _emit("int main(){int a[3];int* p;p=a;p=p+2;return *p;}")
    check("stage2 int* arithmetic scales the int operand (lsl x0 x0 x3)",
          "lsl x0 x0 x3" in eptr, True)
    echar = _emit("int main(){char s[3];char* p;p=s;p=p+2;return *p;}")
    check("stage2 char* arithmetic does NOT scale (no lsl x0 x0 x3)",
          "lsl x0 x0 x3" in echar, False)
    ediff = _emit("int main(){int a[4];int* p;int* q;p=a;q=a+3;return q-p;}")
    check("stage2 int* difference divides by element size (lsr x0 x0 x3)",
          "lsr x0 x0 x3" in ediff, True)
    # Behavioural: exit codes on the real assembled ladder. These are the cases that
    # were WRONG before scaling (p+1 added 1 byte, not sizeof(*p)).
    for cs, want in [
        ("int main(){int a[3];a[0]=10;a[1]=20;a[2]=30;int* p;p=a;p=p+2;return *p;}", 30),   # p+2 -> a[2]
        ("int main(){int a[3];a[0]=10;a[1]=20;a[2]=30;int* p;p=a;p=p+1;return *p;}", 20),   # p+1 -> a[1]
        ("int main(){int a[3];a[0]=10;a[1]=20;a[2]=30;int* p;p=a;p=2+p;return *p;}", 30),   # n+p commutes
        ("int main(){int a[3];a[0]=10;a[1]=20;a[2]=30;int* p;p=a;p=p+2;p=p-1;return *p;}", 20),  # p-1
        ("int main(){char s[3];s[0]=65;s[1]=66;s[2]=67;char* q;q=s;q=q+2;return *q;}", 67),  # char* scale 1
        ("int main(){int a[5];int* p;p=a;int* q;q=a;q=q+3;return q-p;}", 3),                 # int* diff -> 3
        ("int main(){char s[8];char* p;p=s;char* q;q=s;q=q+5;return q-p;}", 5),              # char* diff -> 5
        ("int main(){int a[4];a[0]=1;a[1]=2;a[2]=3;a[3]=4;int* p;p=a;int s;s=0;int i;i=0;while(i<4){s=s+*p;p=p+1;i=i+1;}return s;}", 10),  # walk+sum
        ("int slen(char* s){int n;n=0;while(*s){n=n+1;s=s+1;}return n;} int main(){return slen(\"hello\");}", 5),  # real strlen
        ("int g[3];int main(){g[0]=4;g[1]=9;g[2]=13;int* p;p=g;p=p+2;return *p;}", 13),      # global array
        ("int* gp;int a[3];int main(){a[0]=1;a[1]=2;a[2]=3;gp=a;gp=gp+1;return *gp;}", 2),    # global pointer
        ("int at(int* p,int i){p=p+i;return *p;} int main(){int a[4];a[0]=5;a[1]=6;a[2]=7;a[3]=8;return at(a,3);}", 8),  # pointer param
    ]:
        check(f"stage2 ptr-scaling exit -> {want}", _exit(cs), want)
    # Regression: plain integer arithmetic (both operands non-pointer) is unchanged —
    # no stray scaling — and a local decl whose initializer contains an operator still
    # stores correctly (the type stack must not clobber the store-offset register).
    for cs, want in [
        ("int main(){int a=5;int b=a+2;return b;}", 7),
        ("int gcd(int a,int b){while(b){int t=a%b;a=b;b=t;}return a;} int main(){return gcd(48,36);}", 12),
        ("int main(){return 3+4*2;}", 11),
        ("int main(){int x=100;x=x-58;return x;}", 42),
    ]:
        check(f"stage2 non-pointer arithmetic unaffected -> {want}", _exit(cs), want)

    # ---- structs (m46 / A8a): definitions in a struct table, sizeof(struct T),
    # value + pointer locals/params/globals, . and -> member get/set incl. chains ----
    # Structural: sizeof folds to the packed word size; a member access adds the field
    # byte offset to a base then word/byte loads/stores; struct field names live in the
    # struct table and are NEVER emitted as labels (only :func names are).
    emsz = _emit("struct P{int x;int y;};int main(){return sizeof(struct P);}")
    check("stage2 sizeof(struct P) folds to 16 (mov x0 0016)", "mov x0 0016" in emsz, True)
    emmm = _emit("struct P{int x;int y;};int main(){struct P p;p.x=3;p.y=5;return p.x;}")
    check("stage2 member add 1st-field offset (add x1 x1 0000)", "add x1 x1 0000" in emmm, True)
    check("stage2 member add 2nd-field offset (add x1 x1 0008)", "add x1 x1 0008" in emmm, True)
    check("stage2 struct field names are not labels (only :main)",
          [l for l in emmm.splitlines() if l.startswith(":")], [":main"])
    emar = _emit("struct N{int v;struct N* nx;};int main(){struct N a;struct N* q;q=&a;q->v=7;return q->v;}")
    check("stage2 -> derefs a pointer base (ldr x1 x1)", "ldr x1 x1" in emar, True)
    emgs = _emit("struct P{int x;int y;};struct P g;int main(){g.x=1;return g.x;}")
    check("stage2 struct global gets a :g_ data label", ":g_g" in emgs, True)
    # Behavioural: real assembled ladder (prog.c | stage2 | stage1 | stage0-as).
    for cs, want in [
        ("struct P{int x;int y;};int main(){return sizeof(struct P);}", 16),
        ("struct P{int x;int y;int z;};int main(){return sizeof(struct P);}", 24),
        ("struct C{char a;int b;};int main(){return sizeof(struct C);}", 16),
        ("struct P{int x;int y;int z;};int main(){int n;n=sizeof(struct P)/sizeof(int);return n;}", 3),
        ("struct P{int x;int y;};int main(){struct P p;p.x=7;p.y=9;return p.x+p.y;}", 16),
        ("struct C{char a;int b;};int main(){struct C c;c.a=65;c.b=100;return c.a+c.b;}", 165),
        ("struct P{int x;int y;};int main(){struct P p;p.x=5;p.y=p.x+10;return p.y;}", 15),
        ("struct P{int x;int y;};int main(){struct P p;struct P* q;q=&p;q->x=17;q->y=25;return p.x+p.y;}", 42),
        ("struct N{int v;struct N* nx;};int main(){struct N b;b.v=99;struct N a;a.nx=&b;return a.nx->v;}", 99),
        ("struct N{int v;struct N* nx;};int main(){struct N b;struct N a;a.nx=&b;a.nx->v=77;return b.v;}", 77),
        ("struct N{int v;struct N* nx;};int main(){struct N c;c.v=3;struct N b;b.nx=&c;struct N a;a.nx=&b;return a.nx->nx->v;}", 3),
        ("struct P{int x;int y;};int main(){struct P p;p.x=8;int* q;q=&p.x;return *q;}", 8),
        ("struct P{int x;int y;};int gv(struct P* p){return p->x+p->y;} int main(){struct P p;p.x=10;p.y=20;return gv(&p);}", 30),
        ("struct N{int v;struct N* nx;};int sm(struct N* p){int s;s=0;while(p){s=s+p->v;p=p->nx;}return s;} int main(){struct N c;c.v=3;c.nx=0;struct N b;b.v=2;b.nx=&c;struct N a;a.v=1;a.nx=&b;return sm(&a);}", 6),
        ("struct N{int v;struct N* nx;};int last(struct N* p){while(p->nx){p=p->nx;}return p->v;} int main(){struct N c;c.v=7;c.nx=0;struct N b;b.nx=&c;struct N a;a.nx=&b;return last(&a);}", 7),
        ("struct P{int x;int y;};struct P g;int main(){g.x=13;g.y=4;return g.x+g.y;}", 17),
        ("struct N{int v;struct N* nx;};struct N n;struct N* gp;int main(){n.v=42;gp=&n;return gp->v;}", 42),
        ("struct N{int v;struct N* nx;};struct N a;struct N b;int main(){b.v=5;a.v=10;a.nx=&b;return a.nx->v;}", 5),
    ]:
        check(f"stage2 struct exit -> {want}", _exit(cs), want)

    print("== stage 2 &member: address-of a struct field (m49 fix + m50 guard) ==")
    # m49 fixed a latent `.s1` bug: `&p.x` / `&p->f` used to leak the field name as a
    # stray primary (`adr x0 <field>`) instead of computing the member address, which
    # m45 scaling / m48 decay then turned into a WILD address. The bench interp used to
    # tolerate that address (read 0), so only real qemu witnessed the SIGSEGV. With the
    # m50 OOB trap the bench faults on it too, so the behavioural checks below are now
    # genuine witnesses — a regression raises OOBAccess here instead of a lucky read.
    # The correct shape: base -> x1, add the field's byte offset, push the address
    # (str x1 x9); NO `adr x0 <field>`, and NO index scaling on the address-of path.
    def _exit_amp(cs):                       # report a trap as a clean check value, not a traceback
        try: return _exit(cs)
        except OOBAccess as e: return f"OOB-FAULT({e})"
    emam = _emit("struct P{int x;int y;};int main(){struct P p;int* q;q=&p.y;return *q;}")
    check("stage2 &member adds the field byte offset (add x1 x1 0008)", "add x1 x1 0008" in emam, True)
    check("stage2 &member pushes the address (str x1 x9)",              "str x1 x9" in emam, True)
    check("stage2 &member does NOT leak the field as a primary (no adr x0 x)", "adr x0 x" in emam, False)
    check("stage2 &member does NOT scale the address (no lsl on this path)",    "lsl" in emam, False)
    for cs, want in [
        ("struct P{int x;int y;};int main(){struct P p;p.x=8;int* q;q=&p.x;return *q;}", 8),        # offset 0
        ("struct P{int x;int y;};int main(){struct P p;p.y=7;int* q;q=&p.y;return *q;}", 7),        # nonzero offset
        ("struct P{int x;int y;};int main(){struct P p;int* q;q=&p.x;*q=42;return p.x;}", 42),      # write through &member
        ("struct C{char a;int b;};int main(){struct C c;c.a=65;char* q;q=&c.a;return *q;}", 65),    # char member (ptype 1)
        ("struct P{int x;int y;};int main(){struct P p;p.y=9;struct P* r;r=&p;int* q;q=&r->y;return *q;}", 9),  # &(ptr->field)
    ]:
        check(f"stage2 &member exit -> {want}", _exit_amp(cs), want)

    print("== stage 2 function pointers: int (*f)(...), decay, call-through blr (m48) ==")
    # Three mechanisms, all exercised through the real assembled ladder:
    #   (1) declarator  int (*f)(...)  -> a one-word pointer variable (local/param/global)
    #   (2) a bare function name used as a value decays to its entry address (adr x0 <fn>)
    #   (3) f(args): a known function -> direct `bl f`; a fnptr variable -> `ldr x16 &f; blr x16`
    # The bl-vs-blr split keys off the symbol tables: a called name found by resolve is a
    # variable (fnptr) -> blr; a name absent from every table is a function -> direct bl.
    emfp = _emit("int inc(int n){return n+1;}"
                 "int main(){int (*fp)(int); fp = inc; return fp(41);}")
    check("stage2 fnptr decays a function name (adr x0 inc)", "adr x0 inc" in emfp, True)
    check("stage2 fnptr call loads the code address (ldr x16 x1)", "ldr x16 x1" in emfp, True)
    check("stage2 fnptr call branches through a register (blr x16)", "blr x16" in emfp, True)
    emap = _emit("int inc(int n){return n+1;}"
                 "int apply(int (*f)(int), int x){return f(x);}"
                 "int main(){return apply(inc, 41);}")
    check("stage2 direct call still uses bl (bl apply)", "bl apply" in emap, True)
    check("stage2 fnptr param is called through blr (blr x16)", "blr x16" in emap, True)
    check("stage2 fnptr argument decays (adr x0 inc)", "adr x0 inc" in emap, True)
    emfpg = _emit("int inc(int n){return n+1;}int (*gp)(int);"
                  "int main(){gp = inc; return gp(99);}")
    check("stage2 global fnptr gets a data label (:g_gp)", ":g_gp" in emfpg, True)
    check("stage2 global fnptr is called through blr (blr x16)", "blr x16" in emfpg, True)
    for cs, want in [
        ("int inc(int n){return n+1;}"
         "int main(){int (*fp)(int); fp = inc; return fp(41);}", 42),                 # local, 1 arg
        ("int inc(int n){return n+1;}"
         "int apply(int (*f)(int), int x){return f(x);}"
         "int main(){return apply(inc, 41);}", 42),                                    # param + decay arg
        ("int seven(){return 7;}"
         "int callit(int (*f)()){return f();}"
         "int main(){return callit(seven);}", 7),                                      # param, zero-arg call
        ("int add(int a, int b){return a+b;}"
         "int main(){int (*fp)(int,int); fp = add; return fp(30,12);}", 42),           # local, two args
        ("int inc(int n){return n+1;}int (*gp)(int);"
         "int main(){gp = inc; return gp(99);}", 100),                                 # global fnptr
        ("int add1(int n){return n+1;}int dbl(int n){return n*2;}"
         "int main(){int (*fp)(int); int acc; int i; acc=0; i=0;"
         "while(i<5){fp=add1; acc=fp(acc); fp=dbl; acc=fp(acc); i=i+1;} return acc;}", 62),  # loop dispatch
        ("int counter;"
         "int bump(){counter = counter + 1; return counter;}"
         "int twice(int (*f)()){f(); f(); return counter;}"
         "int main(){counter = 0; return twice(bump);}", 2),                           # fnptr param + global mutate
    ]:
        check(f"stage2 fnptr exit -> {want}", _exit(cs), want)

    # ---- stage 2: large integer literals (>= 2^16) via movz + movk halfwords ----
    # a bare `mov` is a 16-bit MOVZ, so a literal >= 65536 must be materialised as
    # `mov x0 <lo16>` + `movk x0 <hw> <shift>` per nonzero higher halfword. Before this
    # fix the compiler emitted a single `mov x0 <n>` whose immediate overflowed into
    # the shift/opcode bits on real hardware (the bench masked it by carrying the full
    # value in its decoded op); s0as now rejects an out-of-range mov, so the class is
    # caught, and these check the halfword lowering and the values it produces.
    print("== stage 2 large integer literals: movz + movk materialisation ==")
    embig = _emit("int main(){return 262143;}")
    check("stage2 large literal low half (mov x0 65535)", "mov x0 65535" in embig, True)
    check("stage2 large literal high half (movk x0 3 16)", "movk x0 3 16" in embig, True)
    check("stage2 262144 high half (movk x0 4 16)", "movk x0 4 16" in _emit("int main(){return 262144;}"), True)
    emsmall = _emit("int main(){return 999;}")
    check("stage2 small literal stays one mov (mov x0 999)", "mov x0 999" in emsmall, True)
    check("stage2 small literal emits no movk", "movk x0" in emsmall, False)
    for cs, want in [
        ("int main(){return 262143;}", 262143 & 255),
        ("int main(){return 262144;}", 262144 & 255),
        ("int main(){return 1000000;}", 1000000 & 255),
        ("int main(){return 70000 - 65536;}", (70000 - 65536) & 255),
        ("int main(){int a=100000; int b=3; return a*b/1000;}", (100000 * 3 // 1000) & 255),
        ("int main(){int* p=calloc(100000,8); p[99999]=42; return p[99999];}", 42),
    ]:
        check(f"stage2 large-literal exit -> {want}", _exit(cs), want)

    # ---- stage 2: heap — calloc / free (A10) ----------------------------------
    # calloc/free are compiled as direct `bl calloc` / `bl free`; a bump allocator
    # over a large anonymous `mmap` arena is appended ONCE at program end, but only
    # for the builtins actually used, and only when the user has not defined their
    # own. calloc rounds the request up to 8 bytes; the arena is MAP_ANONYMOUS so it
    # is kernel-zeroed and bump-only allocation never reuses memory, so every block
    # is pristine zero (no zero-fill loop needed). `mmap` (not `brk`) is used because
    # qemu-user's brk region is small, while an anonymous mapping of any size is fine.
    # free is a no-op for a batch compiler. The bump pointer __mp lives inline after
    # the routine (never executed). A user definition of calloc/free overrides it.
    print("== stage 2 heap: calloc / free bump allocator over brk (A10) ==")
    emcal = _emit("int main(){int* p=calloc(1,8); return 0;}")
    check("stage2 calloc emits a direct call (bl calloc)", "bl calloc" in emcal, True)
    check("stage2 calloc runtime routine is appended (:calloc)", ":calloc" in emcal, True)
    check("stage2 calloc maps the heap via mmap (mov x8 222)", "mov x8 222" in emcal, True)
    check("stage2 bump pointer is emitted inline (:__mp)", ":__mp" in emcal, True)
    check("stage2 unused free is NOT emitted (no :free)", ":free" in emcal, False)
    emfree = _emit("int main(){int* p=calloc(1,8); free(p); return 0;}")
    check("stage2 free runtime routine is appended (:free)", ":free" in emfree, True)
    emnoheap = _emit("int main(){int a=5; return a;}")
    check("stage2 heap runtime emitted ONLY when used (no :calloc)", ":calloc" in emnoheap, False)
    emovr = _emit("int calloc(int a,int b){return 77;} int main(){return calloc(1,2);}")
    check("stage2 user calloc overrides the builtin (one :calloc)", emovr.count(":calloc"), 1)
    check("stage2 overridden builtin steps aside (no :__mp)", ":__mp" in emovr, False)
    # behavioural exit codes: calloc returns distinct, zero-filled, 8-byte-rounded
    # blocks that persist and grow the break; free is a safe no-op. The linked-list
    # cases build nodes on the heap and traverse them through a helper that takes a
    # struct-pointer parameter — the shape M2-Planet uses for its token/AST lists.
    _P = "struct N{int v; struct N* nx;};"
    _AL = (" struct N* a=calloc(1,sizeof(struct N)); struct N* b=calloc(1,sizeof(struct N));"
           " struct N* c=calloc(1,sizeof(struct N)); a->v=1; a->nx=b; b->v=2; b->nx=c;"
           " c->v=3; c->nx=0;")
    for cs, want in [
        ("int main(){int* p=calloc(4,8); p[0]=10; p[1]=20; return p[0]+p[1];}", 30),      # words persist
        ("int main(){int* p=calloc(3,8); return p[0]+p[1]+p[2];}", 0),                     # zero-filled
        ("int main(){char* s=calloc(10,1); s[0]=65; s[1]=66; return s[0]+s[1];}", 131),    # char buffer
        ("int main(){int* a=calloc(2,8); int* b=calloc(2,8); a[0]=5; b[0]=7; return a[0]+b[0];}", 12),  # distinct blocks
        ("int main(){int* p=calloc(3,8); p[2]=55; return p[2];}", 55),                     # count*size
        ("int main(){int* p=calloc(1000,8); p[999]=123; return p[999];}", 123),            # large, far access
        ("int main(){char* b=calloc(65536,1); b[65535]=7; return b[65535];}", 7),          # 64KB buffer
        ("int main(){char* b=calloc(262144,1); b[262143]=9; return b[262143];}", 9),        # 256KB — beyond the old brk region
        ("struct T{int k; int t; struct T* nx;}; int main(){struct T* t=calloc(1,sizeof(struct T)); t->k=40; t->t=2; return t->k+t->t;}", 42),  # M2 idiom: struct* p=calloc(1,sizeof)
        ("int main(){int* p=calloc(2,8); p[0]=40; p[1]=2; int r=p[0]; int q=p[1]; return r+q;}", 42),  # decl-init from a heap read
        ("int main(){int* p=calloc(1,8); p[0]=9; int r=p[0]; free(p); return r;}", 9),     # free is a safe no-op
        ("int main(){int i=0; int last=0; while(i<50){int* p=calloc(1,8); p[0]=i+1; last=p[0]; i=i+1;} return last;}", 50),  # alloc in a loop
        (_P+"int sm(struct N* p){int s; s=0; while(p){s=s+p->v; p=p->nx;} return s;} int main(){"+_AL+" return sm(a);}", 6),   # heap list, sum via helper
        (_P+"int cnt(struct N* p){int n; n=0; while(p){n=n+1; p=p->nx;} return n;} int main(){"+_AL+" return cnt(a);}", 3),    # heap list, count via helper
        (_P+"int lst(struct N* p){while(p->nx){p=p->nx;} return p->v;} int main(){"+_AL+" return lst(a);}", 3),                # heap list, last via helper
        ("int calloc(int a, int b){return 77;} int main(){return calloc(1,2);}", 77),      # user override wins
    ]:
        check(f"stage2 heap exit -> {want}", _exit(cs), want)

    # ---- stage 2 file I/O: open / read / write / close / exit (A12) ----------
    # The last floor rung: a compiled program can read source bytes and write
    # assembly text. open/read/write/close/exit lower to direct `bl` calls, and
    # a thin syscall wrapper is appended ONCE at program end per used builtin,
    # unless the user defines their own (then the builtin steps aside). Each pops
    # its args off the value stack (last arg on top), loads x0..x3, `svc`s, and
    # pushes the kernel return value. Syscall numbers and the openat(AT_FDCWD)
    # shape match M2libc/aarch64 exactly, so real M2libc overrides them cleanly.
    # The interp models a tiny in-memory FS + fd table so the bench WITNESSES the
    # real behaviour (files created/read/written, missing-file open fails) rather
    # than being more capable than reality (the m50/m51 lesson).
    print("== stage 2 file I/O: open / read / write / close / exit (A12) ==")
    def _io(csrc, stdin=b'', files=None):
        # prog.c | stage2 | stage1 | stage0-as, then run against an in-memory FS
        _, resolved = run(s1prog, stdin=_emit(csrc).encode())
        prog = assemble(resolved.decode())[1]
        fs = {} if files is None else dict(files)
        rc, out = run(prog, stdin=stdin, files=fs)
        return rc, out, fs
    # structural: each builtin is a direct `bl`, appended once, with the right svc
    emio = _emit('int main(){char b[8];int fd;fd=open("f",0,0);read(fd,b,8);'
                 'write(1,b,8);close(fd);exit(0);return 0;}')
    check("stage2 open is a direct call (bl open)",  "bl open" in emio, True)
    check("stage2 read is a direct call (bl read)",  "bl read" in emio, True)
    check("stage2 write is a direct call (bl write)","bl write" in emio, True)
    check("stage2 close is a direct call (bl close)","bl close" in emio, True)
    check("stage2 exit is a direct call (bl exit)",  "bl exit" in emio, True)
    check("stage2 open routine appended (:open)",   ":open" in emio, True)
    check("stage2 open uses openat (mov x8 56)",    "mov x8 56" in emio, True)
    check("stage2 open sets AT_FDCWD (sub x0 x0 100)", "sub x0 x0 100" in emio, True)
    check("stage2 read uses __NR_read (mov x8 63)", "mov x8 63" in emio, True)
    check("stage2 write uses __NR_write (mov x8 64)","mov x8 64" in emio, True)
    check("stage2 close uses __NR_close (mov x8 57)","mov x8 57" in emio, True)
    check("stage2 exit uses __NR_exit (mov x8 93)", "mov x8 93" in emio, True)
    # only-when-used: an I/O-free program appends none of them
    emnio = _emit("int main(){int a=5; return a;}")
    for nm in ("open","read","write","close","exit"):
        check(f"stage2 I/O emitted ONLY when used (no :{nm})", f":{nm}" in emnio, False)
    # a program that uses only write appends only write
    emw = _emit('int main(){write(1,"x",1); return 0;}')
    check("stage2 lone write appends :write", ":write" in emw, True)
    check("stage2 lone write does NOT append :read", ":read" in emw, False)
    # user override: a user-defined write is used and the builtin steps aside
    emovw = _emit("int write(int a,int b,int c){return 9;} int main(){return write(1,2,3);}")
    check("stage2 user write overrides builtin (one :write)", emovw.count(":write"), 1)
    # behavioural (through the real assembled ladder, against an in-memory FS):
    rc, out, fs = _io('int main(){write(1,"HELLO",5); return 0;}')
    check("stage2 write(1,...) reaches stdout", out, b"HELLO")
    rc, out, fs = _io('int main(){int fd;char b[16];int n;fd=open("in",0,0);'
                      'n=read(fd,b,16);close(fd);return n;}', files={"in": b"12345"})
    check("stage2 read returns the byte count", rc, 5)
    fs0 = {"in": b"copy this text"}
    rc, out, fs = _io('int main(){int fd;char b[64];int n;fd=open("in",0,0);'
                      'n=read(fd,b,64);close(fd);fd=open("out",577,0);'
                      'write(fd,b,n);close(fd);return n;}', files=fs0)
    check("stage2 file copy exit = bytes copied", rc, 14)
    check("stage2 file copy produced the out file", fs.get("out"), b"copy this text")
    rc, out, fs = _io('int main(){exit(42); return 7;}')
    check("stage2 exit(42) builtin (overrides fallthrough)", rc, 42)
    rc, out, fs = _io('int main(){int fd;fd=open("missing",0,0);'
                      'if(fd<0){return 5;} return 0;}', files={})
    check("stage2 open of a missing file returns < 0", rc, 5)
    rc, out, fs = _io('int main(){int fd;char b[3];fd=open("in",0,0);read(fd,b,3);'
                      'close(fd);return b[0];}', files={"in": b"ABC"})
    check("stage2 read fills the buffer (b[0]=='A')", rc, 65)

if FAILS:
    print(f"\nFAILED: {FAILS}\nThe bench no longer matches CI ground truth — fix before trusting it.")
    sys.exit(1)
print("\nAll bench checks pass — model matches known CI results.")
