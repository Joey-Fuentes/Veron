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
    /* THE SAME LOOKUP THE VERIFIER USES -- passwd first, environment second,
     * inverted alongside verify.c and wrap.c after HOME=/root on the console
     * sent this exact binary writing to and reading from /root/.config while
     * uid 1000's real config sat untouched in /home/veron. A mismatch here
     * produces the worst kind of failure: a config file written successfully
     * and never found. */
    struct passwd *pw = getpwuid(getuid());
    const char *home = (pw && pw->pw_dir && *pw->pw_dir) ? pw->pw_dir : NULL;
    if (!home) {
        home = getenv("HOME");
        if (home && !*home)
            home = NULL;
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
"  veron-enroll keyfile <path>    record a key file as a factor\n"
"  veron-enroll totp              generate a TOTP seed and print it\n"
"  veron-enroll card              require an OpenPGP card to be present\n"
"  veron-enroll require any|all   one factor is enough, or all are needed\n"
"  veron-enroll autologin on|off  off = the session starts locked\n"
"  veron-enroll show              what is configured now\n"
"  veron-enroll check             walk every factor and say what works\n"
"  veron-enroll remove keyfile <slot>|all\n"
"  veron-enroll remove totp|card\n"
"\n"
"A key file should be real entropy on something you carry. The `media`\n"
"service mounts the first removable device at /run/media/veron/stick:\n"
"  dinitctl start media\n"
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

    /* check IS READ-ONLY AND RUNS BEFORE mkconfdir ON PURPOSE: a diagnostic
     * that creates directories changes the thing it is diagnosing.
     *
     * WHY THIS EXISTS. `veron-login` on tty3 said `not accepted` with a
     * correctly enrolled key file on disk, and said nothing else -- every
     * failure inside veron_verify collapses to the same two words, which is
     * right for a gate and useless for finding out why. This walks the same
     * steps the verifier walks and names the first one that fails.
     *
     * RUN IT TWO WAYS AND COMPARE:
     *
     *     veron-enroll check              # the session's environment
     *     env -u HOME veron-enroll check  # what getty gives veron-login
     *
     * The second strips HOME, which getty never sets -- if it fails where
     * the first succeeds, the fault is the home lookup on this machine, and
     * the line below that says `getpwuid:` is the one to read. */
    if (!strcmp(argv[1], "check")) {
        const char *env_home = getenv("HOME");
        printf("HOME (environment):   %s\n",
               env_home && *env_home ? env_home : "(unset)");
        struct passwd *pw = getpwuid(getuid());
        printf("getpwuid(%u):         %s\n", (unsigned)getuid(),
               (pw && pw->pw_dir && *pw->pw_dir) ? pw->pw_dir
                                                 : "(no passwd entry -- "
                                                   "the getty path is broken)");
        char cdir[1024];
        if (!veron_confdir(cdir, sizeof cdir)) {
            printf("confdir:              CANNOT RESOLVE -- every check "
                   "below would fail the same way\n");
            return 1;
        }
        printf("confdir:              %s\n", cdir);

        char cpath[1088];
        snprintf(cpath, sizeof cpath, "%s/auth.conf", cdir);
        FILE *cf = fopen(cpath, "r");
        printf("auth.conf:            %s\n",
               cf ? "readable" : strerror(errno));
        if (cf)
            fclose(cf);

        int usable = 0;
        for (int i = 0; i < 8; i++) {
            char k[32], kf[1024], wp[1200];
            snprintf(k, sizeof k, "keyfile%d", i);
            if (!conf_get_pub(k, kf, sizeof kf))
                continue;
            printf("keyfile%d:             %s\n", i, kf);

            int rm = veron_is_removable(kf);
            printf("  removable:          %s\n",
                   rm == 1 ? "yes" : rm == 0 ? "NO -- internal disk"
                                             : "cannot determine");

            FILE *pf = fopen(kf, "rb");
            printf("  readable:           %s\n",
                   pf ? "yes" : strerror(errno));
            if (pf)
                fclose(pf);

            snprintf(wp, sizeof wp, "%s/master.%d.wrap", cdir, i);
            uint8_t salt[16];
            printf("  wrap %s: %s\n", wp,
                   veron_wrap_salt(wp, salt) ? "present, well-formed"
                                             : "MISSING or malformed");

            uint8_t master[VERON_MASTER_LEN];
            if (veron_master_from_keyfile(kf, wp, master)) {
                printf("  unwrap:             OK -- this factor works\n");
                explicit_bzero(master, sizeof master);
                usable++;
            } else {
                printf("  unwrap:             FAILED -- wrong file, wrong "
                       "wrap, or unreadable\n");
            }
        }
        if (!usable)
            printf("keyfiles:             none enrolled or none usable\n");

        char v[64];
        printf("totp:                 %s\n",
               conf_get_pub("totp", v, sizeof v) ? v : "(not enrolled)");
        printf("card:                 %s\n",
               conf_get_pub("card", v, sizeof v) ? v : "(not enrolled)");
        printf("require:              %s\n",
               conf_get_pub("require", v, sizeof v) ? v : "(default: any)");
        printf("autologin:            %s\n",
               conf_get_pub("autologin", v, sizeof v) ? v : "(default: on)");

        printf("verdict:              %s\n",
               usable ? "a possession factor unwraps -- veron_verify can "
                        "succeed in THIS environment"
                      : "NO possession factor unwraps -- veron_verify "
                        "refuses everything in THIS environment");
        return usable ? 0 : 1;
    }

    char dir[1024];
    if (!mkconfdir(dir, sizeof dir))
        return 1;

    if (!strcmp(argv[1], "keyfile")) {
        if (argc < 3) {
            usage();
            return 1;
        }

        /* REFUSED ON THE ROOT FILESYSTEM, NOT WARNED ABOUT.
         *
         * Every other secret this system stores is encrypted to something
         * that is not on the disk. The key file is where that chain
         * terminates, so it cannot itself be encrypted -- which makes its
         * PLACEMENT the entire security property. On the internal disk it
         * protects nothing: whoever takes the disk takes the key with it.
         *
         * A warning would be ignored, and was: every instruction given during
         * testing put the key file in $HOME, which is precisely the useless
         * arrangement. Refusing is the only version that holds.
         *
         * A LIVE IMAGE PASSES NATURALLY, because there the root filesystem IS
         * removable, so this rule needs no exception for the case it would
         * otherwise break. */
        int rm = veron_is_removable(argv[2]);
        if (rm != 1) {
            if (rm < 0)
                fprintf(stderr,
                  "veron-enroll: %s cannot be traced to a removable disk --\n"
                  "  refused. Either the file does not exist, or it lives on\n"
                  "  tmpfs or an overlay, where it would not survive a reboot\n"
                  "  and cannot be shown to be on media you carry.\n\n",
                  argv[2]);
            else
                fprintf(stderr,
                  "veron-enroll: %s is on this machine's internal disk --\n"
                  "  refused.\n\n"
                  "  A key file on the disk it unlocks protects nothing:\n"
                  "  whoever takes the disk takes the key with it.\n\n",
                  argv[2]);
            fprintf(stderr,
              "  Put it on removable media -- the thing you carry and the\n"
              "  disk does not. The `media` service mounts the first\n"
              "  removable device it finds at /run/media/veron/stick:\n\n"
              "    dinitctl start media\n"
              "    head -c 64 /dev/urandom > /run/media/veron/stick/veron.key\n"
              "    veron-enroll keyfile /run/media/veron/stick/veron.key\n"
              "    dinitctl stop media       # before unplugging\n\n"
              "  VERON_ALLOW_ONDISK_KEYFILE=1 overrides this for testing, and\n"
              "  produces a configuration that is not secure.\n");
            if (!getenv("VERON_ALLOW_ONDISK_KEYFILE"))
                return 1;
            fprintf(stderr, "  overridden -- continuing INSECURELY\n\n");
        }

        FILE *probe = fopen(argv[2], "rb");
        if (!probe) {
            fprintf(stderr, "veron-enroll: cannot open %s: %s\n",
                    argv[2], strerror(errno));
            return 1;
        }
        fclose(probe);

        /* THE MASTER SECRET IS CREATED ONCE AND WRAPPED MANY TIMES.
         *
         * If a wrap already exists for another factor, this one wraps the
         * SAME master secret rather than inventing a new one -- which is what
         * allows a second key file to be enrolled without invalidating the
         * first, and what will let a disk key survive a factor being added
         * later. Only the first enrolment generates. */
        char wrapdir[1024], wrappath[1200];
        if (!veron_confdir(wrapdir, sizeof wrapdir))
            return 1;

        uint8_t master[VERON_MASTER_LEN];
        int have_master = 0;
        for (int i = 0; i < 8 && !have_master; i++) {
            char other[1200], okf[1024];
            snprintf(other, sizeof other, "%s/master.%d.wrap", wrapdir, i);
            char key[32];
            snprintf(key, sizeof key, "keyfile%d", i);
            if (conf_get_pub(key, okf, sizeof okf) &&
                veron_master_from_keyfile(okf, other, master))
                have_master = 1;
        }
        if (!have_master) {
            veron_master_new(master);
            printf("a new master secret was generated -- this is the first "
                   "factor\n");
        }

        /* THE FIRST FREE SLOT. Slots are per-factor so removing one does not
         * disturb the others. */
        int slot = -1;
        for (int i = 0; i < 8; i++) {
            char k[32], v[1024];
            snprintf(k, sizeof k, "keyfile%d", i);
            if (!conf_get_pub(k, v, sizeof v)) { slot = i; break; }
            if (!strcmp(v, argv[2]))           { slot = i; break; }
        }
        if (slot < 0) {
            fprintf(stderr, "veron-enroll: no free key file slot (8 max)\n");
            explicit_bzero(master, sizeof master);
            return 1;
        }
        snprintf(wrappath, sizeof wrappath, "%s/master.%d.wrap",
                 wrapdir, slot);

        if (!veron_wrap_to_keyfile(argv[2], wrappath, master)) {
            fprintf(stderr, "veron-enroll: %s is readable but the key "
                            "derivation failed\n", argv[2]);
            explicit_bzero(master, sizeof master);
            return 1;
        }
        explicit_bzero(master, sizeof master);

        char k[32];
        snprintf(k, sizeof k, "keyfile%d", slot);
        if (!conf_set(dir, k, argv[2]))
            return 1;

        printf("keyfile enrolled in slot %d: %s\n", slot, argv[2]);
        printf("  the file itself is NOT copied anywhere\n");

        /* ENROLLING A FACTOR ARMS THE GATE -- the recorded design, enabled
         * now that the lock and the console gate are both proven on
         * hardware. A person who enrolls a key expects the machine to
         * demand it; a gate that stays open after enrolment until a second
         * command nobody knows about is a gate that surprises its owner in
         * the wrong direction (measured: "it should have the login prompt"
         * was the owner's exact reading). The proof-of-unwrap requirement
         * is satisfied by construction here -- the wrap that arms the gate
         * was created seconds ago from the very file that opens it. First
         * enrolment only; re-enrolling a spare does not overwrite an
         * explicit later choice of `autologin on`. */
        {
            char av[64];
            if (!conf_get_pub("autologin", av, sizeof av)) {
                if (conf_set(dir, "autologin", "off"))
                    printf("\n  autologin is now OFF: the session STARTS "
                           "LOCKED and every console\n  asks for this "
                           "factor. Consoles already open stay open until\n"
                           "  exit or reboot. `veron-enroll autologin on` "
                           "disarms.\n");
            }
        }

        /* ONE FACTOR IS A SINGLE POINT OF FAILURE AND THE PERSON SHOULD BE
         * TOLD SO IN WORDS. There is no recovery in this system by design:
         * no escrow, no reset, no master password. Redundancy is the user's
         * to arrange, in advance, and it is only arranged if they know. */
        int n = 0;
        for (int i = 0; i < 8; i++) {
            char kk[32], vv[1024];
            snprintf(kk, sizeof kk, "keyfile%d", i);
            if (conf_get_pub(kk, vv, sizeof vv)) n++;
        }
        if (n < 2) {
            printf("\n  WARNING: this is your only enrolled factor.\n");
            printf("  There is no recovery. Lose it and the vault, the lock\n");
            printf("  screen and the console are closed permanently -- there\n");
            printf("  is no escrow, no reset and no master password by\n");
            printf("  design. Enrol a second key file or a second token now:\n");
            printf("    veron-enroll keyfile /run/media/veron/backup/veron.key\n");
        }
        return 0;
    }

    if (!strcmp(argv[1], "totp")) {
        /* TOTP IS NEVER A FIRST FACTOR, AND THIS IS WHERE THAT IS ENFORCED.
         *
         * A TOTP verifier must hold the shared secret in usable form -- that
         * is what symmetric means, and no construction avoids it. Stored in
         * the clear it lets anyone with the disk mint valid codes forever, so
         * it would be worth nothing against exactly the attacker it is
         * imagined to stop.
         *
         * So the seed is encrypted under the master secret, and the master
         * secret only exists once a possession factor has been enrolled. TOTP
         * therefore cannot be checked until something you HAVE has already
         * succeeded. It stops being an independent factor, which is the
         * design rather than a limitation of it. */
        char wrapdir[1024];
        if (!veron_confdir(wrapdir, sizeof wrapdir))
            return 1;

        uint8_t master[VERON_MASTER_LEN];
        int have_master = 0;
        for (int i = 0; i < 8 && !have_master; i++) {
            char wp[1200], kf[1024], k[32];
            snprintf(k, sizeof k, "keyfile%d", i);
            snprintf(wp, sizeof wp, "%s/master.%d.wrap", wrapdir, i);
            if (conf_get_pub(k, kf, sizeof kf) &&
                veron_master_from_keyfile(kf, wp, master))
                have_master = 1;
        }
        if (!have_master) {
            fprintf(stderr,
              "veron-enroll: no possession factor is enrolled.\n\n"
              "  TOTP cannot stand alone here. Its seed is a SHARED secret --\n"
              "  anything able to check a code can also generate one -- so on\n"
              "  an unencrypted disk a plaintext seed protects nothing at all.\n"
              "  It is stored encrypted under a master secret that only a\n"
              "  possession factor can unwrap, which means one has to exist\n"
              "  first:\n\n"
              "    veron-enroll keyfile /run/media/veron/stick/veron.key\n\n"
              "  Then enrol TOTP as the second factor it is meant to be.\n");
            return 1;
        }

        char seed[64];
        if (!gen_totp_seed(seed, sizeof seed)) {
            fprintf(stderr, "veron-enroll: no entropy\n");
            explicit_bzero(master, sizeof master);
            return 1;
        }

        if (!veron_totp_seed_write(master, seed)) {
            fprintf(stderr, "veron-enroll: cannot write the encrypted seed\n");
            explicit_bzero(master, sizeof master);
            explicit_bzero(seed, sizeof seed);
            return 1;
        }
        explicit_bzero(master, sizeof master);

        /* THE REPLAY STATE STAYS IN THE CLEAR AND THAT IS CORRECT. It records
         * the last time step accepted, which is not a secret -- knowing it
         * lets nobody generate a code. Encrypting it would only mean the
         * replay check could not run until after a factor succeeded, which is
         * the wrong order. */
        char path[1200];
        snprintf(path, sizeof path, "%s/totp.state", wrapdir);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            dprintf(fd, "0\n");
            close(fd);
        }

        /* THE OLD PLAINTEXT SEED IS REMOVED IF IT IS THERE. An earlier
         * version wrote ~/.config/veron/totp.key in the clear; leaving it
         * behind would mean the encrypted seed sat beside a readable copy of
         * itself. */
        snprintf(path, sizeof path, "%s/totp.key", wrapdir);
        if (unlink(path) == 0)
            printf("removed the old plaintext seed at %s\n", path);

        if (!conf_set(dir, "totp", "yes"))
            return 1;
        printf("TOTP enrolled. Add this secret to your authenticator app:\n\n");
        printf("    %s\n\n", seed);
        printf("  algorithm SHA1, 6 digits, 30 seconds -- the defaults.\n");
        printf("  Write it down before closing this terminal; it is not shown\n");
        printf("  again and the stored copy is encrypted.\n");
        printf("  It is a SECOND factor: a possession factor must succeed\n");
        printf("  before it is even consulted.\n");
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

    if (!strcmp(argv[1], "autologin")) {
        if (argc < 3 || (strcmp(argv[2], "on") && strcmp(argv[2], "off"))) {
            usage();
            return 1;
        }
        if (!strcmp(argv[2], "off")) {
            /* PROVE A FACTOR WORKS BEFORE ARMING THE GATE. `autologin off`
             * makes the session start locked, and a lock that no enrolled
             * factor can open is a machine reachable only from the spare
             * console. So the exact check the lock screen will run is run
             * HERE, NOW, with the media plugged in -- turning the gate on
             * requires demonstrating, once, that it can be turned back off. */
            char wrapdir[1024];
            if (!veron_confdir(wrapdir, sizeof wrapdir))
                return 1;
            uint8_t master[VERON_MASTER_LEN];
            int have_master = 0;
            for (int i = 0; i < 8 && !have_master; i++) {
                char k[32], kf[1024], wp[1200];
                snprintf(k, sizeof k, "keyfile%d", i);
                snprintf(wp, sizeof wp, "%s/master.%d.wrap", wrapdir, i);
                if (conf_get_pub(k, kf, sizeof kf) &&
                    veron_master_from_keyfile(kf, wp, master))
                    have_master = 1;
            }
            if (!have_master) {
                fprintf(stderr,
                  "veron-enroll: refused -- no enrolled possession factor\n"
                  "  unwrapped just now. Turning autologin off would lock a\n"
                  "  session nothing can open. Plug the key file in and run\n"
                  "  `veron-enroll check`; when a factor shows `unwrap: OK`,\n"
                  "  this command will accept.\n");
                return 1;
            }
            explicit_bzero(master, sizeof master);
        }
        if (!conf_set(dir, "autologin", argv[2]))
            return 1;
        printf("autologin = %s\n", argv[2]);
        if (!strcmp(argv[2], "off"))
            printf("  the session now STARTS LOCKED. The factor that just\n"
                   "  unwrapped is what opens it. Ctrl+Alt+F2 remains the\n"
                   "  escape hatch.\n");
        return 0;
    }

    if (!strcmp(argv[1], "remove")) {
        if (argc < 3) {
            usage();
            return 1;
        }
        if (!strcmp(argv[2], "keyfile")) {
            /* THE OLD FORM DELETED KEYS THE ENROLLER NO LONGER WRITES.
             * Enrolment stores keyfile0..7 plus a wrap file per slot; this
             * used to delete `keyfile`, `keyfile-salt` and `keyfile-hash`,
             * all from the pre-wrap design -- so an enrolled key file could
             * not be removed at all. It now takes a slot number or `all`,
             * and deletes the wrap beside the config line, because a wrap
             * with no config line is a wrap the verifier can never reach
             * and the next enroller would silently reuse. */
            if (argc < 4) {
                fprintf(stderr, "veron-enroll: remove keyfile <slot>|all "
                                "(see `veron-enroll show` for slots)\n");
                return 1;
            }
            int lo = 0, hi = 7;
            if (strcmp(argv[3], "all")) {
                char *end = NULL;
                long s = strtol(argv[3], &end, 10);
                if (!end || *end || s < 0 || s > 7) {
                    fprintf(stderr, "veron-enroll: slot must be 0..7 or "
                                    "all\n");
                    return 1;
                }
                lo = hi = (int)s;
            }

            /* COUNT WHAT WOULD REMAIN BEFORE REMOVING ANYTHING. Removing
             * the last possession factor while the session gate is armed
             * is a lockout by definition -- the gate would refuse every
             * input at the next session start. Refused, with the way out
             * named, rather than performed with a warning nobody reads. */
            int enrolled = 0, removing = 0;
            for (int i = 0; i < 8; i++) {
                char k[32], v[1024];
                snprintf(k, sizeof k, "keyfile%d", i);
                if (!conf_get_pub(k, v, sizeof v))
                    continue;
                enrolled++;
                if (i >= lo && i <= hi)
                    removing++;
            }
            char al[64];
            int gate_armed = conf_get_pub("autologin", al, sizeof al)
                          && !strcmp(al, "off");
            if (gate_armed && removing >= enrolled && enrolled > 0) {
                fprintf(stderr,
                  "veron-enroll: refused -- that is every enrolled key file\n"
                  "  and autologin is off, so the next session would start\n"
                  "  locked with nothing able to open it. First:\n"
                  "    veron-enroll autologin on\n");
                return 1;
            }

            char tv[64];
            if (removing >= enrolled && enrolled > 0 &&
                conf_get_pub("totp", tv, sizeof tv) && !strcmp(tv, "yes"))
                fprintf(stderr,
                  "veron-enroll: note -- TOTP stays enrolled but its seed is\n"
                  "  encrypted under the master secret, which no factor can\n"
                  "  now unwrap. Re-enrol a key file or remove totp too.\n");

            for (int i = lo; i <= hi; i++) {
                char k[32], v[1024], wp[1200];
                snprintf(k, sizeof k, "keyfile%d", i);
                if (!conf_get_pub(k, v, sizeof v))
                    continue;
                conf_set(dir, k, NULL);
                snprintf(wp, sizeof wp, "%s/master.%d.wrap", dir, i);
                if (unlink(wp) == 0)
                    printf("removed slot %d: %s (and its wrap)\n", i, v);
                else
                    printf("removed slot %d: %s (wrap was already gone: "
                           "%s)\n", i, v, strerror(errno));
            }
            /* The pre-wrap keys, if an old enrolment left them behind. */
            conf_set(dir, "keyfile", NULL);
            conf_set(dir, "keyfile-salt", NULL);
            conf_set(dir, "keyfile-hash", NULL);
            return 0;
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
