/* The display: a Wayland connection, and the two factory vfuncs.
 *
 * MODELLED ON headless, NOT ON wayland. wpe/headless is 433 lines for a
 * complete backend -- display, toplevel and view -- and implements eight
 * vfuncs in total. wpe/wayland is 5404 lines because it implements
 * EVERYTHING: gamepads, touch, input methods, presentation feedback, explicit
 * sync, DMABuf feedback, multi-screen. This starts from the smaller shape and
 * grows into what it needs, rather than copying five thousand lines to change
 * one of them.
 */
#include "wpe-display-veron.h"
#include "wpe-veron-private.h"

#include <wayland-client.h>
#include <epoxy/egl.h>
#include "xdg-shell-client-protocol.h"
#include "linux-dmabuf-unstable-v1-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include <string.h>

/* gio.h for GIOModule and gmodule.h for G_MODULE_EXPORT -- both are needed by
 * the module entry points at the bottom of this file. */
#include <gio/gio.h>
#include <gmodule.h>

struct _WPEDisplayVeron {
    WPEDisplay parent_instance;

    struct wl_display    *wlDisplay;
    struct wl_registry   *wlRegistry;
    struct wl_compositor *wlCompositor;
    /* THE SUBCOMPOSITOR IS THE POINT OF THIS BACKEND. The page goes in a
     * wl_subsurface so the toplevel's own surface is free to carry chrome.
     * Without it there is nothing here the stock backend does not do. */
    struct wl_subcompositor *wlSubcompositor;
    struct xdg_wm_base   *xdgWMBase;
    struct wl_shm        *wlShm;
    struct wl_seat       *wlSeat;
    struct zwp_linux_dmabuf_v1 *linuxDMABuf;
    /* WITHOUT THIS THE WINDOW HAS NO TITLEBAR AND CANNOT BE MOVED. labwc
     * decorates a toplevel only when the client asks through this protocol,
     * and this backend never bound it -- so on bare metal veron-browser and
     * MiniBrowser both came up undecorated, unmovable and unresizable. It
     * looked like a regression because MiniBrowser used to be decorated, and
     * it was: back when the module was being REJECTED and MiniBrowser fell
     * through to the stock Wayland backend, which does bind it
     * (WPEToplevelWayland.cpp:569). */
    struct zxdg_decoration_manager_v1 *xdgDecorationManager;

    EGLDisplay eglDisplay;
    GSource   *eventSource;
    VeronSeat *seat;
    /* CREATED LAZILY, AFTER connect(), because wl_cursor_theme_load needs the
     * shm the registry supplies and the registry has not run at construction. */
    VeronCursor *cursor;
};

G_DEFINE_TYPE_WITH_CODE(WPEDisplayVeron, wpe_display_veron, WPE_TYPE_DISPLAY,
    /* PRIORITY 100 BEATS WAYLAND'S. Extensions are ordered, and
     * wpe_display_get_default walks the list trying to connect until one
     * succeeds -- WPEDisplay.cpp:287. A higher number means this is tried
     * first, so a system with the module installed gets it without setting
     * anything, and WPE_DISPLAY=wpe-display-wayland still selects the stock
     * one. That fallback is free and worth having. */
    g_io_extension_point_implement(WPE_DISPLAY_EXTENSION_POINT_NAME,
        g_define_type_id, "wpe-display-veron", 100))

/* ---- the registry -------------------------------------------------- */

static const struct xdg_wm_base_listener xdgWMBaseListener;

static void registryGlobal(void *data, struct wl_registry *registry, uint32_t name,
                           const char *interface, uint32_t version)
{
    WPEDisplayVeron *display = WPE_DISPLAY_VERON(data);

    if (!strcmp(interface, "wl_compositor"))
        display->wlCompositor = wl_registry_bind(registry, name, &wl_compositor_interface, MIN(version, 4u));
    else if (!strcmp(interface, "wl_subcompositor"))
        display->wlSubcompositor = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
    else if (!strcmp(interface, "wl_shm"))
        display->wlShm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "wl_seat"))
        display->wlSeat = wl_registry_bind(registry, name, &wl_seat_interface, MIN(version, 5u));
    else if (!strcmp(interface, "xdg_wm_base")) {
        display->xdgWMBase = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        /* THE PING LISTENER IS NOT OPTIONAL. A compositor pings periodically
         * and kills a client that does not pong -- labwc included. Without
         * this the browser is closed as unresponsive some seconds after it
         * starts, which looks like a crash and is not one. */
        xdg_wm_base_add_listener(display->xdgWMBase, &xdgWMBaseListener, display);
    } else if (!strcmp(interface, "zxdg_decoration_manager_v1")) {
        display->xdgDecorationManager = wl_registry_bind(registry, name,
            &zxdg_decoration_manager_v1_interface, 1);
    } else if (!strcmp(interface, "zwp_linux_dmabuf_v1")) {
        /* VERSION 3 IS ENOUGH for create_params/create_immed with modifiers,
         * which is all the view uses. Asking for more would exclude
         * compositors that offer less for no gain. */
        display->linuxDMABuf = wl_registry_bind(registry, name,
            &zwp_linux_dmabuf_v1_interface, MIN(version, 3u));
    }
}

static void xdgWMBasePing(void *data, struct xdg_wm_base *base, uint32_t serial)
{
    xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener xdgWMBaseListener = { xdgWMBasePing };

static void registryGlobalRemove(void *data, struct wl_registry *registry, uint32_t name) { }

static const struct wl_registry_listener registryListener = {
    registryGlobal, registryGlobalRemove
};

/* ---- connect --------------------------------------------------------- */

static gboolean wpeDisplayVeronConnect(WPEDisplay *display, GError **error)
{
    WPEDisplayVeron *self = WPE_DISPLAY_VERON(display);

    /* NULL MEANS WAYLAND_DISPLAY, and failing here is how the extension list
     * moves on to the next backend. This must return FALSE rather than abort
     * when there is no compositor -- wpe_display_get_default tries each
     * extension in turn and a hard failure here would take the whole list
     * down with it. */
    self->wlDisplay = wl_display_connect(NULL);
    if (!self->wlDisplay) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
            "veron: no Wayland display");
        return FALSE;
    }

    self->wlRegistry = wl_display_get_registry(self->wlDisplay);
    wl_registry_add_listener(self->wlRegistry, &registryListener, self);
    wl_display_roundtrip(self->wlDisplay);

    /* EVERY ONE OF THESE IS REQUIRED AND THE MESSAGE SAYS WHICH IS MISSING.
     * A backend that connects and then fails obscurely later is worse than
     * one that declines to connect: declining hands over to the stock
     * Wayland backend and the user gets a working browser without chrome. */
    if (!self->wlCompositor || !self->xdgWMBase || !self->wlSubcompositor) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
            "veron: compositor lacks %s",
            !self->wlCompositor ? "wl_compositor"
                : !self->xdgWMBase ? "xdg_wm_base" : "wl_subcompositor");
        return FALSE;
    }

    self->eglDisplay = eglGetDisplay((EGLNativeDisplayType)self->wlDisplay);
    if (self->eglDisplay != EGL_NO_DISPLAY)
        eglInitialize(self->eglDisplay, NULL, NULL);

    /* THE SEAT IS OPTIONAL AND ITS ABSENCE IS NOT AN ERROR. A compositor with
     * no input devices is unusual but legal -- a kiosk, or a headless test --
     * and refusing to connect over it would be wrong. */
    if (self->wlSeat)
        self->seat = wpeVeronSeatNew(self, self->wlSeat);
        self->cursor = wpeVeronCursorNew(self);
        if (!self->cursor)
            g_warning("veron: no cursor theme -- the pointer will not change shape");

    self->eventSource = wpeVeronEventSourceNew(self->wlDisplay);
    wl_display_roundtrip(self->wlDisplay);
    return TRUE;
}

/* ---- the two factories ----------------------------------------------- */

static WPEView *wpeDisplayVeronCreateView(WPEDisplay *display)
{
    return WPE_VIEW(g_object_new(WPE_TYPE_VIEW_VERON, "display", display, NULL));
}

static WPEToplevel *wpeDisplayVeronCreateToplevel(WPEDisplay *display, guint maxViews)
{
    return WPE_TOPLEVEL(g_object_new(WPE_TYPE_TOPLEVEL_VERON,
        "display", display, "max-views", maxViews, NULL));
}

static gpointer wpeDisplayVeronGetEGLDisplay(WPEDisplay *display, GError **error)
{
    WPEDisplayVeron *self = WPE_DISPLAY_VERON(display);
    if (self->eglDisplay == EGL_NO_DISPLAY) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
            "veron: no EGL display");
        return NULL;
    }
    return self->eglDisplay;
}

/* THE KEYMAP COMES FROM THE SEAT, because the compositor sends it over the
 * keyboard and there is nowhere else to get it. Returning NULL before the
 * keymap arrives is correct -- WebKit asks again. */
static WPEKeymap *wpeDisplayVeronGetKeymap(WPEDisplay *display)
{
    return wpeVeronSeatGetKeymap(WPE_DISPLAY_VERON(display)->seat);
}

/* ---- accessors the toplevel and view need ---------------------------- */

struct wl_display       *wpeVeronDisplayGetWlDisplay(WPEDisplayVeron *d)    { return d->wlDisplay; }
struct wl_compositor    *wpeVeronDisplayGetCompositor(WPEDisplayVeron *d)   { return d->wlCompositor; }
struct wl_subcompositor *wpeVeronDisplayGetSubcompositor(WPEDisplayVeron *d){ return d->wlSubcompositor; }
struct xdg_wm_base      *wpeVeronDisplayGetXDGWMBase(WPEDisplayVeron *d)    { return d->xdgWMBase; }
struct wl_shm           *wpeVeronDisplayGetShm(WPEDisplayVeron *d)          { return d->wlShm; }

struct wl_shm *wpe_display_veron_get_shm(WPEDisplayVeron *d)
{
    g_return_val_if_fail(WPE_IS_DISPLAY_VERON(d), NULL);
    return d->wlShm;
}
struct wl_seat          *wpeVeronDisplayGetSeat(WPEDisplayVeron *d)         { return d->wlSeat; }
struct zwp_linux_dmabuf_v1 *wpeVeronDisplayGetLinuxDMABuf(WPEDisplayVeron *d) { return d->linuxDMABuf; }

/* NOT REQUIRED IN connect(). A compositor without xdg-decoration is a
 * compositor that draws no decorations, which is a worse window and not a
 * reason to decline the display and hand the user no browser at all. */
struct zxdg_decoration_manager_v1 *wpeVeronDisplayGetDecorationManager(WPEDisplayVeron *d)
{
    return d->xdgDecorationManager;
}

static void wpe_display_veron_init(WPEDisplayVeron *self)
{
    self->eglDisplay = EGL_NO_DISPLAY;
}

static void wpe_display_veron_dispose(GObject *object)
{
    WPEDisplayVeron *self = WPE_DISPLAY_VERON(object);
    g_clear_pointer(&self->cursor, wpeVeronCursorFree);
    g_clear_pointer(&self->seat, wpeVeronSeatFree);
    g_clear_pointer(&self->eventSource, wpeVeronEventSourceFree);
    if (self->wlDisplay) {
        wl_display_flush(self->wlDisplay);
        wl_display_disconnect(self->wlDisplay);
        self->wlDisplay = NULL;
    }
    G_OBJECT_CLASS(wpe_display_veron_parent_class)->dispose(object);
}

static void wpe_display_veron_class_init(WPEDisplayVeronClass *klass)
{
    G_OBJECT_CLASS(klass)->dispose = wpe_display_veron_dispose;

    WPEDisplayClass *displayClass = WPE_DISPLAY_CLASS(klass);
    displayClass->connect         = wpeDisplayVeronConnect;
    displayClass->create_view     = wpeDisplayVeronCreateView;
    displayClass->create_toplevel = wpeDisplayVeronCreateToplevel;
    displayClass->get_egl_display = wpeDisplayVeronGetEGLDisplay;
    displayClass->get_keymap      = wpeDisplayVeronGetKeymap;
}

/* ---- the GIO module entry points ------------------------------------
 *
 * WITHOUT THESE THE MODULE DOES NOT LOAD AT ALL. GIO dlopens a file in
 * WPE_PLATFORMS_PATH and immediately looks for g_io_module_load; when it is
 * missing the loader reports
 *
 *     'g_io_module_load': .../libwpe-display-veron.so: undefined symbol
 *     Failed to load module: .../libwpe-display-veron.so
 *
 * and WPE falls through to the next extension -- which is why the browser came
 * up on the stock wayland backend with no chrome and nothing said the module
 * had been rejected. The G_DEFINE_TYPE_WITH_CODE above registers the extension
 * point, but that code only runs when the type is first used, and nothing uses
 * it until something loads the module.
 *
 * g_io_module_query MAY BE OMITTED, but returning the extension point name
 * lets GIO cache what this file provides instead of dlopening it to find out.
 */

G_MODULE_EXPORT void g_io_module_load(GIOModule *module)
{
    /* RESIDENT, AND THIS IS THE WHOLE OF THE MiniBrowser CRASH.
     *
     * GIOModule is a GTypeModule, and GIO unloads a module whose use count
     * falls back to zero after the scan. The types above are registered with
     * G_DEFINE_TYPE_WITH_CODE -- STATIC registration -- so they SURVIVE that
     * unload while their class vfunc pointers do not: the pointers keep
     * naming addresses inside a library that has been munmapped, and the next
     * vfunc call jumps into the hole.
     *
     * That is exactly what three cores showed. The faulting PC was
     * 0x7f317c0f2980, 0x7f37418cd980 and 0x7f0e2c866980 across three runs --
     * three ASLR bases, all ending 980, one function at one offset in one
     * library -- and eu-unstrip answered where the library had gone:
     *
     *     libwpe-display-veron.so IS NOT IN THIS CORE MODULE LIST
     *
     * AND IT IS WHY veron-browser NEVER HIT IT. dc68313 gave veron-browser
     * -lwpe-display-veron so it could call wpe_toplevel_veron_* directly, so
     * ld.so holds the library for the life of that process whatever GIO does
     * with its handle. MiniBrowser only reaches it through the module scan.
     * One binary was protected by accident; the other was not. Confirmed in
     * run 31727755290 with no source change at all: LD_PRELOAD of this exact
     * file turned MINI-VERON-DEAD into MINI-PRELOAD-ALIVE.
     *
     * g_type_module_use TAKES A REFERENCE THAT IS NEVER DROPPED, which is how
     * a GIO module holding static types keeps itself loaded. It cannot
     * recurse into this function: use_count is already 1 here -- GIO raised
     * it to call load -- and g_type_module_use only invokes load on the 0 -> 1
     * transition.
     *
     * THE ALTERNATIVE WAS G_DEFINE_DYNAMIC_TYPE, which is the other correct
     * answer and a much larger change: three types would need class_finalize
     * handlers and registration against the GTypeModule, and would have to be
     * re-registerable across an unload/reload cycle that nothing here needs.
     * Residency is the smaller claim -- this module is loaded once and stays. */
    g_type_module_use(G_TYPE_MODULE(module));

    /* Forces the class to be registered, which runs the
     * g_io_extension_point_implement above. */
    wpe_display_veron_get_type();
}

G_MODULE_EXPORT void g_io_module_unload(GIOModule *module)
{
    (void)module;
    /* Nothing to undo: the type stays registered for the life of the process,
     * and GIO does not unload extension implementations. */
}

G_MODULE_EXPORT char **g_io_module_query(void)
{
    char *eps[] = { (char *)WPE_DISPLAY_EXTENSION_POINT_NAME, NULL };
    return g_strdupv(eps);
}

VeronCursor *wpeVeronDisplayGetCursor(WPEDisplayVeron *display)
{
    return display ? display->cursor : NULL;
}

VeronSeat *wpeVeronDisplayGetVeronSeat(WPEDisplayVeron *display)
{
    return display ? display->seat : NULL;
}
