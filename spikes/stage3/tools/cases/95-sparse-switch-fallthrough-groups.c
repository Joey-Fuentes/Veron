/* BITMASK
 *
 * gotplt_entry_type(), arm64-link.c -- the switch that decides whether a
 * relocation needs a GOT entry. 34 cases in three fall-through groups over a
 * SPARSE range, 257 to 1026.
 *
 * Measured symptom it comes from: a tcc built by micro-c compiles and links a
 * freestanding hello world into a valid aarch64 ELF that runs and exits 0 and
 * prints nothing. The object file is BYTE-IDENTICAL to the control's, so
 * codegen is right; the link is not. Its .got has three reserved entries, all
 * zero, where the control has a fourth holding the string's address. The
 * ADRP/LDR pair therefore loads 0 and write() gets a null pointer.
 *
 * No GOT entry is created at all, and no "Unknown relocation type" is printed
 * -- so gotplt_entry_type returned a VALID answer for R_AARCH64_ADR_GOT_PAGE
 * (311), just the wrong one. NO_GOTPLT_ENTRY makes build_got_entries
 * `continue` before it can allocate anything.
 *
 * The case values and the grouping below are copied from arm64-link.c rather
 * than simplified, because sparseness and grouping are what is in question.
 */
#define NO_GOTPLT_ENTRY     0
#define AUTO_GOTPLT_ENTRY   1
#define ALWAYS_GOTPLT_ENTRY 2
#define BUILD_GOT_ONLY      3

static int gotplt_entry_type(int reloc_type)
{
    switch (reloc_type) {
        case 261: /* PREL32 */
        case 264: /* MOVW_UABS_G0_NC */
        case 275: /* ADR_PREL_PG_HI21 */
        case 277: /* ADD_ABS_LO12_NC */
        case 286: /* LDST64_ABS_LO12_NC */
        case 278: /* LDST8_ABS_LO12_NC */
        case 1025: /* GLOB_DAT */
        case 1026: /* JUMP_SLOT */
        case 1024: /* COPY */
        case 279: /* TSTBR14 */
        case 280: /* CONDBR19 */
            return NO_GOTPLT_ENTRY;

        case 258: /* ABS32 */
        case 257: /* ABS64 */
        case 282: /* JUMP26 */
        case 283: /* CALL26 */
            return AUTO_GOTPLT_ENTRY;

        case 311: /* ADR_GOT_PAGE      -- the one that matters */
        case 312: /* LD64_GOT_LO12_NC  -- and its partner */
            return ALWAYS_GOTPLT_ENTRY;
    }
    return -1;
}

int main(void)
{
    int bits = 0;

    /* 1,2: the two that decide whether a GOT entry exists at all */
    if (gotplt_entry_type(311) != ALWAYS_GOTPLT_ENTRY) bits = bits + 1;
    if (gotplt_entry_type(312) != ALWAYS_GOTPLT_ENTRY) bits = bits + 2;

    /* 4: the group before it, reached by falling through ten labels */
    if (gotplt_entry_type(280) != NO_GOTPLT_ENTRY) bits = bits + 4;

    /* 8: the middle group */
    if (gotplt_entry_type(283) != AUTO_GOTPLT_ENTRY) bits = bits + 8;

    /* 16: the first label of the first group */
    if (gotplt_entry_type(261) != NO_GOTPLT_ENTRY) bits = bits + 16;

    /* 32: the far end of the sparse range */
    if (gotplt_entry_type(1026) != NO_GOTPLT_ENTRY) bits = bits + 32;

    /* 64: a value in no group at all must reach the default return */
    if (gotplt_entry_type(999) != -1) bits = bits + 64;

    return bits;
}
