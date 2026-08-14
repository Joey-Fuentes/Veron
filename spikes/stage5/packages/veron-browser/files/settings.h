/* Persistent browser settings, and the page that edits them.
 *
 * WHY THESE LIVE IN A FILE AND THE SESSION DOES NOT. The network session is
 * ephemeral on purpose -- no cookie, cache or credential survives exit, and
 * the recipe's deferral asks for exactly that. Settings are the opposite kind
 * of state: they are the user's decision about how the browser behaves, and a
 * decision that has to be remade every boot is not a setting. $HOME is bind
 * mounted from /persist, so a file under the config directory outlives a
 * reboot while the browsing session still does not.
 *
 * WHY THE EDITOR IS A PAGE AND NOT A DROPDOWN. The chrome strip is 40 pixels
 * tall and the page is a sibling subsurface stacked above it, so a panel drawn
 * below the strip is painted behind the page. A page needs none of that, has
 * room for as many toggles as the list grows to, and gets back, forward and
 * reload for free because it is a real navigation to a real URL.
 *
 * WHY THE PAGE USES NO JAVASCRIPT. One of these settings turns JavaScript off.
 * A settings page that needs JavaScript to function would, the moment it was
 * used for that, become the one page that cannot undo what it just did. Every
 * control here is a plain link.
 */
#pragma once

#include <glib.h>

/* THE SCHEME IS OURS AND REGISTERED. Navigating to an unregistered scheme is
 * not reliably delivered anywhere we can intercept; registering it makes
 * `veron:settings` an ordinary URL that loads, appears in the URL bar, and
 * sits in session history like any other. */
#define VERON_SCHEME       "veron"
#define VERON_SETTINGS_URI "veron:settings"

typedef struct {
    /* PERSISTENT IS THE ONE THAT CANNOT BE APPLIED LIVE. The network session
     * is a construct property of the web view, so which kind of session this
     * process has is decided before the first page and cannot change under it.
     * The setting is stored when toggled and read at the next start. */
    gboolean persistent;

    gboolean javascript;
    gboolean localStorage;
    gboolean cookies;
    gboolean downloads;
} VeronSettings;

/* MISSING FILE IS NOT AN ERROR -- it is a first run, and every setting takes
 * its default. Defaults are all "enabled": a browser that silently starts with
 * capabilities switched off is indistinguishable, to the person using it, from
 * a broken one. */
void     veron_settings_load (VeronSettings *s);
gboolean veron_settings_save (const VeronSettings *s);

/* APPLY ONE KEY BY NAME, which is what the settings page's links carry.
 * Returns TRUE when the key was recognised and the value changed. */
gboolean veron_settings_set  (VeronSettings *s, const char *key, gboolean value);

/* THE PAGE ITSELF, as a complete HTML document the caller owns and frees. */
char    *veron_settings_html (const VeronSettings *s);
