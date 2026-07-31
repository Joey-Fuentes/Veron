/* BITMASK -- one bit per probe, 0 means every probe passed.
 *
 * `*p += v` loaded the POINTER at the pointed-at type's width -- a four-byte
 * SIGNED read of an eight-byte pointer -- so the address stored through was
 * truncated. `*p = *p + v`, which means the same thing, was always correct:
 *
 *     *p = 5     lea_rax,[rbp-8] / mov_rax,[rax]                8 bytes
 *     *p += 5    lea_rax,[rbp-8] / movsx_rax,DWORD_PTR_[rax]    4, SIGNED
 *
 * `is_assignment` in cc_core.c was `match("=")` only, so a compound assignment
 * took the RVALUE branch -- which steps the type down before loading, because
 * that is what an rvalue read of `*p` wants. EXPERIMENT-zzzl.
 *
 * tcc's find_field accumulates an offset with `*cumofs += s->c` while walking
 * anonymous struct members, so a designated initializer naming a member of an
 * anonymous struct segfaulted mc-tcc at COMPILE time -- tests2/90_struct-init.
 *
 * The global probe is separate because the local and global paths reach the
 * store through different branches and only one of them was wrong.
 */
int g;

int addto(int *p, int v) { *p += v; return 0; }
int subto(int *p, int v) { *p -= v; return 0; }
int oreq(int *p, int v)  { *p |= v; return 0; }
int plain(int *p, int v) { *p = *p + v; return 0; }

int main(void)
{
    int a;
    int bits;
    bits = 0;

    /* 1: the spelled-out form, which was always correct */
    a = 10; plain(&a, 5); if (a != 15) bits = bits + 1;

    /* 2: the same thing as a compound assignment -- this is the bug */
    a = 10; addto(&a, 5); if (a != 15) bits = bits + 2;

    /* 4: -= reaches the same store through the same branch */
    a = 10; subto(&a, 3); if (a != 7) bits = bits + 4;

    /* 8: and so does a bitwise compound operator */
    a = 8; oreq(&a, 1); if (a != 9) bits = bits + 8;

    /* 16: a global target, which resolves its address differently */
    g = 10; addto(&g, 5); if (g != 15) bits = bits + 16;

    return bits;
}
