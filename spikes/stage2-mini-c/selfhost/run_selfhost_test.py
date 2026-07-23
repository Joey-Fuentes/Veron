#!/usr/bin/env python3
"""Stage-2 self-host TEST (a canary / proof-of-pivot, not a permanent rung).

Compiles selfhost/canon.c through the real ladder

    canon.c -> stage2-mini-c.s1 -> stage1-as.s0 -> stage0-as(model) -> a.out

and runs the result on the interp's in-memory filesystem, proving three things:

  (1) COMPILER-SHAPED RUN.  canon reads a file, tokenizes it into a heap
      linked list of token records via a function-pointer classifier, walks
      that list recursively, and writes an output file.  That is the same
      shape as a compiler front end, exercised end to end through the ladder.

  (2) FIXPOINT.  gen1 = canon(input); gen2 = canon(gen1).  The canonical form
      is idempotent, so gen2 must equal gen1 byte for byte.  This is the
      self-application property a self-hosting compiler needs, in miniature:
      running the program over its own output reproduces that output exactly.

  (3) FIXPOINT ON ITS OWN SOURCE.  canon is run over canon.c itself, and the
      result is likewise stable across a second generation.  The program is
      fed the very text it was compiled from.

Bench, not CI: this driver runs on the Python model of stage0-as plus the
aarch64 interpreter.  CI (real `as` + qemu-user) remains the witness of
record; a green run here is a cheap local de-risk, not a substitute.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.normpath(os.path.join(HERE, "..", "..", "bench"))
sys.path.insert(0, BENCH)

from s0as import assemble          # noqa: E402
from interp import run, OOBAccess  # noqa: E402

S1 = os.path.join(BENCH, "..", "stage1-as", "stage1-as.s0")
S2 = os.path.join(BENCH, "..", "stage2-mini-c", "stage2-mini-c.s1")
SRC = os.path.join(HERE, "canon.c")

MEM = 0x400000


def build_ladder():
    """Assemble stage 1, run stage 2 through it, return a C-source compiler."""
    _, s1prog, _ = assemble(open(S1).read())
    _, s2asm = run(s1prog, stdin=open(S2).read().encode())
    _, s2prog, _ = assemble(s2asm.decode())

    def compile_c(csrc):
        rc, emitted = run(s2prog, stdin=csrc.encode())
        if rc != 0:
            raise RuntimeError(f"stage-2 compile failed, rc={rc}")
        _, resolved = run(s1prog, stdin=emitted)
        return assemble(resolved.decode())[1]

    return compile_c


def show(label, ok):
    print(f"  [{'OK ' if ok else 'FAIL'}] {label}")
    return ok


def main():
    print("== stage-2 self-host test: lexical canonicalizer (canon.c) ==")
    compile_c = build_ladder()
    canon_prog = compile_c(open(SRC).read())

    def canon(data):
        """Run the compiled canonicalizer over `data`; returns (rc, output)."""
        fs = {"in": bytes(data)}
        rc, _ = run(canon_prog, files=fs, mem_size=MEM)
        return rc, fs.get("out", b"")

    ok = True

    # (1) compiler-shaped run over messy, compiler-ish input
    sample = (b"  int  main( ) {\n"
              b"\t int   x =\t42 ;\n"
              b"   return   x+x ;\n"
              b"}\n")
    rc1, gen1 = canon(sample)

    ok &= show(f"gen1 wrote an output file ({len(gen1)} bytes)", len(gen1) > 0)
    # exit status is a single byte, so compare against the low byte of the length
    ok &= show(f"gen1 return value is the output length ({rc1})",
               rc1 == (len(gen1) & 0xFF))

    expect = [b"int", b"main(", b")", b"{", b"int", b"x", b"=", b"42", b";",
              b"return", b"x+x", b";", b"}"]
    body = gen1.split(b"\n")[:-1] if gen1.endswith(b"\n") else gen1.split(b"\n")
    ok &= show(f"gen1 is one token per line, newline-terminated "
               f"({len(body)} tokens)",
               gen1.endswith(b"\n") and all(
                   t and b" " not in t and b"\t" not in t for t in body))
    ok &= show("gen1 token stream matches the expected tokenization",
               body == expect)

    # (2) fixpoint across a second generation
    rc2, gen2 = canon(gen1)
    ok &= show(f"gen2 = canon(gen1) ran ({len(gen2)} bytes)",
               rc2 == (len(gen2) & 0xFF))
    ok &= show("FIXPOINT: canon(canon(x)) == canon(x), byte for byte",
               gen2 == gen1 and len(gen1) > 0)

    # (3) fixpoint over canon's own source text
    own = open(SRC, "rb").read()
    rcs1, self1 = canon(own)
    rcs2, self2 = canon(self1)
    ok &= show(f"canon ran over its own source, {len(own)} bytes in -> "
               f"{len(self1)} bytes out",
               rcs1 == (len(self1) & 0xFF) and len(self1) > 0)
    ok &= show("token count matches the source's whitespace-split token count",
               len(self1.split(b"\n")[:-1]) == len(own.split()))
    ok &= show("FIXPOINT on own source: canon(canon(src)) == canon(src)",
               self2 == self1 and len(self1) > 0)

    # (4) scale: the emit walk recurses once per token, so a long token list
    #     is a real deep-recursion test of the ladder's stack handling.
    many = 500
    big = b" ".join(b"tok%d" % i for i in range(many))
    rcb, outb = canon(big)
    lines = outb.split(b"\n")[:-1] if outb.endswith(b"\n") else []
    ok &= show(f"scale: {many} tokens in, {len(lines)} lines out "
               f"(emit recursion depth {many})", len(lines) == many)

    print()
    if ok:
        print("SELF-HOST TEST PASSED -- the ladder compiles a compiler-shaped, "
              "file-reading, heap-allocating program, and its output is a "
              "byte-stable fixpoint across generations.")
        return 0
    print("SELF-HOST TEST FAILED.")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OOBAccess as e:
        print(f"  [FAIL] out-of-bounds access during run: {e}")
        sys.exit(1)
