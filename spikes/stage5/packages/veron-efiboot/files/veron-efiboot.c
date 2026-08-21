/* veron-efiboot -- the boot-variable writer for A/B, from source, no deps.
 *
 * WHAT THIS IS. The one tool that touches UEFI NVRAM: it composes
 * Boot#### load options pointing at Veron's per-slot kernels, and sets
 * BootNext / BootOrder. Everything else in the A/B design (tries,
 * successful, priority) lives in GPT attributes ON DISK, written by other
 * tools -- NVRAM is only the trigger, because the research found real
 * firmware that ignores, volatilizes or resets it, and a design whose
 * health record can be wiped by a CMOS reset is not a design.
 *
 * THE WRITE PATH IS THE RESEARCH VERDICT, REIMPLEMENTED NOT COPIED.
 * systemd's efi_set_variable() (LGPL -- studied, not imported) and
 * rhboot/efivar's raw-ioctl flag handling establish the shape:
 *
 *   1. efivarfs files are IMMUTABLE by default (kernel ed8b0de5a33d),
 *      because `rm -rf /` bricked laptops whose firmware kept POST data
 *      in NVRAM. Clear FS_IMMUTABLE_FL first, restore it after. Both via
 *      FS_IOC_GETFLAGS / FS_IOC_SETFLAGS.
 *   2. The variable is written as ONE buffer: a 4-byte little-endian
 *      attributes word (NON_VOLATILE|BOOTSERVICE|RUNTIME = 0x7) followed
 *      by the payload, in ONE write() -- efivarfs maps a write to a
 *      single SetVariable(); a short or split write corrupts.
 *   3. Read first, skip if already correct. NVRAM has wear and firmware
 *      garbage collectors with a bricking history (Samsung, Lenovo);
 *      the cheapest write is the one not issued.
 *   4. Delete is unlink(), never a zero-length write.
 *   5. EINTR/EBUSY are retried with backoff -- the kernel ratelimits
 *      efivarfs on purpose.
 *   6. efi_no_storage_paranoia is NEVER suggested, set, or worked
 *      around: the kernel's QueryVariableInfo free-space margin is the
 *      standing guard against store exhaustion and it stays on.
 *
 * TESTABILITY OFF-TARGET. Everything except the final write is pure byte
 * layout: EFI_LOAD_OPTION, the HD() and File() device-path nodes, the
 * mixed-endian GUID. `--print` emits the composed variable payload to
 * stdout, and --efivars DIR retargets the filesystem root, so golden
 * tests run anywhere; only the last centimetre needs a machine with
 * firmware.
 *
 * Usage:
 *   veron-efiboot print-entry  --desc "Veron slot A" \
 *       --disk-guid G --part-num N --part-start LBA --part-size LBAS \
 *       --part-guid G --file '\EFI\veron\A\linux.efi' \
 *       --cmdline 'root=PARTUUID=... ro'          > payload.bin
 *   veron-efiboot set-entry 0050 <same args>       # writes Boot0050
 *   veron-efiboot boot-next 0050                   # try-once trigger
 *   veron-efiboot boot-order 0050,0051             # commit ordering
 *   veron-efiboot get Boot0050 | delete Boot0051
 * Options: --efivars DIR (default /sys/firmware/efi/efivars)
 *          --no-chattr   (test filesystems have no immutable flag)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <linux/fs.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#define EFI_GLOBAL_GUID "8be4df61-93ca-11d2-aa0d-00e098032b8c"
#define ATTRS 0x00000007u /* NV | BOOTSERVICE | RUNTIME */
#define LOAD_OPTION_ACTIVE 0x00000001u
#define RETRIES 25
#define RETRY_DELAY_US 50000

static const char *efivars = "/sys/firmware/efi/efivars";
static int no_chattr = 0;

static void die(const char *m) { fprintf(stderr, "veron-efiboot: %s\n", m); exit(1); }
static void die_errno(const char *m) { fprintf(stderr, "veron-efiboot: %s: %s\n", m, strerror(errno)); exit(1); }

/* ---- byte emit helpers: everything is explicit little-endian ---------- */
typedef struct { uint8_t *p; size_t len, cap; } buf;
static void put(buf *b, const void *d, size_t n) {
    if (b->len + n > b->cap) { b->cap = (b->len + n) * 2 + 64; b->p = realloc(b->p, b->cap); if (!b->p) die("oom"); }
    memcpy(b->p + b->len, d, n); b->len += n;
}
static void put8(buf *b, uint8_t v)   { put(b, &v, 1); }
static void put16(buf *b, uint16_t v) { uint8_t d[2] = { v & 0xff, v >> 8 }; put(b, d, 2); }
static void put32(buf *b, uint32_t v) { uint8_t d[4] = { v, v >> 8, v >> 16, v >> 24 }; put(b, d, 4); }
static void put64(buf *b, uint64_t v) { put32(b, (uint32_t)v); put32(b, (uint32_t)(v >> 32)); }

/* ASCII -> UTF-16LE, including the NUL. The strings this tool writes are
 * descriptions, ESP paths and kernel cmdlines -- ASCII by construction;
 * anything above 0x7f is refused rather than silently mangled. */
static void put_utf16(buf *b, const char *s) {
    for (; ; s++) {
        if ((unsigned char)*s > 0x7f) die("non-ASCII string; refusing to guess an encoding");
        put16(b, (uint8_t)*s);
        if (!*s) return;
    }
}

/* GUID text -> the 16 bytes as they sit in a GPT entry and an HD() node:
 * first three fields little-endian, last two big-endian ("mixed endian").
 * This is the same byte order the GPT itself uses, so a partition GUID
 * read from the table is copied verbatim. */
static int hexv(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static void guid_bytes(const char *text, uint8_t out[16]) {
    /* aabbccdd-eeff-gghh-iijj-kkllmmnnoopp */
    uint8_t raw[16]; int i = 0;
    for (const char *p = text; *p && i < 16; p++) {
        if (*p == '-') continue;
        int hi = hexv(p[0]), lo = hexv(p[1]);
        if (hi < 0 || lo < 0) die("bad GUID text");
        raw[i++] = (uint8_t)(hi << 4 | lo); p++;
    }
    if (i != 16) die("bad GUID length");
    out[0]=raw[3]; out[1]=raw[2]; out[2]=raw[1]; out[3]=raw[0];   /* d1 LE */
    out[4]=raw[5]; out[5]=raw[4];                                  /* d2 LE */
    out[6]=raw[7]; out[7]=raw[6];                                  /* d3 LE */
    memcpy(out + 8, raw + 8, 8);                                   /* d4 BE */
}

/* ---- EFI_LOAD_OPTION composition (UEFI 2.11 §3.1.3) ------------------- */
struct entry_args {
    const char *desc, *part_guid, *file, *cmdline;
    uint32_t part_num; uint64_t part_start, part_size;
};

static void compose_load_option(buf *b, const struct entry_args *a) {
    /* device path, built first so FilePathListLength is known */
    buf dp = {0};
    /* HD() node: Type 4 (Media), SubType 1 (Hard Drive), length 42 */
    put8(&dp, 0x04); put8(&dp, 0x01); put16(&dp, 42);
    put32(&dp, a->part_num);
    put64(&dp, a->part_start);
    put64(&dp, a->part_size);
    uint8_t g[16]; guid_bytes(a->part_guid, g); put(&dp, g, 16);
    put8(&dp, 0x02);  /* MBRType: GPT */
    put8(&dp, 0x02);  /* SignatureType: GUID */
    /* File() node: Type 4, SubType 4; UTF-16LE path incl NUL */
    {
        buf f16 = {0}; put_utf16(&f16, a->file);
        put8(&dp, 0x04); put8(&dp, 0x04); put16(&dp, (uint16_t)(4 + f16.len));
        put(&dp, f16.p, f16.len); free(f16.p);
    }
    /* End node: Type 0x7f, SubType 0xff, length 4 */
    put8(&dp, 0x7f); put8(&dp, 0xff); put16(&dp, 4);

    put32(b, LOAD_OPTION_ACTIVE);
    put16(b, (uint16_t)dp.len);
    put_utf16(b, a->desc);
    put(b, dp.p, dp.len); free(dp.p);
    /* OptionalData: the kernel EFI stub reads this as its command line,
     * UTF-16LE. No trailing NUL is required by the stub; one is included
     * because a bounded string is kinder to every other reader. */
    if (a->cmdline && *a->cmdline) put_utf16(b, a->cmdline);
}

/* ---- the hardened efivarfs write path --------------------------------- */
static void var_path(char *out, size_t n, const char *name) {
    snprintf(out, n, "%s/%s-%s", efivars, name, EFI_GLOBAL_GUID);
}

static int chattr_immutable(const char *path, int set, int *had) {
    if (no_chattr) return 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return (errno == ENOENT) ? 0 : -1;  /* new variable: no flag yet */
    long flags = 0;
    if (ioctl(fd, FS_IOC_GETFLAGS, &flags) < 0) { close(fd); return -1; }
    if (had) *had = !!(flags & FS_IMMUTABLE_FL);
    long want = set ? (flags | FS_IMMUTABLE_FL) : (flags & ~FS_IMMUTABLE_FL);
    int r = (want == flags) ? 0 : ioctl(fd, FS_IOC_SETFLAGS, &want);
    close(fd);
    return r;
}

static int read_var(const char *name, uint8_t **out, size_t *outlen) {
    char p[512]; var_path(p, sizeof p, name);
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st; if (fstat(fd, &st) < 0 || st.st_size < 4) { close(fd); return -1; }
    uint8_t *b = malloc(st.st_size); if (!b) die("oom");
    ssize_t n = read(fd, b, st.st_size);
    close(fd);
    if (n != st.st_size) { free(b); return -1; }
    *out = b; *outlen = (size_t)n;
    return 0;
}

static void write_var(const char *name, const uint8_t *data, size_t len) {
    char p[512]; var_path(p, sizeof p, name);

    /* idempotency first: the cheapest NVRAM write is the one not issued */
    uint8_t *cur; size_t curlen;
    if (read_var(name, &cur, &curlen) == 0) {
        uint32_t curattr = cur[0] | cur[1] << 8 | cur[2] << 16 | (uint32_t)cur[3] << 24;
        if (curattr == ATTRS && curlen - 4 == len && memcmp(cur + 4, data, len) == 0) {
            free(cur);
            fprintf(stderr, "  %s already in the wanted state -- not written\n", name);
            return;
        }
        free(cur);
    }

    size_t total = 4 + len;
    uint8_t *msg = malloc(total); if (!msg) die("oom");
    msg[0] = ATTRS & 0xff; msg[1] = 0; msg[2] = 0; msg[3] = 0;
    memcpy(msg + 4, data, len);

    int had_immutable = 0;
    if (chattr_immutable(p, 0, &had_immutable) < 0) die_errno("clearing immutable flag");

    int ok = 0;
    for (int attempt = 0; attempt < RETRIES && !ok; attempt++) {
        int fd = open(p, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOCTTY, 0644);
        if (fd < 0) die_errno("open for write");
        ssize_t n = write(fd, msg, total);
        int saved = errno;
        close(fd);
        if (n == (ssize_t)total) { ok = 1; break; }
        /* A short write to efivarfs is a failed SetVariable, not progress:
         * the whole message is re-sent, never a remainder. */
        if (n >= 0 || saved == EINTR || saved == EBUSY) { usleep(RETRY_DELAY_US); continue; }
        errno = saved; die_errno("write");
    }
    /* Restore the flag the kernel put there for a documented reason --
     * even after failure, and before reporting it. */
    chattr_immutable(p, 1, NULL);
    free(msg);
    if (!ok) die("write did not complete after retries (firmware busy or store full)");

    /* read back: a write the firmware silently dropped must be caught
     * HERE, not at the reboot that was supposed to be recoverable. */
    uint8_t *chk; size_t chklen;
    msg = malloc(total); if (!msg) die("oom");
    msg[0] = ATTRS & 0xff; msg[1] = 0; msg[2] = 0; msg[3] = 0;
    memcpy(msg + 4, data, len);
    if (read_var(name, &chk, &chklen) != 0)
        die("read-back failed: variable absent after write");
    if (chklen != total || memcmp(chk, msg, total) != 0)
        die("read-back mismatch: firmware did not store what was written");
    free(chk); free(msg);
    fprintf(stderr, "  %s written and read back verified (%zu bytes)\n", name, len);
}

/* ---- argument plumbing ------------------------------------------------- */
static const char *need(int argc, char **argv, int *i, const char *flag) {
    if (*i + 1 >= argc) { fprintf(stderr, "veron-efiboot: %s needs a value\n", flag); exit(2); }
    return argv[++*i];
}

static int parse_entry_args(int argc, char **argv, int i, struct entry_args *a) {
    memset(a, 0, sizeof *a);
    for (; i < argc; i++) {
        const char *f = argv[i];
        if      (!strcmp(f, "--desc"))       a->desc = need(argc, argv, &i, f);
        else if (!strcmp(f, "--part-guid"))  a->part_guid = need(argc, argv, &i, f);
        else if (!strcmp(f, "--part-num"))   a->part_num = (uint32_t)strtoul(need(argc, argv, &i, f), NULL, 0);
        else if (!strcmp(f, "--part-start")) a->part_start = strtoull(need(argc, argv, &i, f), NULL, 0);
        else if (!strcmp(f, "--part-size"))  a->part_size = strtoull(need(argc, argv, &i, f), NULL, 0);
        else if (!strcmp(f, "--file"))       a->file = need(argc, argv, &i, f);
        else if (!strcmp(f, "--cmdline"))    a->cmdline = need(argc, argv, &i, f);
        else { fprintf(stderr, "veron-efiboot: unknown option %s\n", f); exit(2); }
    }
    if (!a->desc || !a->part_guid || !a->part_num || !a->part_size || !a->file)
        die("print-entry/set-entry need --desc --part-guid --part-num --part-start --part-size --file");
    return 0;
}

static int hex4(const char *s) {
    if (strlen(s) != 4) die("Boot#### number must be exactly 4 hex digits, e.g. 0050");
    int v = 0;
    for (int i = 0; i < 4; i++) { int h = hexv(s[i]); if (h < 0) die("bad hex in Boot#### number"); v = v << 4 | h; }
    return v;
}

int main(int argc, char **argv) {
    int i = 1;
    /* global options first, in any order before the verb */
    while (i < argc && argv[i][0] == '-') {
        if (!strcmp(argv[i], "--efivars")) { efivars = need(argc, argv, &i, "--efivars"); i++; }
        else if (!strcmp(argv[i], "--no-chattr")) { no_chattr = 1; i++; }
        else break;
    }
    if (i >= argc) die("usage: veron-efiboot [--efivars DIR] [--no-chattr] <print-entry|set-entry|clone-cmdline|boot-next|boot-order|get|delete> ...");
    const char *verb = argv[i++];

    if (!strcmp(verb, "print-entry") || !strcmp(verb, "set-entry")) {
        const char *num = NULL;
        if (!strcmp(verb, "set-entry")) { if (i >= argc) die("set-entry needs a Boot#### number"); num = argv[i++]; }
        struct entry_args a; parse_entry_args(argc, argv, i, &a);
        buf b = {0}; compose_load_option(&b, &a);
        if (num) {
            char name[16]; snprintf(name, sizeof name, "Boot%04X", hex4(num));
            write_var(name, b.p, b.len);
        } else if (fwrite(b.p, 1, b.len, stdout) != b.len) die_errno("stdout");
        free(b.p);
        return 0;
    }
    if (!strcmp(verb, "boot-next")) {
        if (i >= argc) die("boot-next needs a Boot#### number");
        uint16_t v = (uint16_t)hex4(argv[i]);
        uint8_t d[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
        write_var("BootNext", d, 2);
        return 0;
    }
    if (!strcmp(verb, "boot-order")) {
        if (i >= argc) die("boot-order needs a comma-separated Boot#### list");
        buf b = {0};
        char *list = argv[i], *save = NULL;
        for (char *tok = strtok_r(list, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
            put16(&b, (uint16_t)hex4(tok));
        if (b.len == 0) die("empty boot order");
        write_var("BootOrder", b.p, b.len);
        free(b.p);
        return 0;
    }
    if (!strcmp(verb, "get")) {
        if (i >= argc) die("get needs a variable name, e.g. Boot0050");
        uint8_t *d; size_t n;
        if (read_var(argv[i], &d, &n) != 0) die_errno("read");
        if (fwrite(d, 1, n, stdout) != n) die_errno("stdout");
        free(d);
        return 0;
    }
    if (!strcmp(verb, "delete")) {
        if (i >= argc) die("delete needs a variable name");
        char p[512]; var_path(p, sizeof p, argv[i]);
        /* delete is unlink(), NEVER a zero-length write -- a zero-size
         * variable is an uncommitted state, not an absence. */
        if (chattr_immutable(p, 0, NULL) < 0) die_errno("clearing immutable flag");
        if (unlink(p) < 0 && errno != ENOENT) die_errno("unlink");
        return 0;
    }
    if (!strcmp(verb, "clone-cmdline")) {
        /* Clone an existing boot entry, changing ONLY its command line. This is
         * the maintenance-mode trigger's workhorse: the flasher takes the entry
         * the machine is actually booting (right disk GUID, ESP partition range,
         * kernel file) and re-emits it verbatim with init=/usr/bin/
         * veron-maintenance-init veron.maintenance=1 ... swapped in, then points
         * BootNext at it. Preserving the device path byte-for-byte is the whole
         * point: reconstructing it from spec constants would risk naming the
         * wrong disk, and the entry that booted us is by definition correct.
         *
         *   veron-efiboot clone-cmdline <srcBoot####> <dstBoot####> --cmdline '...'
         *
         * EFI_LOAD_OPTION = Attributes(4) FilePathListLength(2)
         *   Description(UTF-16, NUL-term) DevicePath(FilePathListLength)
         *   OptionalData(rest = the cmdline). We keep everything through the
         * device path and replace OptionalData. read_var returns the efivarfs
         * 4-byte attribute prefix ahead of the load option; skip it. */
        if (i >= argc) die("clone-cmdline needs a source Boot#### number");
        const char *src = argv[i++];
        if (i >= argc) die("clone-cmdline needs a destination Boot#### number");
        const char *dst = argv[i++];
        const char *newcmd = NULL;
        while (i < argc) {
            if (!strcmp(argv[i], "--cmdline")) newcmd = need(argc, argv, &i, "--cmdline");
            else die("clone-cmdline: unexpected argument");
            i++;
        }
        if (!newcmd || !*newcmd) die("clone-cmdline needs --cmdline '<new command line>'");

        char srcname[16]; snprintf(srcname, sizeof srcname, "Boot%04X", hex4(src));
        uint8_t *raw; size_t rawlen;
        if (read_var(srcname, &raw, &rawlen) != 0) die_errno("reading the source entry");
        /* skip the efivarfs 4-byte attribute prefix to reach the load option */
        if (rawlen < 4 + 6) die("source entry is too small to be a boot option");
        uint8_t *lo = raw + 4; size_t lolen = rawlen - 4;
        /* Attributes(4) + FilePathListLength(2) */
        uint16_t fplen = lo[4] | (lo[5] << 8);
        /* Description: UTF-16LE starting at offset 6, NUL-terminated (2 zero
         * bytes). Walk to its end. */
        size_t off = 6;
        while (off + 1 < lolen && !(lo[off] == 0 && lo[off + 1] == 0)) off += 2;
        if (off + 1 >= lolen) die("source entry description is not terminated");
        off += 2;                             /* consume the UTF-16 NUL */
        size_t keep = off + fplen;            /* through the end of the device path */
        if (keep > lolen) die("source entry device path runs past the option");

        /* rebuild: keep [0, keep), append the new cmdline as OptionalData */
        buf b = {0};
        put(&b, lo, keep);
        put_utf16(&b, newcmd);

        char dstname[16]; snprintf(dstname, sizeof dstname, "Boot%04X", hex4(dst));
        write_var(dstname, b.p, b.len);
        free(b.p); free(raw);
        return 0;
    }
    die("unknown verb");
}
