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
    check("stage2 if skips on false (b.eq __L)",     "b.eq __L" in emif, True)
    check("stage2 program entered via bl main",     "bl main" in emif, True)
    check("stage2 main is a resolvable label (:main)", ":main" in emif, True)
    emwh = _emit("int main(){int a=3;while(a){a=a-1;}return a;}")
    check("stage2 while branches back (b __L)",       "\nb __L" in emwh, True)
    check("stage2 while exits on false (b.eq __L)",   "b.eq __L" in emwh, True)
    # the only labels are function definitions; the loop's own branches are numeric
    check("stage2 while labels are compiler-generated (:main + :__L*)",
          all(l == ":main" or l.startswith(":__L")
              for l in emwh.split("\n") if l.startswith(":")), True)
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

    print("== stage 2 label-based control flow (A22 — backpatching retired) ==")
    # SUPERSEDES the m29 backpatched-numeric design. Backpatching existed for one
    # reason (TARGET-SUBSET floor item 2): stage0-as's 128-entry symtab capped a
    # program's labels, so stage 2 could not emit one per branch. m32 retired that
    # -- stage 1 became a two-pass NUMERIC RESOLVER, so label count is "bounded only
    # by memory" and the symtab is never in the path. m58's goto proved the
    # replacement end to end. So if/while/else and &&/|| now emit named labels
    # (:__L<id> / b.eq __L<id>) exactly as goto does, and the compiler never seeks
    # backwards -- which is what makes streaming output possible, and which deletes
    # the x17 absolute-position invariant (the m54 bug class) outright.
    emif = _emit("int main(){int a=0;if(a){return 7;}return 9;}")
    check("stage2 if branches to a named label (b.eq __L)", "b.eq __L" in emif, True)
    check("stage2 no numeric @ positions remain", "@" in emif, False)
    check("stage2 the if target is DEFINED in the program",
          any(l.startswith(":__L") for l in emif.split("\n")), True)
    emwh = _emit("int main(){int i=0;int s=0;while(i<3){s=s+1;i=i+1;}return s;}")
    check("stage2 while branches back to a named label", "\nb __L" in emwh, True)
    check("stage2 while defines both top and exit labels",
          len([l for l in emwh.split("\n") if l.startswith(":__L")]), 2)
    # every label a branch references must be defined exactly once, and every
    # definition must be referenced -- the property backpatching used to give by
    # construction, now checked directly.
    import re as _re
    for _src in ["int main(){int a=0;if(a){return 7;}return 9;}",
                 "int main(){int i=0;int s=0;while(i<3){s=s+1;i=i+1;}return s;}",
                 "int main(){int a=1;if(a){a=2;}else{a=3;}return a;}",
                 "int main(){int a=1;int b=0;if(a&&!b){return 5;}return 0;}"]:
        _o = _emit(_src)
        _defs = [l[1:] for l in _o.split("\n") if l.startswith(":__L")]
        _refs = _re.findall(r"\b(?:b|b\.eq|b\.ne)\s+(__L\d+)", _o)
        check("stage2 label defs are unique", len(_defs) == len(set(_defs)), True)
        check("stage2 every branch target is defined", set(_refs) <= set(_defs), True)
        check("stage2 every label is referenced", set(_defs) <= set(_refs), True)
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
    check("stage2 else emits a skip branch (b __L) after the then-block",
          eie.count("b __L") >= 1 and "b.eq __L" in eie, True)
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
    # A22: if-blocks are labelled now, so the assertion is that every label is
    # compiler-generated and self-consistent, not that there are none.
    check("stage2 80-block program: labels are :main + generated :__L*",
          all(l == ":main" or l.startswith(":__L")
              for l in big80.split("\n") if l.startswith(":")), True)
    check("stage2 80-block program: one label def per if-block",
          len([l for l in big80.split("\n") if l.startswith(":__L")]), 80)
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
                      'n=read(fd,b,64);close(fd);fd=open("out",577,420);'
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

    # ---------------------------------------------------------------- m54 / A13
    # x17 EMIT ACCOUNTING.  stage2 is single-pass: `if`/`while` targets are
    # ABSOLUTE `@<byte-pos>` values the compiler computes itself from x17, its
    # count of emitted instructions.  x17 is bumped once per '\n' seen by
    # emitstr, so the model is "every emitted line is exactly 4 bytes".  Any
    # emitted line that is NOT 4 bytes desynchronises x17 from the true
    # instruction count -- and because x17 is monotonic across the whole
    # program, the drift corrupts the @-targets of every function emitted
    # AFTERWARDS, not the function that caused it.
    #
    # The member-store templates smst2/smst2b used to carry a LEADING '\n'.
    # They are emitted after compile_expr, which already ends at a fresh line,
    # so each `p->f = v;` emitted a BLANK line: +1 to x17, 0 bytes assembled.
    # An append-shaped function (3 member stores) drifted 12 bytes, so the next
    # function's loop/branch targets landed 3 instructions past their intent.
    # Symptom: a later function silently returns 0/garbage, or -- when the
    # skipped target is a loop bound around an allocating call -- never
    # terminates.  Guard the invariant directly, not just its symptoms.
    print("== stage 2 x17 emit accounting: no 0-byte lines in code (A13) ==")
    import stage1_ref
    def _drift(csrc):
        """(#blank lines, x17-model bytes - real bytes) over the CODE region."""
        model = actual = blanks = 0
        _lines = _emit(csrc).split("\n")
        if _lines and _lines[-1] == "":
            _lines.pop()            # trailing newline of the last line, not a blank line
        for line in _lines:
            s = line.strip()
            if s.startswith(".byte") or s.startswith(".ascii"):
                break                       # data section: emitted after all code
            if s.startswith(":"):
                continue                    # labels are 0 bytes and bypass x17
            if s == "":
                blanks += 1; model += 4; continue
            model += 4; actual += stage1_ref._size(s)
        return blanks, model - actual

    _S = "struct N{int v;int w;struct N* nx;};struct N* HEAD;struct N* TAIL;"
    _APPEND = (_S + "int append(int v){struct N* n=calloc(1,sizeof(struct N));"
               "n->v=v;n->nx=0;if(HEAD==0){HEAD=n;TAIL=n;}"
               "else{TAIL->nx=n;TAIL=n;}return 0;}")
    for nm, cs in [
        ("member store",   _S + "int f(struct N* n){n->v=5;return 0;}int main(){return 0;}"),
        ("member store x3",_S + "int f(struct N* n){n->v=1;n->w=2;n->nx=0;return 0;}int main(){return 0;}"),
        ("chained store",  _S + "int f(struct N* n){n->nx->v=7;return 0;}int main(){return 0;}"),
        ("byte store",     _S + "int f(char* p){p[0]=65;return 0;}int main(){return 0;}"),
        ("append shape",   _APPEND + "int main(){return 0;}"),
    ]:
        b, d = _drift(cs)
        check(f"stage2 no blank emitted line: {nm}", b, 0)
        check(f"stage2 x17 == real instr count: {nm}", d, 0)

    # Behavioural: definition ORDER must not change a function's meaning.  Each
    # victim returns 3 alone; it must still return 3 when defined after append.
    # A mis-aimed @-target can send a loop back past its own increment, so the
    # compiled program never terminates -- report that as a value, don't let it
    # take down the whole validation run.
    def _exit_safe(csrc):
        try:
            return _exit(csrc)
        except RuntimeError as e:
            return f"<{e}>"
        except OOBAccess:
            return "<oob>"

    for nm, victim in [
        ("if/else", "int g(){int a;if(0){a=9;}else{a=3;}return a;}"),
        ("while",   "int g(){int i;int s;i=0;s=0;while(i<3){s=s+1;i=i+1;}return s;}"),
        ("nested",  "int g(){int i;int j;int c;i=0;c=0;while(i<3){j=0;"
                    "while(j<1){c=c+1;j=j+1;}i=i+1;}return c;}"),
    ]:
        check(f"stage2 victim after append still returns 3: {nm}",
              _exit_safe(_APPEND + victim + "int main(){return g();}"), 3)

    # The three-way shape that used to miscompile into a runaway: a recursive
    # emit path + a separator predicate + an allocating builder, all in one
    # program.  Each half was green alone; only the combination broke.
    _ISSEP = "int issep(int c){if(c==32){return 1;}if(c==44){return 1;}return 0;}"
    _EMITL = ("int emit_span(struct N* p,int n){if(p==0){return n;}"
              "if(issep(p->v)){return n;}p->w=n;return emit_span(p->nx,n+1);}"
              "int emit_list(struct N* p){if(p==0){return 0;}"
              "if(issep(p->v)){return emit_list(p->nx);}"
              "return emit_span(p,0)+emit_list(p->nx);}")
    _BUILD = "int build(int n){if(n==0){return 0;}append(65+n);return 1+build(n-1);}"
    _THREE = _S + _ISSEP + _EMITL + _BUILD + _APPEND[len(_S):]
    check("stage2 emit+issep+builder: builder count correct",
          _exit_safe(_THREE + "int main(){return build(3);}"), 3)
    check("stage2 emit+issep+builder: emit path correct",
          _exit_safe(_THREE + "int main(){build(3);return emit_list(HEAD);}"), 6)

    # ---- m55: comments, bare blocks, struct* returns, bounded global data ----
    # Four independent front-end gaps.  Each previously presented as a HANG or a
    # wild-address fault, so every check goes through _exit_safe.

    print("== stage 2 comment stripping (m55) ==")
    # The tokenizer had no comment rule, so '/' fell through to the operator
    # path and the comment body was lexed as source -- a wild address.
    for nm, cs, want in [
        ("block comment",      "int main(){/* hi */ return 7;}", 7),
        ("line comment",       "int main(){// hi\nreturn 7;}", 7),
        ("multi-line block",   "int main(){/* a\nb\nc */return 3;}", 3),
        ("stars inside block", "int main(){/** a ** b */return 4;}", 4),
        ("comment at top level","/* h */int f(){return 5;}// t\nint main(){return f();}", 5),
        ("comment then decl",  "int main(){/*x*/int i;i=6;return i;}", 6),
    ]:
        check(f"stage2 comment: {nm}", _exit_safe(cs), want)
    # '/' must still tokenize as division -- the comment rule only fires on // and /*.
    check("stage2 division still lexes (12/3)", _exit_safe("int main(){return 12/3;}"), 4)
    check("stage2 division no spaces (20/4)", _exit_safe("int main(){return 20/4;}"), 5)

    print("== stage 2 bare block statements (m55) ==")
    # if/while push a block record; a BARE '{' pushed none, so its '}' popped the
    # enclosing record -- or ended the function early -- and the program ran away.
    for nm, cs, want in [
        ("bare block",          "int main(){{return 7;}}", 7),
        ("block with decl",     "int main(){int i;i=0;while(i<3){i=i+1;}"
                                "{int fd;fd=7;return fd+i;}}", 10),
        ("double nested",       "int main(){{{return 9;}}}", 9),
        ("block then block",    "int main(){int a;{a=2;}{int b;b=3;return a+b;}}", 5),
        ("block inside while",  "int main(){int i;int s;i=0;s=0;"
                                "while(i<3){{s=s+1;}i=i+1;}return s;}", 3),
        ("block inside if",     "int main(){if(1){{return 8;}}return 4;}", 8),
        ("block inside else",   "int main(){if(0){return 1;}else{{return 6;}}}", 6),
    ]:
        check(f"stage2 bare block: {nm}", _exit_safe(cs), want)

    print("== stage 2 struct* return types (m55) ==")
    # 'struct T *f()' was routed to the GLOBAL-struct path, which skipped to the
    # first ';' (inside the body) and resumed top-level parsing mid-function.
    _T = "struct T{int v;struct T* nx;};"
    check("stage2 struct* fn: trivial body",
          _exit_safe(_T + "struct T* f(){return 0;}int main(){return 5;}"), 5)
    check("stage2 struct* fn: returns a real node",
          _exit_safe(_T + "struct T* mk(int v){struct T* n=calloc(1,sizeof(struct T));"
                     "n->v=v;n->nx=0;return n;}"
                     "int main(){struct T* p;p=mk(9);return p->v;}"), 9)
    check("stage2 struct* fn: pointer param passthrough",
          _exit_safe(_T + "struct T* id(struct T* p){return p;}"
                     "int main(){struct T* n=calloc(1,sizeof(struct T));n->v=7;"
                     "struct T* q;q=id(n);return q->v;}"), 7)
    check("stage2 struct* fn: chained through a list",
          _exit_safe(_T + "struct T* mk(int v){struct T* n=calloc(1,sizeof(struct T));"
                     "n->v=v;n->nx=0;return n;}"
                     "int main(){struct T* a;struct T* b;a=mk(4);b=mk(6);a->nx=b;"
                     "return a->nx->v;}"), 6)
    # REGRESSION: a genuine global struct pointer / value must still be a global.
    check("stage2 global struct* still a global",
          _exit_safe(_T + "struct T* HEAD;int main(){HEAD=0;return 4;}"), 4)
    check("stage2 global struct value still a global",
          _exit_safe(_T + "struct T G;int main(){G.v=6;return G.v;}"), 6)

    print("== stage 2 global data is bounded, not silently overrun (m55) ==")
    # Each global array byte emits '.byte 0\n' (8 chars) into a fixed data region.
    # Oversized globals used to store past the region -- clobbering the save area
    # and then brk.  It must now stop cleanly instead of corrupting memory.
    check("stage2 small global array still works",
          _exit_safe("char A[16];int main(){A[0]=65;return A[0];}"), 65)
    check("stage2 mid global array still works",
          _exit_safe("char A[1024];int main(){A[1000]=42;return A[1000];}"), 42)
    def _emit_safe(csrc):
        # The oversized case stops the COMPILER, so there is no program to run:
        # assert on the emitted output, never on an exit code.
        try:
            return _emit(csrc)
        except OOBAccess:
            return "<oob>"
        except RuntimeError as e:
            return f"<{e}>"
    _huge = "char A[8192];char B[16384];int main(){return 3;}"
    check("stage2 oversized globals do not fault", _emit_safe(_huge), "")
    check("stage2 oversized globals emit no partial code",
          len(_emit_safe(_huge)), 0)

    # x17 accounting must survive all four fixes: none of them may add an
    # emitted line, or bug class #2 (drifting @-targets) comes straight back.
    for nm, cs in [
        ("bare block",     _S + "int f(){int i;i=0;{int fd;fd=7;}return i;}int main(){return 0;}"),
        ("block in while", _S + "int f(){int i;i=0;while(i<3){{i=i+1;}}return i;}int main(){return 0;}"),
        ("comments",       _S + "int f(){/*a*/int i;// b\ni=0;return i;}int main(){return 0;}"),
        ("struct* fn",     _S + "struct N* mk(int v){struct N* n=calloc(1,sizeof(struct N));"
                                "n->v=v;return n;}int main(){return 0;}"),
    ]:
        b, d = _drift(cs)
        check(f"stage2 no blank emitted line: {nm}", b, 0)
        check(f"stage2 x17 == real instr count: {nm}", d, 0)


# ---------------------------------------------------------------------------
# m56 (A15) — self-host canary: a compiler-shaped program through the ladder.
#
# selfhost/canon.c reads a file, tokenizes it into a heap linked list of token
# records via a function-pointer classifier, walks that list recursively, and
# writes a file. Its canonical output (one token per line) is IDEMPOTENT, so
# re-running it over its own output must reproduce it byte for byte.
#
# This pins the canary on the bench. CI runs the same program through the real
# ladder; per AGENTS.md a green bench never overrides a red CI.
_canon = os.path.join(os.path.dirname(__file__), "..", "stage2-mini-c",
                      "selfhost", "canon.c")
if os.path.exists(s1p) and os.path.exists(s2p) and os.path.exists(_canon):
    print("\n== stage-2 self-host canary (m56/A15) ==")
    _csrc = open(_canon).read()
    _, _cres = run(s1prog, stdin=_emit(_csrc).encode())
    _cprog = assemble(_cres.decode())[1]

    def _canon_run(data):
        fs = {"in": bytes(data)}
        run(_cprog, files=fs, mem_size=0x800000)
        return fs.get("out", b"")

    # compiler-shaped: the emitted program must really use the hard features.
    _cem = _emit(_csrc)
    check("selfhost emits heap alloc (bl calloc)", "bl calloc" in _cem, True)
    check("selfhost emits indirect call (blr)",    "blr" in _cem, True)
    check("selfhost emits file I/O (bl open)",     "bl open" in _cem, True)
    check("selfhost emits recursive walk (:emit_list)", ":emit_list" in _cem, True)

    # behavioural: messy input -> one canonical token per line.
    _g1 = _canon_run(b"  int  main( ) {\n\t int   x =\t42 ;\n}\n")
    check("selfhost tokenizes to one token per line",
          _g1, b"int\nmain(\n)\n{\nint\nx\n=\n42\n;\n}\n")

    # the fixpoint: canon(canon(x)) == canon(x), byte for byte.
    check("selfhost fixpoint canon(canon(x))==canon(x)",
          _canon_run(_g1) == _g1, True)

    # and over its own source text, which is what makes it a self-host canary.
    _s1o = _canon_run(open(_canon, "rb").read())
    check("selfhost own-source token count",
          len(_s1o.split(b"\n")[:-1]), len(open(_canon, "rb").read().split()))
    check("selfhost fixpoint on own source",
          _canon_run(_s1o) == _s1o and len(_s1o) > 0, True)

    # scale: emit_list recurses once per token, so this is a depth-500 walk.
    _big = b" ".join(b"tok%d" % i for i in range(500))
    check("selfhost 500-token scale (recursion depth 500)",
          len(_canon_run(_big).split(b"\n")[:-1]), 500)

if os.path.exists(s1p) and os.path.exists(s2p):
    # -----------------------------------------------------------------------
    # m57 (A16) — short-circuit `&&`/`||`, hex literals, and `^`.
    #
    # SHORT-CIRCUIT is not an ordinary binary operator and cannot be emitted
    # like one.  A shunting-yard emits code when it POPS an operator, by which
    # point both operands are already on the value stack — too late to skip the
    # right one.  So `&&`/`||` emit at PUSH time instead: `cewhile` has already
    # applied every higher-precedence pending operator by the time it reaches
    # `cepushop`, so the left operand's value is final exactly there.  The
    # prologue pops it, pushes a provisional result (0 for `&&`, 1 for `||`),
    # and emits `b.eq`/`b.ne @<placeholder>`; the placeholder's buffer position
    # is recorded in a parallel array at x19+0x54000 INDEXED BY THE OPERATOR'S
    # OPSTACK SLOT.  That indexing is what makes it re-entrancy-safe for free:
    # opstack slots are unique per nesting level, so `f(a&&b, c||d)` and
    # `a && g(c||d)` need no save/restore.  `emitapply` sees the operator at
    # that same index, normalises the right operand to 0/1, and backpatches.
    #
    # Why this must be SHORT-CIRCUIT and not `and`/`orr` of both sides: M2-Planet
    # guards null derefs with it (`NULL != a && a->s`), so evaluating the right
    # operand is not merely wasteful, it FAULTS.  The witnesses below are
    # therefore behavioural, not structural — a side effect that must not happen,
    # and a null deref that must not be reached.  Since m50 the interp faults on
    # wild addresses like hardware, so the null-guard case is a real witness.
    print("\n== stage 2: short-circuit &&/||, hex literals, ^ (m57/A16) ==")

    # ---- eor: the stage-0 leaf `^` lowers onto (same shape as the udiv rung).
    # Derived from the ARM ARM and its ORR/AND siblings: logical shifted-register
    # differs only in opc, so AND=0x8A.., ORR=0xAA.., EOR=0xCA...  CI's byte-check
    # against real `as` is the ground truth that confirms it; this pins the model.
    check("eor x9 x9 x1 encodes as EOR-shifted-reg",
          hexb("eor x9 x9 x1\n"), "290101ca")

    # ---- truth table + C's 0/1 normalisation (NOT the operand's own value).
    for cs, want in [("int main(){return 1&&1;}", 1),
                     ("int main(){return 1&&0;}", 0),
                     ("int main(){return 0&&1;}", 0),
                     ("int main(){return 5&&3;}", 1),   # normalises, not 3
                     ("int main(){return 0||0;}", 0),
                     ("int main(){return 0||7;}", 1),   # normalises, not 7
                     ("int main(){return 9||0;}", 1),
                     ("int main(){return 1&&1&&1;}", 1),
                     ("int main(){return 1&&0&&1;}", 0),
                     ("int main(){return 0||0||3;}", 1)]:
        check(f"stage2 sc value: {cs[13:-1]}", _exit(cs), want)

    # ---- THE point of the feature: the right operand must not be evaluated.
    _B = "int g;int bump(){g=g+1;return 1;}"
    check("stage2 && skips RHS (no side effect)",
          _exit(_B + "int main(){int r;g=0;r=0&&bump();return g;}"), 0)
    check("stage2 && runs RHS when LHS true",
          _exit(_B + "int main(){int r;g=0;r=1&&bump();return g;}"), 1)
    check("stage2 || skips RHS (no side effect)",
          _exit(_B + "int main(){int r;g=0;r=1||bump();return g;}"), 0)
    check("stage2 || runs RHS when LHS false",
          _exit(_B + "int main(){int r;g=0;r=0||bump();return g;}"), 1)

    # The M2-Planet shape: a null guard.  Without short-circuiting `p->v` derefs
    # NULL and the m50 wild-address trap fires, so a PASS here is a real witness.
    _N = "struct N{int v;struct N* nx;};"
    check("stage2 null guard p&&p->v does not deref",
          _exit_safe(_N + "int main(){struct N* p;p=0;if(p&&p->v){return 9;}return 3;}"), 3)
    check("stage2 null guard 0!=p&&p->v does not deref",
          _exit_safe(_N + "int main(){struct N* p;p=0;if(0!=p&&p->v){return 9;}return 3;}"), 3)
    check("stage2 guard still passes when non-null",
          _exit_safe(_N + "int main(){struct N* p;p=calloc(1,16);p->v=7;"
                          "if(p&&p->v){return 9;}return 3;}"), 9)

    # ---- precedence: || < && < | < ^ < & < == < relational.  Each case below
    # gives a DIFFERENT answer under naive left-to-right, so they discriminate.
    for cs, want in [("int main(){return 1||0&&0;}", 1),   # not (1||0)&&0 == 0
                     ("int main(){return 0||1&&1;}", 1),
                     ("int main(){return 0&&0||1;}", 1),
                     ("int main(){return (1||0)&&0;}", 0),
                     ("int main(){return 1|2&&1;}", 1),
                     ("int main(){return 2&3&&0;}", 0),
                     ("int main(){return 1|2^3;}", 1),     # ^ tighter than |
                     ("int main(){return 6^3&1;}", 7),     # & tighter than ^
                     ("int main(){return 1^1==1;}", 0)]:   # == tighter than ^
        check(f"stage2 precedence: {cs[13:-1]}", _exit(cs), want)

    # ---- structural: `||` is the only thing that emits `b.ne @` (if/while and
    # `&&` use `b.eq @`, back-branches use `b @`), so this is a sharp check that
    # the branch really is there and really is inverted for `||`.
    _emAnd = _emit("int f(int a,int b){return a&&b;}int main(){return 0;}")
    _emOr  = _emit("int f(int a,int b){return a||b;}int main(){return 0;}")
    check("stage2 && emits forward b.eq __L", "b.eq __L" in _emAnd, True)
    check("stage2 && emits no b.ne",          "b.ne " in _emAnd, False)
    check("stage2 || emits inverted b.ne __L","b.ne __L" in _emOr,  True)
    check("stage2 sc normalises result to 0/1",
          ("sub x2 x2 x0" in _emAnd) and ("orr x0 x0 x2" in _emAnd)
          and ("lsr x0 x0 x2" in _emAnd), True)

    # ---- A13 x17 accounting.  The prologue is 8 emitted lines and the epilogue
    # 9, all real 4-byte instructions and none with a leading '\n'.  Drift here
    # would corrupt the @-targets of every function emitted AFTERWARDS (m54).
    for nm, cs in [
        ("plain &&",      "int f(int a,int b){return a&&b;}int main(){return 0;}"),
        ("plain ||",      "int f(int a,int b){return a||b;}int main(){return 0;}"),
        ("chained &&",    "int f(int a,int b,int c){return a&&b&&c;}int main(){return 0;}"),
        ("mixed ||/&&",   "int f(int a,int b,int c){return a||b&&c;}int main(){return 0;}"),
        ("&& in if",      "int f(int a){if(a>0&&a<9){return 1;}return 0;}int main(){return 0;}"),
        ("&& in while",   "int f(int a){int i;i=0;while(i<3&&a){i=i+1;}return i;}int main(){return 0;}"),
        ("&& over calls", "int g(){return 1;}int f(){return g()&&g();}int main(){return 0;}"),
        ("&& null guard", _N + "int f(struct N* p){if(p&&p->v){return 1;}return 0;}"
                               "int main(){return 0;}"),
        ("^ operand",     "int f(int a,int b){return a^b;}int main(){return 0;}"),
        ("hex literal",   "int f(){return 0x1234;}int main(){return 0;}"),
    ]:
        b, d = _drift(cs)
        check(f"stage2 no blank emitted line: {nm}", b, 0)
        check(f"stage2 x17 == real instr count: {nm}", d, 0)

    # ---- order dependence: a victim defined AFTER a short-circuiting function
    # must still mean what it meant alone.  This is the m54 symptom, not its cause.
    _SC = "int chk(int a,int b){if(a>0&&b>0){return 1;}return 0;}"
    for nm, victim in [
        ("if/else", "int g(){int a;if(0){a=9;}else{a=3;}return a;}"),
        ("while",   "int g(){int i;int s;i=0;s=0;while(i<3){s=s+1;i=i+1;}return s;}"),
        ("nested",  "int g(){int i;int j;int c;i=0;c=0;while(i<3){j=0;"
                    "while(j<1){c=c+1;j=j+1;}i=i+1;}return c;}"),
    ]:
        check(f"stage2 victim after && still returns 3: {nm}",
              _exit_safe(_SC + victim + "int main(){return g();}"), 3)

    # ---- re-entrancy: the patch slot is keyed by opstack index, so short-circuits
    # nested inside call arguments (and calls inside short-circuit operands) need
    # no save/restore.  These are the cases a single global patch stack would break.
    check("stage2 && inside call arguments",
          _exit("int f(int a,int b){return a+b*10;}int main(){return f(1&&1,0||5);}"), 11)
    check("stage2 calls inside && operands",
          _exit("int one(){return 1;}int zero(){return 0;}"
                "int main(){return one()&&zero()||one();}"), 1)
    check("stage2 nested (a&&b)||(c&&d)",
          _exit("int main(){int a;int b;int c;int d;a=1;b=0;c=1;d=1;"
                "return (a&&b)||(c&&d);}"), 1)

    # ---- hex literals.  One lexer rule (0x/0X prefix + hex-digit scan) and one
    # value rule; `parsenum` was a duplicate decimal loop and now calls `parseval`,
    # so array sizes accept hex as a side effect.  Decimal must be untouched.
    for cs, want in [("int main(){return 0x2A;}", 42),
                     ("int main(){return 0xff;}", 255),
                     ("int main(){return 0XFF;}", 255),
                     ("int main(){return 0x0;}", 0),
                     ("int main(){return 0;}", 0),
                     ("int main(){return 10;}", 10),
                     ("int main(){return 42;}", 42),
                     ("int main(){return 0x10+6;}", 22),
                     ("int main(){return 0xFF&0x0F;}", 15),
                     ("int main(){int c;c=321;return c&0xFF;}", 65)]:
        check(f"stage2 hex: {cs[13:-1]}", _exit(cs), want)
    # >= 2^16 must still go through the A11 movk halfword path.
    check("stage2 hex large literal uses movk path",
          _exit("int main(){return 0x12345&0xFF;}"), 69)
    check("stage2 hex 0x10000>>16", _exit("int main(){return 0x10000>>16;}"), 1)
    check("stage2 hex array size a[0x10]",
          _exit("int main(){int a[0x10];a[15]=7;return a[15];}"), 7)
    check("stage2 decimal array size unchanged",
          _exit("int main(){int a[16];a[15]=7;return a[15];}"), 7)

    # ---- `^` itself, and the neighbours it must not have disturbed.
    for cs, want in [("int main(){return 12^10;}", 6),
                     ("int main(){return 0xFF^0x0F;}", 240),
                     ("int main(){int x;x=93;return x^x;}", 0),
                     ("int main(){int x;x=93;return x^0;}", 93),
                     ("int main(){return (5^3)&&1;}", 1),
                     ("int main(){return (12|3)+(12&8);}", 23)]:
        check(f"stage2 xor: {cs[13:-1]}", _exit(cs), want)
    check("stage2 ^ lowers to a single eor",
          _emit("int f(int a,int b){return a^b;}int main(){return 0;}").count("eor x0 x1 x0"), 1)

    print("== stage 2 goto + labels (A17) ==")
    # A label definition emits a NAMED label; `goto L` emits `b <label>`. Both are
    # resolved by stage1 (a two-pass numeric resolver since m32), so a FORWARD goto
    # needs no backpatching in the single-pass compiler — that is the whole reason
    # this rung is cheap. The name is prefixed with a per-function index
    # (__Lg<idx>_<name>) so labels are FUNCTION-scoped, as C requires: two functions
    # may each define `lp:` without colliding in the flat assembler namespace.
    emg = _emit("int main(){int i;i=0;top: i=i+1;if(i<3){goto top;}return i;}")
    check("stage2 goto emits a named branch (b __Lg)", "\nb __Lg" in emg, True)
    check("stage2 label emits a definition (:__Lg)",   "\n:__Lg" in emg, True)
    check("stage2 goto label carries the source name", "_top" in emg, True)
    check("stage2 goto label is function-indexed (fn 1 -> 0001)",
          ":__Lg0001_top" in emg, True)
    # A22: if/while are labelled too now, so a goto label coexists with generated
    # ones. Every label must still be compiler-generated and the goto label present.
    check("stage2 goto: goto label coexists with generated if/while labels",
          (":__Lg0001_top" in emg) and ("b.eq __L" in emg)
          and all(l == ":main" or l.startswith(":__L")
                  for l in emg.split("\n") if l.startswith(":")), True)
    # A22 retires the A13 x17 invariant for control flow: there are no absolute
    # @-positions left to drift, because every branch names its target and stage 1
    # resolves it. What must hold instead is label INTEGRITY -- each referenced
    # label defined exactly once, each definition referenced -- which is checked
    # structurally here and behaviourally by the order-independence witness below.
    import re as _re2
    _defs = [l[1:] for l in emg.split("\n") if l.startswith(":__L")]
    _refs = _re2.findall(r"\b(?:b|b\.eq|b\.ne)\s+(__L\w+)", emg)
    check("stage2 goto: no blank emitted line", 
          any(l.strip() == "" for l in emg.split("\n")[:-1]), False)
    check("stage2 goto: label defs unique", len(_defs) == len(set(_defs)), True)
    check("stage2 goto: every branch target defined", set(_refs) <= set(_defs), True)
    # Two functions each defining `lp:` -> distinct emitted labels (function scope).
    emg2 = _emit("int a(){int i;i=0;lp: i=i+1;if(i<3){goto lp;}return i;}"
                 "int b(){int j;j=0;lp: j=j+2;if(j<8){goto lp;}return j;}"
                 "int main(){return a()+b();}")
    check("stage2 goto: same label name in 2 functions -> 2 distinct labels",
          (":__Lg0001_lp" in emg2) and (":__Lg0002_lp" in emg2), True)
    # Behavioural, through the real assembled ladder. Covers the shapes M2-Planet
    # actually uses: a backward jump to a label at body top (its `reset:` loop
    # idiom), a forward jump to a label near the end (`goto exit_success;`), and
    # jumps out of arbitrarily many open blocks (`goto reset;` from inside nested
    # else-if chains wrapped around while loops).
    # A drifted @-target jumps into the middle of nowhere, which since m50 the
    # interp faults on rather than tolerating -- so these are caught, but as an
    # exception. Report that as a failed check instead of aborting the run.
    def _exit_safe(csrc):
        try:
            return _exit(csrc)
        except Exception as e:
            return f"<{type(e).__name__}>"
    for cs, want in [
        ("int main(){int i;int s;i=0;s=0;top: i=i+1;s=s+i;if(i<4){goto top;}return s;}", 10),
        ("int main(){int a;a=1;goto done;a=99;done: return a+4;}", 5),
        ("int f(int n){int s;s=0;again: s=s+n;n=n-1;if(n>0){goto again;}return s;}int main(){return f(4);}", 10),
        ("int main(){int i;i=0;top: i=i+1;if(i<20){if(i<10){while(i<50){i=i+3;goto top;}}}return i;}", 13),
        ("int main(){int i;i=0;while(1){i=i+1;if(i>5){goto out;}}out: return i;}", 6),
        ("int main(){int a;a=0;top: a=a+1;if(a>3){return a;}else{goto top;}return 99;}", 4),
        ("int main(){int a;a=0;one: a=a+1;if(a<2){goto one;}two: a=a+10;if(a<30){goto two;}return a;}", 32),
        ("int main(){int a;a=0;top: int b;b=a+1;a=b;if(a<5){goto top;}return a;}", 5),
        ("int a(){int i;i=0;lp: i=i+1;if(i<3){goto lp;}return i;}"
         "int b(){int j;j=0;lp: j=j+2;if(j<8){goto lp;}return j;}int main(){return a()+b();}", 11),
    ]:
        check(f"stage2 goto exit -> {want}", _exit_safe(cs), want)
    # Order-independence: a function defined AFTER a goto-using one must be
    # unaffected. This is the behavioural witness for the x17 invariant — the m54
    # drift bug corrupted only the functions emitted afterwards, never the culprit.
    check("stage2 goto: later function unaffected (x17 order-independence)",
          _exit_safe("int g(){int i;i=0;lp: i=i+1;if(i<3){goto lp;}return i;}"
                "int later(){int k;k=0;while(k<7){k=k+1;}return k;}"
                "int main(){return g()*10+later();}"), 37)
    # A program with no goto must be byte-identical to before the rung.
    check("stage2 goto: non-goto programs emit no __Lg",
          "__Lg" in _emit("int main(){int i;i=0;while(i<3){i=i+1;}return i;}"), False)

    print("== stage 2 forward prototypes (A18) ==")
    # `int f(int, int);` at file scope. Before this rung funcloop committed to a
    # DEFINITION the moment it saw `(` after the name, so the `;` where `{` should
    # be derailed it and the compiler HUNG -- the biggest single blocker on real
    # M2-Planet code, which declares nearly every function ahead of use (73 sites).
    # The fix is a paren-matching lookahead: scan from `(` to its partner, skip
    # whitespace, and branch on `;` (prototype) vs anything else (definition).
    #
    # A prototype declares nothing and emits nothing. That is not a shortcut, it is
    # correct for this compiler: the bl-vs-blr split is read off the symbol tables
    # (a called name found in NO table is a function -> direct `bl`), so a function
    # needs no prior declaration to be callable. Unnamed parameters
    # (`int f(struct type*, char*);`) therefore fall out for free -- the declarator
    # is never parsed at all.
    check("stage2 prototype emits nothing (output byte-identical without it)",
          _emit("int add(int a,int b){return a+b;}int main(){return add(1,2);}")
          == _emit("int add(int,int);int add(int a,int b){return a+b;}int main(){return add(1,2);}"),
          True)
    check("stage2 prototype emits no label of its own",
          [l for l in _emit("int f(int);int g(int);int h(int);int main(){return 1;}")
           .split("\n") if l.startswith(":")], [":main"])
    # Behavioural, through the real assembled ladder. Each of these HUNG the
    # compiler before this rung.
    for nm, cs, want in [
        ("named params",  "int add(int a,int b);int main(){return add(3,4);}"
                          "int add(int a,int b){return a+b;}", 7),
        ("unnamed params","int add(int,int);int main(){return add(20,22);}"
                          "int add(int a,int b){return a+b;}", 42),
        ("struct* return","struct N{int v;struct N* nx;};struct N* mk(int v);"
                          "int main(){struct N* p;p=mk(9);return p->v;}"
                          "struct N* mk(int v){struct N* n;n=calloc(1,sizeof(struct N));"
                          "n->v=v;return n;}", 9),
        ("void proto",    "void bump(void);int G;int main(){bump();bump();return G;}"
                          "void bump(void){G=G+3;}", 6),
        ("recursion",     "int fact(int n);int main(){return fact(5);}"
                          "int fact(int n){if(n<2){return 1;}return n*fact(n-1);}", 120),
        ("mutual recursion",
                          "int odd(int n);int even(int n){if(n==0){return 1;}return odd(n-1);}"
                          "int odd(int n){if(n==0){return 0;}return even(n-1);}"
                          "int main(){return even(10)+odd(7);}", 2),
        ("multi-line proto",
                          "int add(int a,\n  int b);\nint main(){return add(6,6);}\n"
                          "int add(int a,int b){return a+b;}", 12),
        ("no proto (regression)",
                          "int add(int a,int b){return a+b;}int main(){return add(1,2);}", 3),
    ]:
        check(f"stage2 prototype: {nm}", _exit_safe(cs), want)

    print("== stage 2 braceless statement bodies (A19) ==")
    # `if(cond) return x;` with no braces -- ~370 sites in M2-Planet's self-host
    # (199 return, 120 call/assign, 34 bare else, 11 break, 2 goto), and until now
    # silently miscompiled. Two parts:
    #
    # (1) The CONDITION had to be bounded. compile_expr did not stop at the
    #     condition's closing paren -- it relied on the body's `{` to terminate it,
    #     and worse, ce_kw treats ANY keyword in operand position as `sizeof`. So
    #     `if(a) return 5;` swallowed `return` into the condition, and
    #     `if(a) f(b);` emitted the call as part of the condition and then tested
    #     ITS result. Fixed by scanning to the matching `)` and temporarily
    #     lowering x21 (the input length) so the tokenizer reports EOF there --
    #     which compile_expr already terminates on cleanly. The scanner skips char
    #     and string literals exactly as the lexer does, so `if(c=='(')` cannot
    #     unbalance it.
    #
    # (2) A braceless body closes after ONE statement. Block records carry kind+4
    #     for a braceless variant; every statement-completion exit now routes
    #     through `stmtend`, which pops and closes while the top record is
    #     braceless. The close routines re-enter stmtend, so `if(a) if(b) x;`
    #     unwinds correctly and a dangling `else` binds to the inner `if`.
    #
    # The strongest guarantee first: a BRACED program must be unchanged.
    for cs in ["int main(){int a;a=5;if(a){a=a+1;}return a;}",
               "int main(){int i;int s;i=0;s=0;while(i<10){s=s+i;i=i+1;}return s;}",
               "int main(){int a;a=1;if(a){a=2;}else{a=3;}return a;}"]:
        b, d = _drift(cs)
        check(f"stage2 braceless: braced program still drift-free", (b, d), (0, 0))
    # x17 accounting for each NEW construct: a braceless body must not add or lose
    # an emitted line (A13 -- drift here would corrupt every later function).
    for nm, cs in [
        ("braceless if",     "int main(){int a;a=1;if(a) return 5;return 9;}"),
        ("braceless while",  "int main(){int i;i=0;while(i<5) i=i+1;return i;}"),
        ("bare else",        "int main(){int a;a=0;if(a) return 1;else return 8;}"),
        ("nested braceless", "int main(){int a;int b;a=1;b=1;if(a) if(b) return 7;return 2;}"),
    ]:
        b, d = _drift(cs)
        check(f"stage2 braceless no blank line: {nm}", b, 0)
        check(f"stage2 braceless x17 == real instr count: {nm}", d, 0)
    # Behavioural, through the real assembled ladder: every shape M2-Planet uses.
    for nm, cs, want in [
        ("if + return",        "int main(){int a;a=1;if(a) return 5;return 9;}", 5),
        ("if false falls through","int main(){int a;a=0;if(a) return 5;return 9;}", 9),
        ("if + assign",        "int main(){int a;a=0;if(1) a=7;return a;}", 7),
        ("if + call",          "int G;int bump(){G=G+4;return 0;}int main(){if(1) bump();return G;}", 4),
        ("braceless while",    "int main(){int i;i=0;while(i<5) i=i+1;return i;}", 5),
        ("bare else",          "int main(){int a;a=0;if(a) return 1;else return 8;}", 8),
        ("else-if chain",      "int f(int n){if(n<1) return 10;else if(n<2) return 20;"
                               "else return 30;}int main(){return f(1);}", 20),
        ("braced then, bare else","int main(){int a;a=0;if(a){a=1;}else a=6;return a;}", 6),
        ("bare then, braced else","int main(){int a;a=1;if(a) a=3;else{a=9;}return a;}", 3),
        ("nested braceless",   "int main(){int a;int b;a=1;b=1;if(a) if(b) return 7;return 2;}", 7),
        ("dangling else binds inner",
                               "int f(int a,int b){if(a) if(b) return 1;else return 2;return 3;}"
                               "int main(){return f(1,0);}", 2),
        ("braceless if + braced while",
                               "int main(){int i;i=0;if(1) while(i<6){i=i+1;}return i;}", 6),
        ("braceless if + block","int main(){int a;a=0;if(1) {a=4;}return a;}", 4),
        ("braceless + goto",   "int main(){int i;i=0;top: i=i+1;if(i<4) goto top;return i;}", 4),
        ("empty statement body","int main(){int a;a=5;if(a) ;return a;}", 5),
        # condition-bounding regressions: a paren inside a literal, a call in the
        # condition, nested parens, and short-circuit operators must all still work.
        ("cond has char-literal paren",
                               "int f(int c){if(c==40) return 3;return 9;}int main(){return f(40);}", 3),
        ("cond has a call",    "int p(int n){return n;}int main(){if(p(1)) return 6;return 0;}", 6),
        ("cond nested parens", "int main(){int a;a=2;if(((a+1)*2)==6) return 4;return 0;}", 4),
        ("cond with && and !", "int main(){int a;int b;a=1;b=0;if(a&&!b) return 5;return 0;}", 5),
        ("deep braceless chain","int f(int n){if(n==0) return 1;if(n==1) return 2;"
                               "if(n==2) return 3;return 9;}int main(){return f(2);}", 3),
    ]:
        check(f"stage2 braceless: {nm}", _exit_safe(cs), want)

    # The payoff witness: M2-Planet-SHAPED code exercising A17+A18+A19 at once --
    # forward prototypes, a goto loop, braceless if bodies, char* parameters,
    # subscripts, string literals, calls inside conditions, and unary !.
    # `in_set` and `match` are the shape of M2-Planet's own helpers (`match` here
    # written as its goto-loop idiom rather than a while, which is how several of
    # its scanners are actually written). Returns 42 only if every assertion holds.
    check("stage2 M2-shaped: prototypes + goto + braceless together",
          _exit_safe(
            'int match(char* a, char* b);\n'
            'int in_set(int c, char* s);\n'
            'int in_set(int c, char* s)\n'
            '{\n\twhile(0 != s[0])\n\t{\n\t\tif(c == s[0]) return 1;\n'
            '\t\ts = s + 1;\n\t}\n\treturn 0;\n}\n'
            'int match(char* a, char* b)\n'
            '{\n\tint i = 0;\nmloop:\n\tif(a[i] != b[i]) return 0;\n'
            '\tif(a[i] == 0) return 1;\n\ti = i + 1;\n\tgoto mloop;\n}\n'
            'int main()\n{\n'
            '\tif(!match("hello","hello")) return 1;\n'
            '\tif(match("hello","world")) return 2;\n'
            '\tif(!in_set(101, "abcde")) return 3;\n'
            '\tif(in_set(122, "abcde")) return 4;\n'
            '\treturn 42;\n}\n'), 42)

    print("== stage 2 string/char escapes (A20) ==")
    # ~993 escapes in M2-Planet's self-host -- the largest single count in the
    # source, and the one gap no source rewrite could paper over: the escapes sit
    # inside the assembly text M2-Planet EMITS ("\n# Core program\n"), so a lexer
    # that stores \n as two literal bytes produces a compiler whose OUTPUT is
    # textually wrong everywhere. Distribution: \n 964, \\ 10, \' 7, \" 7, \t 4,
    # \r 1. \0 is implemented too -- zero uses today, but it falls out of the table.
    #
    # Three sites had to agree: the char-literal lexer (which assumed a 3-character
    # 'X'), the string scanner (which stopped at the first '"', including an escaped
    # one), and the data-section emitter (which copied source bytes verbatim). The
    # A19 condition scanner needed it too, since it skips literals to keep its paren
    # count honest.
    _LEN = 'int len(char* p){int n;n=0;while(p[n]){n=n+1;}return n;}'
    _BS = chr(92)          # a single backslash, spelled without nesting escapes
    _SQ = chr(39)
    _DQ = chr(34)
    for nm, cs, want in [
        # ---- char literals: the decoded value IS the observable
        ("char \\n",  "int main(){char c;c=" + _SQ + _BS + "n" + _SQ + ";return c;}", 10),
        ("char \\t",  "int main(){char c;c=" + _SQ + _BS + "t" + _SQ + ";return c;}", 9),
        ("char \\r",  "int main(){char c;c=" + _SQ + _BS + "r" + _SQ + ";return c;}", 13),
        ("char \\\\", "int main(){char c;c=" + _SQ + _BS + _BS + _SQ + ";return c;}", 92),
        ("char \\'",  "int main(){char c;c=" + _SQ + _BS + _SQ + _SQ + ";return c;}", 39),
        ("char \\\"", "int main(){char c;c=" + _SQ + _BS + _DQ + _SQ + ";return c;}", 34),
        ("char \\0",  "int main(){char c;c=" + _SQ + _BS + "0" + _SQ + ";return c+7;}", 7),
        ("plain char unchanged", "int main(){char c;c=" + _SQ + "A" + _SQ + ";return c;}", 65),
        # ---- strings: an escape must occupy exactly ONE byte in the data section
        ("\\n is one byte", _LEN + "int main(){return len(" + _DQ + "a" + _BS + "nb" + _DQ + ");}", 3),
        ("\\n byte value",  "int main(){char* s;s=" + _DQ + "a" + _BS + "nb" + _DQ + ";return s[1];}", 10),
        ("\\t byte value",  "int main(){char* s;s=" + _DQ + "a" + _BS + "tb" + _DQ + ";return s[1];}", 9),
        ("\\r byte value",  "int main(){char* s;s=" + _DQ + "a" + _BS + "rb" + _DQ + ";return s[1];}", 13),
        ("\\\\ byte value", "int main(){char* s;s=" + _DQ + "a" + _BS + _BS + "b" + _DQ + ";return s[1];}", 92),
        # an escaped quote must NOT terminate the literal -- the scanner bug
        ("\\\" does not end the string",
                           "int main(){char* s;s=" + _DQ + "a" + _BS + _DQ + "b" + _DQ + ";return s[1];}", 34),
        ("\\\" length is 3", _LEN + "int main(){return len(" + _DQ + "a" + _BS + _DQ + "b" + _DQ + ");}", 3),
        ("escape at start", "int main(){char* s;s=" + _DQ + _BS + "nx" + _DQ + ";return s[0];}", 10),
        ("escape at end",   "int main(){char* s;s=" + _DQ + "x" + _BS + "n" + _DQ + ";return s[1];}", 10),
        ("all-escape string", _LEN + "int main(){return len(" + _DQ + (_BS + "n") * 5 + _DQ + ");}", 5),
        ("M2 output-string shape",
                           _LEN + "int main(){return len(" + _DQ + _BS + "n# Core program" + _BS + "n" + _DQ + ");}", 16),
        ("escaped strings as call args",
                           _LEN + "int f(char* a,char* b){return len(a)*10+len(b);}"
                           "int main(){return f(" + _DQ + "a" + _BS + "nb" + _DQ + ","
                           + _DQ + "c" + _BS + "td" + _DQ + ");}", 33),
        ("plain string unchanged", _LEN + "int main(){return len(" + _DQ + "hello" + _DQ + ");}", 5),
        # ---- A19 interop: the condition scanner skips literals to keep parens
        # balanced, so an escaped quote inside a condition must not confuse it.
        ("escaped quote inside a condition",
                           _LEN + "int main(){if(len(" + _DQ + "a" + _BS + _DQ + "b" + _DQ + ")==3) return 8;return 0;}", 8),
        ("escaped char literal in a condition",
                           "int main(){char c;c=" + _SQ + _BS + "n" + _SQ + ";if(c==" + _SQ + _BS + "n" + _SQ + ") return 6;return 0;}", 6),
    ]:
        check("stage2 escape: " + nm, _exit_safe(cs), want)
    # The property that actually matters: the BYTES reaching stdout. M2-Planet's
    # emitted assembly is textually wrong everywhere if these are not real bytes.
    def _stdout(csrc):
        _, resolved = run(s1prog, stdin=_emit(csrc).encode())
        _, out = run(assemble(resolved.decode())[1])
        return out
    _prog = (_LEN + "int puts(char* s){write(1,s,len(s));return 0;}int main(){"
             "puts(" + _DQ + _BS + "n# Core program" + _BS + "n" + _DQ + ");"
             "puts(" + _DQ + "a" + _BS + "tb" + _BS + "n" + _DQ + ");"
             "puts(" + _DQ + "q" + _BS + _DQ + "q" + _BS + "n" + _DQ + ");"
             "puts(" + _DQ + "back" + _BS + _BS + "slash" + _BS + "n" + _DQ + ");return 0;}")
    check("stage2 escape: emitted bytes reach stdout exactly",
          _stdout(_prog),
          b'\n# Core program\na\tb\nq"q\nback\\slash\n')

    print("== stage 2 preprocessor directives (A21) ==")
    # Scoped by reading how M2-Planet's self-host is ACTUALLY built, not by
    # implementing C's preprocessor. Its own bootstrap passes every translation
    # unit as an ordered `-f` list and runs with `--bootstrap-mode`, in which its
    # entire preprocessor is `remove_preprocessor_directives`: any token starting
    # with '#' discards the rest of the line. No include expansion, no macro
    # substitution, no conditionals.
    #
    # That works because the -f list makes `#include` redundant, and because there
    # are NO object-like #define constants in the source -- the only #define is the
    # `CC_H` include guard. NULL, TRUE, FALSE, EOF, stdin/stdout/stderr and
    # EXIT_SUCCESS/FAILURE are `enum` constants in M2libc/bootstrap.c, which is
    # itself in the -f list. So `enum`, not the preprocessor, is what these 287
    # NULL uses actually depend on.
    #
    # Our equivalent of the -f list is concatenated stdin (`cat a.c b.c | stage2`),
    # which already worked. So this rung is one lexer rule, in the same place as
    # the comment skip.
    _LEN2 = 'int len(char* p){int n;n=0;while(p[n]){n=n+1;}return n;}'
    _DQ2 = chr(34)
    _BS2 = chr(92)
    for nm, cs, want in [
        ("#include is skipped",
         '#include <stdio.h>\n#include "cc.h"\nint main(){return 7;}', 7),
        ("include-guard trio is skipped",
         '#ifndef CC_H\n#define CC_H\nint main(){return 9;}\n#endif\n', 9),
        ("directive between functions",
         'int a(){return 3;}\n#include "x.h"\nint main(){return a()+1;}', 4),
        ("directive inside a function body",
         'int main(){int a;a=1;\n#ifdef FOO\n a=a+4;\nreturn a;}', 5),
        ("indented directive",
         '   #include <stdlib.h>\nint main(){return 6;}', 6),
        # '#' only starts a directive at token position -- inside a string literal
        # it is an ordinary byte, which matters because M2-Planet EMITS "\n# Core
        # program\n". A directive rule that fired inside strings would eat it.
        ("# inside a string is not a directive",
         _LEN2 + 'int main(){return len(' + _DQ2 + '#not a directive' + _DQ2 + ');}', 16),
        ("# inside a string with an escape (A20 interop)",
         _LEN2 + 'int main(){return len(' + _DQ2 + _BS2 + 'n# Core program'
         + _BS2 + 'n' + _DQ2 + ');}', 16),
        # the -f list equivalent: several translation units concatenated, with
        # directives interleaved exactly as they appear in the real source.
        ("concatenated translation units with directives",
         'int in_set(int c,char* s);\n'
         '#include "cc.h"\n'
         'int in_set(int c,char* s){while(0 != s[0]){if(c == s[0]) return 1;'
         's = s + 1;}return 0;}\n'
         '#include <stdio.h>\n'
         'int main(){if(!in_set(101,' + _DQ2 + 'abcde' + _DQ2 + ')) return 1;return 21;}', 21),
    ]:
        check("stage2 preprocessor: " + nm, _exit_safe(cs), want)
    # A directive contributes nothing: a program with directives must emit exactly
    # what the same program without them emits.
    check("stage2 preprocessor: directives emit nothing",
          _emit('int main(){return 7;}')
          == _emit('#include <stdio.h>\n#define X 1\nint main(){return 7;}\n#endif\n'),
          True)




if FAILS:
    print(f"\nFAILED: {FAILS}\nThe bench no longer matches CI ground truth — fix before trusting it.")
    sys.exit(1)
print("\nAll bench checks pass — model matches known CI results.")
