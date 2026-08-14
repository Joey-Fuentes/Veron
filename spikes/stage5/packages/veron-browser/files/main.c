/* veron-browser: a web browser with a URL bar.
 *
 * HOW THE PIECES FIT. WebKit creates its own WPEView and WPEToplevel on
 * whatever WPEDisplay it is given -- MiniBrowser passes none and gets the
 * default. This passes a WPEDisplayVeron, so the toplevel it builds is one
 * whose page lives in a subsurface with a strip reserved above it. The strip
 * is then ours: chrome.c draws it, and the backend delivers events that land
 * on it as "chrome-event" and "chrome-key" rather than to the page.
 *
 * WHAT MAKES THIS SMALL. Nothing here hit-tests against the web content, and
 * nothing translates coordinates. The compositor knows the page and the strip
 * are different surfaces and says which one an event was on. The whole of the
 * routing is one comparison, in the backend, and this file never sees a click
 * that belonged to the page.
 */
#include "chrome.h"
#include "settings.h"

#include <wpe/wpe-platform.h>
#include <wpe/webkit.h>
#include "wpe-display-veron.h"

#include <libsoup/soup.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <string.h>

typedef struct {
    WPEDisplayVeron  *display;
    WPEToplevelVeron *toplevel;
    WebKitWebView    *webView;
    VeronChrome      *chrome;
    int               width;
    gboolean          selecting;      /* a pointer drag is in progress   */
    guint             lastUrlClick;   /* for the double-click threshold  */
    /* THE LOOP, SO SOMETHING CAN STOP IT. Without a handle here nothing could
     * end the process except a signal, which is why the close button did
     * nothing. */
    GMainLoop        *loop;

    /* THE SETTINGS ARE HELD HERE, NOT RE-READ PER USE. They are consulted on
     * every download and every settings navigation; loading the file each time
     * would make a toggle's effect depend on the filesystem being writable at
     * that instant rather than on what the user chose. */
    VeronSettings     settings;
} Browser;

/* ---- the address the user typed --------------------------------------- */

/* A URL, OR A SEARCH, AND THE RULE IS DELIBERATELY DULL. Anything with a
 * scheme is a URL. Anything with a dot and no space is a hostname and gets
 * https. Everything else is a search. That is wrong for "localhost" and for a
 * bare machine name on a LAN, which is a real cost and a smaller one than
 * guessing: those get a scheme typed, and a mistyped word does not become a
 * DNS lookup that hangs. */
static char *veronResolveInput(const char *input)
{
    /* TRIMMED AT BOTH ENDS BEFORE ANYTHING ELSE. Skipping only leading spaces
     * left trailing ones in the string, so "  example.com  " contained a space
     * and became a search -- and pasting a URL is exactly how trailing
     * whitespace arrives. */
    char *text = g_strstrip(g_strdup(input));
    if (!*text) {
        g_free(text);
        return NULL;
    }

    char *result = NULL;
    if (strstr(text, "://")) {
        result = g_strdup(text);
        g_free(text);
        return result;
    }

    if (g_str_has_prefix(text, "about:") || g_str_has_prefix(text, "file:")
        || g_str_has_prefix(text, "data:")) {
        result = g_strdup(text);
        g_free(text);
        return result;
    }

    /* AN ABSOLUTE PATH IS A FILE, NOT A HOSTNAME, AND THE DOT RULE BELOW
     * CANNOT TELL. `/usr/share/veron/test.html` has a dot and no space, so it
     * took the hostname branch and became `https:///usr/share/veron/test.html`
     * -- which WebKit parsed with `usr` as the host. Run 31723918286 is that
     * bug in one frame: the chrome strip drew, the URL field read
     * `https://usr/share/veron/test.html`, and the page surface stayed empty
     * because the load was still resolving a name that does not exist:
     *
     *     IPv4 DNS error: Error resolving "usr": Temporary failure in name
     *     resolution
     *
     * MiniBrowser never had this because it does not parse -- main.cpp:696
     * hands the argument to g_file_new_for_commandline_arg, which resolves an
     * absolute path to file://. THIS CANNOT USE THAT FUNCTION FOR EVERYTHING:
     * a URL bar given `example.com` would have it turned into a RELATIVE file
     * URI against the working directory, which is worse than the bug being
     * fixed. So the test is the one thing that is unambiguous, a leading
     * slash, and everything else keeps the old rule.
     *
     * g_filename_to_uri RATHER THAN PREPENDING "file://", because it
     * percent-encodes: a path containing a space or a `#` survives it and does
     * not survive concatenation. It returns NULL on a path it cannot convert,
     * and that case falls through to the heuristic rather than returning NULL
     * to the caller, which would silently do nothing. */
    if (g_path_is_absolute(text)) {
        result = g_filename_to_uri(text, NULL, NULL);
        if (result) {
            g_free(text);
            return result;
        }
    }

    gboolean hasSpace = strchr(text, ' ') != NULL;
    gboolean hasDot   = strchr(text, '.') != NULL;

    if (!hasSpace && (hasDot || g_str_has_prefix(text, "localhost"))) {
        result = g_strconcat("https://", text, NULL);
    } else {
        char *escaped = g_uri_escape_string(text, NULL, TRUE);
        result = g_strconcat("https://duckduckgo.com/?q=", escaped, NULL);
        g_free(escaped);
    }

    g_free(text);
    return result;
}

static void browserNavigate(Browser *b)
{
    char *uri = veronResolveInput(veron_chrome_text(b->chrome));
    if (!uri)
        return;

    /* FOCUS LEAVES THE FIELD ON COMMIT, so the page gets the keyboard back and
     * the field starts following the page's URL again. Without this, typing an
     * address and then trying to scroll does nothing. */
    veron_chrome_set_focused(b->chrome, FALSE);
    wpe_toplevel_veron_set_chrome_focus(b->toplevel, FALSE);

    webkit_web_view_load_uri(b->webView, uri);
    g_free(uri);
    veron_chrome_draw(b->chrome, b->width);
}

/* ---- events on the strip ---------------------------------------------- */

/* THE WINDOW WAS CLOSED, AND UNTIL THIS EXISTED NOTHING NOTICED.
 *
 * The chain was already complete on the backend side: labwc's close button
 * sends xdg_toplevel.close, xdgToplevelClose calls wpe_toplevel_closed,
 * WPEToplevel.cpp forwards it to every view as wpe_view_closed, and WPEView
 * emits "closed". Nobody was connected to that signal, so the emission went
 * nowhere and g_main_loop_run kept running a window the compositor had
 * already been asked to destroy. The titlebar button, the menu item and
 * anything else the compositor offers all arrive this way.
 *
 * ON THE VIEW, NOT THE TOPLEVEL. wpe_toplevel_closed does not emit a signal
 * of its own -- it walks its views and closes each one -- so the view is
 * where the notification actually surfaces.
 */
static void onViewClosed(WPEView *view, gpointer data)
{
    Browser *b = data;
    if (b->loop)
        g_main_loop_quit(b->loop);
}

/* JAVASCRIPT window.close() ARRIVES SOMEWHERE ELSE ENTIRELY. It is a WebKit
 * concern rather than a compositor one, so it comes in on the web view and
 * has to be handled separately or a page that closes itself is ignored. */
static void onWebViewClose(WebKitWebView *webView, gpointer data)
{
    Browser *b = data;
    if (b->loop)
        g_main_loop_quit(b->loop);
}

/* THE BACKEND SAW A CLICK LAND ON THE PAGE. It has already stopped routing
 * keys here; this is the half that makes the field look unfocused, because the
 * caret and the blue ring are drawn by this file and the backend cannot know
 * about either. */
static void onChromeFocusLost(WPEToplevelVeron *toplevel, gpointer data)
{
    Browser *b = data;
    if (!veron_chrome_focused(b->chrome))
        return;
    veron_chrome_set_focused(b->chrome, FALSE);
    veron_chrome_draw(b->chrome, b->width);
}

static void onChromeEvent(WPEToplevelVeron *toplevel, guint type, guint time,
                          guint modifiers, guint button, double x, double y,
                          double dx, double dy, gpointer data)
{
    Browser *b = data;

    /* A DRAG IS A MOVE WITH BUTTON 1 HELD, and the backend already puts the
     * button state in the modifier mask, so this needs no press/release
     * bookkeeping of its own. */
    if (type == WPE_EVENT_POINTER_MOVE) {
        if (b->selecting && (modifiers & WPE_MODIFIER_POINTER_BUTTON1)) {
            veron_chrome_drag_to(b->chrome, x);
            veron_chrome_draw(b->chrome, b->width);
        }
        return;
    }
    if (type == WPE_EVENT_POINTER_UP) {
        b->selecting = FALSE;
        return;
    }
    if (type != WPE_EVENT_POINTER_DOWN)
        return;

    VeronChromeHit hit = veron_chrome_hit(b->chrome, x, y);

    switch (hit) {
    case VERON_CHROME_BACK:
        if (webkit_web_view_can_go_back(b->webView))
            webkit_web_view_go_back(b->webView);
        break;
    case VERON_CHROME_FORWARD:
        if (webkit_web_view_can_go_forward(b->webView))
            webkit_web_view_go_forward(b->webView);
        break;
    case VERON_CHROME_RELOAD:
        if (webkit_web_view_is_loading(b->webView))
            webkit_web_view_stop_loading(b->webView);
        else
            webkit_web_view_reload(b->webView);
        break;
    case VERON_CHROME_URL: {
        /* 400 ms IS THE SAME THRESHOLD THE BACKEND USES FOR ITS OWN CLICK
         * COUNT, and the two should not disagree about what a double click
         * is. The backend cannot count these for us: it does not know the
         * chrome has a text field, only that a click landed on the strip. */
        gboolean dbl = (time - b->lastUrlClick) < 400;
        b->lastUrlClick = time;

        gboolean wasFocused = veron_chrome_focused(b->chrome);
        veron_chrome_set_focused(b->chrome, TRUE);

        if (dbl)
            veron_chrome_word_at(b->chrome, x);
        else if (!wasFocused)
            /* THE FIRST CLICK SELECTS THE WHOLE URL, which is what every
             * browser does and what makes typing over it possible without
             * clearing the field by hand first. */
            veron_chrome_select_all(b->chrome);
        else {
            veron_chrome_press_at(b->chrome, x);
            b->selecting = TRUE;
        }
        /* THE BACKEND HAS TO BE TOLD, because the compositor cannot know that
         * a URL field inside our surface wants the keyboard. Wayland routes
         * the pointer for us and cannot route this. */
        wpe_toplevel_veron_set_chrome_focus(b->toplevel, TRUE);
        break;
    }
    case VERON_CHROME_DOWNLOADS:
        /* THE TRAY IS THE DOWNLOADS DIRECTORY, opened in the page. There is no
         * download manager to show and writing one would mean a list widget, a
         * model and per-item controls in a strip 40 pixels tall; the files are
         * already on disk in one place, and WebKit renders a directory listing
         * for a file:// URL without any of that.
         *
         * THE PATH IS BUILT THE SAME WAY onDecideDestination BUILDS IT, so the
         * tray cannot open a different directory from the one downloads land
         * in -- $HOME/Downloads, with the same /tmp fallback. */
        veron_chrome_downloads_acknowledged(b->chrome);
        {
            const char *home = g_get_home_dir();
            char *dir = g_build_filename(home ? home : "/tmp", "Downloads", NULL);
            char *uri = g_filename_to_uri(dir, NULL, NULL);
            if (uri) {
                webkit_web_view_load_uri(b->webView, uri);
                g_free(uri);
            }
            g_free(dir);
        }
        /* THE FIELD GIVES UP THE KEYBOARD, because the click navigated and a
         * caret left blinking in a URL bar that no longer matches the page is
         * the same stale-field problem Escape exists to avoid. */
        veron_chrome_set_focused(b->chrome, FALSE);
        wpe_toplevel_veron_set_chrome_focus(b->toplevel, FALSE);
        break;

    case VERON_CHROME_MENU:
        /* THE MENU IS THE SETTINGS PAGE, and for now that is all it is. A
         * dropdown would need a panel taller than the strip, which cannot be
         * drawn: the page is a sibling subsurface created after the chrome, so
         * Wayland stacks it above and anything painted below y=40 is hidden
         * behind it. A page needs none of that and has room to grow.
         *
         * IT IS A REAL NAVIGATION, so back returns to where you were and the
         * URL bar shows where you are. */
        webkit_web_view_load_uri(b->webView, VERON_SETTINGS_URI);
        veron_chrome_set_focused(b->chrome, FALSE);
        wpe_toplevel_veron_set_chrome_focus(b->toplevel, FALSE);
        break;

    default:
        /* A CLICK ON THE BAR BUT NOT ON ANYTHING GIVES THE PAGE ITS KEYBOARD
         * BACK, which is what every browser does and what a user expects from
         * clicking empty chrome. */
        veron_chrome_set_focused(b->chrome, FALSE);
        wpe_toplevel_veron_set_chrome_focus(b->toplevel, FALSE);
        break;
    }

    veron_chrome_draw(b->chrome, b->width);
}

static void onChromeKey(WPEToplevelVeron *toplevel, guint type, guint time,
                        guint modifiers, guint keycode, guint keyval,
                        gpointer data)
{
    Browser *b = data;

    /* KEY DOWN ONLY. Acting on both would type every character twice, which is
     * the first thing to check if the field fills with doubles. */
    if (type != WPE_EVENT_KEYBOARD_KEY_DOWN)
        return;
    if (!veron_chrome_focused(b->chrome))
        return;

    gboolean shift = (modifiers & WPE_MODIFIER_KEYBOARD_SHIFT) != 0;
    gboolean ctrl  = (modifiers & WPE_MODIFIER_KEYBOARD_CONTROL) != 0;

    /* CONTROL-A BEFORE THE SWITCH, because the plain `a` case below would
     * otherwise insert the letter. Checked on the keysym rather than the
     * keycode so it follows the user's layout. */
    if (ctrl && (keyval == XKB_KEY_a || keyval == XKB_KEY_A)) {
        veron_chrome_select_all(b->chrome);
        veron_chrome_draw(b->chrome, b->width);
        return;
    }
    /* CUT, COPY AND PASTE, ABOVE THE BLANKET REJECTION for the same reason
     * Ctrl-A is: everything below this point treats a control combination as
     * something to discard, and these three are the exceptions that carry
     * data.
     *
     * THE CLIPBOARD BELONGS TO THE DISPLAY, NOT TO THE VIEW. WebKit's own copy
     * and paste inside the page go through this same WPEClipboard, so the URL
     * bar and the page share one selection rather than each having a private
     * one -- which is what makes "copy a link from the page, paste it in the
     * bar" work without a line of code joining them.
     *
     * THERE IS NO wpe_clipboard_set_text. Putting text on the clipboard means
     * building a WPEClipboardContent and handing that over; wpe_clipboard_set_
     * content advertises both text/plain and text/plain;charset=utf-8 on our
     * behalf (WPEClipboard.cpp:227), so neither is named here. */
    if (ctrl && (keyval == XKB_KEY_c || keyval == XKB_KEY_C ||
                 keyval == XKB_KEY_x || keyval == XKB_KEY_X)) {
        gboolean cut = (keyval == XKB_KEY_x || keyval == XKB_KEY_X);

        char *text = veron_chrome_selection(b->chrome);
        if (!text)
            return;

        WPEClipboard *clip = wpe_display_get_clipboard(WPE_DISPLAY(b->display));
        if (clip) {
            WPEClipboardContent *content = wpe_clipboard_content_new();
            wpe_clipboard_content_set_text(content, text);
            wpe_clipboard_set_content(clip, content);
            wpe_clipboard_content_unref(content);
        }
        g_free(text);

        /* CUT COPIES FIRST AND DELETES SECOND, and the order is the whole
         * safety argument: a clipboard that could not be reached leaves the
         * text still in the field rather than destroying it. */
        if (cut && clip) {
            veron_chrome_delete_selection(b->chrome);
            veron_chrome_draw(b->chrome, b->width);
        }
        return;
    }

    if (ctrl && (keyval == XKB_KEY_v || keyval == XKB_KEY_V)) {
        WPEClipboard *clip = wpe_display_get_clipboard(WPE_DISPLAY(b->display));
        if (!clip)
            return;

        /* READ AS BYTES, NOT AS TEXT, AND wpe_clipboard_read_text IS THE TRAP.
         * Its name promises a string and it does not return one: it is
         * read_bytes followed by g_bytes_unref_to_data (WPEClipboard.cpp:310),
         * handing back the raw buffer with a length beside it. Nothing on
         * either path terminates that buffer -- a remote paste is whatever the
         * other client wrote down the pipe, and the local path is a plain
         * write_all of content->text->data() for exactly length() bytes
         * (WPEClipboard.cpp:456). So strlen or strpbrk on that pointer reads
         * off the end of the allocation, and does it invisibly, because
         * allocator slack usually happens to supply a zero.
         *
         * Taking the bytes and copying exactly as many as arrived is correct
         * by construction and costs one allocation.
         *
         * THE UTF-8 FORM IS ASKED FOR FIRST and the short name second. A
         * format the offer does not carry returns NULL rather than failing
         * (the g_ptr_array_find at WPEClipboard.cpp:272), so trying both costs
         * a pointer comparison and covers clients that advertise only one. */
        GBytes *bytes = wpe_clipboard_read_bytes(clip, "text/plain;charset=utf-8");
        if (!bytes)
            bytes = wpe_clipboard_read_bytes(clip, "text/plain");
        if (!bytes)
            return;

        gsize len = 0;
        const char *data = g_bytes_get_data(bytes, &len);
        if (!data || !len) {
            g_bytes_unref(bytes);
            return;
        }

        char *text = g_strndup(data, len);
        g_bytes_unref(bytes);

        /* A URL BAR IS ONE LINE. A multi-line paste keeps the first line
         * rather than embedding a newline in a field with no way to draw one
         * -- and a trailing newline is precisely what copying a URL out of a
         * terminal produces, so this is the common case and not the odd one.
         *
         * The NUL is a cut too: bytes past an embedded NUL are not text this
         * field can hold, and g_strndup already stopped there. */
        char *nl = strpbrk(text, "\r\n");
        if (nl)
            *nl = '\0';

        /* THE INSERT REPLACES THE SELECTION, because veron_chrome_insert
         * begins with selDelete -- so pasting over a selected URL does what a
         * user means without this having to clear the field first. */
        if (*text)
            veron_chrome_insert(b->chrome, text);
        g_free(text);

        veron_chrome_draw(b->chrome, b->width);
        return;
    }

    /* ANY OTHER CONTROL COMBINATION IS NOT TEXT and must not be typed. Without
     * this, Ctrl-C would insert a control character into the field. */
    if (ctrl)
        return;

    switch (keyval) {
    case XKB_KEY_Return:
    case XKB_KEY_KP_Enter:
        browserNavigate(b);
        return;

    case XKB_KEY_Escape:
        /* ESCAPE ABANDONS THE EDIT AND RESTORES THE PAGE'S URL, because
         * set_focused(FALSE) then TRUE would re-copy it -- the field only
         * follows the page while unfocused. */
        veron_chrome_set_focused(b->chrome, FALSE);
        wpe_toplevel_veron_set_chrome_focus(b->toplevel, FALSE);
        break;

    case XKB_KEY_BackSpace: veron_chrome_backspace(b->chrome); break;
    case XKB_KEY_Delete:    veron_chrome_delete(b->chrome);    break;

    /* SHIFT EXTENDS, CONTROL SELECTS EVERYTHING. The modifier mask arrives
     * with the event, so this needs no state of its own -- which matters
     * because a modifier held across a focus change would otherwise stick. */
    case XKB_KEY_Left:
        veron_chrome_move_caret_ex(b->chrome, -1, FALSE, shift); break;
    case XKB_KEY_Right:
        veron_chrome_move_caret_ex(b->chrome,  1, FALSE, shift); break;
    case XKB_KEY_Home:
        veron_chrome_move_caret_ex(b->chrome, -1, TRUE,  shift); break;
    case XKB_KEY_End:
        veron_chrome_move_caret_ex(b->chrome,  1, TRUE,  shift); break;

    default: {
        /* THE KEYSYM BECOMES A CHARACTER, NOT A KEYCODE. xkb_keysym_to_utf32
         * applies the layout and the modifiers, so a French keyboard produces
         * the letters on its own keycaps and Shift produces capitals. Mapping
         * keycodes directly would type QWERTY on every machine. */
        guint32 unicode = xkb_keysym_to_utf32(keyval);
        if (unicode >= 0x20 && unicode != 0x7f) {
            char utf8[8];
            int n = g_unichar_to_utf8((gunichar)unicode, utf8);
            utf8[n] = '\0';
            veron_chrome_insert(b->chrome, utf8);
        } else
            return;
        break;
    }
    }

    veron_chrome_draw(b->chrome, b->width);
}

/* ---- what the page tells us ------------------------------------------- */

static void onUriChanged(WebKitWebView *view, GParamSpec *spec, gpointer data)
{
    Browser *b = data;
    veron_chrome_set_url(b->chrome, webkit_web_view_get_uri(view));
    veron_chrome_set_navigation(b->chrome,
        webkit_web_view_can_go_back(view), webkit_web_view_can_go_forward(view));
    veron_chrome_draw(b->chrome, b->width);
}

/* WHAT THE JAR ACTUALLY HOLDS, ASKED OF THE BROWSER RATHER THAN INFERRED.
 *
 * Four theories have now been refuted by the machine -- the accept policy, the
 * redirect, the ephemeral session, and the filesystem being read-only -- and
 * every one of them looked identical from httpbin's side, because a page can
 * only ever report what it RECEIVED. These three cases are indistinguishable
 * from outside and need different fixes:
 *
 *   stored but not sent      a SameSite or Secure attribute question
 *   never stored             Set-Cookie is reaching the jar and being refused
 *   manager unreachable      the session is not wired up the way we assume
 *
 * webkit_cookie_manager_get_cookies asks the network process directly, so its
 * answer distinguishes all three. Off unless VERON_DEBUG_COOKIES is set. */
static void onCookiesDumped(GObject *manager, GAsyncResult *result, gpointer data)
{
    GError *error = NULL;
    GList *cookies = webkit_cookie_manager_get_cookies_finish(
        WEBKIT_COOKIE_MANAGER(manager), result, &error);

    if (error) {
        g_printerr("veron-cookies: get_cookies failed: %s\n", error->message);
        g_error_free(error);
        return;
    }
    if (!cookies) {
        g_printerr("veron-cookies: jar is EMPTY for %s\n", (const char *)data);
        return;
    }
    for (GList *l = cookies; l; l = l->next) {
        SoupCookie *c = l->data;
        g_printerr("veron-cookies: %s=%s domain=%s path=%s secure=%d httponly=%d\n",
                   soup_cookie_get_name(c), soup_cookie_get_value(c),
                   soup_cookie_get_domain(c), soup_cookie_get_path(c),
                   soup_cookie_get_secure(c), soup_cookie_get_http_only(c));
    }
    g_list_free_full(cookies, (GDestroyNotify)soup_cookie_free);
}

static void browserDumpCookies(Browser *b)
{
    if (!g_getenv("VERON_DEBUG_COOKIES"))
        return;
    const char *uri = webkit_web_view_get_uri(b->webView);
    if (!uri)
        return;
    WebKitCookieManager *cm =
        webkit_network_session_get_cookie_manager(
            webkit_web_view_get_network_session(b->webView));
    webkit_cookie_manager_get_cookies(cm, uri, NULL, onCookiesDumped,
                                      (gpointer)uri);
}

static void onLoadChanged(WebKitWebView *view, WebKitLoadEvent event, gpointer data)
{
    Browser *b = data;
    veron_chrome_set_loading(b->chrome, event != WEBKIT_LOAD_FINISHED,
                             webkit_web_view_get_estimated_load_progress(view));
    /* can_go_back ONLY BECOMES TRUE ONCE A LOAD COMMITS, so the arrows are
     * refreshed here as well as on the URL change. */
    veron_chrome_set_navigation(b->chrome,
        webkit_web_view_can_go_back(view), webkit_web_view_can_go_forward(view));
    veron_chrome_draw(b->chrome, b->width);

    browserDumpCookies(b);
}

static void onProgress(WebKitWebView *view, GParamSpec *spec, gpointer data)
{
    Browser *b = data;
    veron_chrome_set_loading(b->chrome, webkit_web_view_is_loading(view),
                             webkit_web_view_get_estimated_load_progress(view));
    veron_chrome_draw(b->chrome, b->width);
}

static void onTitleChanged(WebKitWebView *view, GParamSpec *spec, gpointer data)
{
    Browser *b = data;
    const char *title = webkit_web_view_get_title(view);
    wpe_toplevel_set_title(WPE_TOPLEVEL(b->toplevel),
                           title && *title ? title : "Veron Browser");
}

/* THE STRIP IS REDRAWN ON EVERY RESIZE, and it has to be: the buffer is sized
 * to the window and a stale one would be stretched or clipped by the
 * compositor. */
/* THE BACKEND TELLS US; THERE IS NO PROPERTY TO WATCH.
 *
 * This was connected to "notify::width" on the toplevel, and WPEToplevel has
 * no width property -- it installs display and max-views and nothing else, and
 * wpe_toplevel_resized emits nothing. The handler never ran, so b->width kept
 * the 1024 it was given at startup and the strip was redrawn at that width for
 * the life of the window however large it got. */
static void onToplevelResized(WPEToplevelVeron *toplevel, guint width,
                              guint height, gpointer data)
{
    Browser *b = data;
    if (width < 1)
        return;
    b->width = (int)width;
    veron_chrome_draw(b->chrome, b->width);
}

/* ---- the user agent ---------------------------------------------------- */

/* WHAT IS ACTUALLY BROKEN, AND IT IS ONE TOKEN. WPE's default is
 *
 *   Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko)
 *   Version/60.5 Safari/605.1.15
 *
 * and the temptation is to read "Safari on Linux" as the fault. It is not.
 * Epiphany -- GNOME Web, a shipped browser millions of people use -- sends the
 * same shape:
 *
 *   Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko)
 *   Version/16.4 Safari/605.1.15
 *
 * and is not treated as a bot. Every WebKit browser on Linux claims Safari,
 * because the alternative is half the web serving degraded markup.
 *
 * THE FAULT IS Version/60.5, WHICH HAS NEVER EXISTED. Real Safari went 15, 16,
 * 17, 18, then to calendar versioning at 26. There has never been a 60.5, and
 * UserAgentGLib.cpp:110 says the number was chosen high on purpose to get past
 * version checks. A version no release ever carried is a far louder signal than
 * the platform token.
 *
 * WHY NOT CLAIM FIREFOX, which was the first answer here and was wrong. A UA is
 * checked against the TLS handshake by anything serious -- Cloudflare and
 * Google both do it. Firefox uses NSS; this uses whatever glib-networking is
 * built on, exactly like Epiphany. Claiming Firefox would CREATE a mismatch
 * between the handshake and the string that does not otherwise exist. Claiming
 * Safari is consistent with the engine that is really here.
 *
 * THE VERSION GOES STALE AND THAT IS ITSELF A SIGNAL. 26.6 was current in
 * August 2026. Bump it when it is wrong by more than a release or two, or set
 * VERON_USER_AGENT and do not wait for a rebuild. */
static void browserSetUserAgent(WebKitWebView *view)
{
    WebKitSettings *settings = webkit_web_view_get_settings(view);

    const char *override = g_getenv("VERON_USER_AGENT");
    if (override && *override) {
        webkit_settings_set_user_agent(settings, override);
        return;
    }

    /* Veron/1.0 SITS BETWEEN Version AND Safari, which is Epiphany's own
     * pattern and the conventional place for a product token. It says which
     * browser this actually is without removing the tokens sites check for:
     * AppleWebKit names the engine truthfully, Safari keeps the markup sane,
     * and Veron says who we are.
     *
     * A TOKEN NOBODY RECOGNISES IS NOT A BOT SIGNAL. Every WebKit browser adds
     * one -- Epiphany, Luakit, surf, Midori -- and detectors read the engine
     * and version tokens, not the vendor string. Removing it would be less
     * honest and no safer. */
    webkit_settings_set_user_agent(settings,
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 "
        "(KHTML, like Gecko) Version/26.6 Veron/1.0 Safari/605.1.15");
}

/* ---- main -------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
 * Settings: applying them, and the page that edits them.
 * ------------------------------------------------------------------------ */

/* THE ENVIRONMENT'S COOKIE POLICY, IN ONE PLACE. This used to be read inline
 * where the session is built, which was fine while it was read once; the
 * settings page re-asserts the policy every time cookies are switched back on,
 * and a second copy of this ladder is how the two would come to disagree.
 *
 *   VERON_COOKIE_POLICY=always          accept everything
 *   VERON_COOKIE_POLICY=no-third-party  first-party only (the default)
 *   VERON_COOKIE_POLICY=never           accept none
 */
static WebKitCookieAcceptPolicy veronCookiePolicy(void)
{
    const char *policy = g_getenv("VERON_COOKIE_POLICY");
    if (policy && !g_strcmp0(policy, "always"))
        return WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS;
    if (policy && !g_strcmp0(policy, "never"))
        return WEBKIT_COOKIE_POLICY_ACCEPT_NEVER;
    return WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY;
}

/* APPLY EVERYTHING, EVERY TIME, rather than applying the one thing that
 * changed. There are four switches; re-asserting all of them costs nothing and
 * removes the class of bug where a setting is correct in the file, correct on
 * the page, and never actually reached WebKit because the toggle that changed
 * it had its own apply path. */
static void browserApplySettings(Browser *b)
{
    WebKitSettings *ws = webkit_web_view_get_settings(b->webView);
    webkit_settings_set_enable_javascript(ws, b->settings.javascript);
    webkit_settings_set_enable_html5_local_storage(ws, b->settings.localStorage);

    /* THE COOKIE POLICY KEEPS ITS ENVIRONMENT OVERRIDE when cookies are on.
     * VERON_COOKIE_POLICY exists because which policy a site needs is an
     * empirical question; the setting answers a different one -- whether to
     * accept any at all -- so "off" wins and "on" defers to the override
     * rather than overwriting it with a third opinion. */
    WebKitCookieManager *cm = webkit_network_session_get_cookie_manager(
        webkit_web_view_get_network_session(b->webView));
    if (!b->settings.cookies)
        webkit_cookie_manager_set_accept_policy(cm, WEBKIT_COOKIE_POLICY_ACCEPT_NEVER);
    else
        webkit_cookie_manager_set_accept_policy(cm, veronCookiePolicy());

    /* THE BUTTON FOLLOWS THE SWITCH. Turning downloads off takes the button
     * out of the strip immediately, which is the visible confirmation that the
     * setting did something. */
    veron_chrome_set_downloads_enabled(b->chrome, b->settings.downloads);
    veron_chrome_draw(b->chrome, b->width);
}

/* THE SETTINGS PAGE IS SERVED, NOT LOADED FROM DISK. It is generated from the
 * current values, so it cannot disagree with them, and there is no file to
 * install, keep in step with the code, or find missing at runtime.
 *
 * A TOGGLE AND THE PAGE ARE THE SAME URL. `veron:settings` renders; the same
 * URL with ?set=&value= applies first and then renders. That is what makes the
 * page work with JavaScript off: a toggle is an ordinary link, and what comes
 * back is the page with the new state already in it. */
static void onVeronScheme(WebKitURISchemeRequest *request, gpointer data)
{
    Browser *b = data;
    const char *uri = webkit_uri_scheme_request_get_uri(request);

    const char *q = uri ? strchr(uri, '?') : NULL;
    if (q) {
        /* g_uri_parse_params RATHER THAN SPLITTING BY HAND, because it decodes
         * percent-escapes and rejects a malformed query instead of silently
         * yielding a key that matches nothing. */
        GHashTable *params = g_uri_parse_params(q + 1, -1, "&",
                                                G_URI_PARAMS_NONE, NULL);
        if (params) {
            const char *key = g_hash_table_lookup(params, "set");
            const char *val = g_hash_table_lookup(params, "value");
            if (key && val) {
                gboolean on = (g_strcmp0(val, "0") != 0);
                if (veron_settings_set(&b->settings, key, on)) {
                    veron_settings_save(&b->settings);
                    browserApplySettings(b);
                }
            }
            g_hash_table_unref(params);
        }
    }

    char *html = veron_settings_html(&b->settings);
    gsize len = strlen(html);

    /* THE STREAM TAKES THE STRING. g_memory_input_stream_new_from_data with
     * g_free as the notify means the HTML is freed when WebKit is done with
     * it, not when this function returns -- the request is served
     * asynchronously and freeing here would hand it a dangling buffer. */
    GInputStream *stream = g_memory_input_stream_new_from_data(html, (gssize)len, g_free);
    webkit_uri_scheme_request_finish(request, stream, (gint64)len, "text/html");
    g_object_unref(stream);
}

/* ---------------------------------------------------------------------------
 * Downloads.
 *
 * WebKit DOES THE TRANSFER AND WE ONLY CHOOSE WHERE IT LANDS. Without a
 * decide-destination handler WebKit has nowhere to put the bytes, so clicking
 * a download link did nothing at all -- no file, no error, no sign anything
 * had been asked for.
 * ------------------------------------------------------------------------ */

/* A NAME THAT DOES NOT OVERWRITE SOMETHING. Two downloads of the same file
 * must not silently clobber, and a page supplies the suggested name, so the
 * name is attacker-influenced. The counter stops at 999 rather than looping
 * forever on a directory that cannot be written to. */
static char *veronDownloadPath(const char *dir, const char *name)
{
    char *base = g_path_get_basename(name && *name ? name : "download");

    /* A SUGGESTED FILENAME IS UNTRUSTED INPUT. g_path_get_basename strips any
     * directory component, so "../../etc/passwd" becomes "passwd" and the
     * file cannot escape the downloads directory however the name is spelled. */
    if (!*base || !g_strcmp0(base, ".") || !g_strcmp0(base, "..")) {
        g_free(base);
        base = g_strdup("download");
    }

    char *path = g_build_filename(dir, base, NULL);
    if (!g_file_test(path, G_FILE_TEST_EXISTS)) {
        g_free(base);
        return path;
    }
    g_free(path);

    char *dot = strrchr(base, '.');
    char *stem = dot && dot != base ? g_strndup(base, dot - base)
                                    : g_strdup(base);
    const char *ext = dot && dot != base ? dot : "";

    for (int i = 1; i < 1000; i++) {
        char *try = g_strdup_printf("%s/%s-%d%s", dir, stem, i, ext);
        if (!g_file_test(try, G_FILE_TEST_EXISTS)) {
            g_free(stem); g_free(base);
            return try;
        }
        g_free(try);
    }
    g_free(stem); g_free(base);
    return NULL;
}

static gboolean onDecideDestination(WebKitDownload *download,
                                    const char *suggested, gpointer data)
{
    Browser *b = data;

    /* $HOME/Downloads, CREATED IF ABSENT. A first boot has no such directory
     * and a download that fails because of that is indistinguishable, to the
     * person clicking, from a download that does nothing. */
    const char *home = g_get_home_dir();
    char *dir = g_build_filename(home ? home : "/tmp", "Downloads", NULL);
    g_mkdir_with_parents(dir, 0755);

    char *path = veronDownloadPath(dir, suggested);
    if (!path) {
        g_warning("veron: no free name for %s in %s", suggested, dir);
        webkit_download_cancel(download);
        g_free(dir);
        return TRUE;
    }

    /* AN ABSOLUTE PATH, NOT A URI, AND UNDER THIS API A URI IS REJECTED.
     * Checked against WebKitDownload.cpp:526 rather than remembered: with
     * ENABLE(2022_GLIB_API) -- which WPE 2.52 builds with -- the function
     * begins
     *
     *     g_return_if_fail(g_path_is_absolute(destination));
     *
     * and the older branch that accepted "file://" is compiled out. So a URI
     * here would trip a glib assertion and set no destination at all.
     * g_build_filename on g_get_home_dir() is absolute, which satisfies it. */
    webkit_download_set_destination(download, path);

    /* NO VISIBLE FEEDBACK YET, AND THAT IS A REAL GAP. The chrome strip has
     * no status line -- there is veron_chrome_set_url, set_loading and
     * set_navigation and nothing that shows a message -- so a download is
     * silent from the person's side except for the file appearing. Adding a
     * status area means layout, drawing and clearing in chrome.c, which is
     * the next increment rather than something to bolt on here. Until then
     * this is at least visible in the log.
     *
     * The `b` parameter is kept for when there IS somewhere to put this. */
    (void)b;
    g_message("veron-download: %s -> %s", suggested ? suggested : "?", path);

    g_free(path);
    g_free(dir);
    return TRUE;
}

/* "finished" IS EMITTED FOR FAILURES TOO, and that is the whole reason this
 * pair needs a flag between them rather than a handler each.
 * webkitDownloadFailed emits FAILED and then immediately emits FINISHED
 * (WebKitDownload.cpp:419-420), so "finished" does not mean "succeeded" and
 * counting it as one puts a green badge on a download that never arrived.
 *
 * THE FLAG LIVES ON THE DOWNLOAD OBJECT, not on the Browser, because several
 * downloads can be in flight and a single "did the last one fail" field would
 * be answered by whichever finished most recently. */
#define VERON_DOWNLOAD_FAILED "veron-download-failed"

static void onDownloadFailed(WebKitDownload *download, GError *error,
                             gpointer data)
{
    (void)data;
    g_warning("veron-download: failed: %s",
              error ? error->message : "unknown");

    g_object_set_data(G_OBJECT(download), VERON_DOWNLOAD_FAILED,
                      GINT_TO_POINTER(1));
    /* THE UI IS NOT TOUCHED HERE. "finished" follows this immediately and
     * does the clearing and the redraw for both outcomes, so doing it twice
     * would be two repaints and two chances to disagree. */
}

static void onDownloadFinished(WebKitDownload *download, gpointer data)
{
    Browser *b = data;
    gboolean failed = g_object_get_data(G_OBJECT(download),
                                        VERON_DOWNLOAD_FAILED) != NULL;

    if (!failed) {
        const char *dest = webkit_download_get_destination(download);
        g_message("veron-download: finished %s", dest ? dest : "?");
    }

    veron_chrome_download_finished(b->chrome, !failed);
    veron_chrome_draw(b->chrome, b->width);
}

/* THE FRACTION CHANGED. WebKitDownload has no progress signal; it has an
 * "estimated-load-progress" PROPERTY, so this is a notify handler rather than
 * a signal handler and the value is read back off the object. */
static void onDownloadProgress(WebKitDownload *download, GParamSpec *spec,
                               gpointer data)
{
    Browser *b = data;
    (void)spec;

    veron_chrome_download_progress(b->chrome,
        webkit_download_get_estimated_progress(download));
    veron_chrome_draw(b->chrome, b->width);
}

static void onDownloadStarted(WebKitWebContext *context,
                              WebKitDownload *download, gpointer data)
{
    Browser *b = data;

    /* DOWNLOADS OFF MEANS THE TRANSFER DOES NOT HAPPEN, not merely that the
     * button is hidden. Cancelling here is before any byte is written and
     * before a destination is chosen, so nothing lands in the filesystem and
     * no partial file is left to explain. */
    if (!b->settings.downloads) {
        g_message("veron-download: refused -- downloads are turned off");
        webkit_download_cancel(download);
        return;
    }

    g_signal_connect(download, "decide-destination",
                     G_CALLBACK(onDecideDestination), data);
    g_signal_connect(download, "finished", G_CALLBACK(onDownloadFinished), data);
    g_signal_connect(download, "failed",   G_CALLBACK(onDownloadFailed),   data);
    g_signal_connect(download, "notify::estimated-progress",
                     G_CALLBACK(onDownloadProgress), data);

    /* THE BUTTON APPEARS HERE, NOT AT decide-destination. A download that is
     * cancelled because its directory cannot be made never reaches a
     * destination, and it is still a thing the user started and should be able
     * to see the outcome of. */
    veron_chrome_download_started(b->chrome);
    veron_chrome_draw(b->chrome, b->width);
}

/* ---------------------------------------------------------------------------
 * The file chooser.
 *
 * THE DEFAULT HANDLER RUNS A GtkFileChooserDialog, which does not exist here.
 * So `<input type="file">` was inert: clicking it did nothing and the page
 * had no way to know why. Returning TRUE from this handler stops the default
 * from being reached at all.
 * ------------------------------------------------------------------------ */
static gboolean onRunFileChooser(WebKitWebView *view,
                                 WebKitFileChooserRequest *request,
                                 gpointer data)
{
    gboolean multiple = webkit_file_chooser_request_get_select_multiple(request);

    char *argv[8];
    int n = 0;
    argv[n++] = (char *)"/usr/bin/veron-filechooser";
    argv[n++] = (char *)"--title";
    argv[n++] = (char *)(multiple ? "Select files to upload"
                                  : "Select a file to upload");
    if (multiple)
        argv[n++] = (char *)"--multiple";
    argv[n] = NULL;

    /* SYNCHRONOUS, BECAUSE THE PAGE IS WAITING. The request must be answered
     * -- selected or cancelled -- and WebKit holds the element until it is.
     * The browser's own loop is blocked meanwhile, which is what a modal file
     * dialog means everywhere else too.
     *
     * G_SPAWN_SEARCH_PATH IS NOT USED. The absolute path is spelled out so
     * this cannot pick up a different veron-filechooser from a PATH the
     * session happened to inherit. */
    char *out = NULL;
    int status = 0;
    GError *err = NULL;

    if (!g_spawn_sync(NULL, argv, NULL, G_SPAWN_DEFAULT, NULL, NULL,
                      &out, NULL, &status, &err)) {
        g_warning("veron: could not run the file chooser: %s",
                  err ? err->message : "unknown");
        g_clear_error(&err);
        webkit_file_chooser_request_cancel(request);
        return TRUE;
    }

    /* A NONZERO EXIT IS A CANCELLATION, NOT AN ERROR. The chooser exits 1
     * when nothing was chosen, which is the ordinary case of a person
     * changing their mind. */
    if (!g_spawn_check_wait_status(status, NULL) || !out || !*out) {
        g_free(out);
        webkit_file_chooser_request_cancel(request);
        return TRUE;
    }

    char **lines = g_strsplit(out, "\n", -1);
    GPtrArray *files = g_ptr_array_new();
    for (int i = 0; lines[i]; i++)
        if (*lines[i])
            g_ptr_array_add(files, lines[i]);
    g_ptr_array_add(files, NULL);

    /* WebKit COPIES THE ARRAY (g_strdup per entry, WebKitFileChooserRequest.cpp
     * :323), so freeing ours immediately after is correct.
     *
     * IT ALSO PERCENT-DECODES WHAT WE PASS. The same loop runs each string
     * through PAL::decodeURLEscapeSequences even though the documented
     * contract is "paths to local files" -- so a file genuinely named
     * `report%20final.pdf` reaches the page as `report final.pdf` and fails
     * to open. Pre-encoding to compensate would corrupt every ordinary path,
     * so this is recorded and left alone: it is upstream's behaviour, and the
     * affected filenames are rare. */
    if (files->len > 1)
        webkit_file_chooser_request_select_files(
            request, (const char * const *)files->pdata);
    else
        webkit_file_chooser_request_cancel(request);

    g_ptr_array_free(files, TRUE);
    g_strfreev(lines);
    g_free(out);
    return TRUE;
}

int main(int argc, char **argv)
{
    /* THE BACKEND IS NAMED EXPLICITLY rather than left to priority. A browser
     * that silently fell back to the stock Wayland backend would run with no
     * URL bar and no explanation, which is a worse failure than not starting. */
    g_setenv("WPE_DISPLAY", "wpe-display-veron", FALSE);

    Browser b = { 0 };

    WPEDisplay *display = wpe_display_get_default();
    if (!display || !WPE_IS_DISPLAY_VERON(display)) {
        g_printerr("veron-browser: the veron display backend did not load.\n"
                   "  Set WPE_PLATFORMS_PATH to the directory holding\n"
                   "  libwpe-display-veron.so, or install it beside the\n"
                   "  built-in WPE platform modules.\n");
        return 1;
    }
    b.display = WPE_DISPLAY_VERON(display);

    /* "display" IS A CONSTRUCT PROPERTY OF WebKitWebView and is the whole
     * binding -- Tools/MiniBrowser/wpe/main.cpp:411 uses the same one. WebKit
     * builds its own WPEView and WPEToplevel on it, which is why nothing here
     * creates either. */
    /* THE SETTINGS ARE READ BEFORE THE SESSION IS BUILT, because which kind of
     * session this is cannot be changed afterwards -- it is a construct
     * property of the web view. Everything else on this struct is applied
     * later, once there is a view and a chrome to apply it to. */
    veron_settings_load(&b.settings);

    /* INCOGNITO BY DEFAULT, ORDINARY ON REQUEST.
     *
     * EPHEMERAL IS THE DEFAULT AND IT IS A DECISION, not an accident of the
     * filesystem. The stock session is persistent and writes to the XDG
     * directories, which on this system land on the tmpfs overlay -- so
     * nothing would survive a reboot anyway. Relying on that would be
     * depending on where /persist happens to be mounted: change it, or change
     * XDG_DATA_HOME, and the browser silently starts keeping history it was
     * never meant to keep. webkit_network_session_new_ephemeral() is the same
     * thing MiniBrowser's --private uses (main.cpp:478).
     *
     * PERSISTENT COSTS THE PRIVACY AND BUYS THE CAPTCHAS BACK. A browser
     * arriving with no cookies on every request looks like automation, and
     * Google will challenge it more often for that reason alone. That is the
     * trade this setting exists to let the user make, in one direction or the
     * other, rather than having it made for them.
     *
     * THE DIRECTORIES ARE NAMED RATHER THAN DEFAULTED. Passing NULL would take
     * WebKit's own XDG defaults, which is the arrangement the paragraph above
     * declines to depend on; naming them puts the jar somewhere this code
     * chose, under the home directory that /persist actually backs. */
    WebKitNetworkSession *session;
    char *dataDir = NULL;

    if (b.settings.persistent) {
        dataDir = g_build_filename(g_get_user_data_dir(), "veron", "browser", NULL);
        char *cacheDir = g_build_filename(g_get_user_cache_dir(), "veron", "browser", NULL);
        g_mkdir_with_parents(dataDir, 0700);
        g_mkdir_with_parents(cacheDir, 0700);
        session = webkit_network_session_new(dataDir, cacheDir);
        g_free(cacheDir);
    } else {
        session = webkit_network_session_new_ephemeral();
    }

    /* ITP OFF IN BOTH MODES, FOR TWO DIFFERENT REASONS. Ephemerally it is
     * pointless state in a session that is supposed to have none. Persistently
     * it is worse than pointless: while ITP is on, a cookie policy of
     * ACCEPT_NO_THIRD_PARTY is ignored and ACCEPT_ALWAYS is used instead
     * (WebKitNetworkSession.cpp:354), so leaving it enabled would quietly
     * overrule the cookie setting on the page. */
    webkit_network_session_set_itp_enabled(session, FALSE);

    /* NO SAVED PASSWORDS, IN EITHER MODE, AND THIS COMMENT USED TO SAY THAT A
     * FUTURE CHANGE TO THE SESSION TYPE MUST NOT QUIETLY TURN IT ON. That
     * change is the line above, so the reason has to stand on its own now:
     * there is no UI anywhere in this browser to list, inspect or delete a
     * stored credential. Writing them to disk would create state the user
     * cannot see and cannot remove, which is a worse bargain than retyping a
     * password. Cookies are different -- they are what "stay signed in" means,
     * and clearing them is one switch on the settings page. */
    webkit_network_session_set_persistent_credential_storage_enabled(session, FALSE);

    /* COOKIES, EXPLICITLY, AND EPHEMERAL DOES NOT MEAN WITHOUT THEM.
     *
     * `httpbin.org/cookies/set/veron/1` redirects to `/cookies` and the second
     * request arrived with `{"cookies": {}}` -- the cookie did not survive a
     * SAME-ORIGIN redirect. That is not a privacy setting working as intended;
     * it is a browser that cannot complete any set-then-read exchange, which
     * is what every sign-in and every bot challenge is built on. Google's
     * refusal is the visible symptom and not a fingerprinting question at all.
     *
     * THE CAUSE IS ONE LINE ABOVE. WebKitNetworkSession.cpp:354 documents it:
     * "while ITP is enabled the accept policy ACCEPT_NO_THIRD_PARTY is ignored
     * and ACCEPT_ALWAYS is used instead". Turning ITP off -- which this does,
     * deliberately, because ITP keeps per-site state in a session that is
     * supposed to have none -- hands cookie policy back to the default, and
     * the default is stricter than anyone here chose.
     *
     * SO THE POLICY IS NOW STATED RATHER THAN INHERITED. Ephemeral keeps the
     * jar in memory and writes nothing to disk; that is the property the
     * recipe's deferral actually asks for, and it survives this. What changes
     * is that cookies are accepted for the life of the process instead of
     * being dropped at the first redirect.
     *
     * OVERRIDABLE WITHOUT A REBUILD, because which policy a given site needs
     * is an empirical question and this machine is a laptop, not CI:
     *
     *   VERON_COOKIE_POLICY=always          accept everything
     *   VERON_COOKIE_POLICY=no-third-party  first-party only (the default)
     *   VERON_COOKIE_POLICY=never           the old behaviour, for comparison
     */
    /* THE LADDER MOVED TO veronCookiePolicy() so the settings page can
     * re-assert exactly this when cookies are switched back on. */
    WebKitCookieManager *cookies = webkit_network_session_get_cookie_manager(session);
    webkit_cookie_manager_set_accept_policy(cookies, veronCookiePolicy());

    /* A PERSISTENT SESSION STILL DOES NOT SAVE COOKIES BY ITSELF, and this is
     * the line that would have been missing. WebKitCookieManager.cpp:191 says
     * it outright: the manager does not store cookies persistently unless this
     * is called. So "keep me signed in" would have produced a session that
     * writes a cache and a history to disk and still loses every login at
     * exit -- the one symptom the setting exists to fix.
     *
     * SQLITE RATHER THAN TEXT because it is what the format is for, and the
     * jar is read once at startup and appended to on every change.
     *
     * NEVER ON AN EPHEMERAL MANAGER. The call has a g_return_if_fail on
     * exactly that (:200), so this is inside the branch rather than guarded
     * after the fact. */
    if (b.settings.persistent && dataDir) {
        char *jar = g_build_filename(dataDir, "cookies.sqlite", NULL);
        webkit_cookie_manager_set_persistent_storage(
            cookies, jar, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
        g_free(jar);
    }
    g_free(dataDir);

    b.webView = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
        "display", display,
        "network-session", session,
        NULL));

    browserSetUserAgent(b.webView);

    WPEView *wpeView = webkit_web_view_get_wpe_view(b.webView);
    if (!wpeView) {
        g_printerr("veron-browser: WebKit built no WPEView.\n");
        return 1;
    }

    /* CREATED BEFORE THE HANDLERS ARE CONNECTED, not just before the run. A
     * page that closes itself during the first load would otherwise reach
     * onWebViewClose with a NULL loop. */
    b.loop = g_main_loop_new(NULL, FALSE);

    b.toplevel = WPE_TOPLEVEL_VERON(wpe_view_get_toplevel(wpeView));
    wpe_toplevel_set_title(WPE_TOPLEVEL(b.toplevel), "Veron Browser");
    wpe_toplevel_resize(WPE_TOPLEVEL(b.toplevel), 1024, 768);
    b.width = 1024;

    /* THE STRIP IS RESERVED BEFORE ANYTHING IS DRAWN. Setting the height moves
     * the page subsurface down and resizes the view, so the page never renders
     * at the wrong size even once. */
    wpe_toplevel_veron_set_chrome_height(b.toplevel, veron_chrome_height());

    b.chrome = veron_chrome_new(
        wpe_toplevel_veron_get_chrome_surface(b.toplevel),
        wpe_display_veron_get_shm(b.display));

    g_signal_connect(b.toplevel, "chrome-event", G_CALLBACK(onChromeEvent), &b);
    g_signal_connect(b.toplevel, "chrome-key",   G_CALLBACK(onChromeKey),   &b);
    g_signal_connect(b.toplevel, "chrome-focus-lost",
                     G_CALLBACK(onChromeFocusLost), &b);
    g_signal_connect(b.toplevel, "chrome-resized", G_CALLBACK(onToplevelResized), &b);

    g_signal_connect(b.webView, "notify::uri",   G_CALLBACK(onUriChanged),   &b);
    g_signal_connect(b.webView, "notify::title", G_CALLBACK(onTitleChanged), &b);
    g_signal_connect(b.webView, "notify::estimated-load-progress",
                     G_CALLBACK(onProgress), &b);
    g_signal_connect(b.webView, "load-changed",  G_CALLBACK(onLoadChanged),  &b);
    g_signal_connect(b.webView, "close",         G_CALLBACK(onWebViewClose), &b);
    g_signal_connect(wpeView,   "closed",        G_CALLBACK(onViewClosed),   &b);
    g_signal_connect(b.webView, "run-file-chooser",
                     G_CALLBACK(onRunFileChooser), &b);

    /* THE DOWNLOAD SIGNAL IS ON THE NETWORK SESSION, AND WAS ON THE CONTEXT.
     *
     * WebKitWebContext::download-started still exists in the documentation
     * and in the source -- inside `#if !ENABLE(2022_GLIB_API)`. WPE 2.52
     * builds WITH that API, so the signal is compiled out of the context
     * entirely and connecting to it does nothing at all: no error, no
     * warning, just a handler that is never called.
     *
     * The visible result was a download landing in /home/veron rather than
     * /home/veron/Downloads -- which is WebKit's own fallback
     * (G_USER_DIRECTORY_DOWNLOAD, and with no user-dirs.dirs in this image
     * glib resolves that to $HOME). The download worked; our handler simply
     * was not in the path.
     *
     * WebKitNetworkSession::download-started, since 2.40, is where it lives
     * now. `session` is the one this browser already created. */
    g_signal_connect(session, "download-started",
                     G_CALLBACK(onDownloadStarted), &b);

    /* APPLIED BEFORE THE FIRST PAGE LOADS. Doing it after would let one page
     * run with JavaScript the user turned off, which is precisely the page a
     * person disabling JavaScript is worried about. The load happened earlier,
     * before the session was built. */
    browserApplySettings(&b);

    /* THE SCHEME IS REGISTERED ON THE CONTEXT, not on the view: it has to
     * exist before anything navigates to it, and the context outlives any one
     * view. NULL destroy notify because `b` is on main's stack and outlives
     * every request. */
    webkit_web_context_register_uri_scheme(
        webkit_web_view_get_context(b.webView), VERON_SCHEME,
        onVeronScheme, &b, NULL);

    const char *start = argc > 1 ? argv[1] : "https://duckduckgo.com";
    char *uri = veronResolveInput(start);
    webkit_web_view_load_uri(b.webView, uri ? uri : start);
    g_free(uri);

    veron_chrome_draw(b.chrome, b.width);

    g_main_loop_run(b.loop);

    veron_chrome_free(b.chrome);
    g_main_loop_unref(b.loop);
    return 0;
}
