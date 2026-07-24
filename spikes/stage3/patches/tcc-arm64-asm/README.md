# tcc arm64 integrated assembler — recovered patch series

Aleksi Hannula, posted to `tinycc-devel` on **5 Feb 2026**, three patches:

| | |
|---|---|
| `0001` | `arm64-link`: implement `R_AARCH64_TSTBR14` / `R_AARCH64_CONDBR19` relocs |
| `0002` | `asm`: pass `ASMOperand` to the `subst_asm_operand` backend hook |
| `0003` | the assembler itself — `arm64-asm.c` +2579, new `arm64-tok.h` |

Author's own summary: *"Partial implementation, but enough to compile musl
1.2.5."* That is exactly the claim `tcc-userland-arm64` is testing, so this is
the patch that spike is written around.

## Why these files are not the posted text

The `lists.nongnu.org` archive **hard-wraps long lines**. Every wrapped line's
continuation loses its leading `+`/`-`/space marker, so `git apply` rejects the
posted text with `patch fragment without header`. The wrap is greedy at ~76
columns, and a token longer than the column budget gets emitted on a line of its
own, which means some lines are split into **three** fragments — e.g. this one
in `arm64-asm.c`:

```
+/* https://github.com/ruby/ruby/blob/…/bitmask_imm.rs */
```

came back as `+/* ` / `https://…bitmask_imm.rs` / ` */`, and the third fragment
begins with a space, so it reads as a context line rather than a continuation.

These files are the unwrapped series.

## How the unwrap was verified

Nothing here rests on eyeballing. Three independent checks, all exact:

1. **Every hunk balances.** For all 20 hunks, the counted `-`/`+`/context lines
   equal the `@@` header's declared counts, with **no unclaimed lines** between
   the end of a hunk and the next header. A continuation wrongly left as its own
   line inflates a count; a context line wrongly absorbed deflates one. Both
   show up here, and neither does.
2. **`git apply --stat` parses all three** and reports, for `0003`:
   `5 files changed, 2843 insertions(+), 19 deletions(-)` — byte-for-byte the
   diffstat in the patch's own header.
3. **The series matches the cover letter.** `10 files, +2868 / -26`, identical
   to `[PATCH 0/3]`.

No join in the series merges an alphanumeric character onto another
alphanumeric character, so no wrap dropped the space it broke at.

## Applying

Order is load-bearing: `0003` carries the post-`0002` signature
`subst_asm_operand(…, ASMOperand *op)` as **context**, so it will not apply to a
tree that has not had `0002` applied first.

```sh
for p in spikes/stage3/patches/tcc-arm64-asm/000*.patch; do
    git -C tccsrc apply --3way "$p" || exit 1
done
```

`--3way` needs the blobs, so clone tinycc at full depth (the workflow does).

## Is it already upstream?

Check for **`arm64-tok.h`**, which `0003` creates. Do *not* check for
`arm64-asm.c` — that file exists in mob regardless; unpatched it is titled
`ARM64 dummy assembler for TCC` and its `asm_opcode` is a single
`tcc_error("ARM asm not implemented.")`. `tcc-aarch64-probe`'s
`inline asm on arm64: $( [ -f arm64-asm.c ] && echo yes …)` therefore reports
`yes` on a tree with no assembler at all.

## Error strings, for log-scraping

The two versions fail differently, and neither emits the string
`instruction 'X' not implemented` that `tcc-userland-arm64` currently greps for:

| tree | message on an opcode it cannot handle |
|---|---|
| unpatched mob | `ARM asm not implemented.` |
| patched | `unrecognized opcode X`, `unrecognized unary opcode X`, `unrecognized nullaryopcode X` |

The patched assembler's other failure classes are worth counting separately,
since they are *partial-implementation* misses rather than missing mnemonics:
`unsupported extend/shift specifier`, `unexpected operand`,
`immediate %ld out of range`, `invalid bitmask`, `shift amount out of range`,
and `expect()` diagnostics such as `vector operand with arrangement`.

`bic` **is** implemented by `0003` (`TOK_ASM_bic`, both the register and
bitmask-immediate forms), which is the single opcode run 1 died on.

---

## Correction — mob has its OWN arm64 assembler (2026-07-24)

The first attempt to use this series skipped it, on the reasoning that
`arm64-tok.h` being present in mob meant the series was already upstream. That
reasoning was wrong, and the run that exposed it is worth recording:

```
mob HEAD: 85ba3ae8f1e22044255d54c28be04e5fc3e88ae0   2026-07-24 19:27:21 +0200
arm64-tok.h PRESENT -- the series is already upstream; not patching
tcc version 0.9.28rc 2026-07-24 mob@85ba3ae8 (AArch64 Linux)
/tmp/probe.s:5: error: ARM64 instruction 'bic' not implemented
```

Two things follow. **`ARM64 instruction '%s' not implemented` is mob's wording**
— the string appears nowhere in this series, whose unknown-opcode path says
`unrecognized opcode %s`. And this series **does** implement `bic` with an
immediate: `asm_opcode_imm_sh` inverts the operand (`op3.e.v = ~op3.e.v`) and
encodes it as an AND-bitmask, and `~1` is a valid bitmask immediate.

So mob carries a *different* arm64 assembler, which knows the mnemonic well
enough to name it in an error and has no handler behind it. On this instruction
the vendored series is stronger than upstream. `arm64-tok.h` does not
discriminate between them; nothing short of measurement does, which is what
`.github/workflows/tcc-arm64-asm-gap.yml` is for.

The series cannot simply be applied on top of mob — 0003 creates `arm64-tok.h`,
which now exists. To measure it, rewind to the commit before mob's own
assembler landed and apply there:

```sh
FIRST=$(git -C tccsrc log --reverse --format=%H -- arm64-tok.h | head -1)
git -C tccsrc checkout "${FIRST}^"
for p in spikes/stage3/patches/tcc-arm64-asm/000*.patch; do
    git -C tccsrc apply --3way "$p" || exit 1
done
```

## Files here

| | |
|---|---|
| `000{1,2,3}-*.patch` | the unwrapped series |
| `SERIES-COVERAGE.txt` | the 67 instruction mnemonics 0003 implements, one per line — the input to the gap job's bucketing |
| `arm64-tok.h` | 0003's new file, extracted whole; useful if the series is ported forward as files rather than as a diff |

## If the series is ported forward rather than rewound to

`arm64-asm.c` (+2579) and `arm64-tok.h` (+247) are effectively whole new files;
everything else in the series is ~50 lines of hooks —
`arm64-link.c` relocs (18), the `subst_asm_operand` signature across five
backends plus `tcc.h`/`tccasm.c` (7), `tccasm.c` (26), `tccpp.c` (4),
`tcctok.h` (6). Mob's own assembler will already have made equivalent hook
changes, so a forward port is mostly a question of which `arm64-asm.c` you
want, not a merge.
