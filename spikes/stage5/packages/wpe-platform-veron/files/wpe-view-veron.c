/* The view: WebKit's buffer, attached to the page subsurface.
 *
 * ONE VFUNC MATTERS HERE and it is render_buffer. The stock backend's version
 * -- WPEViewWayland.cpp:549 -- attaches to wpe_view_wayland_get_wl_surface(),
 * which is the TOPLEVEL's surface (line 741). This attaches to the page
 * subsurface instead, and that single difference is what leaves a strip for
 * chrome.
 *
 * DMABuf FIRST, SHM AS THE FALLBACK, which is the order the stock backend
 * uses and the order the hardware wants: a DMABuf buffer is already in GPU
 * memory and the compositor can scan it out, while SHM means the page was
 * rendered into main memory and will be copied again. On this laptop mesa
 * gives DMABuf; the SHM path exists because llvmpipe and headless do not.
 */
#include "wpe-display-veron.h"
#include "wpe-veron-private.h"

#include <wayland-client.h>
#include "linux-dmabuf-unstable-v1-client-protocol.h"

struct _WPEViewVeron {
    WPEView parent_instance;
    struct wl_callback *frameCallback;
    WPEBuffer          *pendingBuffer;
};

G_DEFINE_TYPE(WPEViewVeron, wpe_view_veron, WPE_TYPE_VIEW)

/* ---- frame callbacks -------------------------------------------------- */

static void frameDone(void *data, struct wl_callback *callback, uint32_t time);
static const struct wl_callback_listener frameListener = { frameDone };

static void frameDone(void *data, struct wl_callback *callback, uint32_t time)
{
    WPEViewVeron *self = WPE_VIEW_VERON(data);

    g_clear_pointer(&self->frameCallback, wl_callback_destroy);

    /* buffer_rendered IS HOW WEBKIT LEARNS IT MAY DRAW AGAIN. Without it the
     * page renders one frame and stops, which looks exactly like a hang and
     * is the first thing to check if this backend shows a static page. */
    if (self->pendingBuffer) {
        wpe_view_buffer_rendered(WPE_VIEW(self), self->pendingBuffer);
        self->pendingBuffer = NULL;
    }
}

/* ---- buffer conversion ------------------------------------------------ */

/* ---- giving the buffer back ------------------------------------------
 *
 * TWO NOTIFICATIONS, NOT ONE, AND THIS BACKEND ONLY EVER SENT ONE.
 *
 *   wpe_view_buffer_rendered  -- the frame was presented. Sent from the frame
 *                                callback. This backend did send it.
 *   wpe_view_buffer_released  -- the COMPOSITOR HAS FINISHED READING and the
 *                                buffer may be reused. This backend never
 *                                sent it at all.
 *
 * WebKit recycles a small pool of buffers and cannot put one back in the pool
 * until it is told the compositor is done with it. Never being told, it kept
 * allocating instead -- and every DMABuf carries a file descriptor per plane,
 * so a page rendering continuously walks the process into its fd limit. A
 * static page renders a handful of frames and never notices; a video renders
 * thirty a second and falls over in well under a minute, which is exactly the
 * shape of the YouTube crash.
 *
 * BOTH PATHS NEED IT. The stock backend attaches this listener to the DMABuf
 * wl_buffer (WPEViewWayland.cpp:324) and to the shared-memory one
 * (WPEViewWayland.cpp:367), and the SHM path here already had a release
 * listener of its own for its `busy` flag -- it simply never passed the news
 * on to WPE. */
/* THE VIEW IS HELD WEAKLY, WHICH IS NOT A DETAIL. WebKit owns the WPEBuffers
 * and the view owns nothing of them, so a buffer can outlive the view that
 * rendered it -- a window closed while the compositor still holds its last
 * frame is the ordinary case, not a corner one. A raw pointer here would be
 * read after free the moment that release arrives, and the crash would land
 * on window close rather than anywhere near this code.
 *
 * The stock backend holds `GWeakPtr<WPEView> m_view` for the same reason and
 * null-checks it on every release (WPEViewWayland.cpp:529). This is the C
 * spelling of that: g_object_add_weak_pointer nulls the field when the view
 * is finalised, and the handler checks before using it. */
typedef struct {
    struct wl_buffer *wlBuffer;
    WPEView          *view;      /* weak -- nulled when the view dies */
} VeronDMABuf;

static void veronDMABufFree(gpointer ptr)
{
    VeronDMABuf *d = ptr;
    if (!d)
        return;
    if (d->view)
        g_object_remove_weak_pointer(G_OBJECT(d->view), (gpointer *)&d->view);
    g_clear_pointer(&d->wlBuffer, wl_buffer_destroy);
    g_free(d);
}

static void veronBufferReleased(void *data, struct wl_buffer *wlBuffer)
{
    WPEBuffer *buffer = data;
    VeronDMABuf *d = wpe_buffer_get_user_data(buffer);
    if (d && d->view)
        wpe_view_buffer_released(d->view, buffer);
}

static const struct wl_buffer_listener veronBufferReleaseListener = { veronBufferReleased };

static struct wl_buffer *veronBufferFromDMABuf(WPEViewVeron *self, WPEBuffer *buffer, GError **error)
{
    /* CACHED ON THE BUFFER, because WebKit recycles a small pool of them and
     * building a wl_buffer per frame would leak one per frame. wpe_buffer_set_
     * user_data with a destroy notify is how the stock backend does it and is
     * the only place the lifetime is expressible. */
    VeronDMABuf *cached = wpe_buffer_get_user_data(buffer);
    if (cached)
        return cached->wlBuffer;

    WPEDisplayVeron *display = WPE_DISPLAY_VERON(wpe_view_get_display(WPE_VIEW(self)));
    struct zwp_linux_dmabuf_v1 *dmabuf = wpeVeronDisplayGetLinuxDMABuf(display);
    if (!dmabuf) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: compositor has no linux-dmabuf");
        return NULL;
    }

    WPEBufferDMABuf *dma = WPE_BUFFER_DMA_BUF(buffer);
    guint64 modifier = wpe_buffer_dma_buf_get_modifier(dma);
    struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(dmabuf);

    guint32 planes = wpe_buffer_dma_buf_get_n_planes(dma);
    for (guint32 i = 0; i < planes; ++i) {
        zwp_linux_buffer_params_v1_add(params,
            wpe_buffer_dma_buf_get_fd(dma, i), i,
            wpe_buffer_dma_buf_get_offset(dma, i),
            wpe_buffer_dma_buf_get_stride(dma, i),
            modifier >> 32, modifier & 0xffffffff);
    }

    struct wl_buffer *wlBuffer = zwp_linux_buffer_params_v1_create_immed(params,
        wpe_buffer_get_width(buffer), wpe_buffer_get_height(buffer),
        wpe_buffer_dma_buf_get_format(dma), 0);
    zwp_linux_buffer_params_v1_destroy(params);

    if (!wlBuffer) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: could not make a wl_buffer from the DMABuf");
        return NULL;
    }

    /* THE VIEW IS RECORDED ALONGSIDE THE wl_buffer, because the release
     * listener is handed the WPEBuffer and has no other way back to the view
     * that has to be told. */
    VeronDMABuf *d = g_new0(VeronDMABuf, 1);
    d->wlBuffer = wlBuffer;
    d->view = WPE_VIEW(self);
    g_object_add_weak_pointer(G_OBJECT(d->view), (gpointer *)&d->view);

    wl_buffer_add_listener(wlBuffer, &veronBufferReleaseListener, buffer);
    wpe_buffer_set_user_data(buffer, d, veronDMABufFree);
    return wlBuffer;
}

/* ---- the vfunc that is the whole point -------------------------------- */

static gboolean wpeViewVeronRenderBuffer(WPEView *view, WPEBuffer *buffer,
                                         const WPERectangle *damage, guint nDamage,
                                         GError **error)
{
    WPEViewVeron *self = WPE_VIEW_VERON(view);

    struct wl_buffer *wlBuffer = NULL;
    if (WPE_IS_BUFFER_DMA_BUF(buffer))
        wlBuffer = veronBufferFromDMABuf(self, buffer, error);
    else if (WPE_IS_BUFFER_SHM(buffer))
        wlBuffer = wpeVeronBufferFromSHM(self, buffer, error);
    else
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: buffer is neither DMABuf nor SHM");

    if (!wlBuffer)
        return FALSE;

    WPEToplevelVeron *toplevel = WPE_TOPLEVEL_VERON(wpe_view_get_toplevel(view));

    /* THE PAGE SURFACE, NOT THE TOPLEVEL'S. One line, and the reason this
     * backend exists. */
    struct wl_surface *surface = wpeVeronToplevelGetPageSurface(toplevel);

    wl_surface_attach(surface, wlBuffer, 0, 0);

    if (nDamage && damage) {
        for (guint i = 0; i < nDamage; ++i)
            wl_surface_damage_buffer(surface, damage[i].x, damage[i].y,
                                     damage[i].width, damage[i].height);
    } else
        wl_surface_damage(surface, 0, 0, G_MAXINT32, G_MAXINT32);

    /* THE OLD CALLBACK GOES FIRST. WebKit can render again before the
     * compositor has sent the previous frame event -- on a resize, or when a
     * page paints twice quickly. Overwriting the pointer would leak the old
     * wl_callback and leave its listener pointing at this view, so a stale
     * frame event would report a buffer that has already been returned. */
    g_clear_pointer(&self->frameCallback, wl_callback_destroy);

    self->pendingBuffer = buffer;
    self->frameCallback = wl_surface_frame(surface);
    wl_callback_add_listener(self->frameCallback, &frameListener, self);

    wl_surface_commit(surface);
    return TRUE;
}

static void wpe_view_veron_init(WPEViewVeron *self) { }

/* ---- mapping: the reason the page never appeared -------------------------
 *
 * A WPEView PAINTS ONLY WHEN IT IS MAPPED, and this backend never mapped one.
 * WPEWebViewPlatform.cpp:88 connects notify::mapped and feeds it straight into
 * WebCore::ActivityState::IsVisible, and a page that is not visible does not
 * render. So WebKit produced no buffers, render_buffer above was never called,
 * the page subsurface never got anything to show, and both browsers came up
 * with an empty page area and no error anywhere -- because nothing had gone
 * wrong, WebKit had simply been told the view was not on screen.
 *
 * EVERY SHIPPED BACKEND DOES THIS ITSELF; none of it happens automatically.
 * wayland/WPEViewWayland.cpp:123-140, headless/WPEViewHeadless.cpp:80 and
 * drm/WPEViewDRM.cpp:89 each connect notify::toplevel and call wpe_view_map
 * from it. This follows the Wayland one, which is the sibling this backend is
 * modelled on.
 *
 * THE SIZE IS SET BEFORE THE MAP, in that order, because WebKit reads the
 * view's size when visibility turns on. Mapping first means the first paint
 * uses whatever size the view had before -- 0x0 on a new view -- and the page
 * lays out for a window that does not exist.
 *
 * THE CHROME COMES OFF HERE TOO. The toplevel's size includes the strip; the
 * view only ever gets what is left under it. This is the same subtraction as
 * xdgSurfaceConfigure and wpeToplevelVeronResize, and all three have to agree.
 *
 * notify::screen IS DELIBERATELY NOT CONNECTED, and that is a difference from
 * the stock backend rather than an omission. WPEViewWayland connects it and
 * UNMAPS when wpe_view_get_screen returns NULL -- which it can afford because
 * it implements WPEToplevelClass::get_screen. This backend does not, so
 * wpe_view_get_screen is NULL forever, and copying that handler would unmap
 * the view the first time the property was notified. WebKit already handles a
 * screenless view: WPEWebViewPlatform.cpp:83 falls back to the primary display
 * id. Screens are worth implementing and are not this change. */
static void veronViewToplevelChanged(WPEView *view, GParamSpec *pspec, gpointer data)
{
    WPEToplevel *toplevel = wpe_view_get_toplevel(view);
    if (!toplevel) {
        wpe_view_unmap(view);
        return;
    }

    int width = 0, height = 0;
    wpe_toplevel_get_size(toplevel, &width, &height);
    if (width > 0 && height > 0) {
        int pageHeight = height -
            (int)wpe_toplevel_veron_get_chrome_height(WPE_TOPLEVEL_VERON(toplevel));
        if (pageHeight < 1)
            pageHeight = 1;
        wpe_view_resized(view, width, pageHeight);
    }

    wpe_view_map(view);
}

static void wpeViewVeronConstructed(GObject *object)
{
    G_OBJECT_CLASS(wpe_view_veron_parent_class)->constructed(object);
    g_signal_connect(object, "notify::toplevel",
                     G_CALLBACK(veronViewToplevelChanged), NULL);
}

static void wpe_view_veron_dispose(GObject *object)
{
    WPEViewVeron *self = WPE_VIEW_VERON(object);
    g_clear_pointer(&self->frameCallback, wl_callback_destroy);
    G_OBJECT_CLASS(wpe_view_veron_parent_class)->dispose(object);
}

static void wpe_view_veron_class_init(WPEViewVeronClass *klass)
{
    G_OBJECT_CLASS(klass)->constructed = wpeViewVeronConstructed;
    G_OBJECT_CLASS(klass)->dispose = wpe_view_veron_dispose;
    WPE_VIEW_CLASS(klass)->render_buffer = wpeViewVeronRenderBuffer;
}
