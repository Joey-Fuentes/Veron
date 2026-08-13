/* The Wayland socket, in WebKit's main loop.
 *
 * WHY THIS FILE EXISTS AT ALL. WebKit runs a GMainLoop. Wayland events arrive
 * on a file descriptor and are dispatched only when something reads it. Attach
 * nothing and the client sends its surface, waits for the configure that would
 * tell it how big to be, and waits forever -- no window ever appears and
 * nothing says why. It is the single easiest thing to leave out of a Wayland
 * backend and the hardest to diagnose from the symptom.
 *
 * THE PREPARE/READ DANCE IS NOT OPTIONAL EITHER, and it is what makes this
 * more than a GIOChannel. libwayland has a two-phase read to keep multiple
 * threads from consuming each other's events:
 *
 *   wl_display_prepare_read  -- announce the intent to read
 *   poll                     -- wait for the fd
 *   wl_display_read_events   -- actually read
 *   wl_display_dispatch_pending -- run the handlers
 *
 * Calling wl_display_dispatch() from a GSource instead would block inside the
 * dispatch, which stalls every other source in the loop -- timers, the
 * WebProcess socket, everything.
 */
#include "wpe-veron-private.h"

#include <wayland-client.h>
#include <errno.h>

typedef struct {
    GSource            source;
    struct wl_display *display;
    gpointer           fdTag;
    gboolean           reading;
} VeronSource;

static gboolean veronSourcePrepare(GSource *base, gint *timeout)
{
    VeronSource *self = (VeronSource *)base;
    *timeout = -1;

    /* FLUSH BEFORE WAITING, because requests queued during the last dispatch
     * are still in the client's buffer. Without this a commit can sit unsent
     * while both sides wait for the other. */
    while (wl_display_prepare_read(self->display) != 0) {
        if (wl_display_dispatch_pending(self->display) < 0)
            return FALSE;
    }
    self->reading = TRUE;
    wl_display_flush(self->display);
    return FALSE;
}

static gboolean veronSourceCheck(GSource *base)
{
    VeronSource *self = (VeronSource *)base;
    GIOCondition events = g_source_query_unix_fd(base, self->fdTag);

    if (events & (G_IO_ERR | G_IO_HUP)) {
        /* THE COMPOSITOR WENT AWAY. Cancel the read we announced -- leaving it
         * outstanding wedges libwayland for anything else on this display. */
        if (self->reading) {
            wl_display_cancel_read(self->display);
            self->reading = FALSE;
        }
        return TRUE;
    }

    if (self->reading) {
        if (events & G_IO_IN) {
            if (wl_display_read_events(self->display) < 0)
                return TRUE;
        } else
            wl_display_cancel_read(self->display);
        self->reading = FALSE;
    }
    return !!(events & G_IO_IN);
}

static gboolean veronSourceDispatch(GSource *base, GSourceFunc callback, gpointer data)
{
    VeronSource *self = (VeronSource *)base;
    if (wl_display_dispatch_pending(self->display) < 0)
        return G_SOURCE_REMOVE;
    return G_SOURCE_CONTINUE;
}

static void veronSourceFinalize(GSource *base)
{
    VeronSource *self = (VeronSource *)base;
    if (self->reading) {
        wl_display_cancel_read(self->display);
        self->reading = FALSE;
    }
}

static GSourceFuncs veronSourceFuncs = {
    veronSourcePrepare,
    veronSourceCheck,
    veronSourceDispatch,
    veronSourceFinalize,
    NULL, NULL
};

GSource *wpeVeronEventSourceNew(struct wl_display *display)
{
    GSource *source = g_source_new(&veronSourceFuncs, sizeof(VeronSource));
    VeronSource *self = (VeronSource *)source;

    self->display = display;
    self->reading = FALSE;

    g_source_set_name(source, "veron-wayland");
    /* HIGH PRIORITY, because a configure that arrives late is a window that
     * resizes late, and the compositor is entitled to a timely ack. */
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_can_recurse(source, TRUE);

    self->fdTag = g_source_add_unix_fd(source, wl_display_get_fd(display),
        G_IO_IN | G_IO_ERR | G_IO_HUP);

    g_source_attach(source, g_main_context_get_thread_default());
    return source;
}

void wpeVeronEventSourceFree(GSource *source)
{
    if (!source)
        return;
    g_source_destroy(source);
    g_source_unref(source);
}
