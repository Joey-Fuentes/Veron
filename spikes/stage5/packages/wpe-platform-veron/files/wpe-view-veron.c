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

static struct wl_buffer *veronBufferFromDMABuf(WPEViewVeron *self, WPEBuffer *buffer, GError **error)
{
    /* CACHED ON THE BUFFER, because WebKit recycles a small pool of them and
     * building a wl_buffer per frame would leak one per frame. wpe_buffer_set_
     * user_data with a destroy notify is how the stock backend does it and is
     * the only place the lifetime is expressible. */
    struct wl_buffer *cached = wpe_buffer_get_user_data(buffer);
    if (cached)
        return cached;

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

    wpe_buffer_set_user_data(buffer, wlBuffer, (GDestroyNotify)wl_buffer_destroy);
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

static void wpe_view_veron_dispose(GObject *object)
{
    WPEViewVeron *self = WPE_VIEW_VERON(object);
    g_clear_pointer(&self->frameCallback, wl_callback_destroy);
    G_OBJECT_CLASS(wpe_view_veron_parent_class)->dispose(object);
}

static void wpe_view_veron_class_init(WPEViewVeronClass *klass)
{
    G_OBJECT_CLASS(klass)->dispose = wpe_view_veron_dispose;
    WPE_VIEW_CLASS(klass)->render_buffer = wpeViewVeronRenderBuffer;
}
