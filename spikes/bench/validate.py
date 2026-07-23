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

print("== GNU-as source lint (the bench does NOT model real `as`) ==")
# s0as.py models stage0-as's OWN language, not GNU as, so edits to the .s files
# real `as` assembles are unguarded until CI -- and there is no aarch64 assembler
# on the dev box. A pushed commit failed with "attempt to store non-empty string
# in section `.bss'" for exactly this reason. Mechanical classes get a lint.
import os as _os, glob as _glob, subprocess as _sp
_here = _os.path.dirname(_os.path.abspath(__file__))
_srcs = sorted(_glob.glob(_os.path.join(_here, "..", "*", "*.s")))
_r = _sp.run([sys.executable, _os.path.join(_here, "lint_asm.py")] + _srcs,
             capture_output=True, text=True)
check("GNU-as sources lint clean", _r.returncode, 0)
if _r.returncode:
    print(_r.stdout)

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
    # A23 SUPERSEDES the m55 bound. That bound existed because the data section was
    # a FIXED ~124 KB region between the tables: overflowing it silently clobbered
    # the save area, so m55 made it stop with a diagnostic. Data is now emitted
    # INLINE into the streaming code output (behind a skip branch, 4-byte padded),
    # so there is no fixed region left to overflow -- the limit is gone rather than
    # merely reported. What must hold now is that a large global simply WORKS.
    _huge = "char A[8192];char B[16384];int main(){return 3;}"
    check("stage2 large globals compile (no fixed data region to overflow)",
          _exit_safe(_huge), 3)
    check("stage2 large globals emit real data",
          _emit(_huge).count(".byte") > 24000, True)

    print("== stage 2 capacity: input, output and data are all unbounded (A23) ==")
    # The last three fixed ceilings, removed rather than raised:
    #   A1  input was a SINGLE read() of 65,000 B into a 64 KB buffer. It is now an
    #       mmap arena (128 MiB of input room before any table begins) plus a read
    #       LOOP -- a single read on a pipe returns only what is buffered, so the
    #       old code truncated silently well below even 64 KB.
    #   A2  the data section was a fixed ~124 KB region wedged between the tables.
    #   A3  `adr x0 __dN` reached a TRAILING data section, but adr spans only
    #       +-1 MB, so at M2-Planet scale (0.7-1.4 MB of code) the address was
    #       silently wrong.
    # A2 and A3 are one fix: literals and globals are emitted INLINE behind a skip
    # branch, 4-byte padded, so the data sits adjacent to its own `adr` and no data
    # region exists to overflow.
    def _bigsrc(nfn):
        return "".join("int f%d(int a){int b;b=a+%d;if(b>1000){b=b-1000;}return b;}"
                       % (i, i) for i in range(nfn)) + "int main(){return f0(7);}"
    for nfn, want in [(50, 7), (200, 7), (600, 7)]:
        _src = _bigsrc(nfn)
        check(f"stage2 {len(_src)}-byte input compiles and runs", _exit_safe(_src), want)
    # past the OLD 64 KB input buffer. The bench interp cannot run stage1 over the
    # ~1.2 MB result (its step budget, not a tool limit), so this asserts on the
    # COMPILE, which is the thing A1 changed.
    _huge_src = _bigsrc(1200)
    check("stage2 input past the old 64 KB buffer", len(_huge_src) > 65000, True)
    check("stage2 compiles a 73 KB input to >1 MB of assembly",
          len(_emit(_huge_src)) > 1000000, True)
    # inline data: adjacent to its adr, never a trailing section
    _sd = _emit('int main(){char* s;s="ab";return s[1];}')
    check("stage2 literal is emitted inline behind a skip branch",
          ("b __ds" in _sd) and (":__ds" in _sd), True)
    check("stage2 literal data is 4-byte padded",
          _sd.split(":__d0000")[1].split(":__ds")[0].count(".byte") % 4, 0)
    check("stage2 adr targets adjacent data (no trailing section)",
          _sd.index("adr x0 __d0000") > _sd.index(":__d0000"), True)

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




    print("== stage 2 do{}while + break + continue (A24) ==")
    # A do-loop emits the SAME label pair a while-loop does -- top defined at the
    # `do`, exit referenced by the condition's b.eq and defined after the back
    # branch -- so `break` is one mechanism for both:
    #
    #     :__L<top>          <- emitted at `do`
    #       <body>
    #     [:__L<cont>]       <- only if a `continue` was seen (see below)
    #       <cond>; b.eq __L<exit>
    #       b __L<top>
    #     :__L<exit>
    #
    # `break`/`continue` scan the block stack DOWNWARD for the nearest record whose
    # base kind is a loop (1=while, 4=do), skipping if/else/plain records -- which
    # is the whole point, since 11 of M2-Planet's 14 breaks sit in a braceless `if`
    # body inside a loop. The scan masks off the braceless flag, so `while(c) break;`
    # finds its loop too.
    #
    # The block record grew 12 -> 16 bytes for this rung, and the braceless flag
    # moved from bit 2 to bit 3. That was FORCED, not cosmetic: `stmtend` tests
    # `kind >= 4` to mean braceless, so a braced `do` numbered 4 would have been
    # closed by the first `;` inside its own body. The freed field also carries the
    # continue target in slot c.
    #
    # Slot c holds the continue label id PLUS ONE, 0 meaning "none allocated".
    # The +1 is load-bearing: newlbl's first id is 0, so a bare 0 could not be
    # distinguished from label __L0. A `do` allocates its continue label LAZILY, on
    # the first `continue` inside it, because C says continue-in-do jumps to the
    # condition rather than the body top -- a third label that most do-loops (and
    # all 7 of M2-Planet's) never need. Eager allocation would emit a definition
    # nothing references, which is exactly what the A22 label-integrity checks
    # forbid. A `while` needs no laziness: its continue target IS its top label.
    def _exit_safe(csrc):
        try:
            return _exit(csrc)
        except Exception as e:
            return f"<{type(e).__name__}>"

    # Behavioural, through the real assembled ladder.
    for cs, want in [
        # the defining property: the body runs BEFORE the first test
        ("int main(){int i=0;do{i=i+1;}while(i>99);return i;}", 1),
        ("int main(){int i=9;do{i=i+1;}while(0);return i;}", 10),
        ("int main(){int i=0;do{i=i+1;}while(i<5);return i;}", 5),
        ("int main(){int n=4;int f=1;do{f=f*n;n=n-1;}while(n);return f;}", 24),
        # `while` on the line AFTER the closing brace -- 4 of M2-Planet's 7 sites
        ("int main(){int i=0;\ndo\n{\ni=i+1;\n}\nwhile(i<6);\nreturn i;}", 6),
        # braceless body: `do stmt; while(cond);`  (unused by M2-Planet, free here)
        ("int main(){int i=0;do i=i+1; while(i<7);return i;}", 7),
        # nesting, recursion, and interaction with the other control flow
        ("int main(){int a=0;int i=0;do{int j=0;do{j=j+1;a=a+1;}while(j<3);i=i+1;}while(i<2);return a;}", 6),
        ("int f(int n){int s=0;do{s=s+n;n=n-1;}while(n);return s;}int main(){return f(4);}", 10),
        ("int main(){int i=0;do{i=i+1;if(i==3){goto out;}}while(i<9);out:\nreturn i;}", 3),
        ("int main(){int a=1;int i=0;if(a) do{i=i+1;}while(i<4); else i=99;return i;}", 4),
        # break / continue
        ("int main(){int i=0;do{i=i+1;if(i==3){break;}}while(i<9);return i;}", 3),
        ("int main(){int i=0;while(1){i=i+1;if(i>6){break;}}return i;}", 7),
        ("int main(){int i=0;int s=0;while(i<5){i=i+1;if(i==2){continue;}s=s+i;}return s;}", 13),
        ("int main(){int i=0;int s=0;while(i<4){i=i+1;if(i==2)continue;s=s+i;}return s;}", 8),
        # break in a BRACELESS if inside a do -- cc_macro.c:912's shape exactly
        ("int main(){int i=0;do{i=i+1;if(i==4) break;}while(1);return i;}", 4),
        # break binds to the INNERMOST loop, and skips intervening if records
        ("int main(){int o=0;int t=0;while(o<3){o=o+1;int i=0;do{i=i+1;if(i==2){break;}t=t+1;}while(i<9);}return t;}", 3),
        ("int main(){int i=0;while(1){i=i+1;if(i>2){if(i>3){break;}}}return i;}", 4),
        # continue in a do jumps to the CONDITION, not the body top: i still
        # advances to 5 (so the loop terminates) while s counts only i>=3.
        ("int main(){int i=0;int s=0;do{i=i+1;if(i<3){continue;}s=s+1;}while(i<5);return s+i*10;}", 53),
        # conditions of the shapes M2-Planet actually writes
        ("int main(){int e=0;int c=0;int f=5;do{c=c+1;}while(e || (c != f));return c;}", 5),
        ("int main(){int c=0;do{c=c+1;}while((32 != c) && (9 != c) && (10 != c));return c;}", 9),
        # scancond bounds the condition by counting parens, so a ')' or '}' or an
        # ESCAPE inside a char literal there must be skipped, not counted.
        # cc_core.c:3165/2203 test against '}'; cc_reader.c:403 against '\n'.
        ("int main(){char c;c=48;int i=0;do{i=i+1;c=c+1;}while(c != ')' && i<3);return i;}", 3),
        ("int main(){char c;c=48;int i=0;do{i=i+1;c=c+1;}while(c != '}' && i<4);return i;}", 4),
        ("int main(){char c;c=5;int i=0;do{i=i+1;c=c+1;}while('\\n' != c);return i;}", 5),
        ("int main(){char c;c=5;int i=0;do{i=i+1;c=c+1;}while((32 != c) && (9 != c) && ('\\n' != c));return i;}", 4),
    ]:
        check(f"stage2 do/break exit -> {want}", _exit_safe(cs), want)

    # Structural: label integrity, the A22 property, on the new construct.
    import re as _re3
    _emdo = _emit("int main(){int i=0;do{i=i+1;}while(i<5);return i;}")
    _ddefs = [l[1:] for l in _emdo.split("\n") if l.startswith(":__L")]
    _drefs = _re3.findall(r"\b(?:b|b\.eq|b\.ne)\s+(__L\w+)", _emdo)
    check("stage2 do: label defs unique", len(_ddefs) == len(set(_ddefs)), True)
    check("stage2 do: every branch target defined", set(_drefs) <= set(_ddefs), True)
    check("stage2 do: every definition referenced", set(_ddefs) <= set(_drefs), True)
    check("stage2 do: no blank emitted line",
          any(l.strip() == "" for l in _emdo.split("\n")[:-1]), False)
    check("stage2 do: branches back to the top (b __L)", "\nb __L" in _emdo, True)
    check("stage2 do: exits on false (b.eq __L)", "b.eq __L" in _emdo, True)
    # A do-loop with no `continue` emits exactly two labels (top, exit) -- the
    # lazily-allocated continue label must not appear.
    check("stage2 do: 2 labels when no continue", len(set(_ddefs)), 2)
    _emdc = _emit("int main(){int i=0;do{i=i+1;if(i<3){continue;}}while(i<5);return i;}")
    check("stage2 do: 3rd label appears when continue is used",
          len(set(l for l in _emdc.split("\n") if l.startswith(":__L"))), 4)
    # break/continue outside any loop is a LOUD failure (diagnostic + exit 2),
    # not a silently discarded identifier -- which is what they were before this
    # rung, and the reason m58's census called them the dangerous failure mode.
    check("stage2 break outside a loop exits 2", run(s2prog, stdin=b"int main(){break;return 1;}")[0], 2)
    check("stage2 continue outside a loop exits 2",
          run(s2prog, stdin=b"int main(){continue;return 1;}")[0], 2)
    check("stage2 break outside a loop emits nothing",
          len(run(s2prog, stdin=b"int main(){break;return 1;}")[1]), 0)
    # `do`, `break` and `continue` are keywords only as whole words: identifiers
    # that merely start with them must still tokenize as identifiers.
    check("stage2 do/break/continue are whole-word keywords",
          _exit_safe("int main(){int done=2;int breaker=3;int continues=4;return done+breaker+continues;}"), 9)

    # THE LOAD-BEARING GUARD. This rung moved the braceless flag from bit 2 to bit 3
    # and widened every block record 12 -> 16 bytes, which is exactly the kind of
    # change that silently perturbs the constructs sharing that stack. Two things
    # are checked, and it is worth being precise about which is which:
    #
    #  (1) BYTE-IDENTITY vs the PRE-RUNG COMPILER, on a corpus using none of
    #      do/break/continue (if/else/while/braceless/nested/recursion/arrays/
    #      structs/strings/goto/short-circuit). Verified during development by
    #      building both compilers through the real ladder and comparing emissions;
    #      it cannot be pinned here because validate.py has only the current
    #      source. CI carries it: stage2-mini-c-demo diffs against git HEAD~1.
    #  (2) What IS pinned here: the behavioural invariance of those same
    #      constructs, plus a byte-level ORDER-INDEPENDENCE witness -- appending a
    #      do-using function must not change one byte of what precedes it. That is
    #      the m54 failure class (a construct silently corrupting only the
    #      functions emitted AFTER it), which is the specific way a block-record
    #      change would go wrong.
    _pre = "int g(){int i=0;while(i<3){i=i+1;}return i;}int main(){return g();}"
    for _tail, _lbl in [
        ("int later(){int j=0;do{j=j+1;}while(j<2);return j;}", "do"),
        ("int later(){int j=0;while(1){j=j+1;if(j>1){break;}}return j;}", "break"),
        ("int later(){int j=0;int s=0;while(j<3){j=j+1;if(j==2){continue;}s=s+j;}return s;}", "continue"),
    ]:
        check(f"stage2 do rung: appended {_lbl} leaves earlier bytes untouched",
              _emit(_pre + _tail).startswith(_emit(_pre)), True)
    for cs, want in [
        ("int main(){int n=10;int s=0;while(n){s=s+n;n=n-1;}return s;}", 55),
        ("int main(){int a=0;if(a){a=1;}else{a=2;}return a;}", 2),
        ("int main(){int i=3;int t=0;while(i){int j=2;while(j){t=t+1;j=j-1;}i=i-1;}return t;}", 6),
        ("int main(){int a=1;if(a) return 7; return 3;}", 7),
        ("int main(){int a=1;int b=0;if(a) if(b) return 1; else return 2; return 3;}", 2),
        ("int f(int n){if(n<2){return n;}return f(n-1)+f(n-2);}int main(){return f(10);}", 55),
    ]:
        check(f"stage2 do rung: prior control flow unchanged -> {want}", _exit_safe(cs), want)

    print("== stage 2 for loops (A25) ==")
    # `for(init; cond; step) body`. The step appears BEFORE the body in the source
    # but must run AFTER it, and m63 deleted backpatching -- so the usual trick of
    # re-lexing the step from a saved source span is not the only option here. This
    # rung takes the other one: emit everything in SOURCE order and jump over the
    # step on the way in, which costs two extra unconditional branches per iteration
    # and no replay machinery at all:
    #
    #     init
    #   :__L<top>
    #     cond; b.eq __L<exit>
    #     b __L<body>
    #   :__L<step>          <- continue target
    #     step
    #     b __L<top>
    #   :__L<body>
    #     body
    #     b __L<step>       <- emitted at the closing brace
    #   :__L<exit>
    #
    # Every label is referenced by construction, so no lazy allocation is needed
    # (unlike do's continue label), and the CLOSE is byte-for-byte the same routine
    # `while` uses -- back-branch to slot a, define slot b -- because a for record is
    # just [a=step, b=exit, c=step+1]. dclose_for does not exist; kind 5 routes to
    # dclose_while.
    #
    # The init and step CLAUSES are compiled by the ordinary statement machinery
    # rather than by bespoke code: the header pushes a phase record (14=init,
    # 15=step) and returns to stmtloop, and stmtend resumes the header when that
    # statement completes. This works with no input-length juggling because
    # compile_expr already terminates cleanly at `;` AND at an unmatched `)` (ceclose
    # -> cc_term), which are exactly the two clause terminators. It is also why an
    # init like `int i = 0` or `p->n = x` or `f(x)` works: whatever the statement
    # machinery can compile, a for clause can hold.
    #
    # The block record grew 16 -> 24 bytes for the step-phase record, which must
    # carry four labels at once (top/exit/step/body) before the body record replaces
    # it. Two stride bugs during development, both caught by these tests and worth
    # recording: doif pushed 5 words instead of 6 (so every record above an `if` was
    # misaligned -- the if's own end label read back as 0), and findloop still walked
    # the stack in 16-byte steps (so break/continue inside a for read a label id out
    # of the middle of a record). Neither is subtle once seen; both were invisible
    # until a program actually nested the constructs.
    def _exit_safe(csrc):
        try:
            return _exit(csrc)
        except Exception as e:
            return f"<{type(e).__name__}>"

    for cs, want in [
        ("int main(){int i;int s;s=0;for(i=0;i<5;i=i+1){s=s+i;}return s;}", 10),
        # the loop variable survives the loop with its final value
        ("int main(){int i;int n;n=0;for(i=0;i<3;i=i+1){n=n+1;}return n*10+i;}", 33),
        # zero-trip: a for tests BEFORE the first body run (unlike do)
        ("int main(){int i;int s;s=0;for(i=0;i<0;i=i+1){s=s+9;}return s;}", 0),
        # M2-Planet's only shape -- all 4 uses are this linked-list walk
        ("struct N{int v;struct N* nx;};int main(){struct N a;struct N b;a.v=3;a.nx=&b;b.v=4;b.nx=0;"
         "struct N* i;int s;s=0;for(i=&a;0 != i;i=i->nx){s=s+i->v;}return s;}", 7),
        ("int main(){int i;int s;s=0;for(i=0;i<4;i=i+1) s=s+i;return s;}", 6),
        ("int main(){int i;int j;int t;t=0;for(i=0;i<3;i=i+1){for(j=0;j<2;j=j+1){t=t+1;}}return t;}", 6),
        ("int main(){int i;int s;s=0;for(i=0;i<9;i=i+1){if(i==4){break;}s=s+1;}return s;}", 4),
        ("int main(){int i;int s;s=0;for(i=0;i<5;i=i+1){if(i==2){continue;}s=s+i;}return s;}", 8),
        # continue must reach the STEP, not the top -- if it jumped to the top this
        # would spin forever rather than returning a wrong answer
        ("int main(){int i;int s;s=0;for(i=0;i<4;i=i+1){continue;}return i;}", 4),
        # a declaration as the init clause, free from reusing the statement machinery
        ("int main(){int s;s=0;for(int i=0;i<4;i=i+1){s=s+i;}return s;}", 6),
        # empty clauses
        ("int main(){int i;i=0;for(;i<5;i=i+1){}return i;}", 5),
        ("int main(){int i;for(i=0;i<5;){i=i+1;}return i;}", 5),
        ("int main(){int i;i=0;for(;;){i=i+1;if(i>6){break;}}return i;}", 7),
        ("int f(int x){return x*2;}int main(){int i;int s;s=0;for(i=1;i<4;i=i+1){s=s+f(i);}return s;}", 12),
        ("int main(){int i;for(i=0;i<9;i=i+1){if(i==3){goto out;}}out:\nreturn i;}", 3),
        ("int main(){int a;int i;int s;a=1;s=0;if(a) for(i=0;i<3;i=i+1) s=s+1; return s;}", 3),
        # break binds to the innermost loop across all three loop forms
        ("int main(){int i;int j;int t;t=0;for(i=0;i<3;i=i+1){j=0;while(1){j=j+1;if(j>1){break;}t=t+1;}}return t;}", 3),
        ("int main(){int i;int t;t=0;for(i=0;i<3;i=i+1){int k;k=0;do{k=k+1;t=t+1;}while(k<2);}return t;}", 6),
    ]:
        check(f"stage2 for exit -> {want}", _exit_safe(cs), want)

    # Structural: the four-label layout, in order.
    import re as _re4
    _emf = _emit("int main(){int i;int s;s=0;for(i=0;i<3;i=i+1){s=s+i;}return s;}")
    _fdefs = [l[1:] for l in _emf.split("\n") if l.startswith(":__L")]
    _frefs = _re4.findall(r"\b(?:b|b\.eq|b\.ne)\s+(__L\w+)", _emf)
    check("stage2 for: four labels", len(_fdefs), 4)
    check("stage2 for: label defs unique", len(_fdefs) == len(set(_fdefs)), True)
    check("stage2 for: every branch target defined", set(_frefs) <= set(_fdefs), True)
    check("stage2 for: every definition referenced", set(_fdefs) <= set(_frefs), True)
    check("stage2 for: no blank emitted line",
          any(l.strip() == "" for l in _emf.split("\n")[:-1]), False)
    # Labels are allocated top, exit, step, body -- so a layout that emits them in
    # the order top, step, body, exit is exactly ids 0, 2, 3, 1. That single
    # assertion pins the whole jump-over shape: if the step were emitted after the
    # body (or the body branch removed) the order would change.
    check("stage2 for: layout order is top, step, body, exit",
          [d[3:] for d in _fdefs],
          ["000000000", "000000002", "000000003", "000000001"])
    # continue targets the STEP label (2nd defined), break targets the EXIT (last).
    _emfc = _emit("int main(){int i;int s;s=0;for(i=0;i<5;i=i+1){if(i==2){continue;}s=s+i;}return s;}")
    _cdefs = [l[1:] for l in _emfc.split("\n") if l.startswith(":__L")]
    check("stage2 for: continue branches to the step label",
          f"b {_cdefs[1]}" in _emfc.split("\n"), True)
    _emfb = _emit("int main(){int i;int s;s=0;for(i=0;i<9;i=i+1){if(i==4){break;}s=s+1;}return s;}")
    _bdefs = [l[1:] for l in _emfb.split("\n") if l.startswith(":__L")]
    # the exit label is the LAST definition emitted (the if inside the body defines
    # one of its own in between, which is why this indexes from the end)
    check("stage2 for: break branches to the exit label",
          f"b {_bdefs[-1]}" in _emfb.split("\n"), True)
    # a for record closes through dclose_while: back branch, then the exit label
    _ftail = [l for l in _emf.split("\n") if l.startswith("b __L") or l.startswith(":__L")][-2:]
    check("stage2 for: closes with a back branch then the exit label",
          [_ftail[0].split()[0], _ftail[1][:4]], ["b", ":__L"])
    # order-independence: appending a for-using function must not perturb what
    # precedes it (the m54 class, and the way a record-width change goes wrong)
    _pre2 = "int g(){int i;i=0;while(i<3){i=i+1;}return i;}int main(){return g();}"
    check("stage2 for: appended for leaves earlier bytes untouched",
          _emit(_pre2 + "int later(){int j;int s;s=0;for(j=0;j<3;j=j+1){s=s+j;}return s;}")
          .startswith(_emit(_pre2)), True)
    # for-free programs must be byte-identical to the pre-rung compiler (CI diffs
    # against HEAD~1); here the behavioural half of that guarantee is pinned.
    for cs, want in [
        ("int main(){int i;i=0;do{i=i+1;}while(i<5);return i;}", 5),
        ("int main(){int n;int s;n=10;s=0;while(n){s=s+n;n=n-1;}return s;}", 55),
        ("int main(){int a;int b;a=1;b=0;if(a) if(b) return 1; else return 2; return 3;}", 2),
        ("int f(int n){if(n<2){return n;}return f(n-1)+f(n-2);}int main(){return f(10);}", 55),
    ]:
        check(f"stage2 for rung: prior control flow unchanged -> {want}", _exit_safe(cs), want)

    print("== stage 2 enum constants (A26) ==")
    # M2-Planet's 10 enum blocks are ALL anonymous, all file-scope, and every member
    # has an explicit integer value -- verified against the vendored source, not
    # assumed. They carry NULL (287 uses), TRUE/FALSE, EOF, stdin/stdout/stderr and
    # EXIT_*, which is precisely why m62 could strip every preprocessor directive and
    # still have those names resolve: they were never macros to begin with.
    #
    # Constants live in their own 16-byte-record table [name_start | name_len | value
    # | pad], names compared against the input buffer exactly as gsymlookup does, so
    # nothing is copied. The lookup sits in ceid_var AFTER local and global variables
    # miss and BEFORE the `adr x0 <name>` function-address fallback. That ordering is
    # the whole design:
    #   - a local or global variable of the same name still shadows the constant
    #   - a function name still becomes an address
    #   - and an identifier that would previously have silently become `adr x0 <undef>`
    #     -- the m55 "faults below NULLFLOOR" shape -- now resolves if it is a constant
    #
    # Implicit values (`enum{A,B,C}`) are supported even though M2-Planet never uses
    # them, because the alternative is not "unsupported" but "silently wrong": without
    # a running counter, `enum{A,B}` would parse as a member followed by junk.
    # Anything else after `=` (an expression, a negative literal, another constant) is
    # a diagnostic plus exit 2 rather than a guess.
    #
    # THE RISK IN THIS RUNG IS NOT enum. To emit a constant's value the compiler needs
    # to emit an integer whose value is in a REGISTER, while emitnum could only emit
    # one whose text was in the input. emitnum was therefore split: emitval does the
    # halfword lowering from a value, emitnum is now a four-line wrapper that parses
    # the token and calls it. Every integer literal in every program flows through the
    # new code, so the byte-identity corpus below spans literals of all four halfword
    # widths -- that is what actually guards this change.
    def _exit_safe(csrc):
        try:
            return _exit(csrc)
        except Exception as e:
            return f"<{type(e).__name__}>"

    for cs, want in [
        ("enum{FALSE=0,TRUE=1,};int main(){return TRUE;}", 1),
        ("enum{FALSE=0,TRUE=1,};int main(){if(FALSE){return 9;}return 5;}", 5),
        ("enum{A=3,B=4};int main(){return A+B;}", 7),
        # trailing comma, as every one of M2-Planet's blocks has
        ("enum{A=3,B=4,};int main(){return A*B;}", 12),
        # implicit values: unused by the target, supported so they cannot be silently wrong
        ("enum{A,B,C};int main(){return C*10+B;}", 21),
        ("enum{A=5,B,C};int main(){return C;}", 7),
        # hex, including the width EOF uses
        ("enum{X=0x10,};int main(){return X;}", 16),
        ("enum{NULLV=0,};int main(){int* p;p=NULLV;if(NULLV==p){return 4;}return 9;}", 4),
        # cc.h's actual layout: blank lines, tabs, comments inside the block
        ("enum\n{\n\tFALSE = 0,\n\tTRUE = 1,\n};\n\nenum\n{\n\t/* c */\n\tKNIGHT = 1,\n\tX86 = 4,\n};\n"
         "int main(){return TRUE+X86;}", 5),
        # a variable of the same name still wins -- the constant is looked up only
        # after locals and globals miss
        ("enum{V=7};int main(){int V;V=2;return V;}", 2),
        # every expression position
        ("enum{N=3};int f(int x){return x*2;}int main(){int a[4];a[N]=N;return a[N]+f(N);}", 9),
        ("enum{LIM=4};int main(){int i;int s;s=0;for(i=0;i<LIM;i=i+1){s=s+i;}return s;}", 6),
        ("enum{STOP=3};int main(){int i;i=0;do{i=i+1;if(i==STOP){break;}}while(i<9);return i;}", 3),
        # a named tag is accepted and its constants still register (M2-Planet has none,
        # but a tag must not be mistaken for the first member)
        ("enum Color{RED=2,BLUE=5};int main(){return RED+BLUE;}", 7),
        # M2libc bootstrap.c's four blocks, verbatim, including EOF = 0xFFFFFFFF
        ("enum\n{\n\tstdin = 0,\n\tstdout = 1,\n\tstderr = 2,\n};\n\nenum\n{\n\tEOF = 0xFFFFFFFF,\n"
         "\tNULL = 0,\n};\n\nenum\n{\n\tEXIT_FAILURE = 1,\n\tEXIT_SUCCESS = 0,\n};\n\nenum\n{\n"
         "\tTRUE = 1,\n\tFALSE = 0,\n};\nint main(){int* p;p = NULL;if(NULL == p){if(TRUE){"
         "return stderr + EXIT_FAILURE;}}return FALSE;}", 3),
    ]:
        check(f"stage2 enum exit -> {want}", _exit_safe(cs), want)

    # A malformed member is a diagnostic plus exit 2, not a guess.
    check("stage2 enum: '=' without an integer exits 2",
          run(s2prog, stdin=b"enum{A=};int main(){return 1;}")[0], 2)
    check("stage2 enum: '=' without an integer emits nothing",
          len(run(s2prog, stdin=b"enum{A=};int main(){return 1;}")[1]), 0)
    check("stage2 enum: an expression value exits 2",
          run(s2prog, stdin=b"enum{A=1+2};int main(){return A;}")[0], 2)
    # An enum block emits no code of its own -- it is a compile-time table only.
    check("stage2 enum: declaration emits nothing",
          _emit("int main(){return 7;}")
          == _emit("enum{A=1,B=2};enum{C=3};int main(){return 7;}"), True)
    # `enum` must not be confused with `else` -- both are 4 characters starting 'e'
    check("stage2 enum: else still works alongside enum",
          _exit_safe("enum{A=1};int main(){int x;x=0;if(x){return 9;}else{return A+1;}}"), 2)
    # identifiers that merely start with a keyword are still identifiers
    check("stage2 enum: 'enumerate' is an identifier",
          _exit_safe("int main(){int enumerate;enumerate=4;return enumerate;}"), 4)

    # THE LOAD-BEARING GUARD for this rung: emitnum was split so that emitval can emit
    # an integer held in a register. EVERY integer literal in every program now flows
    # through that code, so enum-free programs -- spanning literals of all four
    # halfword widths -- must be byte-identical to the pre-rung compiler. CI diffs
    # against HEAD~1; the behavioural half is pinned here.
    for cs, want in [
        ("int main(){return 0x10+2;}", 18),
        ("int main(){return 1+2*3;}", 7),
        ("int main(){return 255;}", 255),
        ("int main(){int a;a=65535;int b;b=65536;if(a<b){return 11;}return 0;}", 11),
        ("int main(){int a;a=4294967295;if(a>0){return 12;}return 0;}", 12),
        ("int main(){int i;int s;s=0;for(i=0;i<5;i=i+1){s=s+i;}return s;}", 10),
        ("int f(int n){if(n<2){return n;}return f(n-1)+f(n-2);}int main(){return f(10);}", 55),
    ]:
        check(f"stage2 enum rung: literal emission unchanged -> {want}", _exit_safe(cs), want)
    # order-independence: an enum block between two functions must not perturb the
    # bytes of the one before it
    _pre3 = "int g(){int i;i=0;while(i<3){i=i+1;}return i;}int main(){return g();}"
    check("stage2 enum: appended enum leaves earlier bytes untouched",
          _emit(_pre3 + "enum{Z=9};int later(){return Z;}").startswith(_emit(_pre3)), True)

    # CROSS-RUNG COMPOSITION (m64 do/break/continue, m65 for, m66 enum). These three
    # landed together and each has its own section above, but nothing yet checked that
    # a constant can drive the new loop forms -- which is the only reason M2-Planet
    # needs them at once: `while(TRUE)` in cc_macro.c is an enum constant driving a
    # do-loop whose body holds three braceless-if breaks.
    for cs, want in [
        # an enum constant as the loop bound of each form
        ("enum{LIM=6};int main(){int i;int s;s=0;for(i=0;i<LIM;i=i+1){s=s+1;}return s;}", 6),
        ("enum{LIM=4};int main(){int i;i=0;while(i<LIM){i=i+1;}return i;}", 4),
        ("enum{T=1};int main(){int n;n=0;do{n=n+1;}while(n<T+3);return n;}", 4),
        # cc_macro.c:912's actual shape: `do { ... if(...) break; } while(TRUE);`
        ("enum{TRUE=1,FALSE=0};int main(){int n;n=0;do{n=n+1;if(n>4) break;}while(TRUE);return n;}", 5),
        # a constant as the guard of a braceless continue, and as the break test
        ("enum{SKIP=2};int main(){int i;int s;s=0;for(i=0;i<5;i=i+1){if(i==SKIP)continue;s=s+i;}return s;}", 8),
        ("enum{STOP=4};int main(){int i;i=0;while(1){i=i+1;if(i==STOP){break;}}return i;}", 4),
        # a constant in the init and step clauses, not just the condition
        ("enum{START=2,STEP=3,LIM=9};int main(){int i;int n;n=0;for(i=START;i<LIM;i=i+STEP){n=n+1;}return n;}", 3),
        # FALSE as a zero-trip condition for each form
        ("enum{FALSE=0};int main(){int i;int s;s=0;for(i=0;i<FALSE;i=i+1){s=9;}return s;}", 0),
        ("enum{FALSE=0};int main(){int n;n=0;do{n=n+1;}while(FALSE);return n;}", 1),
    ]:
        check(f"stage2 enum x loops -> {want}", _exit_safe(cs), want)

    print("== stage 2 capacity: input, data, adr reach (A23) ==")
    # THE COMPLAINT THAT STARTED THIS: hard-coded limits. Three remained after
    # A22 streamed the output, and all three are now structural rather than raised:
    #
    #  A1 input   -- was a SINGLE read() of 65,000 B into a 64 KB region. A single
    #                read on a pipe returns only what is buffered, so it truncated
    #                silently well below even that. Now: one lazily-paged mmap
    #                arena with the tables based 128 MiB up, and a read LOOP. The
    #                input owns everything below the tables; overflow exits 2.
    #  A2 data    -- was a fixed ~124 KB region wedged between the tables, with the
    #                m55 bound reporting overflow. Now there is no data region:
    #                literals and globals are emitted INLINE into the streaming
    #                code output, behind a skip branch, padded to 4-byte alignment.
    #  A3 adr     -- `adr x0 __dN` used to reach a TRAILING data section. adr is
    #                +-1 MB and M2-Planet's code is ~0.7-1.4 MB, so the address was
    #                silently wrong at scale. Inline data is adjacent to its adr,
    #                so the reach is now O(literal size), not O(program size).
    _LENC = 'int len(char* p){int n;n=0;while(p[n]){n=n+1;}return n;}'
    _DQC = chr(34)
    # ---- A2/A3: inline data, correct at every alignment
    for _n in range(0, 9):
        check(f"stage2 inline literal len {_n}",
              _exit_safe(_LENC + 'int main(){return len(' + _DQC + 'x' * _n + _DQC + ');}'), _n)
    _emlit = _emit('int main(){char* s;s=' + _DQC + 'ab' + _DQC + ';return s[1];}')
    check("stage2 literal is emitted INLINE (skip branch present)",
          "b __ds" in _emlit and ":__ds" in _emlit, True)
    check("stage2 inline literal is 4-byte padded (3 bytes -> 4 .byte lines)",
          _emlit.count(".byte"), 4)
    check("stage2 adr targets ADJACENT data (no trailing section)",
          _emlit.index("adr x0 __d") > _emlit.index(":__d"), True)
    # ---- A1: input past the old 64 KB single-read ceiling
    def _many_fns(n):
        return ''.join('int f%d(int a){int b;b=a+%d;if(b>1000){b=b-1000;}return b;}'
                       % (i, i) for i in range(n)) + 'int main(){return f0(7);}'
    for _n, _min in [(150, 8000), (300, 17000), (600, 36000)]:
        _src = _many_fns(_n)
        check(f"stage2 input {len(_src)//1024} KB compiles ({_n} functions)",
              _exit_safe(_src), 7)
    # the 600-function case is 36 KB of input and ~585 KB of output: both past what
    # the pre-A22/A23 compiler could hold. Larger inputs compile too, but stage 1's
    # findlabel is a LINEAR scan (O(n^2) in label count), which the bench interp --
    # roughly 1e4x slower than native -- cannot run in reasonable wall-clock time.
    # That is a bench limit, not a tool limit; CI on real qemu is the witness.
    check("stage2 input above the old 64 KB single-read ceiling emits real output",
          len(_emit(_many_fns(600))) > 500000, True)

    print("== stage 2 word-typed keywords: unsigned / long (A27, m67) ==")
    # `unsigned` and `long` are accepted as SPELLINGS OF THE MACHINE WORD -- the
    # tokenizer returns keyword id 1 (`int`) for both, so every consumer site
    # (funcloop, paramloop, stmtkw/doint, struct fields, fl_global, sizeof) needs
    # no change and cannot drift out of agreement with `int`. TARGET-SUBSET S3
    # licenses exactly this: `/` and `%` are already unsigned and `ceil_div` --
    # `(a + b - 1) / b` -- is the only arithmetic in the self-host that cares.
    # The strongest form of that claim is byte identity, so it is what we check:
    # if the two spellings ever diverge in emitted bytes, they have stopped being
    # the same type and the reasoning above no longer holds.
    for nm, a, b in [
        ("local decl",     "int main(){int a=5;return a;}",
                           "int main(){unsigned a=5;return a;}"),
        ("local decl long","int main(){int a=5;return a;}",
                           "int main(){long a=5;return a;}"),
        ("param + return", "int f(int a,int b){return a*b;}int main(){return f(6,7);}",
                           "unsigned f(unsigned a,long b){return a*b;}int main(){return f(6,7);}"),
        ("global",         "int g;int main(){g=1;return g;}",
                           "long g;int main(){g=1;return g;}"),
        ("pointer param",  "int f(int* p){return *p;}int main(){int x;x=4;return f(&x);}",
                           "int f(unsigned* p){return *p;}int main(){int x;x=4;return f(&x);}"),
        ("array",          "int main(){int a[3];a[1]=4;return a[1];}",
                           "int main(){long a[3];a[1]=4;return a[1];}"),
        ("struct field",   "struct S{int n;};int main(){struct S s;s.n=4;return s.n;}",
                           "struct S{unsigned n;};int main(){struct S s;s.n=4;return s.n;}"),
        ("prototype",      "int f(int,int);int main(){return f(6,7);}int f(int a,int b){return a*b;}",
                           "int f(unsigned,long);int main(){return f(6,7);}"
                           "int f(unsigned a,long b){return a*b;}"),
        # `unsigned char` must reach the BYTE path, not the word path: our `char`
        # is already the unsigned one (ldrb zero-extends), so the C meaning and
        # our lowering coincide exactly.
        ("unsigned char",  "int main(){char s[4];s[0]=65;return s[0];}",
                           "int main(){unsigned char s[4];s[0]=65;return s[0];}"),
        # multi-word runs collapse to ONE type token, so the declarator that
        # follows is the name -- not the second type word.
        ("unsigned int",   "int main(){int a=5;return a;}",
                           "int main(){unsigned int a=5;return a;}"),
        ("long long",      "int main(){int a=5;return a;}",
                           "int main(){unsigned long long a=5;return a;}"),
        # absorption re-enters next_token rather than scanning the input itself,
        # so comment and directive skipping come along for free.
        ("across comment", "int main(){int a=5;return a;}",
                           "int main(){unsigned /* t */ int a=5;return a;}"),
        ("sizeof",         "int main(){return sizeof(int);}",
                           "int main(){return sizeof(unsigned long);}"),
    ]:
        check(f"stage2 word-type '{nm}' emits exactly what int/char emits",
              _emit(a) == _emit(b), True)

    # Behavioural witnesses on the SHAPES THE PINNED SOURCE ACTUALLY WRITES, not
    # invented ones: cc_core.c's ceil_div + global_variable_zero_initialize, and
    # M2libc's long-typed ftell/fseek and file-scope _malloc_ptr.
    for cs, want in [
        # cc_core.c:2059 -- the only arithmetic that cares about unsignedness
        ("unsigned ceil_div(unsigned a,unsigned b){return (a+b-1)/b;}"
         "int main(){return ceil_div(10,4);}", 3),
        # cc_core.c:2988 -- `unsigned i = ceil_div(...)` driving a != 0 loop
        ("unsigned ceil_div(unsigned a,unsigned b){return (a+b-1)/b;}"
         "int gz(int size){unsigned i;int n;i=ceil_div(size,8);n=0;"
         "while(i!=0){n=n+1;i=i-1;}return n;}int main(){return gz(60);}", 8),
        # cc_core.c:2091 -- an uninitialised unsigned local among other locals
        ("int main(){unsigned d;int n;n=6;d=7;return d*n;}", 42),
        # THE FOUR REAL `long` SITES. All of them are in M2libc/bootstrap.c, which IS
        # in the --bootstrap-mode -f list, and all four are the brk allocator:
        # `long _malloc_ptr;` / `long _brk_ptr;` at file scope (95,96) and
        # `long old_brk = _brk_ptr;` / `long old_malloc = _malloc_ptr;` as locals
        # (110,115), the first of which is declared INSIDE an if block after
        # statements. An earlier draft anchored these to stdio.c's ftell/fseek, which
        # the self-host never compiles -- see the -f list note in the A28 section.
        ("long _malloc_ptr;long _brk_ptr;int main(){_brk_ptr=7;_malloc_ptr=_brk_ptr*6;"
         "return _malloc_ptr;}", 42),
        ("int f(int n){if(n>0){long old_brk=n;return old_brk+41;}return 0;}"
         "int main(){return f(1);}", 42),
        ("int main(){int n;n=1;long old_malloc;old_malloc=41;return old_malloc+n;}", 42),
        # and, now that m69 supplies brk, the allocator those four sites are FOR --
        # M2libc/bootstrap.c's malloc in as close to verbatim shape as the subset
        # allows. This is the real witness: `long` exists in the TU to hold a break.
        ("long _malloc_ptr;long _brk_ptr;"
         "int malloc(int size){"
         "if(0==_brk_ptr){_brk_ptr=brk(0);_malloc_ptr=_brk_ptr;}"
         "if(_brk_ptr<_malloc_ptr+size){"
         "long old_brk;old_brk=_brk_ptr;_brk_ptr=brk(_malloc_ptr+size);"
         "if(_brk_ptr==old_brk){return 0;}}"
         "long old_malloc;old_malloc=_malloc_ptr;_malloc_ptr=_malloc_ptr+size;"
         "return old_malloc;}"
         "int main(){char* p;p=malloc(64);p[0]=42;return p[0];}", 42),
        # M2libc/stdio.c:469,556 -- the two-word `unsigned int` parameter
        ("int f(unsigned int value,int base){return value*base;}"
         "int main(){return f(7,6);}", 42),
        # M2libc/stdio.c:80,332 -- prototype with a named unsigned parameter
        ("int rd(int fd,char* buf,unsigned count);int main(){return rd(0,0,42);}"
         "int rd(int fd,char* buf,unsigned count){return count;}", 42),
        ("int main(){int s;s=0;for(unsigned i=0;i<4;i=i+1){s=s+i;}return s;}", 6),
    ]:
        check(f"stage2 word-type exit -> {want}", _exit_safe(cs), want)

    # WHOLE-WORD matching. The recognizers are length-dispatched, so a prefix can
    # never match, but an identifier that merely BEGINS with the keyword shares
    # the dispatch arm and is the case that would break first.
    for cs, want in [
        ("int main(){int longitude;int unsignedly;longitude=40;unsignedly=2;"
         "return longitude+unsignedly;}", 42),
        ("int main(){int lon;lon=42;return lon;}", 42),
        ("int main(){int unsigne;unsigne=42;return unsigne;}", 42),
        # bootstrappable.c:163 -- `signed_p` is a parameter name, not a type
        ("int int2str(int x,int signed_p){return x+signed_p;}"
         "int main(){return int2str(40,2);}", 42),
    ]:
        check("stage2 word-type: identifiers sharing the prefix are identifiers",
              _exit_safe(cs), want)

    # The `int` path is untouched, so a keyword-free program must be byte-identical
    # to what the pre-A27 compiler emitted. Checked here as a self-consistency
    # property: the constructs below all route through the same tokenizer arms the
    # new keywords were added to (nt_kw4: else/enum/goto/char; nt_kw8: continue).
    check("stage2 word-type: nt_kw4 arms (char/else/enum/goto) still lex",
          _exit_safe("enum{A=1};int main(){char c;c=2;int i;i=0;lp:i=i+1;"
                     "if(i<3){goto lp;}else{c=c+A;}return c+i;}"), 6)
    check("stage2 word-type: nt_kw8 arm (continue) still lexes",
          _exit_safe("int main(){int i;int s;s=0;for(i=0;i<5;i=i+1){"
                     "if(i==3){continue;}s=s+i;}return s;}"), 7)

    print("== stage 2 identifier type names: FILE / FUNCTION / size_t (A28, m68) ==")
    # These are NOT keywords -- they are type NAMES M2-Planet pre-registers as
    # primitives (cc_types.c), so hardcoding them would be the wrong shape and would
    # not cover a typedef later. Instead the two positions that still REQUIRED a
    # keyword now accept an identifier in type position, which is what the other two
    # positions have always done: funcloop treats an unknown leading word as `int`
    # (the accident that makes `void` work) and fl_global follows it.
    #
    # Derived against the pinned tree rather than the doc's list, which was wrong in
    # both directions. The translation unit is the --bootstrap-mode -f list in
    # m2-planet/test/test1000/hello-aarch64.sh -- NOT the makefile, which is the gcc
    # build (it passes gcc_req.h and no M2libc bootstrap files). On that real list:
    # FILE 23 uses, FUNCTION 5, size_t ZERO (its 41 uses are all in stdio/stdlib/
    # string, none of which the self-host compiles) and ssize_t zero anywhere -- it is
    # registered for mes.c. gcc_req.h is genuinely absent from the -f list, which is
    # what licenses treating it as a substitution rather than a capability.
    for cs, want in [
        # cc_core.c:988,1000,1025 -- FUNCTION is a plain VALUE parameter, then called.
        # The bl-vs-blr split is read off the symbol tables, so once the parameter is
        # actually declared the call through it lowers to ldr x16 / blr with no
        # further work -- which is the whole reason this is a parser fix, not codegen.
        ("int inc(int x){return x+1;}int apply(FUNCTION f,int v){return f(v);}"
         "int main(){return apply(inc,41);}", 42),
        ("int inc(int x){return x+1;}int dbl(int x){return x*2;}"
         "int g(FUNCTION f,char* s,char* nm,FUNCTION it){return f(20)+it(21);}"
         "int main(){return g(inc,0,0,inc);}", 43),
        ("int inc(int x){return x+1;}int main(){FUNCTION f;f=inc;return f(41);}", 42),
        ("int inc(int x){return x+1;}FUNCTION h;int main(){h=inc;return h(41);}", 42),
        # cc_core.c:62,73 / cc.c:45 / cc_reader.c:24 / cc_macro.c:642 -- FILE is
        # always FILE*, at every scope.
        ("int wr(FILE* out,int n){return n;}int main(){return wr(0,42);}", 42),
        ("int rat(FILE* a,char* c,char* fn){return a[0]+42;}"
         "int main(){char b[2];b[0]=0;return rat(b,0,0);}", 42),
        ("char* g;int main(){FILE* in=g;return 42;}", 42),
        ("int main(){FILE* f;f=0;if(f){return 9;}return 42;}", 42),
        ("FILE* input;int main(){input=0;return 42;}", 42),
        ("int rd(FILE* f){return f[0];}int main(){char b[2];b[0]=42;return rd(b);}", 42),
        # size_t / ssize_t / va_list / any future pre-registered or typedef'd name --
        # the rule is positional, so none of them is named anywhere in the compiler.
        ("int f(size_t n,int v){return n+v;}int main(){return f(40,2);}", 42),
        ("int main(){size_t n;n=42;return n;}", 42),
        ("int main(){size_t n=42;return n;}", 42),
        ("int f(ssize_t n){return n;}int main(){return f(42);}", 42),
        ("int f(va_list ap,int n){return n;}int main(){return f(0,42);}", 42),
        ("int inc(int x){return x+1;}int g(FILE* out,FUNCTION f,int v){return f(v);}"
         "int main(){return g(0,inc,41);}", 42),
        # An identifier-typed ARRAY is the case that needs `prescan` as well as the
        # parser -- see the frame-size check below.
        ("int sum(size_t* p,int n){int i;int s;i=0;s=0;while(i<n){s=s+p[i];i=i+1;}"
         "return s;}int main(){size_t a[3];a[0]=1;a[1]=2;a[2]=39;return sum(a,3);}", 42),
        ("int f(FILE* o,int n){int a;int b;int c;a=1;b=2;c=n;return a+b+c;}"
         "int main(){return f(0,39);}", 42),
    ]:
        check(f"stage2 identifier type name exit -> {want}", _exit_safe(cs), want)

    # THE DISAMBIGUATION. A statement-initial identifier is a declaration only when
    # it is followed by (stars and) another identifier; everything else must stay
    # exactly what it was. These are the forms that share the entry point.
    for nm, cs, want in [
        ("(void) param list stays empty", "int f(void){return 42;}int main(){return f();}", 42),
        ("void return + (void) params",   "void g(void){return;}int main(){g();return 42;}", 42),
        ("call statement",   "int s;int f(int n){s=n;return 0;}int main(){f(42);return s;}", 42),
        ("assignment",       "int main(){int a;a=42;return a;}", 42),
        ("subscript store",  "int main(){int a[2];a[1]=42;return a[1];}", 42),
        ("member store",     "struct S{int v;};int main(){struct S s;s.v=42;return s.v;}", 42),
        ("arrow store",      "struct S{int v;};int main(){struct S s;struct S* p;p=&s;"
                             "p->v=42;return p->v;}", 42),
        ("label definition", "int main(){int i;i=0;lp:i=i+1;if(i<42){goto lp;}return i;}", 42),
        ("multiply",         "int main(){int a;int b;a=6;b=7;return a*b;}", 42),
        ("deref store",      "int main(){int x;int* p;p=&x;*p=42;return x;}", 42),
        ("char** argv",      "int main(int argc,char** argv){return 42;}", 42),
    ]:
        check(f"stage2 identifier type name: {nm} is unchanged", _exit_safe(cs), want)

    # `prescan` sums declaration sizes to reserve the frame, and it only counted
    # KEYWORD-introduced declarations -- so an identifier-typed array under-sized the
    # frame and a call clobbered it (exactly the m39 failure the prescan exists to
    # prevent; it surfaced here as a wrong sum, not a crash). prescan and the
    # statement parser must apply the SAME rule or the reserved frame will not match
    # what was declared, so the check is emitted-code equality against the `int`
    # spelling rather than merely a correct exit code.
    for nm, a, b in [
        ("array",        "int main(){int a[3];a[0]=1;return a[0];}",
                         "int main(){size_t a[3];a[0]=1;return a[0];}"),
        ("scalar",       "int main(){int n;n=42;return n;}",
                         "int main(){size_t n;n=42;return n;}"),
        ("pointer",      "int main(){char* p;p=0;return 42;}",
                         "int main(){FILE* p;p=0;return 42;}"),
        ("param",        "int f(char* p,int n){return n;}int main(){return f(0,42);}",
                         "int f(FILE* p,int n){return n;}int main(){return f(0,42);}"),
        ("decl after decl", "int main(){int a;int b;a=1;b=41;return a+b;}",
                            "int main(){int a;size_t b;a=1;b=41;return a+b;}"),
        ("array after scalar", "int main(){int n;int a[3];n=1;a[0]=41;return n+a[0];}",
                               "int main(){int n;size_t a[3];n=1;a[0]=41;return n+a[0];}"),
    ]:
        check(f"stage2 identifier type name {nm}: frame matches the int spelling",
              _emit(a) == _emit(b), True)

    # The one shape that must NOT be swallowed by the prescan rule: a multiplication
    # whose left operand starts a statement-initial expression. `a = b * c;` has the
    # pair AFTER an `=`, so the statement-start flag keeps it out.
    check("stage2 identifier type name: 'a = b * c;' is not a declaration",
          _exit_safe("int main(){int a;int b;int c;b=6;c=7;a=b*c;return a;}"), 42)
    check("stage2 identifier type name: multiply after a decl-with-init",
          _exit_safe("int main(){int b;int c;b=6;c=7;int a=b*c;return a;}"), 42)

    print("== stage 2 brk builtin (A29, m69) ==")
    # The LAST of the m53 syscall family. M2libc/aarch64/linux/bootstrap.c defines
    # exactly six functions in asm(): read, write, open, close, brk, exit -- and m53
    # already supplies five of them with matching syscall numbers and argument order,
    # deliberately, so that omitting that one file stays possible. brk is the sixth,
    # so this rung is what makes asm() unnecessary rather than merely deferred.
    # Same contract as every other builtin: lowered to a direct bl, wrapper appended
    # once if used, and a user definition wins.
    for nm, cs, want in [
        ("brk(0) returns a break", "int main(){int p;p=brk(0);if(p){return 42;}return 9;}", 42),
        ("brk grows and returns the new break",
         "int main(){int a;int b;a=brk(0);b=brk(a+4096);if(b>a){return 42;}return 9;}", 42),
        # M2libc/bootstrap.c's malloc verbatim in shape: brk(0) to find the break,
        # then grow it. This is the allocator that would override our calloc/free.
        ("m2libc malloc shape allocates usable memory",
         "long _brk_ptr;long _malloc_ptr;"
         "int mymalloc(int size){if(_brk_ptr==0){_brk_ptr=brk(0);_malloc_ptr=_brk_ptr;}"
         "if(_brk_ptr<_malloc_ptr+size){_brk_ptr=brk(_malloc_ptr+size+4096);}"
         "int old;old=_malloc_ptr;_malloc_ptr=_malloc_ptr+size;return old;}"
         "int main(){char* p;p=mymalloc(64);p[0]=42;return p[0];}", 42),
        ("two brk blocks are distinct and persist",
         "long _brk_ptr;long _malloc_ptr;"
         "int mymalloc(int size){if(_brk_ptr==0){_brk_ptr=brk(0);_malloc_ptr=_brk_ptr;}"
         "if(_brk_ptr<_malloc_ptr+size){_brk_ptr=brk(_malloc_ptr+size+4096);}"
         "int old;old=_malloc_ptr;_malloc_ptr=_malloc_ptr+size;return old;}"
         "int main(){char* a;char* b;a=mymalloc(32);b=mymalloc(32);a[0]=2;b[0]=40;"
         "return a[0]+b[0];}", 42),
        # smainpre already reserves the value/frame stacks with brk 214, so a program
        # that ALSO calls brk must not disturb them -- the stacks live below brk(0).
        ("growing the break does not disturb the value/frame stacks",
         "int f(int n){if(n==0){return 0;}return n+f(n-1);}"
         "int main(){int p;p=brk(0);brk(p+8192);return f(8)+6;}", 42),
        ("a user brk definition wins", "int brk(int a){return 42;}int main(){return brk(0);}", 42),
    ]:
        check(f"stage2 brk: {nm}", _exit_safe(cs), want)
    check("stage2 brk: unused emits no wrapper", ":brk" in _emit("int main(){return 42;}"), False)
    check("stage2 brk: used emits the wrapper exactly once",
          _emit("int main(){return brk(0);}").count(":brk\n"), 1)
    check("stage2 brk: wrapper uses syscall 214",
          "mov x8 214" in _emit("int main(){return brk(0);}"), True)
    check("stage2 brk: user definition suppresses the builtin wrapper",
          _emit("int brk(int a){return 42;}int main(){return brk(0);}").count(":brk\n"), 1)
    check("stage2 brk: call lowers to a direct bl",
          "bl brk" in _emit("int main(){return brk(0);}"), True)

    print("== stage 2 pointer-to-pointer type model (A30, m69) ==")
    # `argv[i]` (29 uses in cc.c) needs an 8-byte stride, but the gap was never
    # argv-specific: the flags word had is_char / is_array / is_ptr and no notion of
    # an element that is ITSELF a pointer, so `char* a[N]` and `int* a[N]` were broken
    # as locals too. A fourth bit (16) records it, and every byte-vs-word decision
    # becomes (flags & 17) == 1 -- byte only when the element really is a char.
    # Two declarator bugs fell out of the same place: only ONE star was ever consumed,
    # so `char** argv` declared a variable literally named `*`; and di_array/flg_array
    # tested `flags != 0` rather than the char bit, so `int* a[N]` was byte-SIZED.
    for nm, cs, want in [
        ("char* a[N], two distinct elements",
         "int main(){char* a[2];char x[2];char y[2];x[0]=1;y[0]=41;a[0]=x;a[1]=y;"
         "char* p;char* q;p=a[0];q=a[1];return p[0]+q[0];}", 42),
        ("int* a[N], two elements",
         "int main(){int* a[2];int x;int y;x=1;y=41;a[0]=&x;a[1]=&y;"
         "int* p;int* q;p=a[0];q=a[1];return *p+*q;}", 42),
        ("char* a[N] indexed by a variable",
         "int main(){char* a[3];char x[2];x[0]=42;a[2]=x;int i;i=2;"
         "char* p;p=a[i];return p[0];}", 42),
        # the argv shapes, from cc.c
        ("char** param, v[i] read",
         "int f(char** v,int i){char* p;p=v[i];return p[0];}"
         "int main(){char* a[2];char x[2];char y[2];x[0]=9;y[0]=42;a[0]=x;a[1]=y;"
         "return f(a,1);}", 42),
        ("char** param, v[i+1] (cc.c:91,103,164,214)",
         "int f(char** v,int i){char* p;p=v[i+1];return p[0];}"
         "int main(){char* a[2];char x[2];char y[2];x[0]=9;y[0]=42;a[0]=x;a[1]=y;"
         "return f(a,0);}", 42),
        ("char** element compared against NULL (cc.c:85)",
         "int f(char** v,int i){if(v[i]==0){return 42;}return 9;}"
         "int main(){char* a[2];a[0]=0;return f(a,0);}", 42),
        ("char** element passed to a char* param (match(argv[i],..))",
         "int g(char* s){return s[0];}int f(char** v,int i){return g(v[i]);}"
         "int main(){char* a[2];char x[2];x[0]=42;a[1]=x;return f(a,1);}", 42),
        ("store through a char** parameter",
         "int f(char** v,char* s){v[1]=s;return 0;}"
         "int main(){char* a[2];char x[2];x[0]=42;f(a,x);char* p;p=a[1];return p[0];}", 42),
        ("char** local", "int main(){char* a[2];char x[2];x[0]=42;a[1]=x;char** v;v=a;"
                          "char* p;p=v[1];return p[0];}", 42),
        ("char** global", "char** g;int main(){char* a[2];char x[2];x[0]=42;a[1]=x;g=a;"
                           "char* p;p=g[1];return p[0];}", 42),
        ("char* a[N] global", "char* g[2];int main(){char x[2];x[0]=42;g[1]=x;"
                               "char* p;p=g[1];return p[0];}", 42),
        ("*v on a char** is a word load",
         "int main(){char* a[2];char x[2];x[0]=42;a[0]=x;char** v;v=a;"
         "char* p;p=*v;return p[0];}", 42),
        ("&a[i] on a pointer array is word-strided",
         "int main(){char* a[3];char x[2];x[0]=42;a[2]=x;char** e;e=&a[2];"
         "char* p;p=*e;return p[0];}", 42),
    ]:
        check(f"stage2 pointer-to-pointer: {nm}", _exit_safe(cs), want)

    # REGRESSION: a real char array/pointer must stay BYTE-accessed. These are the
    # cases the new bit has to leave alone, and they are the whole A3d memory model.
    for nm, cs, want in [
        ("char s[N] byte-packed and byte-indexed",
         "int main(){char s[4];s[0]=65;s[1]=42;return s[1];}", 42),
        ("char* p deref is a byte load",
         "int main(){char s[2];s[0]=42;char* p;p=s;return *p;}", 42),
        ("char* p subscript is byte",
         "int main(){char s[3];s[2]=42;char* p;p=s;return p[2];}", 42),
        ("string literal indexing is byte", 'int main(){char* m;m="*";return m[0];}', 42),
        ("strlen shape",
         "int len(char* p){int n;n=0;while(p[n]){n=n+1;}return n;}"
         'int main(){return len("hello")+37;}', 42),
        ("int a[N]", "int main(){int a[3];a[2]=42;return a[2];}", 42),
        ("int* p deref", "int main(){int x;x=42;int* p;p=&x;return *p;}", 42),
    ]:
        check(f"stage2 pointer-to-pointer: {nm} unchanged", _exit_safe(cs), want)

    # The declarator now consumes a RUN of stars, so `char** argv` names argv rather
    # than `*`. The param COUNT is unchanged (the old code declared a junk second
    # param), which is why the emitted code for main is byte-identical -- the fix is
    # visible only when the name is used.
    check("stage2 pointer-to-pointer: char** argv is named, not '*'",
          _exit_safe("int main(int argc,char** argv){return 42;}"), 42)
    # Out of subset, and NOT needed: chained subscript on a temporary (v[i][j]).
    # Zero uses in the self-host TU -- cc.c only ever writes argv[i] and argv[i+1].
    check("stage2 pointer-to-pointer: v[i][j] is still out of subset",
          _exit_safe("int f(char** v){return v[1][0];}"
                     "int main(){char* a[2];char y[2];y[0]=42;a[1]=y;return f(a);}") == 42,
          False)

    print("== stage 2 argc/argv from _start (A31, m70) ==")
    # cc.c's option loop is 29 argv uses, and until m69 there was nothing to index it
    # with -- argv is useless if argv[i] has the wrong stride -- which is why this
    # waited on the pointer-to-pointer model rather than landing earlier.
    #
    # At _start the kernel hands the process a stack whose top word is argc, followed
    # by argc pointers, a NULL, then envp. The preamble copies SP into an ordinary
    # register (`add x3 x31 0`, which IS `mov x3, sp` -- ADD-immediate treats Rn=31 as
    # SP, byte-checked against real `as` in CI because the REGISTER form treats Rm=31
    # as XZR instead) and pushes argc then argv, in that order, because a call
    # evaluates arguments left-to-right and the callee pops them in reverse.
    #
    # The pushes are UNCONDITIONAL: the compiler is single-pass and emits the preamble
    # long before it has seen main's declarator. For `int main()` the two values are
    # simply never popped -- a two-slot leak on a 32 KB value stack, once per program.
    #
    # The bench had no x31 at all before this (R was x0..x30), so none of this could be
    # tested here; interp.py now models the initial process stack and run() takes an
    # argv= list. That is the m50/m51 rule again: model it so the bench WITNESSES the
    # behaviour instead of being less capable than reality.
    def _exit_argv(csrc, args):
        try:
            _, resolved = run(s1prog, stdin=_emit(csrc).encode())
            rc, _ = run(assemble(resolved.decode())[1], argv=args)
            return rc
        except RuntimeError as e:
            return f"<{e}>"
        except OOBAccess:
            return "<oob>"
    _A = ["prog", "-o", "out"]
    for nm, cs, args, want in [
        ("argc with no arguments", "int main(int argc,char** argv){return argc;}", None, 1),
        ("argc with two arguments", "int main(int argc,char** argv){return argc;}", _A, 3),
        ("argv[0][0]", "int main(int argc,char** argv){char* p;p=argv[0];return p[0];}", _A, 112),
        ("argv[1][0] is the dash of -o",
         "int main(int argc,char** argv){char* p;p=argv[1];return p[0];}", _A, 45),
        ("argv[1][1] is the o of -o",
         "int main(int argc,char** argv){char* p;p=argv[1];return p[1];}", _A, 111),
        ("argv[i] with a variable index",
         "int main(int argc,char** argv){int i;i=2;char* p;p=argv[i];return p[0];}", _A, 111),
        ("argv[i+1] -- the cc.c option-argument shape",
         "int main(int argc,char** argv){int i;i=1;char* p;p=argv[i+1];return p[0];}", _A, 111),
        ("argv[argc] is the NULL terminator",
         "int main(int argc,char** argv){if(argv[argc]==0){return 42;}return 9;}", _A, 42),
        # cc.c's option loop in miniature, over a real argv
        ("cc.c option loop: match(argv[i],\"-o\")",
         "int eq(char* a,char* b){int i;i=0;while(a[i]){if(a[i]!=b[i]){return 0;}i=i+1;}"
         "if(b[i]){return 0;}return 1;}"
         "int main(int argc,char** argv){int i;i=1;while(i<argc){"
         "if(eq(argv[i],\"-o\")){return 42;}i=i+1;}return 9;}", _A, 42),
        ("argv passed on to a char** parameter",
         "int f(char** v,int i){char* p;p=v[i];return p[0];}"
         "int main(int argc,char** argv){return f(argv,1);}", _A, 45),
        # main WITHOUT parameters: the two pushed values are never popped, and the
        # return value is still the top of the value stack.
        ("int main() with no parameters", "int main(){return 42;}", _A, 42),
        ("int main(void)", "int main(void){return 42;}", _A, 42),
        ("recursion under the new preamble",
         "int f(int n){if(n<2){return n;}return f(n-1)+f(n-2);}"
         "int main(int argc,char** argv){return f(10);}", _A, 55),
        ("calloc under the new preamble",
         "int main(int argc,char** argv){char* p;p=calloc(4,8);p[0]=42;return p[0];}", _A, 42),
    ]:
        check(f"stage2 argv: {nm}", _exit_argv(cs, args), want)

    _av = _emit("int main(int argc,char** argv){return argc;}")
    _pre = _av[:_av.index("bl main")]
    check("stage2 argv: preamble reads sp (add x3 x31 0)", "add x3 x31 0" in _pre, True)
    check("stage2 argv: argc loaded from [sp]", "ldr x0 x3" in _pre, True)
    check("stage2 argv: argv is sp+8", "add x0 x3 8" in _pre, True)
    check("stage2 argv: exactly two pushes before bl main", _pre.count("str x0 x9"), 2)
    # SP is copied out and never used as a load/store base: an SP-based access faults
    # unless SP is 16-byte aligned, and nothing in this ladder maintains that.
    check("stage2 argv: SP is never a load base", "ldr x0 x31" in _av, False)
    check("stage2 argv: SP is never a store base", "str x0 x31" in _av, False)
    # This rung changes every program's first 7 instructions, so plain byte-identity
    # is the wrong guard; the right one is that the change is CONFINED to the preamble.
    check("stage2 argv: the preamble is exactly 7 lines longer",
          _pre.count("\n") - _emit("int main(){return 42;}")[
              :_emit("int main(){return 42;}").index("bl main")].count("\n"), 0)

if FAILS:
    print(f"\nFAILED: {FAILS}\nThe bench no longer matches CI ground truth — fix before trusting it.")
    sys.exit(1)
print("\nAll bench checks pass — model matches known CI results.")
