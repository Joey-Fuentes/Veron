/* The toplevel: the window, and the split between chrome and page.
 *
 * THIS IS WHERE THIS BACKEND DIFFERS FROM THE STOCK ONE, and it is one idea.
 * The toplevel owns a wl_surface, as any Wayland window does. The stock
 * backend hands that surface to the view, so the page covers the window. This
 * one creates a SECOND surface as a wl_subsurface, positions it at y =
 * chrome-height, and gives the view that. What remains -- the strip across the
 * top of the toplevel's own surface -- belongs to whoever is building a
 * browser on this.
 *
 * CHROME HEIGHT DEFAULTS TO ZERO, and that matters for bringing this up. At
 * zero the subsurface covers the whole toplevel and this backend is
 * behaviourally the stock one; that is the first thing to verify, before any
 * chrome exists, because it separates "the backend loads and renders" from
 * "the split works".
 */
#include "wpe-display-veron.h"
#include "wpe-veron-private.h"

#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

struct _WPEToplevelVeron {
    WPEToplevel parent_instance;

    struct wl_surface    *wlSurface;      /* the window: chrome lives here */
    struct wl_surface    *pageSurface;    /* the page, as a subsurface     */
    struct wl_subsurface *pageSubsurface;
    struct xdg_surface   *xdgSurface;
    struct xdg_toplevel  *xdgToplevel;

    guint chromeHeight;
    gboolean chromeFocus;
    int   pendingWidth;
    int   pendingHeight;
};

enum { CHROME_EVENT, CHROME_KEY, N_SIGNALS };
static guint signals[N_SIGNALS];

G_DEFINE_TYPE(WPEToplevelVeron, wpe_toplevel_veron, WPE_TYPE_TOPLEVEL)

/* EVERY TOPLEVEL, BY SURFACE. The seat is told which wl_surface an event
 * happened on and has to get back to the object that owns it. A hash table
 * rather than a field on the surface because wl_surface has no user data slot
 * we own -- wl_surface_set_user_data is already used by libwayland's own
 * dispatch in some paths, and quietly stealing it is the kind of thing that
 * works until it does not. */
static GHashTable *veronSurfaceMap;

static void veronRegisterSurface(struct wl_surface *surface, WPEToplevelVeron *toplevel)
{
    if (!veronSurfaceMap)
        veronSurfaceMap = g_hash_table_new(NULL, NULL);
    g_hash_table_insert(veronSurfaceMap, surface, toplevel);
}

static void veronUnregisterSurface(struct wl_surface *surface)
{
    if (veronSurfaceMap)
        g_hash_table_remove(veronSurfaceMap, surface);
}

WPEToplevelVeron *wpeVeronToplevelForSurface(struct wl_surface *surface)
{
    if (!veronSurfaceMap || !surface)
        return NULL;
    return g_hash_table_lookup(veronSurfaceMap, surface);
}

gboolean wpeVeronToplevelIsPageSurface(WPEToplevelVeron *self, struct wl_surface *surface)
{
    return self && surface == self->pageSurface;
}

gboolean wpeVeronToplevelChromeHasFocus(WPEToplevelVeron *self)
{
    return self && self->chromeFocus;
}

void wpe_toplevel_veron_set_chrome_focus(WPEToplevelVeron *self, gboolean focus)
{
    g_return_if_fail(WPE_IS_TOPLEVEL_VERON(self));
    self->chromeFocus = focus;
}

void wpeVeronToplevelEmitChromeEvent(WPEToplevelVeron *self, WPEEventType type,
                                     guint32 time, WPEModifiers modifiers, guint button,
                                     double x, double y, double dx, double dy)
{
    g_signal_emit(self, signals[CHROME_EVENT], 0,
                  (guint)type, time, (guint)modifiers, button, x, y, dx, dy);
}

void wpeVeronToplevelEmitChromeKey(WPEToplevelVeron *self, WPEEventType type,
                                   guint32 time, WPEModifiers modifiers,
                                   guint keycode, guint keyval)
{
    g_signal_emit(self, signals[CHROME_KEY], 0,
                  (guint)type, time, (guint)modifiers, keycode, keyval);
}

/* ---- xdg plumbing ---------------------------------------------------- */

static void xdgSurfaceConfigure(void *data, struct xdg_surface *surface, uint32_t serial)
{
    WPEToplevelVeron *self = WPE_TOPLEVEL_VERON(data);
    xdg_surface_ack_configure(surface, serial);

    if (self->pendingWidth > 0 && self->pendingHeight > 0) {
        /* THE VIEW IS TOLD THE PAGE'S SIZE, NOT THE WINDOW'S. Everything
         * WebKit lays out is relative to the area it actually has, so the
         * strip must come off here rather than being compensated for later.
         * Getting this wrong is a page that thinks it is taller than it is
         * and scrolls its last rows under the chrome. */
        int pageHeight = self->pendingHeight - (int)self->chromeHeight;
        if (pageHeight < 1)
            pageHeight = 1;

        wpe_toplevel_resized(WPE_TOPLEVEL(self), self->pendingWidth, self->pendingHeight);
        wpeVeronToplevelResizePage(self, self->pendingWidth, pageHeight);
        self->pendingWidth = self->pendingHeight = 0;
    }
}

static const struct xdg_surface_listener xdgSurfaceListener = { xdgSurfaceConfigure };

static void xdgToplevelConfigure(void *data, struct xdg_toplevel *toplevel,
                                 int32_t width, int32_t height, struct wl_array *states)
{
    WPEToplevelVeron *self = WPE_TOPLEVEL_VERON(data);
    /* ZERO MEANS "YOU CHOOSE", which is not the same as "zero pixels". A
     * compositor sends 0x0 for a window it has no opinion about, and treating
     * that as a size produces a one-pixel window. */
    if (width > 0 && height > 0) {
        self->pendingWidth = width;
        self->pendingHeight = height;
    }
}

static void xdgToplevelClose(void *data, struct xdg_toplevel *toplevel)
{
    wpe_toplevel_closed(WPE_TOPLEVEL(data));
}

static const struct xdg_toplevel_listener xdgToplevelListener = {
    xdgToplevelConfigure, xdgToplevelClose
};

/* ---- construction ---------------------------------------------------- */

static void wpeToplevelVeronConstructed(GObject *object)
{
    G_OBJECT_CLASS(wpe_toplevel_veron_parent_class)->constructed(object);

    WPEToplevelVeron *self = WPE_TOPLEVEL_VERON(object);
    WPEDisplayVeron  *display = WPE_DISPLAY_VERON(wpe_toplevel_get_display(WPE_TOPLEVEL(self)));

    struct wl_compositor *compositor = wpeVeronDisplayGetCompositor(display);

    self->wlSurface   = wl_compositor_create_surface(compositor);
    self->pageSurface = wl_compositor_create_surface(compositor);

    self->pageSubsurface = wl_subcompositor_get_subsurface(
        wpeVeronDisplayGetSubcompositor(display), self->pageSurface, self->wlSurface);

    /* DESYNC, NOT SYNC, AND THE REASON IS THE FRAME RATE. A synchronised
     * subsurface only appears when its parent commits, which would tie every
     * page frame to a chrome repaint -- so a video would run at the speed the
     * URL bar redraws, which is never. Desynchronised lets the page commit
     * independently and the chrome update when it has something to say. */
    wl_subsurface_set_desync(self->pageSubsurface);
    wl_subsurface_set_position(self->pageSubsurface, 0, (int)self->chromeHeight);

    self->xdgSurface = xdg_wm_base_get_xdg_surface(
        wpeVeronDisplayGetXDGWMBase(display), self->wlSurface);
    xdg_surface_add_listener(self->xdgSurface, &xdgSurfaceListener, self);

    self->xdgToplevel = xdg_surface_get_toplevel(self->xdgSurface);
    xdg_toplevel_add_listener(self->xdgToplevel, &xdgToplevelListener, self);
    xdg_toplevel_set_title(self->xdgToplevel, "Veron");
    xdg_toplevel_set_app_id(self->xdgToplevel, "org.veron.Browser");

    veronRegisterSurface(self->wlSurface, self);
    veronRegisterSurface(self->pageSurface, self);

    wl_surface_commit(self->wlSurface);
    wl_display_roundtrip(wpeVeronDisplayGetWlDisplay(display));
}

/* ---- the two toplevel vfuncs ----------------------------------------- */

static gboolean wpeToplevelVeronResize(WPEToplevel *toplevel, int width, int height)
{
    WPEToplevelVeron *self = WPE_TOPLEVEL_VERON(toplevel);
    int pageHeight = height - (int)self->chromeHeight;
    if (pageHeight < 1)
        pageHeight = 1;
    wpeVeronToplevelResizePage(self, width, pageHeight);
    return TRUE;
}

static gboolean wpeToplevelVeronSetFullscreen(WPEToplevel *toplevel, gboolean fullscreen)
{
    WPEToplevelVeron *self = WPE_TOPLEVEL_VERON(toplevel);
    if (fullscreen)
        xdg_toplevel_set_fullscreen(self->xdgToplevel, NULL);
    else
        xdg_toplevel_unset_fullscreen(self->xdgToplevel);
    return TRUE;
}

static void wpeToplevelVeronSetTitle(WPEToplevel *toplevel, const char *title)
{
    xdg_toplevel_set_title(WPE_TOPLEVEL_VERON(toplevel)->xdgToplevel, title ? title : "");
}

/* ---- the chrome strip ------------------------------------------------ */

void wpe_toplevel_veron_set_chrome_height(WPEToplevelVeron *self, guint height)
{
    g_return_if_fail(WPE_IS_TOPLEVEL_VERON(self));
    if (self->chromeHeight == height)
        return;

    self->chromeHeight = height;
    wl_subsurface_set_position(self->pageSubsurface, 0, (int)height);

    /* THE PAGE IS RESIZED IMMEDIATELY, because changing the strip changes how
     * much room the page has and nothing else will tell it. */
    /* wpe_toplevel_get_size, NOT get_width/get_height -- those do not exist.
     * WPEToplevel.h:106 has one accessor returning both through out
     * parameters, and an earlier draft of this file invented the other two. */
    int w = 0, h = 0;
    wpe_toplevel_get_size(WPE_TOPLEVEL(self), &w, &h);
    h -= (int)height;
    if (w > 0 && h > 0)
        wpeVeronToplevelResizePage(self, w, h);

    wl_surface_commit(self->wlSurface);
}

guint wpe_toplevel_veron_get_chrome_height(WPEToplevelVeron *self)
{
    g_return_val_if_fail(WPE_IS_TOPLEVEL_VERON(self), 0);
    return self->chromeHeight;
}

struct wl_surface *wpe_toplevel_veron_get_chrome_surface(WPEToplevelVeron *self)
{
    g_return_val_if_fail(WPE_IS_TOPLEVEL_VERON(self), NULL);
    return self->wlSurface;
}

struct wl_surface *wpeVeronToplevelGetPageSurface(WPEToplevelVeron *self)
{
    return self->pageSurface;
}

static gboolean veronResizeOneView(WPEToplevel *toplevel, WPEView *view, gpointer data)
{
    struct { int w, h; } *size = data;
    wpe_view_resized(view, size->w, size->h);
    return FALSE; /* FALSE means keep going -- see WPEToplevelForeachViewFunc */
}

/* THE PAGE'S SIZE IS THE VIEW'S SIZE, and this is the only place that says so.
 *
 * wpe_view_resized tells WebKit how much room it has; the subsurface does not
 * clip, so a view told it is taller than the strip leaves would simply draw
 * over the chrome. Both have to agree and this keeps them together. */
void wpeVeronToplevelResizePage(WPEToplevelVeron *self, int width, int height)
{
    if (width < 1 || height < 1)
        return;

    /* EVERY VIEW ON THE TOPLEVEL, because WPEToplevel is built for more than
     * one -- create_toplevel takes max_views. A browser uses one today; a
     * browser with tabs uses several, and this should not have to change. */
    /* foreach_view, NOT AN INDEXED GETTER. WPEToplevel.h:102 offers
     * wpe_toplevel_foreach_view with a callback and no wpe_toplevel_get_view;
     * an earlier draft invented the latter. */
    struct { int w, h; } size = { width, height };
    wpe_toplevel_foreach_view(WPE_TOPLEVEL(self), veronResizeOneView, &size);
}

static void wpe_toplevel_veron_init(WPEToplevelVeron *self) { }

static void wpeToplevelVeronDispose(GObject *object)
{
    WPEToplevelVeron *self = WPE_TOPLEVEL_VERON(object);
    /* BOTH SURFACES LEAVE THE MAP. A stale entry would hand the seat a
     * freed toplevel the next time the compositor reused the surface id. */
    veronUnregisterSurface(self->wlSurface);
    veronUnregisterSurface(self->pageSurface);
    G_OBJECT_CLASS(wpe_toplevel_veron_parent_class)->dispose(object);
}

static void wpe_toplevel_veron_class_init(WPEToplevelVeronClass *klass)
{
    G_OBJECT_CLASS(klass)->constructed = wpeToplevelVeronConstructed;
    G_OBJECT_CLASS(klass)->dispose     = wpeToplevelVeronDispose;

    /* THE CHROME'S EVENTS, AS SIGNALS. A pointer event over the strip is not
     * the page's and has no WPEView to belong to, so it is passed on raw
     * rather than wrapped. A browser connects to these; nothing else needs
     * them. */
    signals[CHROME_EVENT] = g_signal_new("chrome-event",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 8,
        G_TYPE_UINT,   /* WPEEventType */
        G_TYPE_UINT,   /* time         */
        G_TYPE_UINT,   /* WPEModifiers */
        G_TYPE_UINT,   /* button       */
        G_TYPE_DOUBLE, G_TYPE_DOUBLE,   /* x, y     */
        G_TYPE_DOUBLE, G_TYPE_DOUBLE);  /* dx, dy   */

    signals[CHROME_KEY] = g_signal_new("chrome-key",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 5,
        G_TYPE_UINT, G_TYPE_UINT, G_TYPE_UINT, G_TYPE_UINT, G_TYPE_UINT);

    WPEToplevelClass *toplevelClass = WPE_TOPLEVEL_CLASS(klass);
    toplevelClass->resize         = wpeToplevelVeronResize;
    toplevelClass->set_fullscreen = wpeToplevelVeronSetFullscreen;
    toplevelClass->set_title      = wpeToplevelVeronSetTitle;
}
