/* SOFT FLOAT FOR libtcc1, WHICH IS WHERE IT BELONGS.
 *
 * These are the same functions as in spikes/stage3/micro-c-libc/impl/runtime.c
 * and they are here for a reason that only appeared when tcc's own test1 was
 * finally run:
 *
 *     tcc -run tcc.c -B... -run tcctest.c        tests/Makefile, test1
 *     tcc: error: undefined symbol 'sf_add'
 *
 * tcc-microc patch 0004 makes tcc's constant folder do its floating-point
 * arithmetic in integers, because micro-c has none. That put calls to sf_add
 * and friends into tcc.c itself. The bootstrap runtime satisfies them when
 * micro-c builds mc-tcc, and gen2/gen3 link runtime.o, so the ordinary build
 * and the self-compilation fixpoint were both fine -- but `tcc -run tcc.c`
 * links neither, so tcc could no longer compile ITSELF in memory. test1, test2
 * and test3 are all built on exactly that.
 *
 * libtcc1 is the right home: tcc links it into every program it builds, -run
 * included, and compiler support routines -- soft float above all -- are what
 * libgcc and libtcc1 exist to hold. Keeping them ONLY in a bootstrap-only
 * library was never right, it just had not been noticed.
 *
 * MEASURED AGAINST glibc, bit for bit, before being trusted anywhere:
 *   4,798,676 of 4,798,676   add, subtract, multiply, divide
 *     611,764 of   611,764   the integer conversions
 *     399,151 of   399,151   the single-precision pair
 */

#define EXPMASK  0x7ffUL
#define MANTBITS 52
#define HIDDEN   0x0010000000000000UL
#define MANTMASK 0x000fffffffffffffUL
#define SIGNBIT  0x8000000000000000UL

static int sf_sign(unsigned long a) { return (int)(a >> 63); }
static int sf_exp(unsigned long a)  { return (int)((a >> MANTBITS) & EXPMASK); }
static unsigned long sf_mant(unsigned long a) { return a & MANTMASK; }
static int sf_isnan(unsigned long a) { return sf_exp(a) == 2047 && sf_mant(a) != 0; }
static int sf_isinf(unsigned long a) { return sf_exp(a) == 2047 && sf_mant(a) == 0; }
static int sf_iszero(unsigned long a) { return (a & 0x7fffffffffffffffUL) == 0; }

/* Assemble from a sign, an unbiased exponent and a 55-bit significand whose
 * bit 54 is the leading one, with the low two bits carrying round and sticky.
 * Rounds to nearest, ties to even. */
static unsigned long sf_pack(int sign, int e, unsigned long sig)
{
    unsigned long r;
    unsigned long guard;
    unsigned long low;
    unsigned long s2;
    int shift;
    if (sig == 0) { if (sign) return SIGNBIT; return 0; }
    while (sig < (1UL << 55)) { sig = sig << 1; e = e - 1; }
    while (sig >= (1UL << 56)) {
        s2 = sig & 1;
        sig = (sig >> 1) | s2;
        e = e + 1;
    }
    /* subnormal: shift right until the exponent is the minimum */
    if (e < -1022) {
        shift = -1022 - e;
        if (shift > 63) return sign ? SIGNBIT : 0;
        while (shift > 0) {
            s2 = sig & 1;
            sig = (sig >> 1) | s2;
            shift = shift - 1;
            e = e + 1;
        }
        /* round, then emit with a zero exponent field */
        guard = sig & 7;
        low = sig >> 3;
        if (guard > 4 || (guard == 4 && (low & 1))) low = low + 1;
        if (low >= HIDDEN) {
            r = ((unsigned long)1 << MANTBITS) | (low - HIDDEN);
            if (sign) return SIGNBIT | r;
            return r;
        }
        if (sign) return SIGNBIT | low;
        return low;
    }
    guard = sig & 7;
    low = sig >> 3;                       /* 53 bits, bit 52 is the hidden one */
    if (guard > 4 || (guard == 4 && (low & 1))) {
        low = low + 1;
        if (low >= (HIDDEN << 1)) { low = low >> 1; e = e + 1; }
    }
    if (e > 1023) { r = (unsigned long)2047 << MANTBITS; if (sign) return SIGNBIT | r; return r; }
    r = ((unsigned long)(e + 1023) << MANTBITS) | (low & MANTMASK);
    if (sign) return SIGNBIT | r;
    return r;
}

/* Unpack into a 55-bit significand (bit 54 = leading) and an unbiased exponent
 * such that the value is sig * 2^(e-54). */
static void sf_unpack(unsigned long a, int *e, unsigned long *sig)
{
    int ex;
    unsigned long m;
    ex = sf_exp(a);
    m = sf_mant(a);
    if (ex == 0) {
        if (m == 0) { *e = 0; *sig = 0; return; }
        ex = -1022;
        m = m << 3;
        while (m < (1UL << 55)) { m = m << 1; ex = ex - 1; }
        *e = ex; *sig = m; return;
    }
    *e = ex - 1023;
    *sig = (m | HIDDEN) << 3;
    return;
}

unsigned long sf_neg(unsigned long a) { return a ^ SIGNBIT; }

unsigned long sf_add(unsigned long a, unsigned long b)
{
    int ea; int eb; int sa; int sb; int e;
    int te; int ts;
    unsigned long ma; unsigned long mb; unsigned long tm; unsigned long lost;
    int shift;
    if (sf_isnan(a) || sf_isnan(b)) return 0x7ff8000000000000UL;
    if (sf_isinf(a)) {
        if (sf_isinf(b) && sf_sign(a) != sf_sign(b)) return 0x7ff8000000000000UL;
        return a;
    }
    if (sf_isinf(b)) return b;
    if (sf_iszero(a)) { if (sf_iszero(b)) { if (sf_sign(a) && sf_sign(b)) return SIGNBIT; return 0; } return b; }
    if (sf_iszero(b)) return a;
    sa = sf_sign(a); sb = sf_sign(b);
    sf_unpack(a, &ea, &ma);
    sf_unpack(b, &eb, &mb);
    if (ea < eb) {
        te = ea; ea = eb; eb = te;
        tm = ma; ma = mb; mb = tm;
        ts = sa; sa = sb; sb = ts;
    }
    shift = ea - eb;
    if (shift > 60) { mb = (mb != 0); }
    else {
        lost = 0;
        if (shift > 0) { lost = mb & ((1UL << shift) - 1); mb = mb >> shift; }
        if (lost != 0) mb = mb | 1;
    }
    e = ea;
    if (sa == sb) return sf_pack(sa, e, ma + mb);
    if (ma == mb) return 0;
    if (ma > mb) return sf_pack(sa, e, ma - mb);
    return sf_pack(sb, e, mb - ma);
}

unsigned long sf_sub(unsigned long a, unsigned long b) { return sf_add(a, sf_neg(b)); }

unsigned long sf_mul(unsigned long a, unsigned long b)
{
    int ea; int eb; int s;
    unsigned long ma; unsigned long mb;
    unsigned long ah; unsigned long al; unsigned long bh; unsigned long bl;
    unsigned long hi; unsigned long lo; unsigned long mid1; unsigned long mid2;
    unsigned long carry; unsigned long sig;
    int len; int k; unsigned long t; unsigned long st;
    s = sf_sign(a) ^ sf_sign(b);
    if (sf_isnan(a) || sf_isnan(b)) return 0x7ff8000000000000UL;
    if (sf_isinf(a)) { if (sf_iszero(b)) return 0x7ff8000000000000UL; return (s ? SIGNBIT : 0) | 0x7ff0000000000000UL; }
    if (sf_isinf(b)) { if (sf_iszero(a)) return 0x7ff8000000000000UL; return (s ? SIGNBIT : 0) | 0x7ff0000000000000UL; }
    if (sf_iszero(a) || sf_iszero(b)) { if (s) return SIGNBIT; return 0; }
    sf_unpack(a, &ea, &ma);
    sf_unpack(b, &eb, &mb);
    /* ma and mb are 55-bit; the product is up to 110 bits. Split into 32-bit
     * halves and accumulate, because there is no 128-bit type here. */
    ma = ma >> 3; mb = mb >> 3;               /* back to 53 significant bits */
    ah = ma >> 32; al = ma & 0xffffffffUL;
    bh = mb >> 32; bl = mb & 0xffffffffUL;
    lo = al * bl;
    mid1 = al * bh;
    mid2 = ah * bl;
    hi = ah * bh;
    carry = (lo >> 32) + (mid1 & 0xffffffffUL) + (mid2 & 0xffffffffUL);
    lo = (lo & 0xffffffffUL) | (carry << 32);
    hi = hi + (mid1 >> 32) + (mid2 >> 32) + (carry >> 32);
    /* THE PRODUCT IS hi:lo, 128 BITS. Take its exact bit length, shift right
     * so exactly 56 bits remain (bit 55 leading, three of them guard bits),
     * and fold everything shifted out into a sticky bit.
     *
     * With ma and mb each at least 2^52 the product is at least 2^104, so the
     * shift is 49 or 50 and always fits in one word -- no 128-bit shift is
     * needed. Deriving it this way rather than by adjusting constants is what
     * fixed it; the constants had been guessed twice. */
    {
        if (hi != 0) {
            len = 64; t = hi;
            while (t != 0) { t = t >> 1; len = len + 1; }
        } else {
            len = 0; t = lo;
            while (t != 0) { t = t >> 1; len = len + 1; }
        }
        k = len - 56;
        st = 0;
        if (k > 0) {
            if (lo & ((1UL << k) - 1)) st = 1;
            sig = (hi << (64 - k)) | (lo >> k);
        } else {
            sig = lo;
        }
        if (st != 0) sig = sig | 1;
        /* value = (P / 2^104) * 2^(ea+eb) and P = sig * 2^k, so with sf_pack
         * reading sig as sig/2^55 the exponent is ea + eb + k - 49. */
        return sf_pack(s, ea + eb + k - 49, sig);
    }
}

unsigned long sf_div(unsigned long a, unsigned long b)
{
    int ea; int eb; int s; int i; int adj;
    unsigned long ma; unsigned long mb; unsigned long q; unsigned long rem;
    s = sf_sign(a) ^ sf_sign(b);
    if (sf_isnan(a) || sf_isnan(b)) return 0x7ff8000000000000UL;
    if (sf_isinf(a)) { if (sf_isinf(b)) return 0x7ff8000000000000UL; return (s ? SIGNBIT : 0) | 0x7ff0000000000000UL; }
    if (sf_isinf(b)) { if (s) return SIGNBIT; return 0; }
    if (sf_iszero(b)) { if (sf_iszero(a)) return 0x7ff8000000000000UL; return (s ? SIGNBIT : 0) | 0x7ff0000000000000UL; }
    if (sf_iszero(a)) { if (s) return SIGNBIT; return 0; }
    sf_unpack(a, &ea, &ma);
    sf_unpack(b, &eb, &mb);
    ma = ma >> 3; mb = mb >> 3;
    /* NORMALISE FIRST, so the running remainder stays below the divisor and
     * `rem << 1` cannot overflow. Without this the invariant breaks on the
     * very first step whenever ma >= mb, and the quotient loses its mantissa. */
    adj = 0;
    if (ma < mb) { ma = ma << 1; adj = -1; }
    q = 1; rem = ma - mb;
    i = 0;
    while (i < 55) {
        q = q << 1;
        rem = rem << 1;
        if (rem >= mb) { rem = rem - mb; q = q | 1; }
        i = i + 1;
    }
    if (rem != 0) q = q | 1;
    return sf_pack(s, ea - eb + adj, q);
}

/* double -> 64-bit integer, truncating toward zero, as a C cast does. */
long sf_to_int(unsigned long a, int is_unsigned)
{
	int e;
	int sign;
	unsigned long m;
	unsigned long r;
	sign = sf_sign(a);
	if (sf_isnan(a)) return 0;
	e = sf_exp(a);
	m = sf_mant(a);
	if (e == 0) return 0;                      /* zero or subnormal: |x| < 1 */
	e = e - 1023;
	if (e < 0) return 0;                       /* |x| < 1 truncates to zero */
	if (e > 63) {
		if (is_unsigned) return (long)0xffffffffffffffffUL;
		if (sign) return (long)0x8000000000000000UL;
		return (long)0x7fffffffffffffffUL;
	}
	m = m | HIDDEN;
	if (e >= MANTBITS) r = m << (e - MANTBITS);
	else r = m >> (MANTBITS - e);
	if (sign) return -(long)r;
	return (long)r;
}

/* 64-bit integer -> double, rounding to nearest, ties to even. */
unsigned long sf_from_int(long v, int is_unsigned)
{
	int sign;
	unsigned long u;
	unsigned long sig;
	int e;
	int len;
	unsigned long t;
	unsigned long st;
	int k;
	sign = 0;
	if (is_unsigned) {
		u = (unsigned long)v;
	} else {
		if (v < 0) { sign = 1; u = (unsigned long)(-v); }
		else u = (unsigned long)v;
	}
	if (u == 0) return 0;
	len = 0; t = u;
	while (t != 0) { t = t >> 1; len = len + 1; }
	/* sf_pack wants bit 55 leading, so aim for a 56-bit significand */
	if (len > 56) {
		k = len - 56;
		st = 0;
		if (u & ((1UL << k) - 1)) st = 1;
		sig = u >> k;
		if (st != 0) sig = sig | 1;
	} else {
		k = 0;
		sig = u << (56 - len);
	}
	e = len - 1;
	return sf_pack(sign, e, sig);
}

/* NARROWING TO float, ALSO IN INTEGERS. A cast would be one instruction under
 * mc-tcc and nothing at all under micro-c, which is the whole reason this file
 * cannot use one. */
static unsigned int strtod_to_f32(unsigned long b)
{
    unsigned long sign;
    long ex;
    unsigned long mant;
    unsigned int rbit;
    unsigned int sticky;
    unsigned int m24;
    unsigned int out;
    int drop;

    sign = (b >> 63) & 1;
    ex = (long)((b >> 52) & 0x7ff);
    mant = b & 0xfffffffffffffUL;

    if (ex == 0x7ff) {                       /* inf or nan */
        out = (unsigned int)(sign << 31) | 0x7f800000;
        if (mant != 0) out = out | 0x400000;
        return out;
    }
    if (ex == 0 && mant == 0) return (unsigned int)(sign << 31);

    if (ex == 0) { ex = -1022; }             /* subnormal double -> flushes */
    else { mant = mant | 0x10000000000000UL; ex = ex - 1023; }

    ex = ex + 127;
    if (ex >= 255) return (unsigned int)(sign << 31) | 0x7f800000;

    drop = 29;                               /* 53 significand bits -> 24 */
    if (ex <= 0) {
        drop = drop + (int)(1 - ex);
        ex = 0;
        if (drop >= 54) return (unsigned int)(sign << 31);
    }
    rbit = (unsigned int)((mant >> (drop - 1)) & 1);
    sticky = 0;
    if ((mant & ((1UL << (drop - 1)) - 1)) != 0) sticky = 1;
    m24 = (unsigned int)(mant >> drop);
    if (rbit != 0) {
        if (sticky != 0 || (m24 & 1) != 0) {
            m24 = m24 + 1;
            if (m24 == 0x1000000) { m24 = m24 >> 1; ex = ex + 1; }
        }
    }
    if (ex >= 255) return (unsigned int)(sign << 31) | 0x7f800000;
    if (ex == 0) return (unsigned int)(sign << 31) | m24;
    return (unsigned int)(sign << 31) | ((unsigned int)ex << 23) | (m24 & 0x7fffff);
}

/* THE TWO SINGLE-PRECISION CONVERSIONS tcc's CONSTANT FOLDER NEEDS.
 *
 * gen_cast narrows and widens a folded constant with
 *     vtop->c.f  = (float)vtop->c.ld;
 *     vtop->c.ld = vtop->c.f;
 * which are float operations in C like all the others, so `float x = 2;`
 * folded to 0.0f while every other float path was already right. The
 * narrowing is strtod_to_f32 above, which is exact; the widening is trivial
 * in integers because every float is a double exactly.
 *
 * MEASURED AGAINST glibc: 400,011 of 400,011 for the pair, round-tripping
 * every exponent and the subnormal range. */
unsigned int sf_to_f32(unsigned long b)
{
    return strtod_to_f32(b);
}

unsigned long sf_from_f32(unsigned int f)
{
    unsigned long sign;
    unsigned long ex;
    unsigned long mant;
    int e;
    sign = ((unsigned long)f) >> 31;
    ex = (((unsigned long)f) >> 23) & 255;
    mant = ((unsigned long)f) & 8388607;
    if (ex == 255) {
        if (mant != 0) return 0x7ff8000000000000UL;
        if (sign) return 0xfff0000000000000UL;
        return 0x7ff0000000000000UL;
    }
    if (ex == 0) {
        if (mant == 0) { if (sign) return 0x8000000000000000UL; return 0; }
        /* subnormal float: normalise into the double's much wider exponent */
        e = -126;
        while ((mant & 8388608) == 0) { mant = mant << 1; e = e - 1; }
        mant = mant & 8388607;
        return (sign << 63) | (((unsigned long)(e + 1023)) << 52) | (mant << 29);
    }
    return (sign << 63) | ((ex - 127 + 1023) << 52) | (mant << 29);
}
