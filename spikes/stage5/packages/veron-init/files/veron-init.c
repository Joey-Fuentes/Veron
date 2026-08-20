/* veron-init -- the pre-dinit mount shim, PID 1 on the real image.
 *
 * WHY THIS EXISTS. The shipped image boots EFI-stub with a kernel-baked
 * cmdline: `root=PARTUUID=... rootwait rw init=/usr/bin/veron-init`. The kernel
 * mounts the ext4 root and execs THIS as PID 1. There is no initramfs, so the
 * job guest/init does for CI -- mounting /proc /sys /dev, and crucially a tmpfs
 * on /run BEFORE anything creates a socket there -- has no home on real
 * hardware. This is that home, and nothing more.
 *
 * THE BUG IT FIXES. dinit creates its control socket at /run/dinitctl at
 * startup, before it runs a single service. /etc/fstab lists a tmpfs on /run,
 * mounted by early-filesystems -- which runs AFTER dinit is up, so that mount
 * lands ON TOP of the socket and hides it. Measured on hardware:
 *   veron# /usr/sbin/shutdown -p   -> connect: No such file or directory
 *   veron# ls /run/dinitctl        -> No such file or directory
 *   veron# mount | grep /run       -> tmpfs on /run
 * So shutdown, reboot and dinitctl could not reach PID 1 at all. Mounting /run
 * as tmpfs HERE, before exec'ing dinit, makes dinit's socket land on the tmpfs;
 * early-filesystems then finds /run already mounted and SKIPS it (it mounts
 * what is missing, not `mount -a`), so the socket is never shadowed.
 *
 * DELIBERATELY MINIMAL. Four mounts and an exec. Every mount mirrors an fstab
 * line or guest/init; early-filesystems is idempotent against all of them
 * (grep " $dst " /proc/mounts && continue). /proc is mounted first because
 * early-filesystems reads /proc/mounts to decide what to skip -- without it,
 * that script cannot tell what is already done.
 *
 * FAILURE POLICY. A mount that fails is not fatal here: the kernel may have
 * mounted some already, or a later path may. What must not fail is the exec of
 * dinit -- if that fails there is no init and the kernel panics, so it is the
 * one thing checked. errno is not consulted: this runs before any console
 * layer that could show it, and dinit's own boot output is where evidence
 * lives.
 *
 * NO LIBC ASSUMPTIONS BEYOND THE SYSCALLS. Built static. mount(2) and execv(2)
 * are the whole surface.
 */
#include <sys/mount.h>
#include <unistd.h>
#include <stddef.h>

int main(void)
{
    /* proc first: early-filesystems reads /proc/mounts to skip already-mounted
       entries, so it must exist before dinit runs that script. */
    mount("proc",     "/proc", "proc",     0, NULL);
    mount("sysfs",    "/sys",  "sysfs",    0, NULL);
    mount("devtmpfs", "/dev",  "devtmpfs", 0, "mode=0755");

    /* THE FIX: a tmpfs on /run before dinit creates /run/dinitctl. mode=0755
       matches the fstab line this pre-empts. early-filesystems will skip /run
       because it is now already mounted. */
    mount("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");

    /* Hand off to the real init. exec replaces this process, so dinit becomes
       PID 1 proper. If this returns, dinit is missing or not executable -- the
       kernel will panic on init exit, which is the correct, loud failure. */
    char *argv[] = { "/usr/bin/dinit", NULL };
    execv("/usr/bin/dinit", argv);

    /* Only reached if execv failed. Return non-zero; PID 1 exiting panics the
       kernel, which is the right outcome -- there is no init to run. */
    return 1;
}
