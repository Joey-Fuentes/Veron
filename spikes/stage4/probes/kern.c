/* Does a compiler accept kernel-style C? Linux has no autotools and its honest
 * build floor is make/cc/binutils/sh/coreutils/bc -- but it does need inline
 * asm, packed and aligned attributes. Returns 0 when all work. */
struct __attribute__((packed)) p { char c; int i; };

static inline unsigned long rd(void) {
    unsigned long v;
    __asm__ volatile ("mov %0, #7" : "=r"(v));
    return v;
}

int main(void) {
    struct p x;
    x.c = 1; x.i = 2;
    return (rd() == 7 && sizeof(struct p) == 5) ? 0 : 1;
}
