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

print("== stage 1 label pool holds >62 distinct labels (expanded pool) ==")
# stage1 maps each multi-char label to a single-char pool slot; the pool is the
# hard cap on distinct labels per program. It was expanded past the original 62
# (A-Za-z0-9) with punctuation chars, which stage0-as accepts as labels (symtab
# is indexed by the raw byte). Guard: a program with N distinct labels must
# resolve AND assemble AND run through the real ladder, exercising the new chars.
if os.path.exists(s1p):
    _, s1prog, _ = assemble(open(s1p).read())
    def _chain(n):                       # fall-through chain: exit code == n iff
        L = ["mov x0 0"]                 # every label resolved to the right offset
        for i in range(n):
            L += [f"b L{i:03}", f":L{i:03}", "add x0 x0 1"]
        return "\n".join(L + ["mov x8 93", "svc"]) + "\n"
    for n in (62, 63, 70, 76):           # 63+ forces punctuation pool slots
        _, res = run(s1prog, stdin=_chain(n).encode())
        rc, _ = run(assemble(res.decode())[1])
        check(f"stage1 resolves {n} labels -> ladder exit {n}", rc, n & 0xFF)
    # the pool slots at/after index 62 must be non-alphanumeric (the new chars)
    _, res = run(s1prog, stdin=_chain(76).encode())
    defs = [ln[1] for ln in res.decode().split("\n") if ln.startswith(":") and len(ln) == 2]
    check("stage1 pool slot 63 is a new (punct) char", defs[63].isalnum(), False)
    # backward branch + adr to a high-index (punctuation) label must resolve too
    fill = "\n".join(f"b F{i:03}\n:F{i:03}" for i in range(63))
    loop = fill + "\nmov x0 0\nmov x1 5\n:LOOP\nadd x0 x0 1\ncmp x0 x1\nb.ne LOOP\nmov x8 93\nsvc\n"
    _, res = run(s1prog, stdin=loop.encode())
    rc, _ = run(assemble(res.decode())[1])
    check("stage1 backward-branch to punct label -> 5", rc, 5)

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
    check("stage2 slots are 4-byte", ".byte 0\n.byte 0\n.byte 0\n.byte 0" in em, True)
    for cs, want in [("int main(){int a=5;int b=a+2;return b;}", 7),
                     ("int main(){int a=10;return a*a;}", 100),
                     ("int main(){int x=7;return (x+1)*2;}", 16)]:
        check(f"stage2 exit {cs[:34]}", _exit(cs), want)

    print("== stage 2 control flow: if / while / reassignment ==")
    # Structural: if/while emit a zero-test and branch to UPPERCASE labels (var
    # slots are lowercase a..z, so control-flow targets can't collide).
    emif = _emit("int main(){int a=1;if(a){a=a+1;}return a;}")
    check("stage2 if emits zero-test",         "cmp x0 0" in emif, True)
    check("stage2 if skips on false (b.eq A)", "b.eq A" in emif, True)
    check("stage2 if defines skip label (:A)", ":A\n" in emif, True)
    emwh = _emit("int main(){int a=3;while(a){a=a-1;}return a;}")
    check("stage2 while defines top label (:A)",  ":A\n" in emwh, True)
    check("stage2 while branches back (b A)",     "\nb A\n" in emwh, True)
    check("stage2 while exits on false (b.eq B)", "b.eq B" in emwh, True)
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

if FAILS:
    print(f"\nFAILED: {FAILS}\nThe bench no longer matches CI ground truth — fix before trusting it.")
    sys.exit(1)
print("\nAll bench checks pass — model matches known CI results.")
