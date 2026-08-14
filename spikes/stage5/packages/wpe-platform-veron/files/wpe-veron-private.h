/* Declarations shared between the three files, and nothing public.
 *
 * These are the accessors the toplevel and view need from the display, and the
 * one the view needs from the toplevel. They are here rather than in the public
 * header because a browser has no business reaching for a wl_subcompositor --
 * the only surface it should ever see is the chrome one.
 */
#pragma once

#include "wpe-display-veron.h"

struct wl_display;
struct wl_compositor;
struct wl_subcompositor;
struct wl_shm;
struct wl_seat;
struct wl_surface;
struct wl_buffer;
struct xdg_wm_base;
struct zwp_linux_dmabuf_v1;
struct zxdg_decoration_manager_v1;

G_BEGIN_DECLS

struct wl_display       *wpeVeronDisplayGetWlDisplay     (WPEDisplayVeron *display);
struct wl_compositor    *wpeVeronDisplayGetCompositor    (WPEDisplayVeron *display);
struct wl_subcompositor *wpeVeronDisplayGetSubcompositor (WPEDisplayVeron *display);
struct xdg_wm_base      *wpeVeronDisplayGetXDGWMBase     (WPEDisplayVeron *display);
struct wl_shm           *wpeVeronDisplayGetShm           (WPEDisplayVeron *display);
struct wl_seat          *wpeVeronDisplayGetSeat          (WPEDisplayVeron *display);
struct zwp_linux_dmabuf_v1 *wpeVeronDisplayGetLinuxDMABuf(WPEDisplayVeron *display);
struct zxdg_decoration_manager_v1 *wpeVeronDisplayGetDecorationManager(WPEDisplayVeron *display);
struct wl_data_device_manager *wpeVeronDisplayGetDataDeviceManager(WPEDisplayVeron *display);

/* ---- the clipboard ---- */
#define WPE_TYPE_CLIPBOARD_VERON (wpe_clipboard_veron_get_type())
G_DECLARE_FINAL_TYPE(WPEClipboardVeron, wpe_clipboard_veron, WPE, CLIPBOARD_VERON, WPEClipboard)
WPEClipboard *wpeVeronClipboardNew(WPEDisplayVeron *display);

/* THE LAST INPUT SERIAL, WHICH set_selection REQUIRES. A compositor rejects a
 * selection claimed with a serial it did not issue, and does so silently. */
guint32 wpeVeronSeatGetLastSerial(VeronSeat *seat);

struct wl_surface       *wpeVeronToplevelGetPageSurface  (WPEToplevelVeron *toplevel);
void                     wpeVeronToplevelResizePage      (WPEToplevelVeron *toplevel,
                                                          int width, int height);

typedef struct _VeronSeat VeronSeat;

/* ---- the pointer shape ---- */
typedef struct _VeronCursor VeronCursor;
struct wl_pointer;

VeronCursor *wpeVeronDisplayGetCursor  (WPEDisplayVeron *display);
VeronSeat   *wpeVeronDisplayGetVeronSeat(WPEDisplayVeron *display);

VeronCursor *wpeVeronCursorNew         (WPEDisplayVeron *display);
void         wpeVeronCursorFree        (VeronCursor *cursor);
void         wpeVeronCursorSetFromName (VeronCursor *cursor,
                                        struct wl_pointer *pointer,
                                        guint32 serial, const char *name);
/* CALLED FROM wl_pointer.enter. The protocol hands the client no cursor, so
 * without this the compositor's last shape persists -- a resize arrow, if the
 * pointer crossed a window edge on the way in. */
void         wpeVeronCursorResetOnEnter(VeronCursor *cursor,
                                        struct wl_pointer *pointer,
                                        guint32 serial);

/* THE SEAT OWNS THE POINTER AND THE ENTER SERIAL, and set_cursor needs both.
 * The view has neither, which is why these exist rather than the view
 * reaching into the seat struct. */
struct wl_pointer *wpeVeronSeatGetPointer      (VeronSeat *seat);
guint32            wpeVeronSeatGetEnterSerial  (VeronSeat *seat);

VeronSeat *wpeVeronSeatNew        (WPEDisplayVeron *display, struct wl_seat *seat);
void       wpeVeronSeatFree       (VeronSeat *seat);
WPEKeymap *wpeVeronSeatGetKeymap  (VeronSeat *seat);

/* THE SEAT FINDS A TOPLEVEL FROM THE SURFACE AN EVENT ARRIVED ON, and asks
 * whether that surface is the page or the chrome. Wayland has already done the
 * hit testing by then -- these only turn its answer into ours. */
WPEToplevelVeron *wpeVeronToplevelForSurface     (struct wl_surface *surface);
gboolean          wpeVeronToplevelIsPageSurface  (WPEToplevelVeron *toplevel,
                                                  struct wl_surface *surface);
gboolean          wpeVeronToplevelChromeHasFocus (WPEToplevelVeron *toplevel);
void              wpeVeronToplevelDropChromeFocus(WPEToplevelVeron *toplevel);
void              wpeVeronToplevelEmitResized    (WPEToplevelVeron *toplevel,
                                                  int width, int height);

void wpeVeronToplevelEmitChromeEvent (WPEToplevelVeron *toplevel, WPEEventType type,
                                      guint32 time, WPEModifiers modifiers, guint button,
                                      double x, double y, double dx, double dy);
void wpeVeronToplevelEmitChromeKey   (WPEToplevelVeron *toplevel, WPEEventType type,
                                      guint32 time, WPEModifiers modifiers,
                                      guint keycode, guint keyval);

struct wl_buffer        *wpeVeronBufferFromSHM           (WPEViewVeron *view,
                                                          WPEBuffer *buffer,
                                                          GError **error);

/* A FLAT wl_shm BUFFER, FOR THE TOPLEVEL'S OWN SURFACE.
 *
 * The page and the chrome are both subsurfaces, and a wl_subsurface's buffer
 * does NOT map its parent -- only a buffer on the xdg_surface's own wl_surface
 * does. Nothing in WPE will attach one: WPEViewWayland.cpp:573 has the VIEW
 * attaching to the toplevel surface, which is exactly the arrangement this
 * backend replaces, and WPEToplevelWayland never attaches anything itself. So
 * the backend paints its own background, and this is the smallest thing that
 * can be painted.
 *
 * It lives beside the other shm code because that file already carries
 * _GNU_SOURCE for memfd_create and the pool/fd handling that goes with it. */
typedef struct _VeronSolidBuffer VeronSolidBuffer;

VeronSolidBuffer *wpeVeronSolidBufferNew (struct wl_shm *shm,
                                          int width, int height, guint32 argb);
struct wl_buffer *wpeVeronSolidBufferGet (VeronSolidBuffer *buffer);
void              wpeVeronSolidBufferFree(VeronSolidBuffer *buffer);

/* THE WAYLAND FD IN THE GLIB MAIN LOOP. WebKit runs a GMainLoop and Wayland
 * events arrive on a socket; without a source attached, nothing is ever
 * dispatched and the window never gets a configure. This is the piece that is
 * easy to forget and presents as "the window never appears". */
GSource *wpeVeronEventSourceNew  (struct wl_display *display);
void     wpeVeronEventSourceFree (GSource *source);

G_END_DECLS
