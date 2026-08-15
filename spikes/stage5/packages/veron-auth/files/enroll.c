/* veron-enroll -- write down what "you" means, once, on this machine.
 *
 * WHY THIS IS A SEPARATE PROGRAM. veron-lock and veron-login only ever CHECK
 * factors; neither may create one. If a lock screen could enrol a key file it
 * would be a lock screen that can be told what key opens it, which is not a
 * lock. So enrolment is a deliberate act at a shell, and the checkers are
 * read-only with respect to configuration.
 *
 * NOTHING HERE GOES IN THE IMAGE. Every value this writes is unique to one
 * machine -- a salt, a hash, a TOTP seed -- and the image has to stay
 * byte-for-byte reproducible. So this runs after first boot and writes into
 * the home directory, which /persist backs, and the image itself never
 * contains a secret or anything derived from one.
 *
 * WHAT IT WRITES, all under ~/.config/veron/:
 *   auth.conf    keyfile=, keyfile-salt=, keyfile-hash=, totp=, card=, require=
 *   totp.key     the base32 seed, mode 0600
 *   totp.state   the last accepted time step, so a code cannot be replayed
 */
#define _GNU_SOURCE 1
#include "verify.h"

#include <gcrypt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <pwd.h>
#include <errno.h>

static int mkconfdir(char *out, size_t n)
{
    /* THE SAME LOOKUP THE VERIFIER USES, so enrolment cannot write to one
     * place while the check reads another. veron-enroll is normally run from
     * a shell where HOME is set, but a mismatch here would produce the worst
     * kind of failure: a config file written successfully and never found. */
    const char *home = getenv("HOME");
    if (!home || !*home) {
        struct passwd *pw = getpwuid(getuid());
        home = (pw && pw->pw_dir && *pw->pw_dir) ? pw->pw_dir : NULL;
    }
    if (!home) {
        fprintf(stderr, "veron-enroll: cannot determine the home directory\n");
        return 0;
    }
    snprintf(out, n, "%s/.config/veron", home);
    char parent[1024];
    snprintf(parent, sizeof parent, "%s/.config", home);
    mkdir(parent, 0700);
    if (mkdir(out, 0700) < 0 && errno != EEXIST) {
        fprintf(stderr, "veron-enroll: cannot create %s: %s\n",
                out, strerror(errno));
        return 0;
    }
    return 1;
}

/* THE SALT IS RANDOM AND PER MACHINE, unlike veron-pinentry's fixed one. The
 * difference is deliberate: the pinentry's salt must be identical everywhere
 * forever or an existing vault stops opening, while this one only has to stay
 * put on this machine, so it can be random and is. */
static int gen_salt(uint8_t salt[8])
{
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0)
        return 0;
    ssize_t n = read(fd, salt, 8);
    close(fd);
    return n == 8;
}

static void hex(const uint8_t *in, size_t n, char *out)
{
    for (size_t i = 0; i < n; i++)
        sprintf(out + i * 2, "%02x", in[i]);
    out[n * 2] = '\0';
}

/* THE SALT IS STORED AS HEX AND USED AS 16 RAW BYTES, and the two must not
 * drift apart -- a salt written one way and read another produces a hash that
 * never matches and a key file that is silently always wrong. verify.c reads
 * it back through this same decoder. */
static int unhex(const char *s, uint8_t *out, size_t outlen)
{
    size_t n = strlen(s);
    if (n != outlen * 2)
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

static const char B32[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

static int gen_totp_seed(char *out, size_t outlen)
{
    uint8_t raw[20];                 /* 160 bits, what RFC 4226 recommends */
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0)
        return 0;
    ssize_t n = read(fd, raw, sizeof raw);
    close(fd);
    if (n != (ssize_t)sizeof raw)
        return 0;

    size_t w = 0;
    unsigned buf = 0;
    int bits = 0;
    for (size_t i = 0; i < sizeof raw; i++) {
        buf = (buf << 8) | raw[i];
        bits += 8;
        while (bits >= 5) {
            if (w + 1 >= outlen)
                return 0;
            out[w++] = B32[(buf >> (bits - 5)) & 31];
            bits -= 5;
        }
    }
    if (bits > 0 && w + 1 < outlen)
        out[w++] = B32[(buf << (5 - bits)) & 31];
    out[w] = '\0';
    explicit_bzero(raw, sizeof raw);
    return 1;
}

/* REWRITE THE WHOLE FILE, KEEPING KEYS THIS RUN DID NOT SET. Appending would
 * leave two lines with the same key and let the reader pick whichever it
 * happens to find first, which is how enrolling twice produces a machine that
 * checks against a stale hash. */
static int conf_set(const char *dir, const char *key, const char *val)
{
    char path[1024], tmp[1088];
    snprintf(path, sizeof path, "%s/auth.conf", dir);
    snprintf(tmp, sizeof tmp, "%s/auth.conf.new", dir);

    char keep[64][1024];
    int nkeep = 0;
    FILE *in = fopen(path, "r");
    if (in) {
        char line[1024];
        size_t klen = strlen(key);
        while (fgets(line, sizeof line, in) && nkeep < 64) {
            char *nl = strpbrk(line, "\r\n");
            if (nl) *nl = '\0';
            if (!line[0])
                continue;
            if (!strncmp(line, key, klen) && line[klen] == '=')
                continue;                    /* replaced below */
            snprintf(keep[nkeep++], sizeof keep[0], "%s", line);
        }
        fclose(in);
    }

    FILE *out = fopen(tmp, "w");
    if (!out) {
        fprintf(stderr, "veron-enroll: cannot write %s: %s\n",
                tmp, strerror(errno));
        return 0;
    }
    for (int i = 0; i < nkeep; i++)
        fprintf(out, "%s\n", keep[i]);
    if (val)
        fprintf(out, "%s=%s\n", key, val);
    int ok = fflush(out) == 0;
    fclose(out);
    if (!ok)
        return 0;
    /* RENAMED INTO PLACE so a crash mid-write cannot leave a half-file that
     * locks the machine out of its own configuration. */
    if (rename(tmp, path) < 0) {
        fprintf(stderr, "veron-enroll: cannot replace %s: %s\n",
                path, strerror(errno));
        return 0;
    }
    chmod(path, 0600);
    return 1;
}

static void usage(void)
{
    printf(
"veron-enroll -- configure the factors that unlock this machine\n"
"\n"
"  veron-enroll keyfile <path>   record a key file as a factor\n"
"  veron-enroll totp             generate a TOTP seed and print it\n"
"  veron-enroll card             require an OpenPGP card to be present\n"
"  veron-enroll require any|all  one factor is enough, or all are needed\n"
"  veron-enroll show             what is configured now\n"
"  veron-enroll remove <factor>  keyfile | totp | card\n"
"\n"
"A key file should be real entropy on something you carry:\n"
"  head -c 64 /dev/urandom > /run/media/veron/stick/veron.key\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        usage();
        return 1;
    }
    if (!strcmp(argv[1], "--version")) {
        printf("veron-enroll 1.0\n");
        return 0;
    }

    gcry_check_version(NULL);
    gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0);

    char dir[1024];
    if (!mkconfdir(dir, sizeof dir))
        return 1;

    if (!strcmp(argv[1], "keyfile")) {
        if (argc < 3) {
            usage();
            return 1;
        }
        uint8_t salt[8];
        if (!gen_salt(salt)) {
            fprintf(stderr, "veron-enroll: no entropy\n");
            return 1;
        }
        /* THE TWO FAILURES ARE REPORTED SEPARATELY NOW, because reporting
         * both as "cannot read" sent a real bug hunt to the wrong place: the
         * key file was present, 64 bytes and world-readable, while the actual
         * fault was an 8-byte salt passed as 16. An error that names the
         * wrong cause is worse than one that says only that something
         * failed. */
        FILE *probe = fopen(argv[2], "rb");
        if (!probe) {
            fprintf(stderr, "veron-enroll: cannot open %s: %s\n",
                    argv[2], strerror(errno));
            return 1;
        }
        fclose(probe);

        uint8_t key[32];
        if (!veron_keyfile_derive(argv[2], salt, key)) {
            fprintf(stderr, "veron-enroll: %s is readable but the key "
                            "derivation failed\n", argv[2]);
            fprintf(stderr, "  an empty file, or a libgcrypt that rejected "
                            "the parameters\n");
            return 1;
        }
        char salthex[17], keyhex[65];
        hex(salt, 8, salthex);
        hex(key, 32, keyhex);
        explicit_bzero(key, sizeof key);

        if (!conf_set(dir, "keyfile", argv[2]) ||
            !conf_set(dir, "keyfile-salt", salthex) ||
            !conf_set(dir, "keyfile-hash", keyhex))
            return 1;
        explicit_bzero(keyhex, sizeof keyhex);
        printf("keyfile enrolled: %s\n", argv[2]);
        printf("  the file itself is NOT copied -- keep it, and keep a spare\n");
        return 0;
    }

    if (!strcmp(argv[1], "totp")) {
        char seed[64];
        if (!gen_totp_seed(seed, sizeof seed)) {
            fprintf(stderr, "veron-enroll: no entropy\n");
            return 1;
        }
        char path[1088];
        snprintf(path, sizeof path, "%s/totp.key", dir);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) {
            fprintf(stderr, "veron-enroll: cannot write %s: %s\n",
                    path, strerror(errno));
            return 1;
        }
        dprintf(fd, "%s\n", seed);
        close(fd);

        /* THE STATE FILE IS CREATED NOW, EMPTY-ISH, rather than on first use.
         * veron_totp_check refuses a code it cannot record, so a missing
         * state file would make every code fail with no hint why. */
        snprintf(path, sizeof path, "%s/totp.state", dir);
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            dprintf(fd, "0\n");
            close(fd);
        }

        if (!conf_set(dir, "totp", "yes"))
            return 1;
        printf("TOTP enrolled. Add this secret to your authenticator app:\n\n");
        printf("    %s\n\n", seed);
        printf("  algorithm SHA1, 6 digits, 30 seconds -- the defaults.\n");
        printf("  Write it down somewhere safe before you close this terminal;\n");
        printf("  it is not shown again, and the file is mode 0600.\n");
        explicit_bzero(seed, sizeof seed);
        return 0;
    }

    if (!strcmp(argv[1], "card")) {
        if (!veron_card_present())
            printf("note: no OpenPGP card answered just now -- enrolling anyway\n");
        if (!conf_set(dir, "card", "yes"))
            return 1;
        printf("card enrolled: an OpenPGP card must be present\n");
        return 0;
    }

    if (!strcmp(argv[1], "require")) {
        if (argc < 3 || (strcmp(argv[2], "any") && strcmp(argv[2], "all"))) {
            usage();
            return 1;
        }
        if (!conf_set(dir, "require", argv[2]))
            return 1;
        printf("require = %s\n", argv[2]);
        if (!strcmp(argv[2], "all"))
            printf("  every enrolled factor must now be satisfied. Losing one\n"
                   "  locks the screen against you -- Ctrl+Alt+F2 is the way back.\n");
        return 0;
    }

    if (!strcmp(argv[1], "remove")) {
        if (argc < 3) {
            usage();
            return 1;
        }
        if (!strcmp(argv[2], "keyfile")) {
            conf_set(dir, "keyfile", NULL);
            conf_set(dir, "keyfile-salt", NULL);
            conf_set(dir, "keyfile-hash", NULL);
        } else if (!strcmp(argv[2], "totp")) {
            conf_set(dir, "totp", NULL);
        } else if (!strcmp(argv[2], "card")) {
            conf_set(dir, "card", NULL);
        } else {
            usage();
            return 1;
        }
        printf("removed: %s\n", argv[2]);
        return 0;
    }

    if (!strcmp(argv[1], "show")) {
        char path[1088];
        snprintf(path, sizeof path, "%s/auth.conf", dir);
        FILE *f = fopen(path, "r");
        if (!f) {
            printf("nothing enrolled yet (%s)\n", path);
            return 0;
        }
        char line[1024];
        printf("%s:\n", path);
        while (fgets(line, sizeof line, f)) {
            /* THE HASH IS A VERIFIER, NOT A SECRET, but printing 64 hex
             * characters helps nobody read this. */
            if (!strncmp(line, "keyfile-hash=", 13))
                printf("  keyfile-hash=<set>\n");
            else
                fputs(line[0] == '\n' ? "" : "  ", stdout), fputs(line, stdout);
        }
        fclose(f);
        return 0;
    }

    usage();
    return 1;
}
