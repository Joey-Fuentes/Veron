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
#include "xdg-decoration-unstable-v1-client-protocol.h"

struct _WPEToplevelVeron {
    WPEToplevel parent_instance;

    /* THREE SURFACES, ONE OWNER EACH, AND THAT IS THE WHOLE OF THIS CHANGE.
     *
     * It used to be two, with the chrome drawn straight onto wlSurface, and
     * that had the chrome and the window fighting over one buffer. A
     * wl_surface holds exactly ONE buffer, so veron-browser's 1024x44 chrome
     * buffer WAS the window: labwc sized the toplevel to it and the frame
     * showed a URL bar floating on the desktop with nothing under it. And a
     * client that drew no chrome at all -- MiniBrowser -- attached nothing to
     * wlSurface, so the xdg_toplevel never mapped and no window appeared.
     *
     * Now the toplevel surface carries a background the backend owns, and
     * both the chrome and the page are subsurfaces on top of it. Nobody
     * overwrites anybody, the window maps whether or not a browser draws
     * chrome, and the geometry comes from the toplevel rather than from
     * whatever the caller happened to paint. */
    struct wl_surface    *wlSurface;      /* the window: background lives here */
    struct wl_surface    *chromeSurface;  /* the strip, as a subsurface        */
    struct wl_subsurface *chromeSubsurface;
    struct wl_surface    *pageSurface;    /* the page, as a subsurface         */
    struct wl_subsurface *pageSubsurface;
    struct xdg_surface   *xdgSurface;
    struct xdg_toplevel  *xdgToplevel;
    struct zxdg_toplevel_decoration_v1 *xdgDecoration;

    /* THE BACKGROUND, AND THE SIZE IT WAS PAINTED AT. Kept so a configure
     * that does not change the size does not throw away a good buffer and
     * allocate an identical one every frame the compositor acks. */
    VeronSolidBuffer     *background;
    int                   backgroundWidth;
    int                   backgroundHeight;

    guint chromeHeight;
    gboolean chromeFocus;
    int   pendingWidth;
    int   pendingHeight;
};

enum { CHROME_EVENT, CHROME_KEY, CHROME_FOCUS_LOST, CHROME_RESIZED, N_SIGNALS };
static guint signals[N_SIGNALS];

/* THE SIZE A WINDOW OPENS AT WHEN NOBODY SAYS. 1024x768 is WPE's own default
 * and what MiniBrowser has always come up at on the stock Wayland backend, so
 * a client moved from that backend to this one sees the window it expects.
 * It is only ever a fallback: a compositor that names a size wins, and so does
 * a client that called wpe_toplevel_resize. */
#define VERON_DEFAULT_WIDTH  1024
#define VERON_DEFAULT_HEIGHT 768

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

/* THE PAGE TAKES THE KEYBOARD BACK WHEN IT IS CLICKED, AND NOTHING DID THIS.
 *
 * onChromeEvent clears chrome focus when a click lands on the strip and misses
 * every widget -- but a click on the PAGE never reaches onChromeEvent at all.
 * It goes through seatDispatch to WPEView and touches nothing here. So after
 * one click in the URL bar, chromeFocus stayed TRUE for the life of the
 * window, keyboardKey kept taking the `wpeVeronToplevelChromeHasFocus` branch,
 * and every keystroke went to the URL field no matter where the user clicked.
 * Clicking a search box on the page focused it in WebKit and then typing did
 * nothing visible, which reads as "clicks do not work" and is really "keys go
 * somewhere else".
 *
 * THE BACKEND IS WHERE THIS BELONGS because the backend is what knows the
 * click was on the page: Wayland hit-tested it onto the page subsurface, which
 * is the same fact seatDispatch already routes on. The browser cannot see it
 * without being told, so it is told. */
/* THE WINDOW CHANGED SIZE AND THE BROWSER HAS NO OTHER WAY TO HEAR ABOUT IT.
 *
 * veron-browser connected to "notify::width" on the toplevel, and WPEToplevel
 * HAS NO SUCH PROPERTY -- WPEToplevel.cpp installs exactly two, display and
 * max-views, and wpe_toplevel_resized only assigns priv->width without
 * emitting anything at all. So that handler never ran once: the browser's
 * cached width stayed at the 1024 it was given at startup, and every
 * veron_chrome_draw redrew the strip at the launch width no matter how large
 * the window got. Maximise, fullscreen and a drag-resize all looked the same
 * because none of them was ever delivered.
 *
 * A SIGNAL RATHER THAN A PROPERTY, to match the three already here. The
 * backend is what receives the configure, so it is what knows. */
void wpeVeronToplevelEmitResized(WPEToplevelVeron *self, int width, int height)
{
    if (!self || width < 1 || height < 1)
        return;
    g_signal_emit(self, signals[CHROME_RESIZED], 0, (guint)width, (guint)height);
}

void wpeVeronToplevelDropChromeFocus(WPEToplevelVeron *self)
{
    if (!self || !self->chromeFocus)
        return;
    self->chromeFocus = FALSE;
    g_signal_emit(self, signals[CHROME_FOCUS_LOST], 0);
}

void wpeVeronToplevelEmitChromeKey(WPEToplevelVeron *self, WPEEventType type,
                                   guint32 time, WPEModifiers modifiers,
                                   guint keycode, guint keyval)
{
    g_signal_emit(self, signals[CHROME_KEY], 0,
                  (guint)type, time, (guint)modifiers, keycode, keyval);
}

/* ---- the background the window is made of ---------------------------- */

/* CALLED WHEREVER A SIZE IS DECIDED, AND NOWHERE ELSE. Both call sites are
 * below -- the configure and the resize vfunc -- and they are the only two
 * places this toplevel ever learns how big it is. */
static void veronToplevelPaintBackground(WPEToplevelVeron *self, int width, int height)
{
    if (width < 1 || height < 1)
        return;
    if (self->background && self->backgroundWidth == width
                         && self->backgroundHeight == height) {
        /* Same size: the existing buffer is still correct and still attached.
         * Reallocating here would churn a pool per configure, and compositors
         * send configures for things that are not resizes. */
        return;
    }

    WPEDisplayVeron *display =
        WPE_DISPLAY_VERON(wpe_toplevel_get_display(WPE_TOPLEVEL(self)));
    struct wl_shm *shm = wpeVeronDisplayGetShm(display);
    if (!shm)
        return;

    VeronSolidBuffer *next = wpeVeronSolidBufferNew(shm, width, height, 0xffffffffu);
    if (!next)
        return;

    wl_surface_attach(self->wlSurface, wpeVeronSolidBufferGet(next), 0, 0);
    wl_surface_damage(self->wlSurface, 0, 0, width, height);
    wl_surface_commit(self->wlSurface);

    /* THE OLD BUFFER IS RELEASED AFTER THE COMMIT THAT REPLACES IT, not
     * before. Destroying it first would pull it out from under a compositor
     * that is still scanning it out for the current frame. */
    g_clear_pointer(&self->background, wpeVeronSolidBufferFree);
    g_clear_pointer(&self->xdgDecoration, zxdg_toplevel_decoration_v1_destroy);
    self->background       = next;
    self->backgroundWidth  = width;
    self->backgroundHeight = height;
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

        /* THE BACKGROUND IS PAINTED BEFORE THE VIEW IS TOLD ANYTHING. This is
         * the commit that maps the window, and until it happens the page
         * subsurface has no visible parent to be a subsurface OF. */
        veronToplevelPaintBackground(self, self->pendingWidth, self->pendingHeight);
        wpe_toplevel_resized(WPE_TOPLEVEL(self), self->pendingWidth, self->pendingHeight);
        wpeVeronToplevelEmitResized(self, self->pendingWidth, self->pendingHeight);
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
        return;
    }

    /* BUT DECLINING TO CHOOSE IS NOT AN OPTION EITHER, AND THAT WAS THE BUG.
     * This returned here, so pendingWidth stayed 0, so xdgSurfaceConfigure
     * acked and did nothing, so wpe_toplevel_resized() was NEVER CALLED and
     * WPEToplevel's recorded size stayed 0x0 for the life of the window.
     * labwc sends 0x0 for every new toplevel, so that was every window.
     *
     * "You choose" is an instruction, not permission to skip. Prefer a size
     * WPE already has -- the client may have called wpe_toplevel_resize --
     * and fall back to WPE's own default, which is what the stock Wayland
     * backend ends up at and what MiniBrowser has always opened with. */
    int w = 0, h = 0;
    wpe_toplevel_get_size(WPE_TOPLEVEL(self), &w, &h);
    if (w < 1 || h < 1) {
        w = VERON_DEFAULT_WIDTH;
        h = VERON_DEFAULT_HEIGHT;
    }
    self->pendingWidth  = w;
    self->pendingHeight = h;
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

    self->wlSurface     = wl_compositor_create_surface(compositor);
    self->chromeSurface = wl_compositor_create_surface(compositor);
    self->pageSurface   = wl_compositor_create_surface(compositor);

    struct wl_subcompositor *subcompositor = wpeVeronDisplayGetSubcompositor(display);

    /* THE CHROME IS A SUBSURFACE NOW, AND THE CALLER CANNOT TELL. It still
     * gets a bare wl_surface out of wpe_toplevel_veron_get_chrome_surface and
     * still attaches buffers and commits; a subsurface takes exactly the same
     * calls. What changes is that its buffer no longer decides how big the
     * window is, which is what made veron-browser's window 1024x44. */
    self->chromeSubsurface = wl_subcompositor_get_subsurface(
        subcompositor, self->chromeSurface, self->wlSurface);
    wl_subsurface_set_desync(self->chromeSubsurface);
    wl_subsurface_set_position(self->chromeSubsurface, 0, 0);

    self->pageSubsurface = wl_subcompositor_get_subsurface(
        subcompositor, self->pageSurface, self->wlSurface);

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

    /* SERVER-SIDE DECORATIONS, ASKED FOR EXPLICITLY. A titlebar is not
     * something a Wayland compositor gives an xdg_toplevel by default -- the
     * client requests it, and until this line no window from this backend had
     * one, so none of them could be moved, resized, maximised or closed.
     *
     * NO LISTENER, AND THE STOCK BACKEND EXPLAINS WHY IN ONE SENTENCE
     * (WPEToplevelWayland.cpp:566): a compositor may answer CLIENT_SIDE
     * instead, and knowing that is useless here because painting our own
     * decorations is not something this backend does. Ask for server-side;
     * take what arrives.
     *
     * THE STRIP IS NOT AFFECTED EITHER WAY. Decorations are drawn outside the
     * window geometry by the compositor; the chrome subsurface is inside it,
     * at y=0, and the two do not overlap or compete. */
    struct zxdg_decoration_manager_v1 *decorations =
        wpeVeronDisplayGetDecorationManager(display);
    if (decorations) {
        self->xdgDecoration = zxdg_decoration_manager_v1_get_toplevel_decoration(
            decorations, self->xdgToplevel);
        zxdg_toplevel_decoration_v1_set_mode(self->xdgDecoration,
            ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    }

    /* ALL THREE GO IN THE MAP. The seat resolves an event back to a toplevel
     * through this table, and pointer events over the strip now arrive on
     * chromeSurface rather than on wlSurface. Leaving it out would drop every
     * click on the URL bar -- wpeVeronToplevelForSurface would return NULL and
     * the event would be discarded with nothing logged. */
    veronRegisterSurface(self->wlSurface, self);
    veronRegisterSurface(self->chromeSurface, self);
    veronRegisterSurface(self->pageSurface, self);

    wl_surface_commit(self->wlSurface);
    wl_display_roundtrip(wpeVeronDisplayGetWlDisplay(display));
}

/* ---- the two toplevel vfuncs ----------------------------------------- */

static gboolean wpeToplevelVeronResize(WPEToplevel *toplevel, int width, int height)
{
    WPEToplevelVeron *self = WPE_TOPLEVEL_VERON(toplevel);
    if (width < 1 || height < 1)
        return FALSE;

    int pageHeight = height - (int)self->chromeHeight;
    if (pageHeight < 1)
        pageHeight = 1;

    /* THE TOPLEVEL'S OWN SIZE HAS TO BE RECORDED, AND THIS DID NOT RECORD IT.
     * It resized the views and returned, so WPEToplevel still believed it was
     * whatever it was before -- 0x0 on a fresh window. veron-browser's
     * wpe_toplevel_resize(1024, 768) therefore moved the views and left the
     * toplevel at zero, and wpe_toplevel_veron_set_chrome_height read that
     * zero back out of wpe_toplevel_get_size a few lines later and skipped
     * its own resize. Two functions disagreeing about the size of one window.
     *
     * wpe_toplevel_resized IS THE NOTIFICATION, NOT THE REQUEST, so this does
     * not recurse: wpe_toplevel_resize calls this vfunc, and this tells WPE
     * what the size became. xdgSurfaceConfigure already used it the same way. */
    veronToplevelPaintBackground(self, width, height);
    wpe_toplevel_resized(WPE_TOPLEVEL(self), width, height);
    wpeVeronToplevelEmitResized(self, width, height);
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
    /* The chrome subsurface stays at the origin whatever the height is; the
     * strip's height is the height of the buffer the caller attaches. */

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
    /* THE STRIP'S OWN SURFACE, NOT THE TOPLEVEL'S. Same signature, same
     * meaning, same calls on the far side -- the caller draws the chrome and
     * commits, and cannot tell a subsurface from a toplevel surface by doing
     * so. It no longer competes with the window's background for the one
     * buffer a wl_surface can hold. */
    return self->chromeSurface;
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
    veronUnregisterSurface(self->chromeSurface);
    veronUnregisterSurface(self->pageSurface);
    g_clear_pointer(&self->background, wpeVeronSolidBufferFree);
    g_clear_pointer(&self->xdgDecoration, zxdg_toplevel_decoration_v1_destroy);
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

    /* NO ARGUMENTS: the only fact is that it happened. A browser connects this
     * to unfocus its field and repaint; nothing else needs it. */
    signals[CHROME_FOCUS_LOST] = g_signal_new("chrome-focus-lost",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 0);

    /* WIDTH AND HEIGHT OF THE WHOLE TOPLEVEL, chrome included. The caller
     * subtracts its own strip if it cares; the page's size is the backend's
     * business and is already handled. */
    signals[CHROME_RESIZED] = g_signal_new("chrome-resized",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 2, G_TYPE_UINT, G_TYPE_UINT);

    signals[CHROME_KEY] = g_signal_new("chrome-key",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 5,
        G_TYPE_UINT, G_TYPE_UINT, G_TYPE_UINT, G_TYPE_UINT, G_TYPE_UINT);

    WPEToplevelClass *toplevelClass = WPE_TOPLEVEL_CLASS(klass);
    toplevelClass->resize         = wpeToplevelVeronResize;
    toplevelClass->set_fullscreen = wpeToplevelVeronSetFullscreen;
    toplevelClass->set_title      = wpeToplevelVeronSetTitle;
}
