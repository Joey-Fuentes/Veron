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
