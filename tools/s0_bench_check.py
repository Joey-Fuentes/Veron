#!/usr/bin/env python3
"""s0_bench_check.py -- what does the BENCH model encode this .s0 line as?

    usage: s0_bench_check.py '<one .s0 instruction>'
    prints: 8 hex chars (little-endian bytes) | 'raise' | 'error'

WHY THIS IS A SEPARATE FILE AND NOT INLINE. spikes/bench/s0as.py is the model
local development is written against, and spikes/bench/README.md already records
two real bugs it masked. Measured, run 1 of stage0-selfhost:

    mov w0 w1      bench aa0103e0   stage0-as d2800000   GNU as 2a0103e0
    sub w0 w1 w2   bench RAISES     stage0-as 200000d1   GNU as 2000024b

Three different answers for one instruction, and a case where the model is
correctly strict while the real assembler silently emits a different
instruction. An inner loop that disagrees with ground truth is worse than no
inner loop, because it converts a wrong answer into a confident one.

So every probe run prints the model's answer alongside the real one. When they
agree the bench can be trusted for that form and used for fast local iteration;
where they disagree, the bench gets fixed in the same commit as the assembler.
"""

import sys


def main():
    if len(sys.argv) != 2:
        print("error")
        return 0
    sys.path.insert(0, "spikes/bench")
    try:
        import s0as
    except Exception:
        print("error")
        return 0
    try:
        # a label is supplied so branch forms resolve; position 0, target 4
        word, _ = s0as.encode(sys.argv[1].strip(), 0, {"tgt": 4})
        print(word.to_bytes(4, "little").hex())
    except Exception:
        print("raise")
    return 0


if __name__ == "__main__":
    sys.exit(main())
