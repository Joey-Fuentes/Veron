/* The shared-memory buffer path.
 *
 * WHEN THIS IS USED. DMABuf is the normal path on this hardware -- mesa hands
 * WebKit a GPU buffer and the compositor scans it out without a copy. SHM is
 * what happens when there is no GPU path: llvmpipe, a compositor without
 * linux-dmabuf, or a machine where EGL failed. It is slower by a memcpy per
 * frame and it is the difference between a working browser and a blank window.
 *
 * ONE FORMAT EXISTS. WPEBufferSHM.h:49 defines exactly WPE_PIXEL_FORMAT_ARGB8888
 * and nothing else, so this converts one thing and refuses the rest rather than
 * pretending to be general.
 *
 * A POOL PER BUFFER, NOT PER FRAME. WebKit recycles a small set of buffers, so
 * the wl_shm_pool is created once and cached on the WPEBuffer; the per-frame
 * cost is the memcpy into it. Creating a pool per frame means a file descriptor
 * per frame, and the client hits its fd limit in about a minute.
 */
/* _GNU_SOURCE BEFORE ANY HEADER. memfd_create and its MFD_* flags are behind
 * it in glibc's sys/mman.h, and without it the compiler takes memfd_create for
 * an implicit int-returning function and MFD_CLOEXEC for an undeclared
 * identifier -- which is exactly how this failed. It has to come before the
 * first include, not beside the others, because the feature test macros are
 * read when features.h is first pulled in. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include "wpe-veron-private.h"

#include <wayland-client.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef struct {
    struct wl_buffer   *wlBuffer;
    struct wl_shm_pool *pool;
    void               *data;
    size_t              size;
    /* WHETHER THE COMPOSITOR IS STILL READING IT. wl_buffer.release says it
     * has finished; until then the memory must not be written. Without this
     * flag a fast page can memcpy over a buffer mid-scanout, which shows as
     * tearing or a frame from the wrong moment -- and only on the SHM path,
     * so only on machines without a GPU, which is exactly where nobody
     * looks. */
    gboolean            busy;
    /* WHO TO TELL WHEN IT COMES BACK.
     *
     * THE VIEW IS WEAK AND THE BUFFER IS NOT, and the asymmetry is the point.
     * This struct is owned BY the WPEBuffer through wpe_buffer_set_user_data,
     * so it cannot outlive it and that pointer is always good. The VIEW can
     * die first -- close a window while the compositor still holds its last
     * frame and the release arrives afterwards -- so it is nulled by GObject
     * rather than left dangling. Same reason the stock backend keeps a
     * GWeakPtr (WPEViewWayland.cpp:193) instead of a raw one. */
    WPEView            *view;    /* weak */
    WPEBuffer          *buffer;
} VeronSHMBuffer;

static void shmBufferRelease(void *data, struct wl_buffer *wlBuffer)
{
    VeronSHMBuffer *b = data;
    if (!b)
        return;
    b->busy = FALSE;

    /* AND TELL WPE, which this did not do. Clearing `busy` lets THIS file
     * reuse the pool; it does nothing for WebKit, which has its own pool and
     * waits for wpe_view_buffer_released before putting a buffer back in it.
     * Without this the SHM path leaks buffers exactly the way the DMABuf path
     * did -- slower, because llvmpipe is slower, and no less certain. */
    if (b->view && b->buffer)
        wpe_view_buffer_released(b->view, b->buffer);
}

static const struct wl_buffer_listener shmBufferListener = { shmBufferRelease };

static void veronSHMBufferFree(gpointer ptr)
{
    VeronSHMBuffer *b = ptr;
    if (!b)
        return;
    if (b->view)
        g_object_remove_weak_pointer(G_OBJECT(b->view), (gpointer *)&b->view);
    g_clear_pointer(&b->wlBuffer, wl_buffer_destroy);
    g_clear_pointer(&b->pool, wl_shm_pool_destroy);
    if (b->data && b->data != MAP_FAILED)
        munmap(b->data, b->size);
    g_free(b);
}

/* AN ANONYMOUS FILE, PREFERRING memfd. memfd_create needs no filesystem and no
 * name to collide with; shm_open is the fallback for kernels without it, and
 * the file is unlinked immediately so nothing is left behind if this crashes. */
static int veronAnonFile(size_t size)
{
    int fd = -1;

#ifdef __linux__
    fd = memfd_create("veron-shm", MFD_CLOEXEC | MFD_ALLOW_SEALING);
#endif
    if (fd < 0) {
        char name[] = "/veron-shm-XXXXXX";
        for (int tries = 0; tries < 100 && fd < 0; ++tries) {
            for (char *p = name + 11; *p; ++p)
                *p = 'A' + (g_random_int() % 26);
            fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
            if (fd >= 0)
                shm_unlink(name);
            else if (errno != EEXIST)
                break;
        }
    }
    if (fd < 0)
        return -1;

    /* ftruncate CAN FAIL AND MUST BE CHECKED. A pool sized from a file that
     * was never extended maps successfully and then faults on first write,
     * which presents as a crash in the compositor's address space rather than
     * an error here. */
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

struct wl_buffer *wpeVeronBufferFromSHM(WPEViewVeron *view, WPEBuffer *buffer, GError **error)
{
    WPEBufferSHM *shm = WPE_BUFFER_SHM(buffer);

    if (wpe_buffer_shm_get_format(shm) != WPE_PIXEL_FORMAT_ARGB8888) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: only ARGB8888 shared-memory buffers are supported");
        return NULL;
    }

    GBytes *bytes = wpe_buffer_shm_get_data(shm);
    if (!bytes) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: shared-memory buffer has no data");
        return NULL;
    }

    gsize inSize = 0;
    gconstpointer in = g_bytes_get_data(bytes, &inSize);

    VeronSHMBuffer *cached = wpe_buffer_get_user_data(buffer);
    if (cached) {
        /* THE POOL IS REUSED AND THE PIXELS ARE NOT. WebKit hands back the
         * same WPEBuffer with new contents, so only the copy repeats.
         *
         * BUT NOT WHILE THE COMPOSITOR HOLDS IT. Refusing the frame is the
         * right answer rather than waiting: WebKit will render again, and
         * blocking here would stall the whole main loop -- including the
         * Wayland source that delivers the release this is waiting for, which
         * deadlocks. */
        if (cached->busy) {
            g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
                "veron: shared-memory buffer still held by the compositor");
            return NULL;
        }
        memcpy(cached->data, in, MIN(inSize, cached->size));
        cached->busy = TRUE;
        return cached->wlBuffer;
    }

    int width  = wpe_buffer_get_width(buffer);
    int height = wpe_buffer_get_height(buffer);
    guint stride = wpe_buffer_shm_get_stride(shm);
    size_t size = (size_t)stride * (size_t)height;

    if (width < 1 || height < 1 || !stride || size < inSize) {
        g_set_error(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: implausible shared-memory geometry %dx%d stride %u",
            width, height, stride);
        return NULL;
    }

    int fd = veronAnonFile(size);
    if (fd < 0) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: could not create a shared-memory file");
        return NULL;
    }

    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: could not map the shared-memory file");
        return NULL;
    }

    WPEDisplayVeron *display = WPE_DISPLAY_VERON(wpe_view_get_display(WPE_VIEW(view)));
    struct wl_shm *wlShm = wpeVeronDisplayGetShm(display);
    if (!wlShm) {
        munmap(data, size);
        close(fd);
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: compositor has no wl_shm");
        return NULL;
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(wlShm, fd, (int32_t)size);
    /* THE FD IS OURS TO CLOSE ONCE THE POOL HOLDS IT. wl_shm_create_pool dups
     * what it needs; keeping this open leaks one per buffer. */
    close(fd);

    /* WL_SHM_FORMAT_ARGB8888 IS THE PREMULTIPLIED ONE and matches what WebKit
     * produces. XRGB would drop the alpha channel silently, which shows up as
     * black where a page expected transparency. */
    struct wl_buffer *wlBuffer = wl_shm_pool_create_buffer(pool, 0,
        width, height, (int32_t)stride, WL_SHM_FORMAT_ARGB8888);

    if (!wlBuffer) {
        wl_shm_pool_destroy(pool);
        munmap(data, size);
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
            "veron: could not create a wl_buffer from the pool");
        return NULL;
    }

    memcpy(data, in, MIN(inSize, size));

    VeronSHMBuffer *b = g_new0(VeronSHMBuffer, 1);
    b->wlBuffer = wlBuffer;
    b->pool     = pool;
    b->data     = data;
    b->size     = size;
    b->busy     = TRUE;
    b->view     = WPE_VIEW(view);
    b->buffer   = buffer;
    g_object_add_weak_pointer(G_OBJECT(b->view), (gpointer *)&b->view);
    wl_buffer_add_listener(wlBuffer, &shmBufferListener, b);
    wpe_buffer_set_user_data(buffer, b, veronSHMBufferFree);

    return wlBuffer;
}

/* ---- a flat colour on the toplevel's own surface ----------------------- */

/* WHY THE BACKEND OWNS A BUFFER AT ALL, given the README says drawing belongs
 * to the browser. It does -- the CHROME belongs to the browser, and it still
 * does. This is not chrome. An xdg_toplevel maps when a buffer is attached to
 * its own wl_surface, and a wl_subsurface's buffer does not count. With the
 * page and the chrome both on subsurfaces there is nothing left to map the
 * window, so a client that draws no chrome gets no window at all: MiniBrowser
 * ran happily through three CI runs with no toplevel on screen and nothing in
 * the log, because nothing was wrong except that nobody had painted the parent.
 *
 * OPAQUE WHITE BECAUSE THAT IS WEBKIT'S OWN DEFAULT. WPEViewWayland.cpp:113
 * says so in as many words -- "The web view default background color is opaque
 * white" -- so a page that has not painted yet blends into the background
 * instead of flashing against it.
 *
 * THE CLIENT MAPPING IS KEPT RATHER THAN DROPPED AFTER THE FILL. It could be
 * munmapped -- the compositor maps the fd itself -- but keeping it means a
 * repaint on resize is a memcpy instead of a new pool, and it makes the
 * lifetime obvious: one struct owns the pool, the buffer and the memory, and
 * frees all three together. */
struct _VeronSolidBuffer {
    struct wl_buffer   *wlBuffer;
    struct wl_shm_pool *pool;
    void               *data;
    size_t              size;
};

VeronSolidBuffer *wpeVeronSolidBufferNew(struct wl_shm *shm, int width, int height,
                                         guint32 argb)
{
    if (!shm || width < 1 || height < 1)
        return NULL;

    size_t stride = (size_t)width * 4;
    size_t size   = stride * (size_t)height;

    int fd = veronAnonFile(size);
    if (fd < 0)
        return NULL;

    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        return NULL;
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    close(fd);
    if (!pool) {
        munmap(data, size);
        return NULL;
    }

    struct wl_buffer *wlBuffer = wl_shm_pool_create_buffer(pool, 0, width, height,
        (int32_t)stride, WL_SHM_FORMAT_ARGB8888);
    if (!wlBuffer) {
        wl_shm_pool_destroy(pool);
        munmap(data, size);
        return NULL;
    }

    /* A WORD AT A TIME, NOT memset. memset writes one byte and this is a
     * 32-bit pixel; filling 0xFFFFFFFF happens to survive it and any other
     * colour would come out as a grey the caller never asked for. */
    guint32 *px = data;
    for (size_t i = 0; i < size / 4; ++i)
        px[i] = argb;

    VeronSolidBuffer *b = g_new0(VeronSolidBuffer, 1);
    b->wlBuffer = wlBuffer;
    b->pool     = pool;
    b->data     = data;
    b->size     = size;
    return b;
}

struct wl_buffer *wpeVeronSolidBufferGet(VeronSolidBuffer *buffer)
{
    return buffer ? buffer->wlBuffer : NULL;
}

void wpeVeronSolidBufferFree(VeronSolidBuffer *buffer)
{
    if (!buffer)
        return;
    g_clear_pointer(&buffer->wlBuffer, wl_buffer_destroy);
    g_clear_pointer(&buffer->pool, wl_shm_pool_destroy);
    if (buffer->data && buffer->data != MAP_FAILED)
        munmap(buffer->data, buffer->size);
    g_free(buffer);
}
