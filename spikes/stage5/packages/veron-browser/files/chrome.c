/* The chrome strip: a Cairo drawing on a Wayland surface.
 *
 * WHAT THIS DRAWS. A back button, a forward button, a reload button and a URL
 * field, across the top of the window. The page is a subsurface below it --
 * see wpe-platform-veron -- so nothing here overlaps the web content and
 * nothing here has to hit-test against it.
 *
 * WHY CAIRO AND NOT A TOOLKIT. FLTK is in this package set and would draw
 * widgets, but it wants to own a window and an event loop, and this already
 * has both. Cairo draws into a buffer we allocate and hands it back; that is
 * the whole requirement. A toolkit would be a second opinion about who owns
 * the toplevel.
 *
 * DOUBLE BUFFERING IS NOT IMPLEMENTED AND DOES NOT NEED TO BE. The strip
 * repaints when the URL, the title or the focus changes -- a few times a
 * second at most, never per frame. One buffer, redrawn in place, with the
 * compositor's release tracked so it is never written mid-scanout.
 */
/* _GNU_SOURCE BEFORE ANY HEADER, for memfd_create and the MFD_* flags -- they
 * are behind it in glibc's sys/mman.h. It has to come before the first include
 * because the feature test macros are read when features.h is first pulled in,
 * so putting it beside the other defines further down does nothing. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include "chrome.h"

#include <cairo/cairo.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>

#define CHROME_HEIGHT 40
#define BTN_W         34
#define PAD           6

struct _VeronChrome {
    struct wl_surface  *surface;
    struct wl_shm      *shm;

    struct wl_buffer   *buffer;
    struct wl_shm_pool *pool;
    unsigned char      *data;
    int                 width, height, stride;
    size_t              size;
    gboolean            busy;

    cairo_surface_t    *cairo;

    /* WHAT IS SHOWN. url is what the page reports; editing is what the user
     * has typed and has not yet committed. They are separate because a page
     * that navigates while you are typing must not overwrite the field. */
    char               *url;
    GString            *editing;
    gboolean            focused;
    int                 caret;

    gboolean            canBack, canForward, loading;
    double              progress;

    VeronChromeCallbacks cb;
    gpointer             userData;
};

/* ---- the buffer ------------------------------------------------------ */

static void chromeBufferRelease(void *data, struct wl_buffer *buffer)
{
    VeronChrome *c = data;
    c->busy = FALSE;
}

static const struct wl_buffer_listener bufferListener = { chromeBufferRelease };

static int anonFile(size_t size)
{
    int fd = memfd_create("veron-chrome", MFD_CLOEXEC);
    if (fd < 0)
        return -1;
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static gboolean chromeEnsureBuffer(VeronChrome *c, int width, int height)
{
    if (c->buffer && c->width == width && c->height == height)
        return TRUE;

    g_clear_pointer(&c->cairo, cairo_surface_destroy);
    g_clear_pointer(&c->buffer, wl_buffer_destroy);
    g_clear_pointer(&c->pool, wl_shm_pool_destroy);
    if (c->data) {
        munmap(c->data, c->size);
        c->data = NULL;
    }

    c->width  = width;
    c->height = height;
    c->stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width);
    c->size   = (size_t)c->stride * (size_t)height;

    int fd = anonFile(c->size);
    if (fd < 0)
        return FALSE;

    c->data = mmap(NULL, c->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (c->data == MAP_FAILED) {
        c->data = NULL;
        close(fd);
        return FALSE;
    }

    c->pool = wl_shm_create_pool(c->shm, fd, (int32_t)c->size);
    close(fd);

    c->buffer = wl_shm_pool_create_buffer(c->pool, 0, width, height,
                                          c->stride, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(c->buffer, &bufferListener, c);

    /* CAIRO DRAWS STRAIGHT INTO THE MAPPED PAGES. No intermediate image and no
     * copy: cairo_image_surface_create_for_data wraps the same memory the
     * compositor will read. That is why the stride has to come from Cairo
     * rather than being width*4 -- it aligns rows for its own SIMD paths. */
    c->cairo = cairo_image_surface_create_for_data(c->data, CAIRO_FORMAT_ARGB32,
                                                   width, height, c->stride);
    return c->cairo != NULL;
}

/* ---- drawing --------------------------------------------------------- */

static void roundedRect(cairo_t *cr, double x, double y, double w, double h, double r)
{
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r,     r, -G_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r,     y + h - r, r, G_PI / 2, G_PI);
    cairo_arc(cr, x + r,     y + r,     r, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

static void drawArrow(cairo_t *cr, double cx, double cy, gboolean forward, gboolean enabled)
{
    cairo_set_source_rgb(cr, enabled ? 0.15 : 0.65, enabled ? 0.15 : 0.65, enabled ? 0.15 : 0.65);
    cairo_set_line_width(cr, 2.0);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    double d = forward ? 1.0 : -1.0;
    cairo_move_to(cr, cx + d * 3, cy - 5);
    cairo_line_to(cr, cx - d * 3, cy);
    cairo_line_to(cr, cx + d * 3, cy + 5);
    cairo_stroke(cr);
}

static void drawReload(cairo_t *cr, double cx, double cy, gboolean loading)
{
    cairo_set_source_rgb(cr, 0.15, 0.15, 0.15);
    cairo_set_line_width(cr, 2.0);
    if (loading) {
        /* AN X WHILE LOADING, because the button means "stop" then. A spinner
         * would need an animation timer and a repaint per frame, which is a
         * lot of machinery for a control whose state the user already knows
         * from the progress bar. */
        cairo_move_to(cr, cx - 4, cy - 4); cairo_line_to(cr, cx + 4, cy + 4);
        cairo_move_to(cr, cx + 4, cy - 4); cairo_line_to(cr, cx - 4, cy + 4);
    } else {
        cairo_arc(cr, cx, cy, 5.5, G_PI * 0.35, G_PI * 1.9);
        cairo_move_to(cr, cx + 5.5, cy - 3);
        cairo_line_to(cr, cx + 5.5, cy + 1);
        cairo_line_to(cr, cx + 1.5, cy - 1);
    }
    cairo_stroke(cr);
}

void veron_chrome_draw(VeronChrome *c, int width)
{
    if (c->busy)
        return;
    if (!chromeEnsureBuffer(c, width, CHROME_HEIGHT))
        return;

    cairo_t *cr = cairo_create(c->cairo);

    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgb(cr, 0.93, 0.93, 0.94);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    double y = CHROME_HEIGHT / 2.0;
    drawArrow(cr, PAD + BTN_W * 0.5,     y, FALSE, c->canBack);
    drawArrow(cr, PAD + BTN_W * 1.5,     y, TRUE,  c->canForward);
    drawReload(cr, PAD + BTN_W * 2.5,    y, c->loading);

    double fx = PAD + BTN_W * 3 + PAD;
    double fw = width - fx - PAD;
    if (fw < 40)
        fw = 40;

    roundedRect(cr, fx, 6, fw, CHROME_HEIGHT - 12, 5);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_fill_preserve(cr);
    cairo_set_source_rgb(cr, c->focused ? 0.20 : 0.75,
                             c->focused ? 0.45 : 0.75,
                             c->focused ? 0.85 : 0.75);
    cairo_set_line_width(cr, c->focused ? 1.6 : 1.0);
    cairo_stroke(cr);

    /* THE PROGRESS BAR LIVES INSIDE THE FIELD, which is where a user already
     * looks and costs no extra height. It is drawn under the text so it never
     * obscures the URL. */
    if (c->loading && c->progress > 0.0 && c->progress < 1.0) {
        cairo_save(cr);
        roundedRect(cr, fx, 6, fw, CHROME_HEIGHT - 12, 5);
        cairo_clip(cr);
        cairo_set_source_rgba(cr, 0.20, 0.45, 0.85, 0.18);
        cairo_rectangle(cr, fx, 6, fw * c->progress, CHROME_HEIGHT - 12);
        cairo_fill(cr);
        cairo_restore(cr);
    }

    const char *text = c->focused ? c->editing->str : (c->url ? c->url : "");

    cairo_save(cr);
    roundedRect(cr, fx + 4, 6, fw - 8, CHROME_HEIGHT - 12, 5);
    cairo_clip(cr);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 14.0);
    cairo_set_source_rgb(cr, 0.1, 0.1, 0.1);

    cairo_font_extents_t fe;
    cairo_font_extents(cr, &fe);
    double ty = y + fe.height / 2 - fe.descent;

    cairo_move_to(cr, fx + 8, ty);
    cairo_show_text(cr, text);

    if (c->focused) {
        /* THE CARET IS MEASURED, NOT ESTIMATED. cairo_text_extents on the text
         * before the caret gives its exact x -- a fixed advance per character
         * would drift on any proportional font, and this one is proportional. */
        char *before = g_strndup(c->editing->str, c->caret);
        cairo_text_extents_t te;
        cairo_text_extents(cr, before, &te);
        double caretX = fx + 8 + te.x_advance;
        g_free(before);

        cairo_set_line_width(cr, 1.0);
        cairo_set_source_rgb(cr, 0.1, 0.1, 0.1);
        cairo_move_to(cr, caretX + 0.5, 10);
        cairo_line_to(cr, caretX + 0.5, CHROME_HEIGHT - 10);
        cairo_stroke(cr);
    }
    cairo_restore(cr);

    cairo_destroy(cr);
    cairo_surface_flush(c->cairo);

    wl_surface_attach(c->surface, c->buffer, 0, 0);
    wl_surface_damage_buffer(c->surface, 0, 0, width, CHROME_HEIGHT);
    wl_surface_commit(c->surface);
    c->busy = TRUE;
}

/* ---- hit testing ----------------------------------------------------- */

VeronChromeHit veron_chrome_hit(VeronChrome *c, double x, double y)
{
    if (y < 0 || y >= CHROME_HEIGHT)
        return VERON_CHROME_NONE;
    if (x < PAD)
        return VERON_CHROME_NONE;

    double rel = x - PAD;
    if (rel < BTN_W)     return VERON_CHROME_BACK;
    if (rel < BTN_W * 2) return VERON_CHROME_FORWARD;
    if (rel < BTN_W * 3) return VERON_CHROME_RELOAD;
    if (x >= PAD + BTN_W * 3 + PAD) return VERON_CHROME_URL;
    return VERON_CHROME_NONE;
}

guint veron_chrome_height(void) { return CHROME_HEIGHT; }

/* ---- state ----------------------------------------------------------- */

void veron_chrome_set_url(VeronChrome *c, const char *url)
{
    g_free(c->url);
    c->url = g_strdup(url ? url : "");
    /* TYPING IS NOT INTERRUPTED. A page that redirects while the user is
     * mid-URL must not replace what they are typing; the field only follows
     * the page when it does not have focus. */
    if (!c->focused) {
        g_string_assign(c->editing, c->url);
        c->caret = (int)c->editing->len;
    }
}

void veron_chrome_set_navigation(VeronChrome *c, gboolean back, gboolean forward)
{
    c->canBack = back;
    c->canForward = forward;
}

void veron_chrome_set_loading(VeronChrome *c, gboolean loading, double progress)
{
    c->loading = loading;
    c->progress = progress;
}

void veron_chrome_set_focused(VeronChrome *c, gboolean focused)
{
    if (c->focused == focused)
        return;
    c->focused = focused;
    if (focused) {
        g_string_assign(c->editing, c->url ? c->url : "");
        c->caret = (int)c->editing->len;
    }
}

gboolean veron_chrome_focused(VeronChrome *c) { return c->focused; }

const char *veron_chrome_text(VeronChrome *c) { return c->editing->str; }

/* ---- text editing ---------------------------------------------------- */

void veron_chrome_insert(VeronChrome *c, const char *utf8)
{
    if (!utf8 || !*utf8)
        return;
    g_string_insert(c->editing, c->caret, utf8);
    c->caret += (int)strlen(utf8);
}

void veron_chrome_backspace(VeronChrome *c)
{
    if (c->caret <= 0)
        return;
    /* ONE CHARACTER, NOT ONE BYTE. g_utf8_prev_char walks back over a
     * multi-byte sequence; deleting a byte would leave an invalid string that
     * Cairo then refuses to draw, so the field would go blank on the first
     * accented character. */
    const char *start = c->editing->str;
    const char *at = start + c->caret;
    const char *prev = g_utf8_prev_char(at);
    int n = (int)(at - prev);
    g_string_erase(c->editing, c->caret - n, n);
    c->caret -= n;
}

void veron_chrome_delete(VeronChrome *c)
{
    if (c->caret >= (int)c->editing->len)
        return;
    const char *at = c->editing->str + c->caret;
    const char *next = g_utf8_next_char(at);
    g_string_erase(c->editing, c->caret, (int)(next - at));
}

void veron_chrome_move_caret(VeronChrome *c, int direction, gboolean toEnd)
{
    if (toEnd) {
        c->caret = direction < 0 ? 0 : (int)c->editing->len;
        return;
    }
    const char *start = c->editing->str;
    if (direction < 0 && c->caret > 0)
        c->caret = (int)(g_utf8_prev_char(start + c->caret) - start);
    else if (direction > 0 && c->caret < (int)c->editing->len)
        c->caret = (int)(g_utf8_next_char(start + c->caret) - start);
}

/* ---- lifetime -------------------------------------------------------- */

VeronChrome *veron_chrome_new(struct wl_surface *surface, struct wl_shm *shm)
{
    VeronChrome *c = g_new0(VeronChrome, 1);
    c->surface = surface;
    c->shm     = shm;
    c->editing = g_string_new("");
    c->url     = g_strdup("");
    return c;
}

void veron_chrome_free(VeronChrome *c)
{
    if (!c)
        return;
    g_clear_pointer(&c->cairo, cairo_surface_destroy);
    g_clear_pointer(&c->buffer, wl_buffer_destroy);
    g_clear_pointer(&c->pool, wl_shm_pool_destroy);
    if (c->data)
        munmap(c->data, c->size);
    g_string_free(c->editing, TRUE);
    g_free(c->url);
    g_free(c);
}
