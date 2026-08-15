# Stage-2 self-host test (canary)

A **proof-of-pivot**, not a permanent rung. Per `TARGET-SUBSET.md` §(a), once heap
and I/O landed the next move was to confirm — cheaply, and before investing in
anything else — that the ladder can compile a real **compiler-shaped** program:
one that reads a file, uses deep recursion, structs, function pointers and nested
control flow, and writes output. That is the single scariest unknown on the way to
compiling M2-Planet, so it gets tested first and thrown away, not kept as a stage.

    python3 run_selfhost_test.py

## What the test program is

`canon.c` is a **lexical canonicalizer**: it reads a file, tokenizes it into a
heap-allocated linked list of token records, then walks that list recursively and
writes one canonical token per line.

The shape is deliberately that of a compiler front end:

| Property required by the spec | Where it appears in `canon.c` |
| --- | --- |
| reads a file, writes a file | `main` — `open`/`read`/`close`, `open`/`write`/`close` |
| structs on the heap | `struct Tok {off,len,nx}` built by `mk_tok` via `calloc` |
| the M2-Planet data model | a singly-linked token list with global `HEAD`/`TAIL` |
| function pointers | `int (*sep)(int)` — `issep` passed into `lex`, forwarded to `skip_seps`/`tok_end` |
| deep recursion | `emit_list` recurses once per token — depth 569 over its own source |
| nested control flow | `lex`'s loop with a nested guard; the scanner helpers' loop + early return |

## Why the output is a fixpoint

Canonical form is *one maximal run of non-separator bytes per line*, terminated by
a newline. Separators (space, tab, newline) only delimit. Re-canonicalizing
canonical text therefore reproduces it exactly:

    canon(canon(x)) == canon(x)

That gives the "byte-compared across a second generation" property the spec asks
for, without needing a full toy compiler: the program is run over its own output
and must reproduce it bit for bit. The test also runs `canon` over **`canon.c`
itself** — the very text it was compiled from — and checks that result is stable
across a second generation too.

## What the test asserts

1. `gen1` is produced, is one token per line, and matches the expected
   tokenization of a messy compiler-ish input.
2. `gen2 = canon(gen1)` equals `gen1` byte for byte — the fixpoint.
3. `canon` over its own 3271-byte source yields 569 tokens (matching a
   whitespace split), and that output is likewise a fixpoint.
4. Scale: 500 tokens in, 500 lines out — i.e. 500-deep recursion through the
   ladder.

## Subset constraints observed

Two current stage-2 limits shape the source; both are recorded in `PROGRESS.md`
and neither is a bug in the test:

- **Global data is bounded, not unbounded** (m55). Each global array byte emits a
  `.byte 0` line into the fixed data region, so ~24 KB of globals reaches `brk`.
  `IN` and `OUT` are therefore `calloc`'d and held in global `char*` pointers
  (8 bytes each) rather than declared as global arrays. Input is capped at the
  8192-byte buffer.
- **Member access directly on a call result** (`mk_tok(...)->v`) is a known-bad
  shape flagged in m55. `append` binds the result to a local first
  (`node = mk_tok(...)`, then `node->...`), which is correct.

One non-bug worth knowing when reading the output: `main` returns the output
length, but a process exit status is a single byte, so the return value is the
**low byte** of the length (2833 bytes → rc 17). The test compares against
`len & 0xFF`.

## Standing of the result

This runs on the **bench** — the Python model of `stage0-as` plus the aarch64
interpreter. Per `AGENTS.md`, the bench is a model and CI (real `as` + qemu-user)
is the witness of record. A green run here is a cheap local de-risk, **not** a
substitute for CI, and a green bench never overrides a red CI.
