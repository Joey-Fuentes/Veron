# m72 candidate — redeclared locals bind to the wrong frame slot

**Status: diagnosed and reproduced, fix PROPOSED and UNTESTED.** The patch below
touches `symlookup`, which every variable reference in stage 2 goes through, so
it must not land without the bench behind it.

## Symptom

Our stage-2-built M2-Planet segfaults on `int main(){return sizeof(int);}` and on
`M2libc/bootstrap.c` past line 55 (`malloc`). Both faults are at the *same*
address, `0x42c0cc`, which `tools/pcmap.py` places inside `unary_expr_sizeof`.

## The faulting code

```
ldr x0,[x9]          ; the value type_name() just returned
add x1,x10,#0x28
str x0,[x1]          ; store it into the local at +0x28
add x1,x10,#0x20
ldr x1,[x1]          ; load a DIFFERENT local, at +0x20
add x1,x1,#8
ldr x0,[x1]          ; dereference -> SIGSEGV, that slot is still zero
```

The store and the use disagree about which frame slot holds `a`.

## Why

`cc_core.c`'s `unary_expr_sizeof` declares the same name twice, in sibling
blocks:

```c
if(t != NULL) {
    struct type* a = t->type;      /* first  'a' */
    ...
} else {
    struct type* a = type_name();  /* second 'a' */
    size = a->size;
}
```

Stage 2 has no block scoping:

- `symdecl` **always appends** a record and hands back a fresh offset, computed
  from the previous record's offset plus its size. It never checks whether the
  name already exists.
- `symlookup` scans **forward from index 0** and returns the **first** match.

So the second declaration allocates slot 2 and its initializer stores there,
while `a->size` looks the name up and gets slot 1 — never written, still zero.

It only fires when the *second* branch runs, which is why simple programs work
and anything that reaches a failed type lookup does not.

## Reproducer

```c
struct ty { int pad; int size; };
struct ty* mk(){struct ty* p;p=calloc(1,16);p->size=42;return p;}
int f(int flag){
  int r; r=0;
  if(flag){ struct ty* a = mk(); r=a->size; }
  else    { struct ty* a = mk(); r=a->size+1; }
  return r;
}
int main(){return f(0);}   /* want 43, gets SIGSEGV */
```

Confirmed against variants: separate declaration and assignment
(`struct ty* a; a = mk();`) is **fine**, distinct names are **fine**, taking the
first branch is **fine**. Only declaration-*with-initializer* on a redeclared
name breaks, and only on the branch that redeclares.

## Proposed fix

Make `symlookup` walk the table from newest to oldest, so a name binds to its
most recent declaration.

```diff
 :symlookup
 sub x1 x6 x18
-mov x3 0
+sub x3 x8 1
 :sl_loop
-cmp x3 x8
-b.ge sl_nf
+cmp x3 0
+b.lt sl_nf
 ...
 :sl_next
-add x3 x3 1
+sub x3 x3 1
 b sl_loop
```

With `x8 == 0` the index starts at -1 and `b.lt` takes the not-found path
immediately, so the empty-table case is unchanged.

### Why this shape rather than the alternatives

- **Reusing the existing slot in `symdecl`** would desynchronise prescan, which
  counts declarations to reserve the frame. prescan and the declaration parser
  disagreeing is the m39 failure this design exists to prevent, and m68 already
  paid for that mistake once.
- **Adding real block scoping** is the correct long-term answer and a much
  larger rung. Backward lookup gets the same observable behaviour for textual
  C — every use is textually after its declaration — at the cost of the outer
  binding staying shadowed to end of function rather than end of block.

### What to check before trusting it

Backward lookup changes name resolution for **every** variable reference, so:

1. Parameters are declared before locals. A local shadowing a parameter now
   resolves to the local, which is correct C but is a behaviour change.
2. Globals live in a separate table (`gsymlookup`), so they are unaffected.
3. Byte-identity across the existing corpus is the real gate: any program
   without a redeclared name must emit **identical** bytes, since first-match
   and last-match agree when names are unique.

That last point is the cheap strong check — if a duplicate-name-free corpus is
byte-identical to HEAD~1 and the reproducer returns 43, the change is contained.
