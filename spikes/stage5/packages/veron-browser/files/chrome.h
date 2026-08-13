/* The chrome strip's drawing and editing state. Deliberately knows nothing
 * about WebKit: it is told what to show and reports what was clicked, so the
 * browser owns every decision and this owns every pixel. */
#pragma once

#include <glib.h>
#include <wayland-client.h>

typedef struct _VeronChrome VeronChrome;

typedef enum {
    VERON_CHROME_NONE,
    VERON_CHROME_BACK,
    VERON_CHROME_FORWARD,
    VERON_CHROME_RELOAD,
    VERON_CHROME_URL
} VeronChromeHit;

typedef struct { int unused; } VeronChromeCallbacks;

VeronChrome *veron_chrome_new  (struct wl_surface *surface, struct wl_shm *shm);
void         veron_chrome_free (VeronChrome *chrome);

guint          veron_chrome_height (void);
void           veron_chrome_draw   (VeronChrome *chrome, int width);
VeronChromeHit veron_chrome_hit    (VeronChrome *chrome, double x, double y);

void        veron_chrome_set_url        (VeronChrome *chrome, const char *url);
void        veron_chrome_set_navigation (VeronChrome *chrome, gboolean back, gboolean forward);
void        veron_chrome_set_loading    (VeronChrome *chrome, gboolean loading, double progress);
void        veron_chrome_set_focused    (VeronChrome *chrome, gboolean focused);
gboolean    veron_chrome_focused        (VeronChrome *chrome);
const char *veron_chrome_text           (VeronChrome *chrome);

void veron_chrome_insert     (VeronChrome *chrome, const char *utf8);
void veron_chrome_backspace  (VeronChrome *chrome);
void veron_chrome_delete     (VeronChrome *chrome);
void veron_chrome_move_caret (VeronChrome *chrome, int direction, gboolean toEnd);
