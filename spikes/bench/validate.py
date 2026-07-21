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
from interp import run, asm_run

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
        rc, _ = run(assemble(_emit(csrc))[1]); return rc
    em = _emit("int main(){int a=5;int b=a+2;return b;}")
    check("stage2 var load is word (ldr w0 x1)",  "ldr w0 x1" in em, True)
    check("stage2 var store is word (str w0 x1)", "str w0 x1" in em, True)
    check("stage2 no byte var load (no ldrb x1)", "ldrb w0 x1" in em, False)
    check("stage2 no byte var store (no strb x1)","strb w0 x1" in em, False)
    # Variables are word-sized and 4 bytes apart in the frame: var 'b' (index 1)
    # sits at offset 4 after 'a' (index 0). (The old labeled 4x.byte slot table is
    # gone — variables are frame-relative now; see the frame-relative section.)
    check("stage2 frame stride is 4 (a@000, b@004)",
          ("add x1 x10 000" in em) and ("add x1 x10 004" in em), True)
    for cs, want in [("int main(){int a=5;int b=a+2;return b;}", 7),
                     ("int main(){int a=10;return a*a;}", 100),
                     ("int main(){int x=7;return (x+1)*2;}", 16)]:
        check(f"stage2 exit {cs[:34]}", _exit(cs), want)

    print("== stage 2 control flow: if / while / reassignment ==")
    # Structural: if/while emit a zero-test and a numeric backpatched branch. Since
    # both variables (frame-relative) and control flow (backpatched) are label-free,
    # the emitted program contains no labels at all.
    emif = _emit("int main(){int a=1;if(a){a=a+1;}return a;}")
    check("stage2 if emits zero-test",              "cmp x0 0" in emif, True)
    check("stage2 if skips on false (b.eq @)",      "b.eq @" in emif, True)
    check("stage2 if emits no label",               any(l.startswith(":") for l in emif.split("\n")), False)
    emwh = _emit("int main(){int a=3;while(a){a=a-1;}return a;}")
    check("stage2 while branches back (b @)",        "\nb @" in emwh, True)
    check("stage2 while exits on false (b.eq @)",    "b.eq @" in emwh, True)
    check("stage2 while emits no label",             any(l.startswith(":") for l in emwh.split("\n")), False)
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

    print("== stage 2 frame-relative variables (no per-variable labels) ==")
    # Variables now live at x10+off in a brk frame (off=(c-'a')*4), emitted via an
    # offset table — so the emitted program carries NO :a..:z slot labels and the
    # prologue sets up the frame base. This removes the per-variable label cost
    # (control flow is backpatched too, so the emitted program is fully label-free).
    emfr = _emit("int main(){int a=5;int b=7;return a+b;}")
    check("stage2 prologue sets frame base (mov x10 x0)", "mov x10 x0" in emfr, True)
    check("stage2 var access is frame-relative (add x1 x10)", "add x1 x10 " in emfr, True)
    check("stage2 no :a slot label", ":a\n" in emfr, False)
    check("stage2 no :z slot label", ":z\n" in emfr, False)
    check("stage2 no adr-to-var (adr x1 a)", "adr x1 a" in emfr, False)
    check("stage2 var 'a' -> offset 000", "add x1 x10 000" in emfr, True)
    check("stage2 var 'b' -> offset 004", "add x1 x10 004" in emfr, True)
    # 'z' is index 25 -> offset 100 (the largest); exercises the 3-digit path.
    emz = _emit("int main(){int z=25;return z*4;}")
    check("stage2 var 'z' -> offset 100", "add x1 x10 100" in emz, True)
    # if/while are backpatched, so they emit no labels either — the emitted program
    # is now entirely label-free (this is verified in the backpatch section below).
    emcf = _emit("int main(){int a=1;if(a){a=a+1;}return a;}")
    check("stage2 emitted program has no labels", any(l.startswith(":") for l in emcf.split("\n")), False)
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

    print("== stage 2 backpatched control flow (label-free emitted output) ==")
    # if/while branches are now emitted as numeric b.eq @<pos> / b @<pos> with the
    # target position backpatched when the block closes, so the emitted program has
    # NO labels at all (frame-relative vars + backpatched branches). This lifts the
    # per-if/while label cost; a program's control flow is bounded by nothing but memory.
    emif = _emit("int main(){int a=0;if(a){return 7;}return 9;}")
    check("stage2 emitted output has NO labels", any(l.startswith(":") for l in emif.split("\n")), False)
    check("stage2 if uses numeric branch (b.eq @)", "b.eq @" in emif, True)
    check("stage2 no label-based branch (b.eq A)", "b.eq A" in emif, False)
    emwh = _emit("int main(){int i=0;int s=0;while(i<3){s=s+1;i=i+1;}return s;}")
    check("stage2 while uses backward numeric branch (b @)", "\nb @" in emwh, True)
    check("stage2 while emitted output has NO labels", any(l.startswith(":") for l in emwh.split("\n")), False)
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

    print("== stage 2 large programs (enlarged input/output/stack buffers) ==")
    # The compiler's buffers were raised (input 64KB, output 256KB, bigger stacks),
    # so large programs no longer overflow the old ~4.4KB output buffer. Combined
    # with label-free codegen, control-flow count is now bounded only by memory.
    # A program with 150 sequential if-blocks emits ~65KB and must still run.
    def _many_ifs(n):
        return "int main(){int a=0;" + "".join("if(a<10000){a=a+1;}" for _ in range(n)) + "return a;}"
    big80 = _emit(_many_ifs(80))
    check("stage2 80-block program emits >30KB", len(big80) > 30000, True)
    check("stage2 80-block program still label-free", any(l.startswith(":") for l in big80.split("\n")), False)
    for n in (20, 40, 80, 150):
        check(f"stage2 {n} sequential if-blocks -> exit {n & 0xFF}", _exit(_many_ifs(n)), n & 0xFF)
    # a long-running loop with a big body (stresses output size a different way)
    bigbody = "int main(){int s=0;int i=0;while(i<200){" + "s=s+1;"*20 + "i=i+1;}return s;}"
    check("stage2 big-body loop (200x20) -> 160", _exit(bigbody), 4000 & 0xFF)

if FAILS:
    print(f"\nFAILED: {FAILS}\nThe bench no longer matches CI ground truth — fix before trusting it.")
    sys.exit(1)
print("\nAll bench checks pass — model matches known CI results.")
