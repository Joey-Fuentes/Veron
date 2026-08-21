/* veron-maintenance-init -- the RAM-pivot PID 1 for maintenance mode.
 *
 * WHAT IT IS. A one-shot boot variant. veron-efiboot writes a try-once boot
 * entry whose cmdline reads
 *     init=/usr/bin/veron-maintenance-init veron.maintenance=1 veron.persist=preserve
 * and reboots into it. The kernel mounts the ACTIVE slot (A or B, whichever the
 * user was running) at / and execs THIS as PID 1. Its whole job is to lift the
 * running system entirely into RAM and then let go of the boot device, so the
 * flasher can rewrite the very stick it booted from -- the one operation the
 * normal boot's "the boot disk is sacred" law exists to forbid. Here that law
 * stops applying BY SITUATION: once / is a tmpfs and the stick is unmounted, the
 * stick is just a disk, and flashd's mountinfo-derived sacred check releases it
 * on its own.
 *
 * WHY A SEPARATE INIT. You cannot rewrite the block device your root filesystem
 * is mounted from. The normal image boots init=/usr/bin/veron-init, which keeps
 * the stick as root the whole time. The maintenance cmdline names THIS init
 * instead; normal boots never touch it. It is the veron-init pattern with a
 * copy-to-RAM and a real pivot_root inserted before the exec.
 *
 * THE SEQUENCE.
 *   1. Mount /proc /sys /dev (need cmdline, meminfo, and device nodes).
 *   2. Parse veron.persist=preserve (default) | discard.
 *   3. tmpfs at /mnt/ram, sized from RAM (a demand-paged ceiling).
 *   4. Copy the active root into /mnt/ram, one-filesystem, faithfully
 *      (hardlinks, symlinks, special files, perms, ownership, mtime).
 *   5. preserve: find persist (p4 by PARTUUID), mount ro, copy into the RAM
 *      copy at /run/veron-persist-backup, umount. flashd restores it later.
 *   6. Announce the safety inversion on the console.
 *   7. pivot_root onto the RAM copy, UMOUNT the old root, VERIFY the stick is
 *      gone from the mount table, then exec dinit. The verify is load-bearing:
 *      we must never hand a still-mounted stick to a flasher.
 *
 * FAILURE POLICY. A fatal error prints and HALTS -- it never continues into a
 * half-pivoted state with the stick still mounted. The maintenance entry is
 * try-once, so a reboot returns the user to the normal, safe system. Aborting
 * maintenance is always safer than releasing the stick half-done.
 *
 * STATIC, SYSCALL-ONLY, like veron-init: no busybox applet dependency, no NSS.
 */
#define _GNU_SOURCE
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/sysinfo.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>

#define RAM_ROOT       "/mnt/ram"
#define OLD_ROOT       "/mnt/ram/mnt/oldroot"   /* put_old for pivot_root */
#define PERSIST_BACKUP "/mnt/ram/run/veron-persist-backup"
#define PERSIST_PARTUUID "aaaa0004-0000-4000-8000-564552304e04"
#define COPYBUF (1 << 20)   /* 1 MiB copy buffer */

/* ---- console + failure ------------------------------------------------- */

static void announce(const char *msg) {
    int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (fd >= 0) { dprintf(fd, "VERON-MAINTENANCE: %s\n", msg); close(fd); }
    dprintf(2, "VERON-MAINTENANCE: %s\n", msg);
}
static void announce2(const char *a, const char *b) {
    int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (fd >= 0) { dprintf(fd, "VERON-MAINTENANCE: %s%s\n", a, b); close(fd); }
    dprintf(2, "VERON-MAINTENANCE: %s%s\n", a, b);
}
static void fatal(const char *msg) {
    announce("ABORTED -- the maintenance pivot did not complete:");
    announce(msg);
    announce("halting; reboot returns you to the normal system (this entry was try-once)");
    sync();
    for (;;) pause();
}

/* ---- hardlink table ---------------------------------------------------- *
 * The image has large hardlink clusters (busybox's applets above all). A copy
 * that does not preserve links both balloons in size and loses link identity.
 * We remember (dev,ino) -> first destination path, and link later occurrences
 * to it. A simple growable array; the count is in the low thousands. */
struct linkent { dev_t dev; ino_t ino; char *dst; };
static struct linkent *links; static size_t nlinks, caplinks;

static const char *link_seen(dev_t dev, ino_t ino) {
    for (size_t i = 0; i < nlinks; i++)
        if (links[i].dev == dev && links[i].ino == ino) return links[i].dst;
    return NULL;
}
static void link_remember(dev_t dev, ino_t ino, const char *dst) {
    if (nlinks == caplinks) {
        caplinks = caplinks ? caplinks * 2 : 1024;
        links = realloc(links, caplinks * sizeof *links);
        if (!links) fatal("out of memory tracking hardlinks");
    }
    links[nlinks].dev = dev; links[nlinks].ino = ino;
    links[nlinks].dst = strdup(dst);
    if (!links[nlinks].dst) fatal("out of memory tracking hardlinks");
    nlinks++;
}

/* ---- the copy ---------------------------------------------------------- *
 * A faithful one-filesystem recursive copy: directories, regular files,
 * symlinks, device/fifo/socket nodes, hardlinks, with mode/owner/mtime. Stays
 * on root_dev so /proc /sys /dev /run (separate mounts) are skipped for free. */

static void copy_times(const char *dst, struct stat *st) {
    struct timespec ts[2] = { st->st_atim, st->st_mtim };
    utimensat(AT_FDCWD, dst, ts, AT_SYMLINK_NOFOLLOW);
}

static void copy_file(const char *src, const char *dst, struct stat *st) {
    int in = open(src, O_RDONLY | O_NOFOLLOW);
    if (in < 0) { announce2("skip (open failed): ", src); return; }
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, st->st_mode & 07777);
    if (out < 0) { close(in); announce2("skip (create failed): ", dst); return; }
    static char buf[COPYBUF];
    ssize_t r;
    while ((r = read(in, buf, sizeof buf)) > 0) {
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = write(out, buf + off, r - off);
            if (w < 0) { if (errno == EINTR) continue; fatal("write failed during copy -- RAM full?"); }
            off += w;
        }
    }
    if (r < 0) fatal("read failed during copy");
    if (fchown(out, st->st_uid, st->st_gid) != 0) { /* ownership drift on one file: note, don't abort */ }
    if (fchmod(out, st->st_mode & 07777) != 0) { /* mode drift: note, don't abort */ }
    close(in); close(out);
    copy_times(dst, st);
}

static void copy_tree(const char *src, const char *dst, dev_t root_dev) {
    DIR *d = opendir(src);
    if (!d) { announce2("skip (opendir failed): ", src); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char s[4096], t[4096];
        snprintf(s, sizeof s, "%s/%s", src, e->d_name);
        snprintf(t, sizeof t, "%s/%s", dst, e->d_name);
        struct stat st;
        if (lstat(s, &st) != 0) { announce2("skip (lstat failed): ", s); continue; }

        /* one-filesystem: never cross into another mount (proc/sys/dev/run,
         * the persist mounts, anything). */
        if (st.st_dev != root_dev) continue;

        /* hardlink: if we've copied this inode already, link instead of copy. */
        if (!S_ISDIR(st.st_mode) && st.st_nlink > 1) {
            const char *first = link_seen(st.st_dev, st.st_ino);
            if (first) { if (link(first, t) == 0) continue; /* else fall through to copy */ }
        }

        if (S_ISDIR(st.st_mode)) {
            if (mkdir(t, st.st_mode & 07777) != 0 && errno != EEXIST)
                { announce2("skip (mkdir failed): ", t); continue; }
            copy_tree(s, t, root_dev);
            if (chown(t, st.st_uid, st.st_gid) != 0) { /* dir ownership drift: non-fatal */ }
            if (chmod(t, st.st_mode & 07777) != 0) { /* dir mode drift: non-fatal */ }
            copy_times(t, &st);
        } else if (S_ISLNK(st.st_mode)) {
            char link[4096]; ssize_t n = readlink(s, link, sizeof link - 1);
            if (n < 0) { announce2("skip (readlink failed): ", s); continue; }
            link[n] = 0;
            if (symlink(link, t) != 0 && errno != EEXIST) { announce2("skip (symlink failed): ", t); continue; }
            if (lchown(t, st.st_uid, st.st_gid) != 0) { /* non-fatal */ }
            copy_times(t, &st);
            if (st.st_nlink > 1) link_remember(st.st_dev, st.st_ino, t);
        } else if (S_ISREG(st.st_mode)) {
            copy_file(s, t, &st);
            if (st.st_nlink > 1) link_remember(st.st_dev, st.st_ino, t);
        } else {
            /* device node, fifo, socket: recreate with mknod. */
            if (mknod(t, st.st_mode, st.st_rdev) != 0 && errno != EEXIST)
                { announce2("skip (mknod failed): ", t); continue; }
            if (chown(t, st.st_uid, st.st_gid) != 0) { /* node ownership drift: non-fatal */ }
            copy_times(t, &st);
            if (st.st_nlink > 1) link_remember(st.st_dev, st.st_ino, t);
        }
    }
    closedir(d);
}

/* ---- persist backup ---------------------------------------------------- *
 * Find the persist partition by PARTUUID via /dev/disk/by-partuuid, mount it
 * read-only, copy its tree into the RAM copy at /run/veron-persist-backup, and
 * unmount it. flashd's RESTORE-PERSIST verb copies it back into the freshly
 * flashed stick afterwards. */
static void backup_persist(dev_t ram_dev) {
    const char *node = "/dev/disk/by-partuuid/" PERSIST_PARTUUID;
    struct stat pst;
    if (lstat(node, &pst) != 0) { announce("persist partition not found by PARTUUID -- skipping backup"); return; }
    if (mkdir("/mnt/persist-src", 0755) != 0 && errno != EEXIST) { announce("could not make persist mountpoint -- skipping"); return; }
    if (mount(node, "/mnt/persist-src", "ext4", MS_RDONLY, NULL) != 0) {
        announce("could not mount persist read-only -- skipping backup"); return;
    }
    if (mkdir(PERSIST_BACKUP, 0755) != 0 && errno != EEXIST) { announce("could not make persist backup dir"); umount("/mnt/persist-src"); return; }
    struct stat mst;
    if (stat("/mnt/persist-src", &mst) == 0)
        copy_tree("/mnt/persist-src", PERSIST_BACKUP, mst.st_dev);
    umount("/mnt/persist-src");
    (void)ram_dev;
    announce("persist backed up to RAM (/run/veron-persist-backup)");
}

/* ---- verify the stick is released -------------------------------------- *
 * After pivot_root + umount put_old, confirm the old root device is gone from
 * the mount table. If any mount still sits on the old root, that is fatal: we
 * must never hand a still-mounted stick to a flasher. */
static int old_root_still_mounted(void) {
    int fd = open("/proc/mounts", O_RDONLY);
    if (fd < 0) return 1;                 /* cannot verify -> treat as unsafe */
    static char buf[1 << 16]; ssize_t n = read(fd, buf, sizeof buf - 1); close(fd);
    if (n <= 0) return 1;
    buf[n] = 0;
    /* the old root was moved to /mnt/oldroot; if anything is still mounted
     * there, the stick is not released. */
    return strstr(buf, " /mnt/oldroot ") != NULL;
}

int main(void)
{
    /* STEP 1: virtual filesystems. */
    mount("proc",     "/proc", "proc",     0, NULL);
    mount("sysfs",    "/sys",  "sysfs",    0, NULL);
    mount("devtmpfs", "/dev",  "devtmpfs", 0, "mode=0755");

    announce("entering maintenance mode -- lifting the system into RAM");

    /* the device the active root lives on: everything we copy must match it. */
    struct stat rootst;
    if (stat("/", &rootst) != 0) fatal("could not stat the root filesystem");
    dev_t root_dev = rootst.st_dev;

    /* STEP 2: persist mode from the cmdline. */
    int preserve = 1;
    {
        int fd = open("/proc/cmdline", O_RDONLY);
        char cmd[4096]; ssize_t n = fd >= 0 ? read(fd, cmd, sizeof cmd - 1) : -1;
        if (fd >= 0) close(fd);
        if (n > 0) { cmd[n] = 0; if (strstr(cmd, "veron.persist=discard")) preserve = 0; }
    }
    announce(preserve ? "persist=preserve (user state backed up to RAM)"
                      : "persist=discard (user state will NOT be kept)");

    /* STEP 3: the RAM root, sized to a demand-paged ceiling near total RAM. */
    if (mkdir(RAM_ROOT, 0755) != 0 && errno != EEXIST) fatal("could not create " RAM_ROOT);
    {
        struct sysinfo si; char opt[64] = "mode=0755";
        if (sysinfo(&si) == 0) {
            unsigned long long kb = (unsigned long long)si.totalram * si.mem_unit / 1024;
            snprintf(opt, sizeof opt, "mode=0755,size=%lluk", (kb * 9) / 10);
        }
        if (mount("tmpfs", RAM_ROOT, "tmpfs", 0, opt) != 0) fatal("could not mount the RAM tmpfs root");
    }

    /* STEP 4: copy the active root into RAM (one filesystem, faithful). */
    announce("copying the running system into RAM (the active slot)");
    copy_tree("/", RAM_ROOT, root_dev);
    announce("system copied");

    /* STEP 5: persist backup (preserve only). Needs /run to exist in the copy. */
    if (preserve) {
        struct stat rr; dev_t ram_dev = 0;
        if (stat(RAM_ROOT, &rr) == 0) ram_dev = rr.st_dev;
        if (mkdir("/mnt/ram/run", 0755) != 0 && errno != EEXIST) { /* may already exist from copy */ }
        announce("backing up persist to RAM for restore after the flash");
        backup_persist(ram_dev);
    }

    /* STEP 6. */
    announce("the boot device is now releasable -- the flasher may rewrite it");

    /* STEP 7: pivot_root onto the RAM copy, release + verify the stick. */
    if (mkdir(OLD_ROOT, 0755) != 0 && errno != EEXIST) fatal("could not create the put_old dir");
    if (chdir(RAM_ROOT) != 0) fatal("could not chdir to the RAM root");
    /* pivot_root(new_root=".", put_old="mnt/oldroot"): new must be a mount pt. */
    if (syscall(SYS_pivot_root, ".", "mnt/oldroot") != 0) fatal("pivot_root onto the RAM copy failed");
    if (chroot(".") != 0) fatal("chroot after pivot_root failed");
    if (chdir("/") != 0) fatal("chdir / after pivot_root failed");
    /* release the stick: detach the old root. MNT_DETACH so a lingering ref
     * cannot block us; the device is freed once the last ref drops, and nothing
     * else is running to hold one. */
    if (umount2("/mnt/oldroot", MNT_DETACH) != 0) fatal("could not umount the old root (the stick)");
    if (old_root_still_mounted()) fatal("the boot stick is still mounted after pivot -- refusing to continue");

    announce("running from RAM; the boot disk is released. starting dinit.");
    char *argv[] = { "/usr/bin/dinit", NULL };
    execv("/usr/bin/dinit", argv);
    fatal("exec of /usr/bin/dinit failed -- no init to run");
    return 1;
}
