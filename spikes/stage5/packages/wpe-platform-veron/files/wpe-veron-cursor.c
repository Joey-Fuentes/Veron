/* The pointer shape, which this backend never set at all.
 *
 * WHAT WAS WRONG. WPEViewClass has set_cursor_from_name and
 * set_cursor_from_bytes, and this backend implemented NEITHER -- so every
 * cursor request WebKit made was dropped on the floor. The pointer kept
 * whatever shape the compositor last gave it, which is why it entered the
 * window as an arrow, or as a resize bar if it crossed an edge on the way in,
 * and then never changed again. Hovering a link did not produce a hand; an
 * input field did not produce an I-beam.
 *
 * THE STOCK BACKEND CARRIES 351 LINES FOR THIS across four files
 * (WPEWaylandCursor.cpp/.h, WPEWaylandCursorTheme.cpp/.h) plus the vfunc
 * wiring in WPEViewWayland.cpp:613. It is not something WPE provides and a
 * backend inherits; it is work each backend does. This is the same work,
 * smaller, because libwayland-cursor already parses XCursor files and the
 * theme is one this project generates.
 *
 * NO NEW PACKAGE. libwayland-cursor ships with wayland and veron-cursors
 * already generates left_ptr, xterm, hand2, watch, the resize bars and
 * crosshair, plus an alias table covering the CSS names WebKit actually asks
 * for -- default, pointer, text, wait, progress, grab, grabbing, cell, move,
 * col-resize, row-resize and the four axis resizes. Names outside that set
 * fall back to left_ptr rather than leaving the previous shape up, because a
 * stale cursor is a worse lie than a generic one.
 */
#include "wpe-veron-private.h"

/* wayland-client.h EXPLICITLY, AND NOT BY LUCK FROM ANOTHER HEADER.
 * wpe-veron-private.h only FORWARD-DECLARES the wl_ types -- it declares
 * `struct wl_surface;` so it can name them in prototypes without pulling the
 * protocol in. That is enough to compile a pointer, and not enough to CALL
 * wl_surface_attach or wl_pointer_set_cursor. */
#include <wayland-client.h>
#include <wayland-cursor.h>
#include <stdlib.h>

struct _VeronCursor {
    struct wl_cursor_theme *theme;
    struct wl_surface      *surface;
    char                   *current;   /* last name set; avoids re-attaching */
    int                     size;
};

/* THE SIZE COMES FROM THE ENVIRONMENT, THEN A DEFAULT. XCURSOR_SIZE is what
 * every toolkit reads and what a user changes when a HiDPI screen makes 24px
 * cursors too small. 24 is libwayland-cursor's own fallback. */
static int cursorSize(void)
{
    const char *env = getenv("XCURSOR_SIZE");
    if (env && *env) {
        int n = atoi(env);
        if (n > 0 && n <= 256)
            return n;
    }
    return 24;
}

VeronCursor *wpeVeronCursorNew(WPEDisplayVeron *display)
{
    struct wl_shm *shm = wpeVeronDisplayGetShm(display);
    struct wl_compositor *compositor = wpeVeronDisplayGetCompositor(display);
    if (!shm || !compositor)
        return NULL;

    VeronCursor *c = g_new0(VeronCursor, 1);
    c->size = cursorSize();

    /* NULL FOR THE THEME NAME, WHICH MEANS "whatever XCURSOR_THEME says, or
     * the default". veron-cursors installs its theme as the default one, so
     * naming it here would hardcode a choice the user can otherwise make. */
    c->theme = wl_cursor_theme_load(getenv("XCURSOR_THEME"), c->size, shm);
    if (!c->theme) {
        g_free(c);
        return NULL;
    }

    c->surface = wl_compositor_create_surface(compositor);
    if (!c->surface) {
        wl_cursor_theme_destroy(c->theme);
        g_free(c);
        return NULL;
    }
    return c;
}

void wpeVeronCursorFree(VeronCursor *c)
{
    if (!c)
        return;
    g_clear_pointer(&c->surface, wl_surface_destroy);
    g_clear_pointer(&c->theme, wl_cursor_theme_destroy);
    g_free(c->current);
    g_free(c);
}

/* THE POINTER JUST ENTERED AND WAYLAND HAS GIVEN US NO SHAPE.
 *
 * wl_pointer.enter does not come with a cursor. The protocol makes the CLIENT
 * responsible for setting one, and until it does, whatever the compositor last
 * drew stays on screen. So crossing into the window over a resize edge left
 * the resize arrow up -- and it stayed up, because WebKit tracks its own
 * cursor state and only pushes a CHANGE. From its point of view the cursor was
 * already `default` and there was nothing to say. It corrected itself the
 * moment the pointer hit a link, because that was a genuine change.
 *
 * THE STOCK BACKEND CALLS updateCursor() FROM ITS OWN enter HANDLER
 * (WPEWaylandSeat.cpp:81) for exactly this reason.
 *
 * FORGETTING THE CACHED NAME IS HALF THE FIX. Setting `default` here without
 * clearing `current` would make the next legitimate `default` request a no-op,
 * so the arrow would not come back after leaving a link. */
void wpeVeronCursorResetOnEnter(VeronCursor *c, struct wl_pointer *pointer,
                                guint32 serial)
{
    if (!c)
        return;
    g_clear_pointer(&c->current, g_free);
    wpeVeronCursorSetFromName(c, pointer, serial, "default");
}

void wpeVeronCursorSetFromName(VeronCursor *c, struct wl_pointer *pointer,
                               guint32 serial, const char *name)
{
    if (!c || !pointer || !name)
        return;

    /* "none" HIDES THE POINTER and is a real request -- a video player in
     * fullscreen asks for it. A NULL surface is how wl_pointer says that. */
    if (!g_strcmp0(name, "none")) {
        wl_pointer_set_cursor(pointer, serial, NULL, 0, 0);
        g_free(c->current);
        c->current = g_strdup(name);
        return;
    }

    /* SETTING THE SAME SHAPE AGAIN IS A ROUND TRIP FOR NOTHING, and WebKit
     * asks on every mouse move over the same element. */
    if (!g_strcmp0(c->current, name))
        return;

    struct wl_cursor *cursor = wl_cursor_theme_get_cursor(c->theme, name);
    if (!cursor) {
        /* THE FALLBACK IS AN ARROW, NOT SILENCE. Leaving the previous shape
         * up means a hand stays over plain text once a link has been hovered,
         * which reads as a broken pointer rather than a missing icon. */
        cursor = wl_cursor_theme_get_cursor(c->theme, "left_ptr");
        if (!cursor)
            return;
    }

    /* THE FIRST FRAME ONLY. Animated cursors have several; the stock backend
     * has the same FIXME and shows frame zero, which for this theme is the
     * whole cursor anyway -- nothing veron-cursors generates is animated. */
    struct wl_cursor_image *image = cursor->images[0];
    struct wl_buffer *buffer = wl_cursor_image_get_buffer(image);
    if (!buffer)
        return;

    /* THE SERIAL MUST BE THE ONE FROM wl_pointer.enter. The compositor
     * rejects set_cursor with any other serial -- silently, which is how this
     * fails when someone passes the most recent serial from any event. */
    wl_pointer_set_cursor(pointer, serial, c->surface,
                          (int32_t)image->hotspot_x, (int32_t)image->hotspot_y);

    wl_surface_attach(c->surface, buffer, 0, 0);
    wl_surface_damage(c->surface, 0, 0, (int32_t)image->width, (int32_t)image->height);
    wl_surface_commit(c->surface);

    g_free(c->current);
    c->current = g_strdup(name);
}
