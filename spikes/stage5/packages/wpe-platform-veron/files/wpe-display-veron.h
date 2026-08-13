/* A Veron WPE platform backend: display, toplevel and view.
 *
 * WHAT THIS IS FOR. WPE renders a page into a buffer and, in its stock Wayland
 * backend, attaches that buffer directly to the toplevel's own wl_surface --
 * WPEViewWayland.cpp:741, where wpe_view_wayland_get_wl_surface() returns
 * wpe_toplevel_wayland_get_wl_surface(). The page IS the window's contents, so
 * nothing can be drawn beside it. A browser with a URL bar needs a strip that
 * is not the page, and that is the whole reason this exists.
 *
 * WHY A FOURTH BACKEND RATHER THAN A PATCH. WPEDisplayWayland, WPEToplevelWayland
 * and WPEViewWayland are all G_DECLARE_FINAL_TYPE -- upstream saying their
 * internals are not a stable interface. Subclassing them would mean depending on
 * a private struct layout and on call ordering nobody documents, and re-patching
 * on every upgrade. The BASE classes are WPE_DECLARE_DERIVABLE_TYPE, which is
 * how drm, headless and wayland are siblings rather than a hierarchy. This is a
 * fourth sibling, on public API only.
 *
 * AND IT NEEDS NO WPE REBUILD, EVER. WPEExtensions.cpp:62 scans
 * WPE_PLATFORMS_PATH for GIO modules, so this ships as a .so and is selected
 * with WPE_DISPLAY=wpe-display-veron. The iteration loop for everything built
 * on top of it is a single cc -shared.
 */
#pragma once

#include <wpe/wpe-platform.h>
#include <glib-object.h>

struct wl_shm;
struct wl_surface;

G_BEGIN_DECLS

#define WPE_TYPE_DISPLAY_VERON  (wpe_display_veron_get_type())
#define WPE_TYPE_TOPLEVEL_VERON (wpe_toplevel_veron_get_type())
#define WPE_TYPE_VIEW_VERON     (wpe_view_veron_get_type())

G_DECLARE_FINAL_TYPE(WPEDisplayVeron,  wpe_display_veron,  WPE, DISPLAY_VERON,  WPEDisplay)
G_DECLARE_FINAL_TYPE(WPEToplevelVeron, wpe_toplevel_veron, WPE, TOPLEVEL_VERON, WPEToplevel)
G_DECLARE_FINAL_TYPE(WPEViewVeron,     wpe_view_veron,     WPE, VIEW_VERON,     WPEView)

/* THE HEIGHT OF THE STRIP THIS BACKEND RESERVES, in logical pixels. Zero means
 * the page fills the toplevel and this backend behaves exactly like the stock
 * Wayland one -- which is the first milestone and the thing to verify before
 * any chrome exists. A browser sets it to whatever its URL bar needs. */
void     wpe_toplevel_veron_set_chrome_height (WPEToplevelVeron *toplevel,
                                               guint             height);
guint    wpe_toplevel_veron_get_chrome_height (WPEToplevelVeron *toplevel);

/* THE CHROME SURFACE IS THE CALLER'S TO DRAW ON. The backend owns the toplevel's
 * wl_surface and puts the page in a subsurface below the strip; whoever builds a
 * browser on this draws into the strip with Cairo, or anything else that can
 * write pixels into a wl_buffer. Returning the raw surface rather than wrapping
 * it keeps this backend out of the business of having opinions about drawing. */
struct wl_surface *wpe_toplevel_veron_get_chrome_surface (WPEToplevelVeron *toplevel);

/* WHO GETS THE KEYBOARD. Wayland's hit testing routes the pointer, because the
 * page is a separate surface -- it cannot route the keyboard, because "the URL
 * bar is being typed into" is a state the browser knows and the compositor does
 * not. Set this while the chrome has focus and key events arrive as
 * "chrome-key" instead of reaching the page. */
void wpe_toplevel_veron_set_chrome_focus (WPEToplevelVeron *toplevel,
                                          gboolean          focus);

/* THE COMPOSITOR'S wl_shm, SO THE CHROME CAN ALLOCATE A BUFFER. Whoever draws
 * the strip needs a shared-memory pool and there is no second Wayland
 * connection to get one from -- the backend already holds the only one. */
struct wl_shm *wpe_display_veron_get_shm (WPEDisplayVeron *display);

/* THE CHROME'S OWN EVENTS. Pointer events over the strip are emitted as
 * "chrome-event" (type, time, modifiers, button, x, y, dx, dy) and keys as
 * "chrome-key" (type, time, modifiers, keycode, keyval). They are raw rather
 * than WPEEvents because a WPEEvent belongs to a WPEView and the chrome is not
 * one. */

G_END_DECLS
