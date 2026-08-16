/* veron-lock -- the session lock screen.
 *
 * WHAT LOCKS A SESSION. ext-session-lock-v1 is a privileged Wayland protocol:
 * the client asks the compositor to lock, the compositor stops showing every
 * normal surface and shows only this client's lock surfaces, and it keeps
 * doing so until this client says otherwise. That is why this is not an FLTK
 * program -- FLTK creates ordinary xdg toplevels, and a lock surface is a
 * different surface role that no toolkit here can produce. The Wayland and
 * Cairo code below is the same shape as veron-browser's chrome.c, which is
 * this tree's existing precedent for drawing a surface by hand.
 *
 * WHY NOT THE OLD WAY. Lockers used to take over the screen with
 * layer-shell surfaces. If such a locker crashed, its surfaces went away and
 * the desktop was simply there, unlocked, for anyone standing in front of it.
 * ext-session-lock-v1 inverts the responsibility: the SESSION is locked, not
 * the screen covered, and the compositor keeps it locked whether or not this
 * process is alive.
 *
 * WHICH MEANS A CRASH FAILS SAFE AND ALSO FAILS HARD. The protocol says the
 * compositor should keep the session locked if the client dies, and that "it
 * is acceptable for the session to be permanently locked if this happens".
 * So a bug here does not expose the desktop -- it strands the GUI until a VT
 * switch. Ctrl+Alt+F2 must therefore keep working; see the note on lockout at
 * the bottom of this file.
 *
 * THE SEQUENCE IS EXACT AND MOST OF THE ERRORS ARE FATAL:
 *
 *   1. bind ext_session_lock_manager_v1
 *   2. lock() -> an ext_session_lock_v1
 *   3. IMMEDIATELY get_lock_surface() for every wl_output, before waiting for
 *      anything. The compositor cannot finish locking until every output has
 *      a surface, so creating them lazily delays the lock.
 *   4. per surface: configure(serial, w, h) arrives -> ack_configure(serial)
 *      -> attach a buffer of EXACTLY w x h -> commit. Committing before the
 *      first ack, committing a null buffer, or committing the wrong size are
 *      each a protocol error that kills the client.
 *   5. `locked` arrives once no unlocked content can be seen anywhere. Only
 *      then is the session actually secure.
 *   6. on success: unlock_and_destroy(), then roundtrip so the server has
 *      processed it before we exit. Calling destroy() after `locked` is a
 *      protocol error -- the two are not interchangeable.
 *   7. `finished` instead of `locked` means the compositor refused (another
 *      locker already holds it). Then destroy() IS the correct call, and we
 *      must not draw anything.
 */
#define _GNU_SOURCE 1
#include <wayland-client.h>
#include "ext-session-lock-v1-client-protocol.h"

#include <cairo/cairo.h>
#include <xkbcommon/xkbcommon.h>

#include <sys/mman.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

#include "verify.h"

#include <gcrypt.h>

#define MAX_OUTPUTS 8
#define MAX_ENTRY   256

typedef struct {
    uint32_t                   name;   /* registry name, for global_remove */
    struct wl_output          *output;
    struct wl_surface         *surface;
    struct ext_session_lock_surface_v1 *lock_surface;
    struct wl_buffer          *buffer;
    void                      *data;
    size_t                     size;
    cairo_surface_t           *cairo;
    int32_t                    width, height;
    int                        configured;
} LockOutput;

static struct wl_display    *display;
static struct wl_registry   *registry;
static struct wl_compositor *compositor;
static struct wl_shm        *shm;
static struct wl_seat       *seat;
static struct wl_keyboard   *keyboard;
static struct ext_session_lock_manager_v1 *lock_manager;
static struct ext_session_lock_v1         *session_lock;

static struct xkb_context *xkb_ctx;
static struct xkb_keymap  *xkb_map;
static struct xkb_state   *xkb_st;

static LockOutput outputs[MAX_OUTPUTS];
static int        n_outputs;

static char entry[MAX_ENTRY];
static int  entry_len;
static int  locked_ok;      /* the compositor confirmed the lock  */
static int  finished;       /* the compositor refused it          */
static int  running = 1;
static int  unlocking;
static int  failed_attempt;
static int  checking;

/* ---- shm ------------------------------------------------------------- */

/* memfd, NOT A FILE IN /tmp. The lock screen may run when the disk is
 * unavailable or read-only, and a locker that cannot allocate a buffer is a
 * locker that cannot draw -- which under this protocol means a black screen
 * with no prompt and no way back in. */
static int anon_file(size_t size)
{
    int fd = memfd_create("veron-lock", MFD_CLOEXEC);
    if (fd < 0)
        return -1;
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void buffer_release(void *data, struct wl_buffer *b) { (void)data; (void)b; }
static const struct wl_buffer_listener buffer_listener = { buffer_release };

static int output_alloc(LockOutput *o, int32_t w, int32_t h)
{
    if (o->buffer && o->width == w && o->height == h)
        return 1;

    if (o->cairo)  { cairo_surface_destroy(o->cairo); o->cairo = NULL; }
    if (o->buffer) { wl_buffer_destroy(o->buffer);    o->buffer = NULL; }
    if (o->data)   { munmap(o->data, o->size);        o->data = NULL; }

    int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, w);
    o->size  = (size_t)stride * (size_t)h;
    o->width = w;
    o->height = h;

    int fd = anon_file(o->size);
    if (fd < 0)
        return 0;
    o->data = mmap(NULL, o->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (o->data == MAP_FAILED) {
        o->data = NULL;
        close(fd);
        return 0;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)o->size);
    close(fd);
    o->buffer = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                          WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    wl_buffer_add_listener(o->buffer, &buffer_listener, o);
    o->cairo = cairo_image_surface_create_for_data(
        (unsigned char *)o->data, CAIRO_FORMAT_ARGB32, w, h, stride);
    return o->cairo != NULL;
}

/* ---- drawing ---------------------------------------------------------- */

static void draw(LockOutput *o)
{
    if (!o->cairo)
        return;
    cairo_t *cr = cairo_create(o->cairo);

    cairo_set_source_rgb(cr, 0.07, 0.07, 0.09);
    cairo_paint(cr);

    double cx = o->width / 2.0, cy = o->height / 2.0;

    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                           CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 18.0);
    cairo_set_source_rgb(cr, 0.85, 0.85, 0.88);

    const char *msg = checking ? "Checking..."
                    : failed_attempt ? "Not accepted"
                    : "Locked";
    cairo_text_extents_t te;
    cairo_text_extents(cr, msg, &te);
    cairo_move_to(cr, cx - te.width / 2.0, cy - 40);
    cairo_show_text(cr, msg);

    /* THE FIELD SHOWS LENGTH AND NOTHING ELSE. Dots rather than characters,
     * and a fixed maximum of them, so a shoulder-surfer learns neither the
     * content nor -- past the cap -- the length. */
    int dots = entry_len > 20 ? 20 : entry_len;
    double dw = 14.0, x0 = cx - (dots * dw) / 2.0;
    cairo_set_source_rgb(cr, 0.55, 0.75, 0.95);
    for (int i = 0; i < dots; i++) {
        cairo_arc(cr, x0 + i * dw + dw / 2, cy, 4.0, 0, 2 * 3.14159265);
        cairo_fill(cr);
    }

    cairo_set_source_rgb(cr, 0.45, 0.45, 0.5);
    cairo_set_font_size(cr, 13.0);
    const char *hint = "Enter to unlock";
    cairo_text_extents(cr, hint, &te);
    cairo_move_to(cr, cx - te.width / 2.0, cy + 48);
    cairo_show_text(cr, hint);

    cairo_destroy(cr);
    cairo_surface_flush(o->cairo);

    wl_surface_attach(o->surface, o->buffer, 0, 0);
    wl_surface_damage_buffer(o->surface, 0, 0, o->width, o->height);
    wl_surface_commit(o->surface);
}

static void draw_all(void)
{
    for (int i = 0; i < n_outputs; i++)
        if (outputs[i].configured)
            draw(&outputs[i]);
}

/* ---- the lock surface ------------------------------------------------- */

static void surface_configure(void *data,
                              struct ext_session_lock_surface_v1 *s,
                              uint32_t serial, uint32_t width, uint32_t height)
{
    LockOutput *o = data;

    /* ACK FIRST, THEN A BUFFER OF EXACTLY THIS SIZE. The order is the
     * protocol's, not a preference: a commit before the first ack_configure
     * is the `commit_before_first_ack` error, and a buffer that is not
     * width x height is `dimensions_mismatch`. Both kill the client, and a
     * killed client here leaves the session locked with nothing drawn. */
    ext_session_lock_surface_v1_ack_configure(s, serial);

    if (!output_alloc(o, (int32_t)width, (int32_t)height))
        return;
    o->configured = 1;
    draw(o);
}

static const struct ext_session_lock_surface_v1_listener surface_listener = {
    surface_configure,
};

/* RELEASE ONE OUTPUT'S SURFACE AND BUFFERS. Called when the compositor takes
 * an output away -- which happens on every VT SWITCH, not only when a monitor
 * is unplugged. */
static void output_teardown(LockOutput *o)
{
    if (o->lock_surface) {
        ext_session_lock_surface_v1_destroy(o->lock_surface);
        o->lock_surface = NULL;
    }
    if (o->surface)  { wl_surface_destroy(o->surface);   o->surface = NULL; }
    if (o->cairo)    { cairo_surface_destroy(o->cairo);  o->cairo = NULL; }
    if (o->buffer)   { wl_buffer_destroy(o->buffer);     o->buffer = NULL; }
    if (o->data)     { munmap(o->data, o->size);         o->data = NULL; }
    if (o->output)   { wl_output_destroy(o->output);     o->output = NULL; }
    o->configured = 0;
    o->width = o->height = 0;
}

/* GIVE ONE OUTPUT A LOCK SURFACE. Used both for the outputs present when the
 * lock is taken and for any that appear afterwards. */
static void output_attach(LockOutput *o)
{
    if (!session_lock || !o->output || o->lock_surface)
        return;
    o->surface = wl_compositor_create_surface(compositor);
    o->lock_surface = ext_session_lock_v1_get_lock_surface(
        session_lock, o->surface, o->output);
    ext_session_lock_surface_v1_add_listener(
        o->lock_surface, &surface_listener, o);
}

/* ---- the lock --------------------------------------------------------- */

static void lock_locked(void *data, struct ext_session_lock_v1 *l)
{
    (void)data; (void)l;
    locked_ok = 1;
}

static void lock_finished(void *data, struct ext_session_lock_v1 *l)
{
    (void)data; (void)l;
    /* REFUSED. Another locker already holds the session, or the compositor
     * declined. destroy() is correct here and unlock_and_destroy() would be a
     * protocol error -- we never held the lock to release. */
    finished = 1;
    running = 0;
}

static const struct ext_session_lock_v1_listener lock_listener = {
    lock_locked,
    lock_finished,
};

/* ---- input ------------------------------------------------------------ */

/* KICK THE MEDIA MOUNT, WITHOUT WAITING FOR IT. Measured on hardware: an
 * armed boot with no stick leaves the one-shot media service failed, and
 * every console that could restart it is itself behind the factor that
 * needs the mount -- inserting the stick after boot had NO path to being
 * mounted short of a reboot. So a refused attempt kicks the service: the
 * person's Enter is the signal that they believe the factor is present.
 * dinitctl can block up to twelve seconds (the enumeration wait), so this
 * must not run in-process: double-fork, the grandchild execs, init reaps
 * it, and the caller returns immediately. "Already mounted" exits 0, so
 * kicking on every refusal is harmless when the mount is fine. */
static void kick_media(void)
{
    pid_t pid = fork();
    if (pid == 0) {
        if (fork() == 0) {
            setsid();
            execl("/usr/bin/dinitctl", "dinitctl", "-p", "/run/dinitctl",
                  "start", "media", (char *)NULL);
            _exit(127);
        }
        _exit(0);
    }
    if (pid > 0) {
        int st;
        waitpid(pid, &st, 0);
    }
}

static void try_unlock(void)
{
    checking = 1;
    draw_all();
    wl_display_flush(display);

    int ok = veron_verify(entry, entry_len);

    /* THE ENTRY IS WIPED WHETHER OR NOT IT WAS RIGHT, and before anything
     * else happens. */
    explicit_bzero(entry, sizeof entry);
    entry_len = 0;
    checking = 0;

    if (ok) {
        unlocking = 1;
        running = 0;
        return;
    }
    kick_media();
    failed_attempt = 1;
    /* A DELIBERATE PAUSE ON FAILURE. Not a lockout -- see the note at the end
     * of this file about why this program must never refuse forever -- but
     * enough that guessing is not free. */
    struct timespec ts = { 1, 0 };
    nanosleep(&ts, NULL);
    draw_all();
}

static void kb_keymap(void *data, struct wl_keyboard *k, uint32_t format,
                      int fd, uint32_t size)
{
    (void)data; (void)k;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        close(fd);
        return;
    }
    char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return;
    }
    if (xkb_map) xkb_keymap_unref(xkb_map);
    if (xkb_st)  xkb_state_unref(xkb_st);
    xkb_map = xkb_keymap_new_from_string(xkb_ctx, map,
                                         XKB_KEYMAP_FORMAT_TEXT_V1,
                                         XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    close(fd);
    xkb_st = xkb_map ? xkb_state_new(xkb_map) : NULL;
}

static void kb_key(void *data, struct wl_keyboard *k, uint32_t serial,
                   uint32_t time, uint32_t key, uint32_t state)
{
    (void)data; (void)k; (void)serial; (void)time;
    if (state != WL_KEYBOARD_KEY_STATE_PRESSED || !xkb_st)
        return;

    /* +8 IS THE EVDEV-TO-XKB OFFSET and leaving it out is the classic way a
     * keyboard produces the wrong letters entirely. */
    xkb_keysym_t sym = xkb_state_key_get_one_sym(xkb_st, key + 8);

    if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter) {
        try_unlock();
        return;
    }
    if (sym == XKB_KEY_BackSpace) {
        if (entry_len > 0)
            entry[--entry_len] = '\0';
        failed_attempt = 0;
        draw_all();
        return;
    }
    if (sym == XKB_KEY_Escape) {
        explicit_bzero(entry, sizeof entry);
        entry_len = 0;
        failed_attempt = 0;
        draw_all();
        return;
    }

    char buf[8];
    int n = xkb_state_key_get_utf8(xkb_st, key + 8, buf, sizeof buf);
    if (n > 0 && entry_len + n < (int)sizeof entry - 1) {
        memcpy(entry + entry_len, buf, (size_t)n);
        entry_len += n;
        entry[entry_len] = '\0';
        failed_attempt = 0;
        draw_all();
    }
}

static void kb_modifiers(void *data, struct wl_keyboard *k, uint32_t serial,
                         uint32_t dep, uint32_t lat, uint32_t lock, uint32_t grp)
{
    (void)data; (void)k; (void)serial;
    if (xkb_st)
        xkb_state_update_mask(xkb_st, dep, lat, lock, 0, 0, grp);
}

static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s,
                     struct wl_surface *su, struct wl_array *a)
{
    (void)d; (void)k; (void)s; (void)su; (void)a;
    /* FRESH FOCUS, FRESH SCREEN. After a VT round-trip the reattached
     * surfaces redrew whatever state the last attempt left -- a "Not
     * accepted" from before a person fixed the mount looked exactly like a
     * new refusal, and cost a diagnostic session. Keyboard focus arriving
     * means a person is here now; show the current state, not history. */
    if (failed_attempt) {
        failed_attempt = 0;
        draw_all();
    }
}
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s,
                     struct wl_surface *su)
{ (void)d; (void)k; (void)s; (void)su; }
static void kb_repeat(void *d, struct wl_keyboard *k, int32_t r, int32_t dl)
{ (void)d; (void)k; (void)r; (void)dl; }

static const struct wl_keyboard_listener kb_listener = {
    kb_keymap, kb_enter, kb_leave, kb_key, kb_modifiers, kb_repeat,
};

static void seat_caps(void *data, struct wl_seat *s, uint32_t caps)
{
    (void)data;
    /* THE KEYBOARD GOES AWAY ON EVERY VT SWITCH, EXACTLY LIKE THE OUTPUTS,
     * AND ONLY THE OUTPUTS WERE HANDLED. wlroots removes the input devices
     * when the session deactivates (Ctrl+Alt+F2) and re-adds them on
     * return; the capability bit drops and comes back. This handler only
     * ever ACQUIRED: on re-add, `keyboard` was still the stale non-NULL
     * object -- inert, per protocol, once its capability was withdrawn --
     * so nothing re-bound, and every keystroke after a VT round-trip went
     * nowhere. Measured on hardware, repeatedly, as the lock screen
     * "refusing" Enter while showing a frozen last-drawn message: the
     * refusal was never fresh, the screen was a photograph and the
     * keyboard was dead. Releasing on drop makes the existing acquire
     * branch fire again on return, and the compositor resends the keymap
     * to the new object (kb_keymap already replaces the xkb state). */
    if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && keyboard) {
        wl_keyboard_release(keyboard);
        keyboard = NULL;
    }
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) {
        keyboard = wl_seat_get_keyboard(s);
        wl_keyboard_add_listener(keyboard, &kb_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n)
{ (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = { seat_caps, seat_name };

/* ---- registry --------------------------------------------------------- */

static void reg_global(void *data, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data;
    if (!strcmp(iface, wl_compositor_interface.name))
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, wl_shm_interface.name))
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_seat_interface.name)) {
        seat = wl_registry_bind(r, name, &wl_seat_interface, 5);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    } else if (!strcmp(iface, ext_session_lock_manager_v1_interface.name))
        lock_manager = wl_registry_bind(
            r, name, &ext_session_lock_manager_v1_interface, 1);
    else if (!strcmp(iface, wl_output_interface.name)) {
        /* A FREE SLOT, NOT ALWAYS A NEW ONE. Outputs come and go across VT
         * switches, so reuse a slot an earlier removal emptied rather than
         * running off the end of the array on the third or fourth switch. */
        int i = -1;
        for (int k = 0; k < n_outputs; k++)
            if (!outputs[k].output) { i = k; break; }
        if (i < 0 && n_outputs < MAX_OUTPUTS)
            i = n_outputs++;
        if (i < 0)
            return;
        outputs[i].name = name;
        outputs[i].output = wl_registry_bind(
            r, name, &wl_output_interface, version < 3 ? version : 3);
        /* IF THE SESSION IS ALREADY LOCKED, THIS OUTPUT NEEDS COVERING NOW.
         * An output that appears while locked and gets no lock surface is an
         * output showing whatever the compositor falls back to. */
        output_attach(&outputs[i]);
    }
}

/* AN OUTPUT GOING AWAY IS NOT A RARE EVENT, AND IGNORING IT BROKE THE LOCK
 * SCREEN ON EVERY VT SWITCH.
 *
 * This handler used to do nothing. wlroots removes the wl_output globals when
 * the session is deactivated -- which is what Ctrl+Alt+F2 does -- and re-adds
 * them on return. A lock surface bound to an output that no longer exists is
 * a protocol error the moment it is touched, so the compositor disconnected
 * the client; and because ext-session-lock-v1 keeps the session locked when
 * its client dies, the result was a permanently black screen that no
 * keystroke could reach. Measured on hardware: lock, Ctrl+Alt+F2,
 * Ctrl+Alt+F1, and the lock screen never came back.
 *
 * THE ESCAPE HATCH IS THE THING THAT BROKE IT, which is the worst possible
 * shape for this bug: the documented way out of a misbehaving lock screen was
 * itself what wedged the session. */
static void reg_remove(void *d, struct wl_registry *r, uint32_t name)
{
    (void)d; (void)r;
    for (int i = 0; i < n_outputs; i++)
        if (outputs[i].output && outputs[i].name == name)
            output_teardown(&outputs[i]);
}

static const struct wl_registry_listener reg_listener = {
    reg_global, reg_remove,
};

/* ---- main ------------------------------------------------------------- */

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--version")) {
            printf("veron-lock 1.0\n");
            return 0;
        }

    /* INITIALIZE libgcrypt, WHICH THIS PROGRAM ALONE FORGOT. veron-login and
     * veron-enroll both do this before their first verify; veron-lock never
     * did, and it is the only difference in the verify path between the
     * binaries that accept a valid factor and the one that was measured on
     * hardware refusing it -- same environment, same files, same uid, same
     * mount, all confirmed against the running process. Some libgcrypt
     * builds self-initialize on first use; relying on that is exactly the
     * kind of works-on-one-build behaviour this tree keeps paying for. */
    gcry_check_version(NULL);
    gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0);

    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "veron-lock: no WAYLAND_DISPLAY\n");
        return 1;
    }
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &reg_listener, NULL);
    wl_display_roundtrip(display);   /* globals */
    wl_display_roundtrip(display);   /* seat capabilities, output properties */

    if (!compositor || !shm || !lock_manager) {
        fprintf(stderr, "veron-lock: compositor does not offer "
                        "ext-session-lock-v1\n");
        return 1;
    }
    if (!n_outputs) {
        fprintf(stderr, "veron-lock: no outputs\n");
        return 1;
    }

    xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!xkb_ctx) {
        fprintf(stderr, "veron-lock: no xkb context\n");
        return 1;
    }

    /* LOCK FIRST, THEN SURFACES, IN ONE GO AND BEFORE ANY WAITING. The
     * compositor cannot report `locked` until every output has a surface
     * showing, so anything done between these two calls is time the screen is
     * not yet secure. */
    session_lock = ext_session_lock_manager_v1_lock(lock_manager);
    ext_session_lock_v1_add_listener(session_lock, &lock_listener, NULL);

    /* ONE CODE PATH FOR BOTH CASES. output_attach is what the registry calls
     * for an output that appears later, so using it here too means a
     * hotplugged output is covered exactly the same way as an original one. */
    for (int i = 0; i < n_outputs; i++)
        output_attach(&outputs[i]);

    while (running && wl_display_dispatch(display) != -1)
        ;

    if (finished) {
        /* REFUSED: destroy, and do NOT unlock -- we never held it. */
        ext_session_lock_v1_destroy(session_lock);
        wl_display_roundtrip(display);
        fprintf(stderr, "veron-lock: another locker holds the session\n");
        return 1;
    }

    if (unlocking) {
        /* unlock_and_destroy, NOT destroy, AND THE ROUNDTRIP IS NOT OPTIONAL.
         * The request has to reach the server before this process exits; a
         * client that exits first is a client that died while holding the
         * lock, and the compositor is entitled to keep the session locked
         * forever on exactly that basis. */
        ext_session_lock_v1_unlock_and_destroy(session_lock);
        wl_display_roundtrip(display);
    }

    explicit_bzero(entry, sizeof entry);
    wl_display_disconnect(display);
    return 0;
}

/* LOCKOUT, AND WHY THIS PROGRAM NEVER REFUSES FOREVER.
 *
 * Everything else in this system is recoverable by rebooting. This is not:
 * the compositor holds the session locked whether or not this process lives,
 * so a locker that cannot be satisfied is a desktop that cannot be reached.
 *
 * Three things follow, and all three are decisions rather than oversights:
 *
 *   NO ATTEMPT LIMIT. A counter that eventually refuses every input turns a
 *   forgotten factor into a lost session with no way back short of a reboot.
 *   The delay after a failure is there instead: guessing is slowed, never
 *   stopped.
 *
 *   VT SWITCHING STAYS ENABLED. Ctrl+Alt+F2 reaches a console, which is the
 *   real escape hatch. It is not a hole in the lock -- whoever arrives there
 *   still faces veron-login -- and it is the difference between a locked
 *   laptop and a brick. Disabling it is only defensible once full-disk
 *   encryption and a recovery key both exist.
 *
 *   FAILING TO DRAW IS NOT FAILING TO LOCK. If a buffer cannot be allocated
 *   the surface stays blank and the session stays locked, which is the safe
 *   direction. The prompt is a convenience; the lock is the guarantee.
 */
