# m73 / m74 — two stage-2 bugs on M1's critical path

Both found and fixed **in the bench**, not in CI: `spikes/bench/` models the whole
ladder, so `stage2 | stage1 | stage0-as` and the resulting binary all run locally
in Python. Reproducing M1's failure took 19 seconds there against roughly two
hours of CI round trips.

**These are ours.** The control that settles it: `refM1`, built from the same
`M1-macro.c` by upstream's gcc-built M2-Planet for the same target, runs the same
input under the same qemu in 0 seconds. Upstream's code is fine.

---

## m73 — a file-scope `struct T**` gets no storage

`fl_gstruct` consumed exactly one `*` after the struct tag, so

```c
struct blob** hash_table;      /* M1-macro.c:92 */
```

declared a global literally named `*`, and `hash_table` was never allocated.
Every later reference emitted `adr x1 g_hash_table`, stage 1 could not resolve
it, and the label became **0** — so M1's first statement,
`hash_table = calloc(65537, sizeof(struct blob*))`, stored a valid pointer to
address zero.

This is the m69 defect exactly ("only ONE star was ever consumed at any of the
four declarator sites"), at the fifth site m69 did not reach. Only the struct
path is affected: `char** g`, `int** g` and `int*** g` were already correct.

### Fix

```diff
 b.ne flg_st_val
-mov x2 4
+:flg_st_stars
 bl next_token
+cmp x29 42
+b.eq flg_st_stars
+mov x2 4
 mov x3 x6
```

`mov x2 4` moves **after** the loop because `next_token` clobbers x1/x2/x4 (m67),
so setting the pointer flag before an extra call would lose it.

### Reproducer

```c
struct b{int x;}; struct b** g;
int main(){g=calloc(4,8); if(g==0){return 1;} return 7;}
```

---

## m74 — `a->M[i] = v` stores the subscript into the member

`dra_member` emitted the member's address, then called `next_token` expecting
`=`. On `a->Text[0] = 65` that token is `[`, so `compile_expr` compiled the
**index** as if it were the right-hand side, the member store fired, and
`stmtend` discarded `] = 65`. Emitted code:

```
add x1 x10 0000      ; &a
ldr x1 x1            ; a
add x1 x1 0000       ; &a->Text
str x1 x9            ; push the member's ADDRESS
mov x0 0             ; the SUBSCRIPT INDEX
str x0 x9
ldr x0 x9            ; pop index
ldr x1 x9            ; pop address
str x0 x1            ; *(&a->Text) = index      <-- 65 never compiled
```

So `a->Text` became 0 (and 2 when `i` was 2, which is why the following read
faulted at address 4). `NewBlob`'s copy loop is
`while(i <= size){ a->Text[i] = SCRATCH[i]; i = i + 1; }`, so M1 destroyed its
own buffer pointer on the first iteration and never terminated.

m71 taught the **load** path member subscript (`cem_ltp`, `spopbase`) for the 125
`token->s[i]` sites — all reads. The store path never learned it.

### Fix

`dra_member` peeks past whitespace for `[` before emitting anything, exactly as
`cem_ltp` does. When present it takes a subscript-store path: push the member's
**value** (`sldrw` rather than `spushx1`), compile the index, consume `]` and
`=`, compile the value, then `spopval2` + `spopbase` to land value in x0, index
in x2 and base in x1, and emit the same tail `emitsubstore` uses — `sstrbidx`
for a byte, `sscale`/`saddidx`/`sstrw` for a word. Width is the field's char bit,
the pointee width, which is the rule m71 established for the load side. When
there is no `[`, control falls through to `dram_plain` and the original code is
reached unchanged.

### Reproducers

```c
struct b{char* Text;int type;};
int main(){struct b* a;a=calloc(1,16);a->Text=calloc(8,1);a->Text[0]=65;return a->Text[0];}
/* want 65 */

struct w{int* v;int t;};
int main(){struct w* a;a=calloc(1,16);a->v=calloc(4,8);a->v[2]=77;return a->v[2];}
/* want 77 -- the word case */
```

---

## Containment

Both fixes are +56 lines net in two hunks. A duplicate-name-free, subscript-free
corpus of nine programs spanning every construct compiles to **byte-identical**
output before and after, which is the meaningful check: the new code is only
reachable through a second `*` at file scope, or a `[` after a member in
assignment position.

## Verified end to end, locally

With both fixes, stage 2 builds M1 from the upstream `-f` list with **every
global resolved**, and that M1 processes input correctly:

| input | our M1 | vs upstream M1 |
|---|---|---|
| `:main` (6 bytes) | rc=0, 6 bytes | **identical** |
| `aarch64_defs.M1` (72,791 bytes) | rc=0 | **identical** |

Before the fixes the same binary never terminated.

## What this says about the method

Three conclusions drawn from instrumented qemu traces did not survive a real
measurement: "infinite loop in memset", "~50 bytes/sec", and a per-iteration
value-stack leak. `-d exec,nochain` and `-strace` slow qemu by orders of
magnitude, so a short window shows whatever loop happens to be running, not the
bug. All seven `memset` calls turned out to have correct arguments
(524296, 40, 40, 4097, 32, 40, 6).

The bench answers these questions directly and cheaply, and should be the first
stop, not the last. `tools/pcmap.py` (PC to function via stage 1's own label
positions) and `tools/ab.sh` (size + sha for every artifact, rc and wall time for
every run) exist so neither the guessing nor the unreadable output recurs.
