/* veron-idle -- lock the session when the person walks away.
 *
 * WHY THIS EXISTS. A lock that only fires on Super+L protects only the
 * disciplined; the canonical session contract on every desktop is that the
 * screen locks ITSELF on idle, because the walk-away user who forgot is
 * the median case, not the exception. veron-auth's own recipe named
 * ext-idle-notify-v1 as "the next piece" the day the lock screen shipped;
 * this is that piece.
 *
 * WHAT IT IS. The smallest possible ext-idle-notify-v1 client: bind the
 * notifier and the seat, register one notification with a timeout, and
 * when the compositor says `idled`, start /usr/bin/veron-lock. Nothing
 * else. The locker already handles every hard case this could create:
 * if a locker is already holding the session, the new one receives
 * `finished` and exits without drawing (lock.c's own sequence), so firing
 * into an already-locked session is harmless by construction.
 *
 * ARMED MEANS ARMED EVERYWHERE. This reads the same auth.conf the
 * verifier reads: it locks on idle only when `autologin=off` -- the
 * explicit "this machine demands the factor" state. An unarmed machine
 * (live image, nothing enrolled) never has its session yanked away by a
 * timer. `idle=<seconds>` in auth.conf overrides the default; `idle=0`
 * disables idle locking while staying armed, for the person who wants the
 * boot gate without the timer.
 *
 * THE CONF IS RE-READ ON EVERY IDLE EVENT, not cached at start, so arming
 * or disarming takes effect without restarting this service -- the same
 * reason the verifier re-reads everything per attempt.
 *
 * NO gcrypt, NO shared verifier LINKAGE. This program makes no security
 * decision -- it only decides when to START the thing that does. Linking
 * the verifier here would put crypto in a process that never needs it;
 * the ten-line conf reader below reads two public keys from a file the
 * verifier owns.
 */
#define _GNU_SOURCE 1
#include <wayland-client.h>
#include "ext-idle-notify-v1-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <pwd.h>

#define DEFAULT_IDLE_SECONDS 600

static struct wl_display  *display;
static struct wl_seat     *seat;
static struct ext_idle_notifier_v1 *notifier;

/* THE SAME passwd-FIRST LOOKUP THE VERIFIER USES, for the same measured
 * reason: the environment lies about HOME on this system's consoles and
 * services, and the passwd entry is where home is defined. */
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

/* key from ~/.config/veron/auth.conf -- two public keys, no secrets. */
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
    char line[256];
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

static void notif_idled(void *data, struct ext_idle_notification_v1 *n)
{
    (void)data; (void)n;

    /* ARMED? Re-checked now, not at startup. */
    char v[64];
    if (!conf_get("autologin", v, sizeof v) || strcmp(v, "off") != 0)
        return;
    if (conf_get("idle", v, sizeof v) && !strcmp(v, "0"))
        return;

    /* START THE LOCKER, DON'T BECOME IT. fork+exec so this daemon keeps
     * its idle notification; a second idle event while a locker already
     * holds the session spawns a client that immediately receives
     * `finished` and exits -- lock.c handles that case by design. */
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/veron-lock", "veron-lock", (char *)NULL);
        _exit(127);
    }
}

static void notif_resumed(void *data, struct ext_idle_notification_v1 *n)
{ (void)data; (void)n; }

static const struct ext_idle_notification_v1_listener notif_listener = {
    notif_idled, notif_resumed,
};

static void reg_global(void *data, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, wl_seat_interface.name))
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, ext_idle_notifier_v1_interface.name))
        notifier = wl_registry_bind(r, name,
                                    &ext_idle_notifier_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_listener = {
    reg_global, reg_remove,
};

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--version")) {
            printf("veron-idle 1.0\n");
            return 0;
        }

    /* REAP THE LOCKERS THIS SPAWNS, without waiting on them. */
    signal(SIGCHLD, SIG_IGN);

    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "veron-idle: no wayland display\n");
        return 1;
    }
    struct wl_registry *reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(display);

    if (!notifier) {
        /* SAY SO AND EXIT RATHER THAN PRETENDING. A compositor without the
         * protocol means no idle locking, and a silent daemon doing
         * nothing is how that would go unnoticed forever. */
        fprintf(stderr, "veron-idle: compositor does not offer "
                        "ext-idle-notify-v1\n");
        return 1;
    }
    if (!seat) {
        fprintf(stderr, "veron-idle: no seat\n");
        return 1;
    }

    /* THE TIMEOUT IS READ ONCE, AT REGISTRATION -- the protocol fixes the
     * timeout per notification. Changing `idle=` takes effect on service
     * restart; arming/disarming takes effect immediately (checked per
     * event above). */
    unsigned timeout = DEFAULT_IDLE_SECONDS;
    char v[64];
    if (conf_get("idle", v, sizeof v)) {
        long t = atol(v);
        if (t > 0 && t < 86400)
            timeout = (unsigned)t;
    }

    struct ext_idle_notification_v1 *notif =
        ext_idle_notifier_v1_get_idle_notification(notifier,
                                                   timeout * 1000, seat);
    ext_idle_notification_v1_add_listener(notif, &notif_listener, NULL);

    while (wl_display_dispatch(display) != -1)
        ;
    return 0;
}
