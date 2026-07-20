# stages/ — the ladder

Each stage adds exactly one abstraction and is written in the language the
stage below just produced.

```
0-seed-as → 1-macro-as → 2-mini-c → 3-full-c      (trunk — flavor-blind)
════════════════════════ FORK LINE ════════════════════════
4-libc + 4-binutils → 5-gcc-bootstrap → 5-gcc → 5-userland → 5-kernel
                                        (parameterized by libc = musl | glibc)
```

**Invariant:** nothing below stage 4 may reference libc, even transitively.
CI enforces it (`tools/check-fork-invariant`).

Stages 0–2 are per-arch (written 3×). From stage 3's portable C upward, source
is written **once** and the compiler targets all three arches — so keep the
assembly-language rungs few and small.

See `ARCHITECTURE.md` §2.
