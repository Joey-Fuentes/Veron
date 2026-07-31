/* BITMASK -- one bit per probe, 0 means every probe passed.
 *
 * promote_type picked the winning type by POSITION IN global_types, so a
 * typedef -- always registered after the primitives -- lost to whatever it met.
 * Meeting an `int` returned `int`, carrying is_signed = TRUE, and every
 * unsigned typedef in the program was signed as far as codegen was concerned:
 *
 *     unsigned long x;  x >> 43     shr_rax,cl    logical, correct
 *     u64           x;  x >> 43     sar_rax,cl    arithmetic, WRONG
 *
 * EXPERIMENT-zzzm. tcc's elf.h:34 typedefs uint64_t, so this was every
 * uint64_t in tcc; arm64_movi builds an opcode with `x >> 43` and the
 * arithmetic shift made it emit a word that is not an aarch64 encoding.
 *
 * THE RAW PROBES ARE HERE ON PURPOSE. Each typedef probe is paired with the
 * same expression written with the primitive spelled out. Both columns were
 * green for the raw form throughout, so a case carrying only the typedef form
 * would not have shown WHICH half was wrong.
 */
typedef unsigned long u64;
typedef unsigned int u32;

u64 g;

u64 shift_param(u64 x) { return x >> 43; }
unsigned long shift_raw(unsigned long x) { return x >> 43; }

int main(void)
{
    u64 t;
    unsigned long r;
    u32 s;
    int bits;
    bits = 0;

    t = 0x8000000000000000UL;
    r = 0x8000000000000000UL;

    /* 1 / 2: right shift must be LOGICAL for both spellings */
    if ((r >> 43) != 0x100000UL) bits = bits + 1;
    if ((t >> 43) != 0x100000UL) bits = bits + 2;

    /* 4: through a parameter, which reaches the store a different way */
    if (shift_raw(r) != 0x100000UL) bits = bits + 4;
    if (shift_param(t) != 0x100000UL) bits = bits + 8;

    /* 16: a global target */
    g = 0x8000000000000000UL;
    if ((g >> 43) != 0x100000UL) bits = bits + 16;

    /* 32: division is unsigned too */
    if ((t / 3UL) != 0x2AAAAAAAAAAAAAAAUL) bits = bits + 32;

    /* 64: and so is comparison -- signed, this reads as negative */
    if (!(t > 1UL)) bits = bits + 64;

    /* 128: the 32-bit typedef, same rule one width down */
    s = 0x80000000U;
    if ((s >> 20) != 0x800U) bits = bits + 128;

    return bits;
}
