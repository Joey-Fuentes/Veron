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

/* ONE BUFFER DEADLOCKS, AND THAT IS WHY THE STRIP NEVER UPDATED.
 *
 * A wl_buffer may not be drawn into while the compositor is reading it, and
 * the compositor says it has finished by sending wl_buffer.release. With a
 * SINGLE buffer that is a cycle: wlroots holds an shm buffer until a new one
 * is attached, so no release arrives; no release means the deferred redraw
 * never runs; the redraw is what would have attached a new buffer. The strip
 * painted exactly once, at startup, and every update after it -- the URL
 * following a navigation, the focus ring, the caret, every keystroke typed
 * into the field, the width during a resize -- was queued behind a release
 * that was never coming.
 *
 * It looked like a keyboard fault and was not: typing into the PAGE worked
 * the whole time, because WebKit renders through its own buffers and never
 * touches this one.
 *
 * TWO BUFFERS BREAK THE CYCLE. A redraw takes whichever is free, and
 * attaching it is itself what prompts the compositor to release the other.
 * That is the ordinary Wayland client arrangement and this should have been
 * written that way to begin with; deferring the frame was an improvement on
 * dropping it and still assumed a release that a single-buffered client has
 * no way to provoke. */
typedef struct {
    struct wl_buffer   *buffer;
    struct wl_shm_pool *pool;
    unsigned char      *data;
    size_t              size;
    cairo_surface_t    *cairo;
    int                 width, height, stride;
    gboolean            busy;
    VeronChrome        *owner;
} ChromeBuffer;

struct _VeronChrome {
    struct wl_surface  *surface;
    struct wl_shm      *shm;

    ChromeBuffer        buffers[2];
    /* A REDRAW THAT ARRIVED WHILE BOTH BUFFERS WERE HELD. Rare with two, and
     * still recorded rather than dropped. Only the LATEST width matters -- a
     * drag produces a stream of configures and the intermediate ones are
     * already stale. */
    gboolean            pending;
    int                 pendingWidth;

    /* SELECTION IS AN ANCHOR PLUS THE CARET, and nothing else. The selected
     * range is whatever lies between them, so a caret with no selection is
     * simply anchor == caret and there is no second state to keep in step.
     * Storing a start and a length instead is what makes shift+Left at the
     * left edge of a selection ambiguous. */
    int                 anchor;

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
    /* PER-BUFFER USER DATA, NOT THE CHROME. With two buffers the listener has
     * to know WHICH one came back; passing the chrome would clear the wrong
     * flag and hand a busy buffer to the next paint. */
    ChromeBuffer *b = data;
    VeronChrome *c = b->owner;
    b->busy = FALSE;

    /* THE DEFERRED REDRAW HAPPENS HERE, and this is the whole fix. Without it
     * every chrome update that landed during a busy frame was lost for good:
     * the URL bar not following a navigation, the caret not appearing, the
     * progress bar not moving, and -- most visibly -- the strip keeping its
     * old width through a resize while the window grew around it. */
    if (c->pending) {
        c->pending = FALSE;
        veron_chrome_draw(c, c->pendingWidth);
    }
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

static void chromeBufferFree(ChromeBuffer *b)
{
    g_clear_pointer(&b->cairo, cairo_surface_destroy);
    g_clear_pointer(&b->buffer, wl_buffer_destroy);
    g_clear_pointer(&b->pool, wl_shm_pool_destroy);
    if (b->data) {
        munmap(b->data, b->size);
        b->data = NULL;
    }
    b->width = b->height = 0;
    b->busy = FALSE;
}

static gboolean chromeBufferInit(VeronChrome *c, ChromeBuffer *b,
                                 int width, int height)
{
    if (b->buffer && b->width == width && b->height == height)
        return TRUE;

    chromeBufferFree(b);

    b->owner  = c;
    b->width  = width;
    b->height = height;
    b->stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width);
    b->size   = (size_t)b->stride * (size_t)height;

    int fd = anonFile(b->size);
    if (fd < 0)
        return FALSE;

    b->data = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (b->data == MAP_FAILED) {
        b->data = NULL;
        close(fd);
        return FALSE;
    }

    b->pool = wl_shm_create_pool(c->shm, fd, (int32_t)b->size);
    close(fd);

    b->buffer = wl_shm_pool_create_buffer(b->pool, 0, width, height,
                                          b->stride, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(b->buffer, &bufferListener, b);

    /* CAIRO DRAWS STRAIGHT INTO THE MAPPED PAGES. No intermediate image and no
     * copy: cairo_image_surface_create_for_data wraps the same memory the
     * compositor will read. That is why the stride has to come from Cairo
     * rather than being width*4 -- it aligns rows for its own SIMD paths. */
    b->cairo = cairo_image_surface_create_for_data(b->data, CAIRO_FORMAT_ARGB32,
                                                   width, height, b->stride);
    return b->cairo != NULL;
}

/* THE FIRST FREE ONE, OR NULL. Resizing while one is held is why this
 * reinitialises per buffer rather than tearing both down: the held buffer
 * keeps its old size until the compositor is done with it, and is rebuilt at
 * the new size the next time it comes round. */
static ChromeBuffer *chromeAcquire(VeronChrome *c, int width, int height)
{
    for (int i = 0; i < 2; i++) {
        if (c->buffers[i].busy)
            continue;
        if (!chromeBufferInit(c, &c->buffers[i], width, height))
            continue;
        return &c->buffers[i];
    }
    return NULL;
}

/* ---- selection ------------------------------------------------------- */

static void selRange(VeronChrome *c, int *from, int *to)
{
    *from = c->caret < c->anchor ? c->caret : c->anchor;
    *to   = c->caret < c->anchor ? c->anchor : c->caret;
}

gboolean veron_chrome_has_selection(VeronChrome *c)
{
    return c && c->caret != c->anchor;
}

/* DELETING THE SELECTION IS THE FIRST STEP OF ALMOST EVERY EDIT -- typing,
 * backspace, delete and paste all begin by replacing what is selected. Doing
 * it in one place is what stops those four drifting apart. */
static gboolean selDelete(VeronChrome *c)
{
    if (c->caret == c->anchor)
        return FALSE;
    int from, to;
    selRange(c, &from, &to);
    g_string_erase(c->editing, from, to - from);
    c->caret = c->anchor = from;
    return TRUE;
}

void veron_chrome_select_all(VeronChrome *c)
{
    if (!c)
        return;
    c->anchor = 0;
    c->caret  = (int)c->editing->len;
}

/* THE X OF A BYTE OFFSET, AND THE OFFSET AT AN X. Both go through Cairo rather
 * than assuming a fixed advance -- the field is drawn in a proportional font,
 * so an estimate drifts further the longer the URL. */
static double selXForOffset(VeronChrome *c, cairo_t *cr, double textX, int offset)
{
    char *before = g_strndup(c->editing->str, offset);
    cairo_text_extents_t te;
    cairo_text_extents(cr, before, &te);
    g_free(before);
    return textX + te.x_advance;
}

/* THE BYTE OFFSET UNDER AN X, BY MEASURING. Cairo is asked for the width of
 * each prefix and the nearest boundary wins, so a click lands between the two
 * characters it looks like it landed between. Walking by codepoint rather than
 * byte keeps multi-byte characters indivisible.
 *
 * IT NEEDS A cairo_t TO MEASURE WITH and does not have one at click time, so
 * the field's geometry and font are re-established on a throwaway context.
 * They must match veron_chrome_draw exactly; that is the cost of measuring
 * outside the paint. */
static int selOffsetForX(VeronChrome *c, double x)
{
    if (!c->buffers[0].cairo && !c->buffers[1].cairo)
        return (int)c->editing->len;

    cairo_surface_t *tmp = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    cairo_t *cr = cairo_create(tmp);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                           CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 14.0);

    double textX = PAD + BTN_W * 3 + PAD + 8;
    const char *str = c->editing->str;
    int best = 0;
    double bestD = 1e9;

    for (const char *p = str; ; p = g_utf8_next_char(p)) {
        int off = (int)(p - str);
        double px = selXForOffset(c, cr, textX, off);
        double d = px - x;
        if (d < 0)
            d = -d;
        if (d < bestD) {
            bestD = d;
            best = off;
        }
        if (!*p)
            break;
    }

    cairo_destroy(cr);
    cairo_surface_destroy(tmp);
    return best;
}

void veron_chrome_press_at(VeronChrome *c, double x)
{
    if (!c) return;
    c->caret = c->anchor = selOffsetForX(c, x);
}

void veron_chrome_drag_to(VeronChrome *c, double x)
{
    if (!c) return;
    c->caret = selOffsetForX(c, x);
}

/* A DOUBLE CLICK TAKES THE WORD UNDER THE POINTER, and a URL's separators are
 * not a language's -- splitting on spaces alone would select the whole thing.
 * `/`, `.`, `:`, `?`, `&`, `=`, `-` and `_` all end a word here, which is what
 * makes double-clicking a path segment or a query parameter useful. */
static gboolean selIsWordChar(gunichar u)
{
    if (g_unichar_isalnum(u))
        return TRUE;
    return u == '%' || u == '+' || u == '~';
}

void veron_chrome_word_at(VeronChrome *c, double x)
{
    if (!c) return;
    int at = selOffsetForX(c, x);
    const char *str = c->editing->str;
    int len = (int)c->editing->len;

    int from = at;
    while (from > 0) {
        const char *prev = g_utf8_prev_char(str + from);
        if (!selIsWordChar(g_utf8_get_char(prev)))
            break;
        from = (int)(prev - str);
    }
    int to = at;
    while (to < len) {
        const char *p = str + to;
        if (!selIsWordChar(g_utf8_get_char(p)))
            break;
        to = (int)(g_utf8_next_char(p) - str);
    }
    /* A DOUBLE CLICK ON A SEPARATOR SELECTS THE SEPARATOR, not nothing. */
    if (from == to && to < len)
        to = (int)(g_utf8_next_char(str + to) - str);

    c->anchor = from;
    c->caret  = to;
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
    /* THE SIGN WAS BACKWARDS AND BOTH BUTTONS DREW THE WRONG WAY ROUND.
     * With forward=FALSE this produced an apex at cx+3 -- a chevron pointing
     * RIGHT -- and it is the BACK button (chrome.c:281 passes FALSE). So back
     * showed `>` and forward showed `<`, which is the opposite of every
     * browser ever made. The call sites were right; the geometry was not. */
    double d = forward ? -1.0 : 1.0;
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
    /* WAIT, DO NOT DISCARD. A wl_buffer that the compositor is still reading
     * must not be redrawn into or destroyed, so a redraw arriving now cannot
     * happen now -- but returning without recording it means it never happens
     * at all, and nothing retries. Every one of the nine callers of this
     * function was silently unreliable, and a drag-resize made it obvious
     * because configures arrive faster than releases: the strip stayed at the
     * width it had when the drag started while the window kept growing, so
     * the URL field ended in the middle of the window.
     *
     * WITH TWO BUFFERS THIS IS NOW THE RARE PATH rather than the normal one:
     * it takes both being in flight at once, which needs two commits inside a
     * single compositor frame. It is kept because rare is not never, and a
     * dropped frame here is invisible until someone photographs a stale URL
     * bar. */
    ChromeBuffer *b = chromeAcquire(c, width, CHROME_HEIGHT);
    if (!b) {
        c->pending = TRUE;
        c->pendingWidth = width;
        return;
    }

    cairo_t *cr = cairo_create(b->cairo);

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

    /* THE HIGHLIGHT GOES UNDER THE TEXT, so the glyphs stay dark and legible
     * rather than being painted over. Drawn only when focused, because an
     * unfocused field shows the page's URL and has no editing state to
     * select. */
    if (c->focused && c->caret != c->anchor) {
        int from, to;
        selRange(c, &from, &to);
        double x0 = selXForOffset(c, cr, fx + 8, from);
        double x1 = selXForOffset(c, cr, fx + 8, to);
        cairo_set_source_rgb(cr, 0.68, 0.83, 0.99);
        cairo_rectangle(cr, x0, 8, x1 - x0, CHROME_HEIGHT - 16);
        cairo_fill(cr);
        cairo_set_source_rgb(cr, 0.1, 0.1, 0.1);
    }

    cairo_move_to(cr, fx + 8, ty);
    cairo_show_text(cr, text);

    /* NO CARET WHILE A RANGE IS SELECTED. Every text field hides it, and
     * showing both reads as two cursors. */
    if (c->focused && c->caret == c->anchor) {
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
    cairo_surface_flush(b->cairo);

    wl_surface_attach(c->surface, b->buffer, 0, 0);
    wl_surface_damage_buffer(c->surface, 0, 0, width, CHROME_HEIGHT);
    wl_surface_commit(c->surface);
    b->busy = TRUE;
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
        c->anchor = c->caret;
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
    selDelete(c);
    g_string_insert(c->editing, c->caret, utf8);
    c->caret += (int)strlen(utf8);
    c->anchor = c->caret;
}

void veron_chrome_backspace(VeronChrome *c)
{
    /* A SELECTION IS WHAT GETS DELETED, not the character before it. */
    if (selDelete(c))
        return;
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
    c->anchor = c->caret;
}

void veron_chrome_delete(VeronChrome *c)
{
    if (selDelete(c))
        return;
    if (c->caret >= (int)c->editing->len)
        return;
    const char *at = c->editing->str + c->caret;
    const char *next = g_utf8_next_char(at);
    g_string_erase(c->editing, c->caret, (int)(next - at));
}

void veron_chrome_move_caret(VeronChrome *c, int direction, gboolean toEnd)
{
    veron_chrome_move_caret_ex(c, direction, toEnd, FALSE);
}

/* WITHOUT SHIFT, AN ARROW KEY COLLAPSES THE SELECTION TO ITS EDGE rather than
 * moving from the caret. Pressing Left with `example.com` selected puts the
 * caret at the start, not one character back from wherever the caret happened
 * to be -- that is what every text field does and the difference is obvious
 * the first time someone selects and then arrows. */
void veron_chrome_move_caret_ex(VeronChrome *c, int direction, gboolean toEnd,
                                gboolean extend)
{
    if (!extend && c->caret != c->anchor && !toEnd) {
        int from, to;
        selRange(c, &from, &to);
        c->caret = c->anchor = (direction < 0 ? from : to);
        return;
    }

    if (toEnd)
        c->caret = direction < 0 ? 0 : (int)c->editing->len;
    else {
        const char *start = c->editing->str;
        if (direction < 0 && c->caret > 0)
            c->caret = (int)(g_utf8_prev_char(start + c->caret) - start);
        else if (direction > 0 && c->caret < (int)c->editing->len)
            c->caret = (int)(g_utf8_next_char(start + c->caret) - start);
    }

    if (!extend)
        c->anchor = c->caret;
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
    chromeBufferFree(&c->buffers[0]);
    chromeBufferFree(&c->buffers[1]);
    g_string_free(c->editing, TRUE);
    g_free(c->url);
    g_free(c);
}
