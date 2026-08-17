/* The factor verifier. See verify.h for why TOTP has no derive function. */
#define _GNU_SOURCE 1
#include "verify.h"

#include <gcrypt.h>

#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <pwd.h>

/* ---- configuration ---------------------------------------------------- */

/* THE PASSWD ENTRY FIRST, THE ENVIRONMENT SECOND -- INVERTED, TWICE, EACH
 * TIME FOR A FAILURE MEASURED ON HARDWARE.
 *
 * Round one: getty does not set HOME at all, so getenv returned NULL and
 * console login refused everything. getpwuid was added -- as the FALLBACK.
 *
 * Round two: the console shell inherits init's environment, and on this
 * machine that carries HOME=/root -- set, non-empty, and WRONG for uid
 * 1000. The fallback never fired, the verifier looked for its config in
 * /root/.config/veron, found nothing, and refused everything: `veron-enroll
 * check` on the console printed `confdir: /root/.config/veron` beside
 * `getpwuid(1000): /home/veron`, the same binary flipping to `unwrap: OK`
 * the moment HOME was overridden by hand.
 *
 * The passwd entry is where a home directory is DEFINED; the environment
 * is hearsay about it. So the lookup now asks the definition first and
 * falls back to the environment only when there is no passwd entry to ask
 * -- the reverse of before, and the version that cannot be lied to by
 * whatever a getty or an init happened to leave behind. */
static const char *home_dir(void)
{
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && *pw->pw_dir)
        return pw->pw_dir;
    const char *h = getenv("HOME");
    if (h && *h)
        return h;
    return NULL;
}

/* ONE key = value PER LINE, the same shape veron-pinentry reads, so a person
 * setting this system up learns one file format rather than two. */
/* NOT static: veron-enroll reads the same file with the same parser. Two
 * copies of a config reader is how a writer and a reader drift apart. */
int conf_get_pub(const char *key, char *out, size_t outlen)
{
    /* The system store -- see veron_confdir in wrap.c for the argument. */
    char path[1024];
    snprintf(path, sizeof path, "/persist/veron-auth/auth.conf");
    FILE *f = fopen(path, "r");
    if (!f) {
        /* THE FAILURE THAT HID FOR HOURS. fopen failing on EACCES and on
         * ENOENT both returned 0 here, and the caller reports 0 as "no
         * keyfile slots -- nothing enrolled" -- so a store the greeter
         * COULD NOT READ looked identical to an EMPTY one. On machine #1
         * (2026-08-17) the file was -rw------- veron:veron and the greeter
         * (gid auth) got EACCES; every "nothing enrolled" message was a
         * lie. errno distinguishes them; say which, once, so a permission
         * problem never again masquerades as an enrolment problem. */
        if (errno == EACCES)
            fprintf(stderr, "veron-verify: %s: permission denied "
                    "(the reader is not in the store's group)\n", path);
        return 0;
    }
    char line[1024];
    size_t klen = strlen(key);
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        char *nl = strpbrk(line, "\r\n");
        if (nl) *nl = '\0';
        if (!strncmp(line, key, klen) && line[klen] == '=') {
            snprintf(out, outlen, "%s", line + klen + 1);
            found = out[0] != '\0';
            break;
        }
    }
    fclose(f);
    return found;
}

/* ---- constant-time compare -------------------------------------------- */

/* NO memcmp ON A SECRET. memcmp returns as soon as two bytes differ, so how
 * long it took says how many leading bytes were right. That is a real attack
 * against a code a person can retry, and the fix costs nothing. */
static int ct_equal(const void *a, const void *b, size_t n)
{
    const volatile unsigned char *x = a, *y = b;
    unsigned char d = 0;
    for (size_t i = 0; i < n; i++)
        d |= (unsigned char)(x[i] ^ y[i]);
    return d == 0;
}

/* HEX IN, BYTES OUT. Paired with veron-enroll's writer; see keyfile_gate. */
static int unhex(const char *s, uint8_t *out, size_t outlen)
{
    if (strlen(s) != outlen * 2)
        return 0;
    for (size_t i = 0; i < outlen; i++) {
        int hi = s[i * 2], lo = s[i * 2 + 1];
        hi = hi >= 'a' ? hi - 'a' + 10 : hi >= 'A' ? hi - 'A' + 10 : hi - '0';
        lo = lo >= 'a' ? lo - 'a' + 10 : lo >= 'A' ? lo - 'A' + 10 : lo - '0';
        if (hi < 0 || hi > 15 || lo < 0 || lo > 15)
            return 0;
        out[i] = (uint8_t)(hi * 16 + lo);
    }
    return 1;
}

/* ---- TOTP -------------------------------------------------------------- */

/* BASE32, BECAUSE THAT IS WHAT AUTHENTICATOR APPS EMIT. The seed file holds
 * the same string the app was given, so the two cannot drift apart through a
 * transcription step. */
static int base32_decode(const char *in, uint8_t *out, size_t outlen)
{
    unsigned buf = 0;
    int bits = 0;
    size_t w = 0;
    for (const char *p = in; *p; p++) {
        int v;
        if (*p >= 'A' && *p <= 'Z')      v = *p - 'A';
        else if (*p >= 'a' && *p <= 'z') v = *p - 'a';
        else if (*p >= '2' && *p <= '7') v = *p - '2' + 26;
        else if (*p == '=' || *p == ' ' || *p == '-') continue;
        else return -1;
        buf = (buf << 5) | (unsigned)v;
        bits += 5;
        if (bits >= 8) {
            if (w >= outlen)
                return -1;
            out[w++] = (uint8_t)((buf >> (bits - 8)) & 0xff);
            bits -= 8;
        }
    }
    return (int)w;
}

static int totp_at(const uint8_t *key, size_t keylen, uint64_t step)
{
    uint8_t msg[8];
    for (int i = 7; i >= 0; i--) {
        msg[i] = (uint8_t)(step & 0xff);
        step >>= 8;
    }
    gcry_md_hd_t h;
    if (gcry_md_open(&h, GCRY_MD_SHA1, GCRY_MD_FLAG_HMAC))
        return -1;
    if (gcry_md_setkey(h, key, keylen)) {
        gcry_md_close(h);
        return -1;
    }
    gcry_md_write(h, msg, sizeof msg);
    unsigned char *d = gcry_md_read(h, GCRY_MD_SHA1);
    if (!d) {
        gcry_md_close(h);
        return -1;
    }
    /* RFC 4226 DYNAMIC TRUNCATION: the low nibble of the last byte picks the
     * offset, and the top bit of the selected word is masked off so the
     * result is positive in signed arithmetic. */
    int off = d[19] & 0x0f;
    uint32_t bin = ((uint32_t)(d[off] & 0x7f) << 24)
                 | ((uint32_t)d[off + 1] << 16)
                 | ((uint32_t)d[off + 2] << 8)
                 | (uint32_t)d[off + 3];
    gcry_md_close(h);
    return (int)(bin % 1000000u);
}

/* THE SEED IS PASSED IN, NOT READ FROM A PATH, because there is no longer a
 * file to read: it lives encrypted under the master secret and the caller has
 * just decrypted it. A function that took a path would be a function that
 * invited a plaintext seed back onto the disk. */
int veron_totp_check_seed(const char *seed_b32, const char *statepath,
                          const char *code, int codelen)
{
    if (codelen != 6)
        return 0;

    char b32[512];
    snprintf(b32, sizeof b32, "%s", seed_b32);

    uint8_t key[128];
    int keylen = base32_decode(b32, key, sizeof key);
    explicit_bzero(b32, sizeof b32);
    if (keylen <= 0)
        return 0;

    uint64_t now = (uint64_t)time(NULL);
    uint64_t step = now / 30;

    /* THE LAST ACCEPTED STEP, READ BEFORE ANY CANDIDATE IS TESTED. Without
     * this a code stays valid for its whole thirty seconds no matter how many
     * times it is used, so watching one entry is enough to repeat it. RFC 6238
     * is explicit that a second use of an accepted code must be refused. */
    uint64_t last = 0;
    FILE *sf = fopen(statepath, "r");
    if (sf) {
        if (fscanf(sf, "%llu", (unsigned long long *)&last) != 1)
            last = 0;
        fclose(sf);
    }

    int want = -1;
    uint64_t used = 0;
    for (int64_t d = -1; d <= 1; d++) {
        uint64_t s = step + (uint64_t)d;
        if (s <= last)
            continue;              /* already spent */
        int v = totp_at(key, (size_t)keylen, s);
        /* THE RANGE IS CHECKED RATHER THAN ASSUMED. totp_at returns a value
         * modulo 1000000, but nothing in its signature says so, and the
         * compiler was right to point out that a wider value would overrun a
         * six-digit buffer. */
        if (v < 0 || v > 999999)
            continue;
        char buf[16];
        snprintf(buf, sizeof buf, "%06d", v);
        if (ct_equal(buf, code, 6)) {
            want = v;
            used = s;
            break;
        }
    }
    explicit_bzero(key, sizeof key);
    if (want < 0)
        return 0;

    /* WRITTEN BEFORE SUCCESS IS REPORTED. If this file cannot be written the
     * attempt is refused rather than accepted, because an accepted code that
     * was never recorded is a code that can be used again. */
    sf = fopen(statepath, "w");
    if (!sf)
        return 0;
    fprintf(sf, "%llu\n", (unsigned long long)used);
    int ok = fflush(sf) == 0;
    fclose(sf);
    return ok;
}

/* ---- key file ---------------------------------------------------------- */

int veron_keyfile_derive(const char *path, const uint8_t salt[8],
                         uint8_t out[32])
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return 0;
    unsigned char buf[65536];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    if (!n)
        return 0;

    /* ITERSALTED_S2K, FOR THE REASON SET OUT IN veron-pinentry: gcry_kdf_derive
     * carries no time, memory or lane parameters, so Argon2 is not reachable
     * through it -- libgcrypt exposes Argon2 through gcry_kdf_open/compute/
     * final instead, and passing GCRY_KDF_ARGON2 here fails rather than
     * degrading. The security therefore rests on the key file being real
     * entropy: 32 or more bytes from /dev/urandom, on something you carry. */
    /* saltlen 8, AND PASSING 16 IS WHY THIS ALWAYS FAILED. libgcrypt's S2K
     * requires exactly 8 octets and returns GPG_ERR_INV_VALUE otherwise; the
     * gnupg call this was modelled on (g10/card-util.c:2138) passes 8, and
     * veron-pinentry got it right. Only this copy did not. */
    gcry_error_t e = gcry_kdf_derive(buf, n,
                                     GCRY_KDF_ITERSALTED_S2K, GCRY_MD_SHA256,
                                     salt, 8, 1000000, 32, out);
    explicit_bzero(buf, sizeof buf);
    return e == 0;
}

/* THE STORED HASH OF THE KEY FILE'S DERIVED VALUE. The lock screen has no
 * disk key to unwrap -- it only needs to know the file is the right one -- so
 * it compares against a hash written at enrolment. */
static int keyfile_gate(const char *path)
{
    char expect[128], saltcfg[64];
    if (!conf_get_pub("keyfile-hash", expect, sizeof expect))
        return 0;
    /* THE SALT IS HEX ON DISK AND SIXTEEN RAW BYTES HERE. veron-enroll writes
     * it with %02x; reading it as raw characters instead would derive from a
     * different salt than the one the stored hash was made with, so the key
     * file would be silently and permanently wrong. The two decoders have to
     * agree, which is why this is not a memcpy. */
    uint8_t salt[8];
    memset(salt, 0, sizeof salt);
    if (!conf_get_pub("keyfile-salt", saltcfg, sizeof saltcfg))
        return 0;
    if (!unhex(saltcfg, salt, sizeof salt))
        return 0;

    uint8_t key[32];
    if (!veron_keyfile_derive(path, salt, key))
        return 0;

    char hex[65];
    for (int i = 0; i < 32; i++)
        snprintf(hex + i * 2, 3, "%02x", key[i]);
    explicit_bzero(key, sizeof key);

    int ok = strlen(expect) == 64 && ct_equal(hex, expect, 64);
    explicit_bzero(hex, sizeof hex);
    return ok;
}

/* ---- card presence ----------------------------------------------------- */

/* THE ALREADY-RUNNING gpg STACK ANSWERS THIS, rather than a second USB path.
 * scdaemon, pcscd and the CCID driver are built and running for the vault, so
 * asking gpg is both the smallest code and the only path proven on this
 * hardware. `gpg --card-status` exits non-zero when no card is present.
 *
 * POSSESSION ONLY, AND THE LIMIT IS WORTH STATING: this proves A card is
 * present, not that it is YOURS. Any OpenPGP card answers. For a lock screen,
 * combined with another factor, that is a reasonable bar; for releasing a disk
 * key it is not, which is why there is no derive counterpart here. */
int veron_card_present(void)
{
    int rc = system("gpg --card-status >/dev/null 2>&1");
    return rc == 0;
}

/* ---- policy ------------------------------------------------------------ */

int veron_verify(const char *input, int len)
{
    if (len < 0 || len >= 4096)
        return 0;

    char buf[4096];
    memcpy(buf, input, (size_t)len);
    buf[len] = '\0';

    char wrapdir[1024];
    if (!veron_confdir(wrapdir, sizeof wrapdir)) {
        explicit_bzero(buf, sizeof buf);
        return 0;
    }

    /* A POSSESSION FACTOR FIRST, ALWAYS, AND ANY ONE OF THEM WILL DO.
     *
     * Each enrolled key file has its own wrap of the same master secret, so
     * enrolling a spare does not invalidate the original and losing one does
     * not lock out the other. This is the redundancy the design asks the user
     * to arrange, and it is why the loop runs over slots rather than looking
     * for a single configured file.
     *
     * NOTHING TYPED IS CONSULTED HERE. A key file is something you HAVE: the
     * check is whether the bytes on the stick unwrap the master secret, not
     * whether anybody typed anything. */
    uint8_t master[VERON_MASTER_LEN];
    int have_master = 0;
    int slots_seen = 0;
    for (int i = 0; i < 8 && !have_master; i++) {
        char k[32], kf[1024], wp[1200];
        snprintf(k, sizeof k, "keyfile%d", i);
        if (!conf_get_pub(k, kf, sizeof kf))
            continue;
        slots_seen++;
        snprintf(wp, sizeof wp, "%s/master.%d.wrap", wrapdir, i);
        if (veron_master_from_keyfile(kf, wp, master))
            have_master = 1;
        else
            /* SAY WHICH SLOT AND WHY-SHAPED, ON stderr. "Not accepted" was
             * the only output for every distinct failure this system has
             * had -- wrong HOME, absent mount, stale wrap -- and each cost
             * a diagnostic session to tell apart. Paths are not secrets;
             * the master secret and the key bytes never appear here. The
             * lock screen's stderr lands in the compositor's logfile and
             * the console's on the tty, so the reason is readable where
             * the refusal happened. */
            fprintf(stderr, "veron-verify: slot %d: %s did not unwrap %s "
                    "(missing/unreadable file, wrong key file, or damaged "
                    "wrap)\n", i, kf, wp);
    }
    if (!slots_seen)
        fprintf(stderr, "veron-verify: no keyfile slots configured under "
                "%s -- wrong home resolution or nothing enrolled\n", wrapdir);

    /* THE CARD, IF ENROLLED, IS A POSSESSION FACTOR TOO -- but presence alone
     * proves only that A card is plugged in, not that it is yours. It cannot
     * yield the master secret, so it can accompany a key file and cannot
     * replace one. Recorded plainly rather than counted as equivalent. */
    char v[64];
    int card_ok = 0;
    if (conf_get_pub("card", v, sizeof v) && !strcmp(v, "yes"))
        card_ok = veron_card_present();

    if (!have_master) {
        /* NO POSSESSION FACTOR SUCCEEDED, SO NOTHING ELSE IS EVEN ASKED.
         * There is no path here that a typed input can open: an unconfigured
         * or unreadable store is a closed door, not an open one. */
        explicit_bzero(buf, sizeof buf);
        return 0;
    }

    /* TOTP, ONLY NOW, AND ONLY IF IT WAS ENROLLED. The seed is decrypted with
     * the master secret that a possession factor just produced -- which is
     * the whole reason a plaintext seed no longer sits on the disk. */
    int ok = 1;
    if (conf_get_pub("totp", v, sizeof v) && !strcmp(v, "yes")) {
        char seed[128], state[1200];
        snprintf(state, sizeof state, "%s/totp.state", wrapdir);
        if (!veron_totp_seed_read(master, seed, sizeof seed)) {
            ok = 0;
        } else {
            ok = veron_totp_check_seed(seed, state, buf, len);
            explicit_bzero(seed, sizeof seed);
        }
    }

    if (conf_get_pub("card", v, sizeof v) && !strcmp(v, "yes") && !card_ok)
        ok = 0;

    explicit_bzero(master, sizeof master);
    explicit_bzero(buf, sizeof buf);
    return ok;
}
