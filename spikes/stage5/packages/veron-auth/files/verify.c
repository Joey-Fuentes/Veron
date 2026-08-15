/* The factor verifier. See verify.h for why TOTP has no derive function. */
#define _GNU_SOURCE 1
#include "verify.h"

#include <gcrypt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <pwd.h>

/* ---- configuration ---------------------------------------------------- */

/* THE HOME DIRECTORY IS LOOKED UP, NOT READ FROM THE ENVIRONMENT, AND THIS IS
 * WHY CONSOLE LOGIN REFUSED EVERY ATTEMPT.
 *
 * getty does not set HOME. On an ordinary system login(1) sets it AFTER
 * authenticating -- and login(1) is precisely what veron-login replaces, so
 * by the time the verifier runs there is no HOME to read. getenv returned
 * NULL, no configuration file was found, no factors were configured as far as
 * the verifier could tell, and `veron_verify` refused: "not accepted", for
 * every input, with a correctly enrolled key file sitting on disk.
 *
 * The lock screen was unaffected because it runs inside a session that
 * already has HOME set, which is exactly why this only showed up on tty3.
 *
 * getpwuid IS THE ANSWER RATHER THAN HARDCODING /home/<user>: the passwd
 * entry is where a home directory is actually defined, and it is correct for
 * root, for a relocated home, and for any user this is ever run as. HOME is
 * still preferred when set, so nothing changes for the session case. */
static const char *home_dir(void)
{
    const char *h = getenv("HOME");
    if (h && *h)
        return h;
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && *pw->pw_dir)
        return pw->pw_dir;
    return NULL;
}

/* ONE key = value PER LINE, the same shape veron-pinentry reads, so a person
 * setting this system up learns one file format rather than two. */
static int conf_get(const char *key, char *out, size_t outlen)
{
    const char *home = home_dir();
    if (!home)
        return 0;
    char path[1024];
    snprintf(path, sizeof path, "%s/.config/veron/auth.conf", home);
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
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

int veron_totp_check(const char *seedpath, const char *statepath,
                     const char *code, int codelen)
{
    if (codelen != 6)
        return 0;

    FILE *f = fopen(seedpath, "r");
    if (!f)
        return 0;
    char b32[512];
    if (!fgets(b32, sizeof b32, f)) {
        fclose(f);
        return 0;
    }
    fclose(f);
    char *nl = strpbrk(b32, "\r\n");
    if (nl) *nl = '\0';

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
    if (!conf_get("keyfile-hash", expect, sizeof expect))
        return 0;
    /* THE SALT IS HEX ON DISK AND SIXTEEN RAW BYTES HERE. veron-enroll writes
     * it with %02x; reading it as raw characters instead would derive from a
     * different salt than the one the stored hash was made with, so the key
     * file would be silently and permanently wrong. The two decoders have to
     * agree, which is why this is not a memcpy. */
    uint8_t salt[8];
    memset(salt, 0, sizeof salt);
    if (!conf_get("keyfile-salt", saltcfg, sizeof saltcfg))
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

    const char *home = home_dir();
    char seed[1024], state[1024], kf[1024];
    int need = 0, have = 0;

    if (home) {
        snprintf(seed, sizeof seed, "%s/.config/veron/totp.key", home);
        snprintf(state, sizeof state, "%s/.config/veron/totp.state", home);
    } else {
        seed[0] = state[0] = '\0';
    }

    char v[64];
    if (conf_get("totp", v, sizeof v) && !strcmp(v, "yes")) {
        need++;
        if (seed[0] && veron_totp_check(seed, state, buf, len))
            have++;
    }
    if (conf_get("keyfile", kf, sizeof kf)) {
        need++;
        if (keyfile_gate(kf))
            have++;
    }
    if (conf_get("card", v, sizeof v) && !strcmp(v, "yes")) {
        need++;
        if (veron_card_present())
            have++;
    }

    explicit_bzero(buf, sizeof buf);

    /* NO CONFIGURED FACTORS MEANS NO UNLOCK, NOT A FREE ONE. An unconfigured
     * or unreadable auth.conf must not become an open door -- but see the
     * lockout note in lock.c: the escape from this state is a VT switch, not
     * a fallback here. */
    if (need == 0)
        return 0;

    char mode[32];
    int require_all = conf_get("require", mode, sizeof mode) &&
                      !strcmp(mode, "all");
    return require_all ? (have == need) : (have > 0);
}
