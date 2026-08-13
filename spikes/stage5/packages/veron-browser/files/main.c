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

#include <wpe/wpe-platform.h>
#include <wpe/webkit.h>
#include "wpe-display-veron.h"

#include <xkbcommon/xkbcommon-keysyms.h>
#include <string.h>

typedef struct {
    WPEDisplayVeron  *display;
    WPEToplevelVeron *toplevel;
    WebKitWebView    *webView;
    VeronChrome      *chrome;
    int               width;
    /* THE LOOP, SO SOMETHING CAN STOP IT. Without a handle here nothing could
     * end the process except a signal, which is why the close button did
     * nothing. */
    GMainLoop        *loop;
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
    case VERON_CHROME_URL:
        veron_chrome_set_focused(b->chrome, TRUE);
        /* THE BACKEND HAS TO BE TOLD, because the compositor cannot know that
         * a URL field inside our surface wants the keyboard. Wayland routes
         * the pointer for us and cannot route this. */
        wpe_toplevel_veron_set_chrome_focus(b->toplevel, TRUE);
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
    case XKB_KEY_Left:      veron_chrome_move_caret(b->chrome, -1, FALSE); break;
    case XKB_KEY_Right:     veron_chrome_move_caret(b->chrome,  1, FALSE); break;
    case XKB_KEY_Home:      veron_chrome_move_caret(b->chrome, -1, TRUE);  break;
    case XKB_KEY_End:       veron_chrome_move_caret(b->chrome,  1, TRUE);  break;

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
static void onToplevelResized(WPEToplevel *toplevel, GParamSpec *spec, gpointer data)
{
    Browser *b = data;
    int w = 0, h = 0;
    wpe_toplevel_get_size(toplevel, &w, &h);
    if (w > 0) {
        b->width = w;
        veron_chrome_draw(b->chrome, w);
    }
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
    /* EPHEMERAL BY CHOICE, AND EXPLICITLY RATHER THAN BY ACCIDENT.
     *
     * The default session is persistent and writes to the XDG directories,
     * which on this system land on the tmpfs overlay -- so nothing survives a
     * reboot anyway. Relying on that would be depending on a property of the
     * root filesystem rather than on a decision: mount /persist over the wrong
     * path, or change XDG_DATA_HOME, and the browser silently starts keeping
     * history it was never meant to keep.
     *
     * webkit_network_session_new_ephemeral() is the same thing MiniBrowser's
     * --private uses (main.cpp:478). Nothing is written to disk: no cookie
     * jar, no cache, no local storage, no IndexedDB, no credentials.
     *
     * IT COSTS CAPTCHAS AND THAT IS ACCEPTED. A browser arriving with no
     * cookies on every request looks like automation, and Google will ask more
     * often because of it. The alternative is a disk that remembers where the
     * machine has been, which is the thing being declined. */
    WebKitNetworkSession *session = webkit_network_session_new_ephemeral();

    /* ITP OFF. Intelligent Tracking Prevention profiles which sites are
     * tracking you and keeps that assessment -- state, in a session whose
     * whole point is having none. It also does nothing useful when every
     * cookie dies at exit. */
    webkit_network_session_set_itp_enabled(session, FALSE);

    /* NO SAVED PASSWORDS. Ephemeral already implies it; saying so means a
     * future change to the session type cannot quietly turn it on. */
    webkit_network_session_set_persistent_credential_storage_enabled(session, FALSE);

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
    g_signal_connect(b.toplevel, "notify::width", G_CALLBACK(onToplevelResized), &b);

    g_signal_connect(b.webView, "notify::uri",   G_CALLBACK(onUriChanged),   &b);
    g_signal_connect(b.webView, "notify::title", G_CALLBACK(onTitleChanged), &b);
    g_signal_connect(b.webView, "notify::estimated-load-progress",
                     G_CALLBACK(onProgress), &b);
    g_signal_connect(b.webView, "load-changed",  G_CALLBACK(onLoadChanged),  &b);
    g_signal_connect(b.webView, "close",         G_CALLBACK(onWebViewClose), &b);
    g_signal_connect(wpeView,   "closed",        G_CALLBACK(onViewClosed),   &b);

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
