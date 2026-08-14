/* Copy and paste, which this backend did not have at all.
 *
 * WHAT WAS MISSING. WPEDisplayClass has a get_clipboard vfunc and this backend
 * did not implement it, and the registry handler never bound
 * wl_data_device_manager. So the browser was sealed off from the system
 * clipboard in both directions: foot and the text editor could exchange text
 * with each other and neither could exchange it with a web page or the URL
 * bar. Every diagnostic command during development had to be typed by hand.
 *
 * THE STOCK BACKEND DOES BOTH -- WPEDisplayWayland.cpp:279 binds the manager,
 * :672 installs the vfunc, and WPEClipboardWayland.cpp is 263 lines of offer
 * and source plumbing. This is the same work in C.
 *
 * NO NEW PACKAGE. wl_data_device_manager is core Wayland: it is in
 * wayland-client-protocol.h, which this backend already includes, so there is
 * no protocol to generate and no dependency to add.
 *
 * THE TWO HALVES ARE NOT SYMMETRIC, and that is the thing to understand
 * before reading further:
 *
 *   PASTING is a READ. The compositor hands us a wl_data_offer describing what
 *   some other client is offering. We ask for it on a pipe, the other client
 *   writes, we read. It blocks, briefly, on a round trip.
 *
 *   COPYING is an OFFER. We create a wl_data_source, advertise the formats,
 *   and hand it to the compositor. Nothing is transferred until somebody
 *   pastes, at which point the compositor calls us back with a file descriptor
 *   to write into -- possibly seconds or minutes later, possibly never.
 *
 * So the data being copied has to be kept alive for as long as we hold the
 * selection, and the send callback has to survive the WPEClipboardContent that
 * produced it.
 */
#include "wpe-veron-private.h"

#include <wayland-client.h>
#include <gio/gunixinputstream.h>
#include <glib-unix.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

/* FIELDS DIRECTLY IN THE INSTANCE, NOT IN PRIVATE DATA. G_DECLARE_FINAL_TYPE
 * means nothing can derive from this, so there is nobody to hide the layout
 * from -- and instance-private with a final type buys an accessor call per
 * field access in exchange for nothing. */
struct _WPEClipboardVeron {
    WPEClipboard parent;

    struct wl_data_device *dataDevice;

    /* WHAT SOMEBODY ELSE IS OFFERING US, and the formats they named. The
     * offer is owned by the compositor until we destroy it. */
    struct wl_data_offer  *offer;
    GPtrArray             *offerFormats;

    /* WHAT WE ARE OFFERING THEM. source is non-NULL exactly while we own the
     * selection; content is the data the send callback will write, and must
     * outlive the call that set it. */
    struct wl_data_source *source;
    WPEClipboardContent   *content;

    WPEDisplayVeron       *display;
};

G_DEFINE_TYPE(WPEClipboardVeron, wpe_clipboard_veron, WPE_TYPE_CLIPBOARD)

#define PRIV(o) WPE_CLIPBOARD_VERON(o)

/* ---- offering data to others (copy) ---------------------------------- */

/* SOMEBODY PASTED AND WANTS THE BYTES NOW.
 *
 * THE WRITE IS TO A PIPE THE COMPOSITOR GAVE US AND IT CAN BLOCK. A reader
 * that asks for the format and then never reads leaves us in write(2)
 * forever, which would hang the browser -- so the descriptor is made
 * non-blocking and a short write is accepted rather than retried indefinitely.
 * Losing the tail of a paste is bad; deadlocking the UI process is worse.
 *
 * CLOSING THE FD IS WHAT ENDS THE TRANSFER. The reader sees EOF and stops.
 * Forgetting it is the classic way a paste appears to hang. */
static void dataSourceSend(void *data, struct wl_data_source *source,
                           const char *mimeType, int32_t fd)
{
    WPEClipboardVeron *priv = PRIV(data);

    if (!priv->content) {
        close(fd);
        return;
    }

    GBytes *bytes = wpe_clipboard_content_get_bytes(priv->content, mimeType);
    if (!bytes) {
        close(fd);
        return;
    }

    gsize len = 0;
    const char *buf = g_bytes_get_data(bytes, &len);

    g_unix_set_fd_nonblocking(fd, TRUE, NULL);
    gsize off = 0;
    while (off < len) {
        gssize n = write(fd, buf + off, len - off);
        if (n > 0) {
            off += (gsize)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        /* EAGAIN on a non-blocking pipe means the reader is not draining.
         * Give up rather than spin: see the comment above. */
        break;
    }

    close(fd);
    g_bytes_unref(bytes);
}

/* THE COMPOSITOR GAVE THE SELECTION TO SOMEBODY ELSE. Our source is dead and
 * must be destroyed; the data it was holding can go. */
/* LOSING THE SELECTION HAS TO BE REPORTED, NOT JUST CLEANED UP.
 *
 * Destroying the source without telling WPE leaves it believing it still owns
 * local content, so the next paste is answered from a clipboard the
 * compositor gave to somebody else. Stock notifies here too
 * (WPEClipboardWayland.cpp:84). */
static void dataSourceCancelled(void *data, struct wl_data_source *source)
{
    WPEClipboardVeron *priv = PRIV(data);
    g_clear_pointer(&priv->source, wl_data_source_destroy);
    g_clear_pointer(&priv->content, wpe_clipboard_content_unref);
    WPE_CLIPBOARD_GET_CLASS(data)->changed(WPE_CLIPBOARD(data), NULL, FALSE, NULL);
}

static void dataSourceTarget(void *data, struct wl_data_source *s, const char *m) { }
static void dataSourceDndDropPerformed(void *data, struct wl_data_source *s) { }
static void dataSourceDndFinished(void *data, struct wl_data_source *s) { }
static void dataSourceAction(void *data, struct wl_data_source *s, uint32_t a) { }

static const struct wl_data_source_listener dataSourceListener = {
    dataSourceTarget,
    dataSourceSend,
    dataSourceCancelled,
    dataSourceDndDropPerformed,
    dataSourceDndFinished,
    dataSourceAction,
};

/* ---- receiving what others offer (paste) ----------------------------- */

/* THE FORMAT STRINGS MUST BE INTERNED, NOT COPIED, AND THIS IS WHY PASTING
 * DID NOTHING AT ALL.
 *
 * wpe_clipboard_read_bytes (WPEClipboard.cpp:272) looks the requested format
 * up like this:
 *
 *     const auto* internalFormat = g_intern_string(format);
 *     if (!priv->formats || !g_ptr_array_find(priv->formats.get(),
 *                                             internalFormat, nullptr))
 *         return nullptr;
 *
 * g_ptr_array_find compares POINTERS. An interned string has one address for
 * a given value, so the comparison works -- but only if what went into the
 * array was interned too. This used g_strdup, so every entry was a fresh
 * allocation that could never match, the lookup failed, and read() was never
 * even reached. The clipboard looked wired up and returned NULL every time.
 *
 * THE DUPLICATE CHECK AND THE OFFER CHECK ARE STOCK'S
 * (WPEClipboardWayland.cpp:99-107). A compositor may announce the same type
 * twice, and offers for a drag-and-drop arrive on the same listener as the
 * selection. */
static void dataOfferOffer(void *data, struct wl_data_offer *offer, const char *mimeType)
{
    WPEClipboardVeron *priv = PRIV(data);
    if (priv->offer != offer || !priv->offerFormats)
        return;

    const char *format = g_intern_string(mimeType);
    if (!g_ptr_array_find(priv->offerFormats, format, NULL))
        g_ptr_array_add(priv->offerFormats, (gpointer)format);
}

static void dataOfferSourceActions(void *data, struct wl_data_offer *o, uint32_t a) { }
static void dataOfferAction(void *data, struct wl_data_offer *o, uint32_t a) { }

static const struct wl_data_offer_listener dataOfferListener = {
    dataOfferOffer,
    dataOfferSourceActions,
    dataOfferAction,
};

/* A NEW OFFER IS ANNOUNCED BEFORE ITS FORMATS ARE. wl_data_device.data_offer
 * arrives first, then one wl_data_offer.offer per MIME type, then
 * wl_data_device.selection tells us what the offer is FOR. The array is
 * created here and consumed there. */
static void dataDeviceDataOffer(void *data, struct wl_data_device *device,
                                struct wl_data_offer *offer)
{
    WPEClipboardVeron *priv = PRIV(data);
    g_clear_pointer(&priv->offer, wl_data_offer_destroy);
    if (priv->offerFormats)
        g_ptr_array_unref(priv->offerFormats);
    /* NO FREE FUNC. The entries are interned strings owned by glib for the
     * life of the process; freeing them would be a double free of memory
     * this code does not own. */
    priv->offerFormats = g_ptr_array_new();

    priv->offer = offer;
    wl_data_offer_add_listener(offer, &dataOfferListener, data);
}

/* THE SELECTION CHANGED. A NULL offer means the clipboard was cleared.
 *
 * WE DO NOT TELL WPE ABOUT OUR OWN COPY. When priv->source is set we are the
 * owner, the compositor is echoing our own selection back at us, and
 * reporting it as a change would make WebKit re-read what it just wrote. */
static void dataDeviceSelection(void *data, struct wl_data_device *device,
                                struct wl_data_offer *offer)
{
    WPEClipboard *clipboard = WPE_CLIPBOARD(data);
    WPEClipboardVeron *priv = PRIV(data);

    if (priv->source)
        return;

    GPtrArray *formats = NULL;
    if (offer && offer == priv->offer && priv->offerFormats) {
        /* NULL-TERMINATED, because WPEClipboard treats the array as a strv. */
        g_ptr_array_add(priv->offerFormats, NULL);
        formats = priv->offerFormats;
        priv->offerFormats = NULL;
    } else if (!offer) {
        g_clear_pointer(&priv->offer, wl_data_offer_destroy);
    }

    /* THE PARENT CLASS IS TOLD, NOT OURS. Calling our own changed() would
     * take the local-copy branch and try to claim a selection we do not own.
     * is_local is FALSE here by definition: somebody else put this there. */
    WPE_CLIPBOARD_CLASS(wpe_clipboard_veron_parent_class)
        ->changed(clipboard, formats, FALSE, NULL);

    if (formats)
        g_ptr_array_unref(formats);
}

static void dataDeviceEnter(void *d, struct wl_data_device *dd, uint32_t s,
                            struct wl_surface *su, wl_fixed_t x, wl_fixed_t y,
                            struct wl_data_offer *o) { }
static void dataDeviceLeave(void *d, struct wl_data_device *dd) { }
static void dataDeviceMotion(void *d, struct wl_data_device *dd, uint32_t t,
                             wl_fixed_t x, wl_fixed_t y) { }
static void dataDeviceDrop(void *d, struct wl_data_device *dd) { }

static const struct wl_data_device_listener dataDeviceListener = {
    dataDeviceDataOffer,
    dataDeviceEnter,
    dataDeviceLeave,
    dataDeviceMotion,
    dataDeviceDrop,
    dataDeviceSelection,
};

/* ---- the vfuncs ------------------------------------------------------ */

/* PASTING BLOCKS ON A ROUND TRIP AND THERE IS NO WAY AROUND IT. WPEClipboard's
 * read vfunc is synchronous: it returns the bytes. So the pipe is handed to
 * the other client, the display is flushed, and the read completes before this
 * returns. The stock backend does exactly the same thing. */
static GBytes *wpeClipboardVeronRead(WPEClipboard *clipboard, const char *format)
{
    WPEClipboardVeron *priv = PRIV(clipboard);
    if (!priv->offer || !format)
        return NULL;

    int fds[2];
    if (!g_unix_open_pipe(fds, FD_CLOEXEC, NULL))
        return NULL;

    wl_data_offer_receive(priv->offer, format, fds[1]);
    close(fds[1]);

    /* THE ROUNDTRIP IS WHAT MAKES THE OTHER CLIENT WRITE. Without it the
     * receive request sits in our output buffer and the read below blocks
     * forever on a pipe nobody is filling. */
    wl_display_roundtrip(wpeVeronDisplayGetWlDisplay(priv->display));

    GInputStream *in = g_unix_input_stream_new(fds[0], TRUE);
    GOutputStream *out = g_memory_output_stream_new_resizable();
    gssize spliced = g_output_stream_splice(out, in,
        G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET,
        NULL, NULL);

    GBytes *bytes = NULL;
    if (spliced >= 0)
        bytes = g_memory_output_stream_steal_as_bytes(G_MEMORY_OUTPUT_STREAM(out));

    g_object_unref(in);
    g_object_unref(out);
    return bytes;
}

/* WebKit HAS PUT SOMETHING ON THE CLIPBOARD. Advertise it.
 *
 * is_local IS THE WHOLE DECISION HERE. TRUE means the change came from us and
 * we should claim the selection; FALSE means we are being told about somebody
 * else's change and there is nothing to offer. */
static void wpeClipboardVeronChanged(WPEClipboard *clipboard, GPtrArray *formats,
                                     gboolean isLocal, WPEClipboardContent *content)
{
    WPEClipboardVeron *priv = PRIV(clipboard);

    /* THE PARENT IS CALLED LAST, AS STOCK DOES (WPEClipboardWayland.cpp:230).
     * It records the formats and content that the read path then consults, so
     * claiming the selection first keeps the compositor's view and WPE's view
     * in the same order they are established. */
    if (!isLocal || !content || !formats) {
        WPE_CLIPBOARD_CLASS(wpe_clipboard_veron_parent_class)
            ->changed(clipboard, formats, isLocal, content);
        return;
    }

    struct wl_data_device_manager *mgr =
        wpeVeronDisplayGetDataDeviceManager(priv->display);
    if (!mgr || !priv->dataDevice)
        return;

    /* THE INCOMING OFFER IS DROPPED TOO. We are taking ownership, so whatever
     * another client was offering is no longer what the clipboard holds --
     * keeping it would let a later read answer from the wrong side. */
    g_clear_pointer(&priv->offer, wl_data_offer_destroy);
    if (priv->offerFormats)
        g_clear_pointer(&priv->offerFormats, g_ptr_array_unref);
    g_clear_pointer(&priv->source, wl_data_source_destroy);
    g_clear_pointer(&priv->content, wpe_clipboard_content_unref);

    priv->source = wl_data_device_manager_create_data_source(mgr);
    if (!priv->source)
        return;

    /* THE CONTENT IS REFERENCED, NOT COPIED. The send callback may run long
     * after this returns -- whenever somebody pastes -- and needs the data
     * still to exist. */
    priv->content = wpe_clipboard_content_ref(content);
    wl_data_source_add_listener(priv->source, &dataSourceListener, clipboard);

    for (guint i = 0; i < formats->len; i++) {
        const char *f = g_ptr_array_index(formats, i);
        if (f)
            wl_data_source_offer(priv->source, f);
    }

    /* THE SERIAL MUST BE A REAL INPUT EVENT'S. A compositor rejects
     * set_selection with a serial it did not issue, silently, which is how a
     * copy that looks correct produces nothing on the other side. */
    /* THE KEYBOARD SERIAL, NOT THE LAST ONE. A pointer serial here is
     * silently refused -- see wpeVeronSeatGetKeyboardSerial. */
    wl_data_device_set_selection(priv->dataDevice, priv->source,
                                 wpeVeronSeatGetKeyboardSerial(
                                     wpeVeronDisplayGetVeronSeat(priv->display)));

    WPE_CLIPBOARD_CLASS(wpe_clipboard_veron_parent_class)
        ->changed(clipboard, formats, isLocal, content);
}

static void wpeClipboardVeronConstructed(GObject *object)
{
    G_OBJECT_CLASS(wpe_clipboard_veron_parent_class)->constructed(object);

    WPEClipboardVeron *priv = PRIV(object);
    priv->display = WPE_DISPLAY_VERON(
        wpe_clipboard_get_display(WPE_CLIPBOARD(object)));

    struct wl_data_device_manager *mgr =
        wpeVeronDisplayGetDataDeviceManager(priv->display);
    struct wl_seat *seat = wpeVeronDisplayGetSeat(priv->display);
    if (!mgr || !seat) {
        /* A COMPOSITOR WITHOUT wl_data_device_manager IS LEGAL AND RARE.
         * Saying so once beats a clipboard that silently does nothing. */
        g_warning("veron: no wl_data_device_manager -- copy and paste will not work");
        return;
    }

    priv->dataDevice = wl_data_device_manager_get_data_device(mgr, seat);
    wl_data_device_add_listener(priv->dataDevice, &dataDeviceListener, object);
}

static void wpeClipboardVeronDispose(GObject *object)
{
    WPEClipboardVeron *priv = PRIV(object);
    g_clear_pointer(&priv->source, wl_data_source_destroy);
    g_clear_pointer(&priv->offer, wl_data_offer_destroy);
    g_clear_pointer(&priv->content, wpe_clipboard_content_unref);
    if (priv->offerFormats)
        g_clear_pointer(&priv->offerFormats, g_ptr_array_unref);
    g_clear_pointer(&priv->dataDevice, wl_data_device_destroy);
    G_OBJECT_CLASS(wpe_clipboard_veron_parent_class)->dispose(object);
}

static void wpe_clipboard_veron_init(WPEClipboardVeron *self) { }

static void wpe_clipboard_veron_class_init(WPEClipboardVeronClass *klass)
{
    G_OBJECT_CLASS(klass)->constructed = wpeClipboardVeronConstructed;
    G_OBJECT_CLASS(klass)->dispose = wpeClipboardVeronDispose;
    WPE_CLIPBOARD_CLASS(klass)->read = wpeClipboardVeronRead;
    WPE_CLIPBOARD_CLASS(klass)->changed = wpeClipboardVeronChanged;
}

WPEClipboard *wpeVeronClipboardNew(WPEDisplayVeron *display)
{
    return WPE_CLIPBOARD(g_object_new(WPE_TYPE_CLIPBOARD_VERON,
                                      "display", display, NULL));
}
