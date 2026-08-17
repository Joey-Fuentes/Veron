/* The factor store: one master secret, wrapped once per factor.
 *
 * WHY WRAPS RATHER THAN INDEPENDENT SECRETS. A person should be able to
 * enrol a second key file, or a third, without invalidating the first and
 * without re-encrypting anything that depends on the result. So there is ONE
 * master secret, generated once, and each enrolled factor gets its own
 * wrapped copy of it. Adding a factor writes a file; removing one deletes a
 * file; the master secret never changes.
 *
 * This is the same arrangement LUKS uses for key slots, and it is here for
 * the same reason: the thing being protected must not be tied to the identity
 * of any one thing that protects it.
 *
 * WHAT THE MASTER SECRET IS FOR. Today: decrypting the TOTP seed, so that a
 * shared secret never sits in the clear on a disk. Tomorrow: unwrapping a
 * disk key, which is the same operation one layer down.
 *
 * EVERY CONSTRUCTION HERE IS SYMMETRIC, AND THAT IS DELIBERATE RATHER THAN
 * INCIDENTAL. AES-256 and SHA-256 are not broken by Shor's algorithm --
 * Grover's halves the effective key length, which is why AES-256 and not
 * AES-128. An RSA or ECC wrap would be the one quantum-vulnerable link in a
 * chain whose whole point is that it does not have one, and it would be the
 * worst-placed link at that: the wrapped blob sits on disk, so it is a
 * harvest-now-decrypt-later target.
 */
#define _GNU_SOURCE 1
#include "verify.h"

#include <gcrypt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <pwd.h>

#define MASTER_LEN 64
#define WRAP_MAGIC "VERONWRAP1"

/* ---- where things live ------------------------------------------------ */

const char *veron_home(void)
{
    /* PASSWD FIRST, ENVIRONMENT SECOND -- the same inversion as verify.c's
     * home_dir, for the same measured reason: the console inherits
     * HOME=/root from init, and a set-but-wrong HOME defeated the fallback
     * entirely. Two copies of this lookup is already one too many; two
     * copies that DISAGREE would be the drift the config-reader comment
     * warns about, so change both or neither. */
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && *pw->pw_dir)
        return pw->pw_dir;
    const char *h = getenv("HOME");
    if (h && *h)
        return h;
    return NULL;
}

int veron_confdir(char *out, size_t outlen)
{
    /* A SYSTEM STORE, NOT A HOME. The enrolment records are machine
     * credentials: the greeter must read them to verify, and a greeter
     * with reason to touch any user's home is a greeter with too much
     * reach (the operator's exact objection, 2026-08-17, when a mode-700
     * home made the lock face refuse a key tty2 accepted). /persist
     * backs it, guest/init creates it veron:auth 0750, enrolment (veron)
     * writes, the auth group reads, and HOME leaves the auth path
     * entirely -- which also retires the whole /root-vs-/home class of
     * bugs the old resolution fought. */
    (void)veron_home;
    snprintf(out, outlen, "/persist/veron-auth");
    return 1;
}

/* ---- the removable-media rule ----------------------------------------- */

/* A KEY FILE ON THE DISK IT UNLOCKS IS A KEY LEFT IN THE LOCK.
 *
 * Everything else this system stores is encrypted to something not on the
 * disk. The key file is where that chain terminates, so it is the one thing
 * that cannot be encrypted -- and therefore the one thing whose PLACEMENT is
 * the entire security property. On the internal disk it protects nothing at
 * all: whoever takes the disk takes the key with it.
 *
 * THE KERNEL IS ASKED, NOT THE MOUNT TABLE. The first version compared
 * st_dev of the key file against st_dev of "/", which measures WHICH
 * FILESYSTEM and not WHETHER REMOVABLE -- and on the test machine
 * /home/veron is a bind mount from a different partition of the SAME
 * internal disk, so a key file in $HOME passed the check and was enrolled.
 * That is exactly the arrangement the check exists to prevent, verified on
 * hardware.
 *
 * So this walks from the file's st_dev to the block device behind it:
 * /sys/dev/block/<maj>:<min> resolves to the device's sysfs node, a
 * partition is stepped up to its whole disk, and the answer comes from two
 * facts the kernel states about that disk:
 *
 *   removable    the disk's own `removable` attribute -- 1 for USB sticks
 *                and SD cards, 0 for internal SATA/NVMe
 *   the bus      the resolved sysfs path names every bus on the way to the
 *                device, so "/usb" in it means USB-attached -- which covers
 *                USB SSDs and hard drives, most of which report
 *                removable=0 because their MEDIA is fixed even though the
 *                device unplugs
 *
 * Either is enough: both are things you carry away from the machine.
 *
 * THE KNOWN OVER-ACCEPT IS AN INTERNAL SD READER, which reports removable=1
 * while living inside the laptop. That errs toward accepting a card the
 * user can in fact pull out and pocket, which is the tolerable direction.
 *
 * -1 MEANS "COULD NOT DETERMINE", AND IT IS A REFUSAL, NOT A PASS. A file
 * on tmpfs, an overlay upper, or anything whose st_dev has no
 * /sys/dev/block entry cannot be traced to a disk -- and a key file that
 * cannot be shown to be on removable media must not be enrolled as though
 * it were.
 *
 * VERON_SYSFS_ROOT is a test seam: it relocates the /sys prefix so the
 * walk can be driven through a fixture tree and PROVEN TO FAIL (AGENTS.md
 * section 2c). It grants nothing the caller does not already have --
 * whoever sets the environment of veron-enroll already holds
 * VERON_ALLOW_ONDISK_KEYFILE.
 */
#include <sys/sysmacros.h>
#include <limits.h>

int veron_is_removable(const char *path)
{
    struct stat sf;
    if (stat(path, &sf) != 0)
        return -1;                 /* cannot tell; caller reports the errno */

    const char *sysroot = getenv("VERON_SYSFS_ROOT");
    if (!sysroot || !*sysroot)
        sysroot = "/sys";

    char link[PATH_MAX];
    snprintf(link, sizeof link, "%s/dev/block/%u:%u", sysroot,
             major(sf.st_dev), minor(sf.st_dev));

    char node[PATH_MAX];
    if (!realpath(link, node))
        return -1;                 /* tmpfs, overlay: no block device */

    /* A PARTITION'S removable ATTRIBUTE LIVES ON ITS DISK. The partition
     * node carries a `partition` file and the whole-disk node does not, so
     * one step up is taken exactly when the kernel says to. */
    char probe[PATH_MAX + 16];
    snprintf(probe, sizeof probe, "%s/partition", node);
    if (access(probe, F_OK) == 0) {
        char *slash = strrchr(node, '/');
        if (!slash)
            return -1;
        *slash = '\0';
    }

    snprintf(probe, sizeof probe, "%s/removable", node);
    FILE *f = fopen(probe, "r");
    if (!f)
        return -1;                 /* not a disk we understand: refuse */
    int c = fgetc(f);
    fclose(f);
    if (c == '1')
        return 1;
    if (c != '0')
        return -1;

    /* removable=0 BUT USB-ATTACHED IS STILL SOMETHING YOU CARRY. The
     * resolved path names the buses: .../usb3/3-2/... appears for anything
     * hanging off USB, and never for an internal SATA or NVMe device. */
    if (strstr(node, "/usb"))
        return 1;

    return 0;
}

/* ---- wrapping ---------------------------------------------------------- */

/* AES-256-GCM, SO A TAMPERED WRAP FAILS LOUDLY.
 *
 * A plain cipher would decrypt a corrupted or substituted wrap into garbage
 * and hand it back as if it were the master secret -- which then silently
 * fails to decrypt the TOTP seed, and the error surfaces somewhere unrelated.
 * GCM's tag turns that into an authentication failure at the point it
 * happens.
 *
 * File layout, fixed and simple enough to read with od(1):
 *   "VERONWRAP1"  10 bytes
 *   salt          16 bytes   (KDF salt for this factor)
 *   nonce         12 bytes   (GCM)
 *   tag           16 bytes
 *   ciphertext    64 bytes   (the master secret)
 */
static int wrap_write(const char *path, const uint8_t key[32],
                      const uint8_t master[MASTER_LEN],
                      const uint8_t salt[16])
{
    uint8_t nonce[12], tag[16], ct[MASTER_LEN];
    gcry_randomize(nonce, sizeof nonce, GCRY_STRONG_RANDOM);

    gcry_cipher_hd_t h;
    if (gcry_cipher_open(&h, GCRY_CIPHER_AES256, GCRY_CIPHER_MODE_GCM, 0))
        return 0;
    int ok = 0;
    if (!gcry_cipher_setkey(h, key, 32) &&
        !gcry_cipher_setiv(h, nonce, sizeof nonce) &&
        !gcry_cipher_encrypt(h, ct, sizeof ct, master, MASTER_LEN) &&
        !gcry_cipher_gettag(h, tag, sizeof tag))
        ok = 1;
    gcry_cipher_close(h);
    if (!ok)
        return 0;

    /* WRITTEN 0640 -- GROUP-READABLE ON PURPOSE. This is the wrapped
     * master: ciphertext whose only key is the factor the person holds.
     * The greeter (group auth) must read it to verify, and reading it
     * reveals nothing without the key file -- the design's whole premise.
     * 0600 here was the second half of machine #1's lockout (2026-08-17):
     * even with the dir traversable, the wrap itself refused the group.
     * RENAMED INTO PLACE, so a crash cannot leave a
     * half-written wrap where a whole one used to be. */
    char tmp[1088];
    snprintf(tmp, sizeof tmp, "%s.new", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0640);
    if (fd < 0)
        return 0;
    ok = write(fd, WRAP_MAGIC, 10) == 10
      && write(fd, salt, 16) == 16
      && write(fd, nonce, 12) == 12
      && write(fd, tag, 16) == 16
      && write(fd, ct, MASTER_LEN) == MASTER_LEN;
    close(fd);
    explicit_bzero(ct, sizeof ct);
    if (!ok) {
        unlink(tmp);
        return 0;
    }
    return rename(tmp, path) == 0;
}

static int wrap_read(const char *path, const uint8_t key[32],
                     uint8_t master[MASTER_LEN], uint8_t salt_out[16])
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    uint8_t magic[10], salt[16], nonce[12], tag[16], ct[MASTER_LEN];
    int ok = read(fd, magic, 10) == 10
          && read(fd, salt, 16) == 16
          && read(fd, nonce, 12) == 12
          && read(fd, tag, 16) == 16
          && read(fd, ct, MASTER_LEN) == MASTER_LEN;
    close(fd);
    if (!ok || memcmp(magic, WRAP_MAGIC, 10) != 0)
        return 0;
    if (salt_out)
        memcpy(salt_out, salt, 16);

    gcry_cipher_hd_t h;
    if (gcry_cipher_open(&h, GCRY_CIPHER_AES256, GCRY_CIPHER_MODE_GCM, 0))
        return 0;
    ok = 0;
    if (!gcry_cipher_setkey(h, key, 32) &&
        !gcry_cipher_setiv(h, nonce, sizeof nonce) &&
        !gcry_cipher_decrypt(h, master, MASTER_LEN, ct, sizeof ct) &&
        !gcry_cipher_checktag(h, tag, sizeof tag))
        ok = 1;
    gcry_cipher_close(h);
    if (!ok)
        explicit_bzero(master, MASTER_LEN);
    return ok;
}

/* ---- the salt lives with the wrap ------------------------------------- */

/* READ THE SALT OUT OF THE WRAP FILE ITSELF rather than from auth.conf.
 *
 * Each factor needs its own salt, and keeping it beside the thing it belongs
 * to means enrolling a second key file cannot disturb the first. It also
 * means auth.conf carries no cryptographic material at all -- it becomes a
 * list of which factors exist, which is metadata rather than secret.
 */
int veron_wrap_salt(const char *path, uint8_t salt[16])
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    uint8_t magic[10];
    int ok = read(fd, magic, 10) == 10 && read(fd, salt, 16) == 16;
    close(fd);
    return ok && memcmp(magic, WRAP_MAGIC, 10) == 0;
}

int veron_master_from_keyfile(const char *keyfile, const char *wrappath,
                              uint8_t master[MASTER_LEN])
{
    uint8_t salt[16], key[32];
    if (!veron_wrap_salt(wrappath, salt)) {
        fprintf(stderr, "veron-verify:   wrap %s: missing or malformed\n",
                wrappath);
        return 0;
    }
    /* THE FIRST 8 BYTES, BECAUSE S2K TAKES EXACTLY EIGHT. libgcrypt rejects
     * any other length with GPG_ERR_INV_VALUE (cipher/kdf.c) -- passing 16
     * made every derivation fail silently, and the error was reported as a
     * missing file. Sixteen are stored so the salt is not shortened if the
     * KDF is ever changed to one that takes more. */
    if (!veron_keyfile_derive(keyfile, salt, key)) {
        fprintf(stderr, "veron-verify:   keyfile %s: unreadable, or the "
                "key derivation itself failed (libgcrypt)\n", keyfile);
        return 0;
    }
    int ok = wrap_read(wrappath, key, master, NULL);
    if (!ok)
        fprintf(stderr, "veron-verify:   wrap %s: authentication failed -- "
                "this key file is not the one that made this wrap\n",
                wrappath);
    explicit_bzero(key, sizeof key);
    return ok;
}

int veron_master_new(uint8_t master[MASTER_LEN])
{
    gcry_randomize(master, MASTER_LEN, GCRY_VERY_STRONG_RANDOM);
    return 1;
}

int veron_wrap_to_keyfile(const char *keyfile, const char *wrappath,
                          const uint8_t master[MASTER_LEN])
{
    uint8_t salt[16], key[32];
    gcry_randomize(salt, sizeof salt, GCRY_STRONG_RANDOM);
    if (!veron_keyfile_derive(keyfile, salt, key))
        return 0;
    int ok = wrap_write(wrappath, key, master, salt);
    explicit_bzero(key, sizeof key);
    return ok;
}

/* ---- the TOTP seed, encrypted --------------------------------------- */

/* TOTP IS A SHARED SECRET, SO THE VERIFIER MUST HOLD IT -- AND THAT IS
 * EXACTLY WHY IT CANNOT BE A FACTOR ON ITS OWN HERE.
 *
 * A verifier that can check a code can also generate one. Stored in the
 * clear, the seed on an unencrypted disk lets anyone holding that disk mint
 * valid codes forever, which makes TOTP worth nothing against the attacker it
 * is usually imagined to stop.
 *
 * The way out is not a cleverer construction -- there isn't one, TOTP is
 * symmetric by definition -- but a policy: the seed is encrypted under the
 * master secret, so a possession factor must succeed BEFORE TOTP can even be
 * checked. TOTP stops being an independent factor, which is the point rather
 * than the cost. It is a second factor, never a first.
 */
int veron_totp_seed_read(const uint8_t master[MASTER_LEN],
                         char *b32, size_t b32len)
{
    char dir[1024], path[1088];
    if (!veron_confdir(dir, sizeof dir))
        return 0;
    snprintf(path, sizeof path, "%s/totp.wrap", dir);

    uint8_t key[32];
    /* THE SEED KEY IS DERIVED FROM THE MASTER, NOT THE MASTER ITSELF, so that
     * a compromise of one derived use does not hand over the others. */
    gcry_md_hd_t h;
    if (gcry_md_open(&h, GCRY_MD_SHA256, GCRY_MD_FLAG_HMAC))
        return 0;
    gcry_md_setkey(h, master, MASTER_LEN);
    gcry_md_write(h, "veron-totp-seed", 15);
    unsigned char *d = gcry_md_read(h, GCRY_MD_SHA256);
    if (!d) {
        gcry_md_close(h);
        return 0;
    }
    memcpy(key, d, 32);
    gcry_md_close(h);

    uint8_t out[MASTER_LEN];
    int ok = wrap_read(path, key, out, NULL);
    explicit_bzero(key, sizeof key);
    if (!ok)
        return 0;
    /* The seed is stored NUL-padded inside a fixed-size wrap so its length
     * does not leak through the file size. */
    snprintf(b32, b32len, "%.*s", MASTER_LEN, (char *)out);
    explicit_bzero(out, sizeof out);
    return 1;
}

int veron_totp_seed_write(const uint8_t master[MASTER_LEN], const char *b32)
{
    char dir[1024], path[1088];
    if (!veron_confdir(dir, sizeof dir))
        return 0;
    snprintf(path, sizeof path, "%s/totp.wrap", dir);

    uint8_t key[32];
    gcry_md_hd_t h;
    if (gcry_md_open(&h, GCRY_MD_SHA256, GCRY_MD_FLAG_HMAC))
        return 0;
    gcry_md_setkey(h, master, MASTER_LEN);
    gcry_md_write(h, "veron-totp-seed", 15);
    unsigned char *d = gcry_md_read(h, GCRY_MD_SHA256);
    if (!d) {
        gcry_md_close(h);
        return 0;
    }
    memcpy(key, d, 32);
    gcry_md_close(h);

    uint8_t buf[MASTER_LEN];
    memset(buf, 0, sizeof buf);
    snprintf((char *)buf, sizeof buf, "%s", b32);

    uint8_t salt[16];
    gcry_randomize(salt, sizeof salt, GCRY_STRONG_RANDOM);
    int ok = wrap_write(path, key, buf, salt);
    explicit_bzero(key, sizeof key);
    explicit_bzero(buf, sizeof buf);
    return ok;
}
