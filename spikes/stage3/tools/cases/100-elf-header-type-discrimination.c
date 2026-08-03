/* BITMASK -- KNOWN GAP: MICRO-C.md defect 2. mc-tcc rejects glibc's shared
 * objects with `unrecognized file type`, which gates every dynamic link:
 * hello-exe, tests2-dir, dlltest, and the `dynamic:` line at rung 3. This
 * case is the freestanding half of that measurement; tcc-two-ways runs the
 * other half against the real files.
 *
 * WHY THE SHAPE IS WORTH ISOLATING. Two verdicts come out of ONE member read
 * compared against two constants, in tcc_object_type (tccelf.c):
 *
 *     if (h->e_type == ET_REL) return AFF_BINTYPE_REL;   //  1  -- works
 *     if (h->e_type == ET_DYN) return AFF_BINTYPE_DYN;   //  3  -- does not
 *
 * ET_REL demonstrably works -- mc-tcc links the objects it compiles, and the
 * gen2 == gen3 == gen4 fixpoint goes through this function every time. So
 * either the read is right and the SECOND `if` is never reached, or the read
 * is wrong and ET_REL survives it by accident. Those are different bugs and
 * the CI log cannot tell them apart, which is why this is one bit per link in
 * the chain rather than one verdict for the function.
 *
 * Freestanding on purpose: no libc, no file I/O, no includes. The header is
 * built in memory, so this runs on both columns in under a second and needs
 * neither an emulator nor a glibc to be present.
 *
 * SEVEN BITS, MAX 127, deliberately. difftest.sh reads the exit code, and a
 * bitmask that reaches 128 is indistinguishable from a signal at the shell.
 */

/* Elf64_Ehdr, laid out exactly: e_type is an unsigned short at offset 16 and
 * e_machine is the unsigned short immediately after it. The adjacency is the
 * point -- a member load two bytes too wide swallows e_machine, and on
 * aarch64 e_machine is 183, which is loud. */
struct Ehdr {
    unsigned char  e_ident[16];   /*  0 */
    unsigned short e_type;        /* 16 */
    unsigned short e_machine;     /* 18 */
    unsigned int   e_version;     /* 20 */
    unsigned long  e_entry;       /* 24 */
    unsigned long  e_phoff;       /* 32 */
    unsigned long  e_shoff;       /* 40 */
    unsigned int   e_flags;       /* 48 */
    unsigned short e_ehsize;      /* 52 */
    unsigned short e_phentsize;   /* 54 */
    unsigned short e_phnum;       /* 56 */
    unsigned short e_shentsize;   /* 58 */
    unsigned short e_shnum;       /* 60 */
    unsigned short e_shstrndx;    /* 62 */
};                                /* 64 */

#define ET_REL 1
#define ET_EXEC 2
#define ET_DYN 3
#define BIN_REL 11
#define BIN_DYN 22
#define BIN_AR  33

static int mcmp(unsigned char *a, char *b, int n)
{
    int i = 0;
    while (i < n) {
        if (a[i] != (unsigned char) b[i]) return 1;
        i = i + 1;
    }
    return 0;
}

/* tcc_object_type's body, with full_read's result passed in rather than read.
 * The `&&`, the two consecutive ifs, the else-if and the fallthrough to 0 are
 * all kept in their original order and nesting. */
static int object_type(struct Ehdr *h, int size)
{
    if (size == sizeof *h && 0 == mcmp((unsigned char *) h, "\177ELF", 4)) {
        if (h->e_type == ET_REL)
            return BIN_REL;
        if (h->e_type == ET_DYN)
            return BIN_DYN;
    } else if (size >= 8) {
        if (0 == mcmp((unsigned char *) h, "!<arch>\n", 8))
            return BIN_AR;
    }
    return 0;
}

static void fill(struct Ehdr *h, int type)
{
    int i = 0;
    unsigned char *p = (unsigned char *) h;
    while (i < 64) { p[i] = 0; i = i + 1; }
    h->e_ident[0] = 127;          /* \177, written numerically on purpose */
    h->e_ident[1] = 'E';
    h->e_ident[2] = 'L';
    h->e_ident[3] = 'F';
    h->e_ident[4] = 2;            /* ELFCLASS64 */
    h->e_ident[5] = 1;            /* ELFDATA2LSB */
    h->e_ident[6] = 1;            /* EV_CURRENT */
    h->e_type = type;
    h->e_machine = 183;           /* EM_AARCH64 -- adjacent to e_type */
    h->e_version = 1;
    h->e_entry = 0x400000;
    h->e_shstrndx = 29;
}

int main(void)
{
    struct Ehdr h;
    struct Ehdr *p;
    int bits = 0;

    p = &h;

    /* 1: sizeof of a dereferenced PARAMETER pointer, which is the left half
     *    of the guard. The MEMBER form of this was EXPERIMENT-zzzi; the plain
     *    form is claimed always to have been right, and this says so or does
     *    not. */
    if (sizeof *p != 64) bits = bits + 1;

    /* 2: ELFMAG's OCTAL ESCAPE -- the guard's right half. M2-Planet's
     *    escape_lookup special-cases \0 and \x and has never had general
     *    octal; tcc spells the magic "\177ELF" and nothing else in the tree
     *    depends on that form, so a gap here would fail everywhere at once
     *    and look like a codegen fault. Named separately so it cannot. */
    {
        char *mag = "\177ELF";
        int bad = 0;
        if ((unsigned char) mag[0] != 127) bad = 1;
        if (mag[1] != 'E') bad = 1;
        if (mag[2] != 'L') bad = 1;
        if (mag[3] != 'F') bad = 1;
        if (bad) bits = bits + 2;
    }

    /* 4: the two-byte member reads back ET_REL -- the value that works. */
    fill(p, ET_REL);
    if (h.e_type != 1) bits = bits + 4;

    /* 8: the same member reads back ET_DYN, and e_machine did not leak into
     *    it. A four-byte load at offset 16 on aarch64 gives 0x00B70003; this
     *    is that hypothesis, isolated. If this fires with bit 4 clear, the
     *    load depends on the VALUE, which would be new. */
    fill(p, ET_DYN);
    if (h.e_type != 3) bits = bits + 8;
    else if (h.e_machine != 183) bits = bits + 8;

    /* 16: the whole function on an ET_REL header. This is the path mc-tcc is
     *     known to take successfully, so it is the CONTROL for bit 32 -- if
     *     both fire the fault is in the guard, not in the discrimination. */
    fill(p, ET_REL);
    if (object_type(p, 64) != BIN_REL) bits = bits + 16;

    /* 32: THE DEFECT. Same function, same read, second constant. */
    fill(p, ET_DYN);
    if (object_type(p, 64) != BIN_DYN) bits = bits + 32;

    /* 64: the fallthrough and the else-if arm, which share their exit with a
     *     missed ET_DYN. An ET_EXEC header must reach neither arm and return
     *     0; a short archive must reach the else-if. If this fires the two
     *     ifs are not independent of each other. */
    fill(p, ET_EXEC);
    if (object_type(p, 64) != 0) bits = bits + 64;
    else {
        int i = 0;
        unsigned char *q = (unsigned char *) p;
        char *ar = "!<arch>\n";
        while (i < 8) { q[i] = (unsigned char) ar[i]; i = i + 1; }
        if (object_type(p, 60) != BIN_AR) bits = bits + 64;
    }

    return bits;
}
