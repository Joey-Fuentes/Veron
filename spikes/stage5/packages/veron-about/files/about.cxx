// What this machine is, and whether it is current.
//
// WHY THIS EXISTS. Nothing in a running Veron could say which commit built it.
// Answering "is my fix in this image" took, on one evening, three photographs,
// a file size comparison and eu-nm against the deployed module -- because the
// image records no provenance at all and the GitHub release page permanently
// reports the commit its tag was first created at, not the one whose artifacts
// are attached. This reads /etc/veron-release, which the workflow writes at
// build time, and shows it.
//
// FLTK BECAUSE IT IS ALREADY HERE. veron-edit is FLTK's own editor example, so
// the toolkit is built, installed and known to work under labwc. A GTK app
// would be a new dependency for one window.
//
// THE UPDATE CHECK SHELLS OUT TO curl AND DOES NOT PARSE JSON PROPERLY.
// GitHub's compare API returns ahead_by as a small integer in a large
// document; pulling one number out with a substring search is enough and
// avoids linking json-c for a single field. It is stated here rather than
// hidden because a real JSON parse is what this should become if the app ever
// reads a second field.
//
// A SUBSTRING SEARCH IS ALSO WHY THE FIELD NAME MATTERS SO MUCH. There is no
// schema to disagree with, so reading the wrong key is not an error -- it
// finds a real number and reports it confidently. That is exactly what
// happened with behind_by.

#include <FL/Fl.H>
#include <veron/veron-fltk-style.h>
#include <FL/Fl_Window.H>
#include <FL/Fl_Box.H>
#include <FL/Fl_Button.H>
#include <FL/Fl_Text_Display.H>
#include <FL/Fl_Text_Buffer.H>
#include <FL/fl_ask.H>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RELEASE_FILE "/etc/veron-release"
#define REPO_URL     "https://github.com/Joey-Fuentes/Veron"

static char g_commit[64] = "";
static Fl_Text_Buffer *g_buf = 0;
static Fl_Box *g_status = 0;

// A KEY=VALUE READER, NOT A CONFIG LIBRARY. /etc/veron-release is written by
// the workflow in the shell-sourceable form os-release uses, so values may be
// quoted. Both forms are accepted because a future writer may quote and this
// should not care.
static int release_value(const char *key, char *out, size_t outlen)
{
    FILE *f = fopen(RELEASE_FILE, "r");
    if (!f)
        return 0;

    char line[512];
    size_t klen = strlen(key);
    int found = 0;

    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, klen) != 0 || line[klen] != '=')
            continue;
        char *v = line + klen + 1;
        char *nl = strchr(v, '\n');
        if (nl)
            *nl = '\0';
        if (*v == '"') {
            v++;
            char *q = strrchr(v, '"');
            if (q)
                *q = '\0';
        }
        snprintf(out, outlen, "%s", v);
        found = 1;
        break;
    }
    fclose(f);
    return found;
}

static void append(const char *label, const char *value)
{
    char row[600];
    snprintf(row, sizeof row, "%-14s %s\n", label, value && *value ? value : "(unknown)");
    g_buf->append(row);
}

// COMMITS BEHIND, VIA THE COMPARE API.
//
// api.github.com/repos/OWNER/REPO/compare/BASE...HEAD reports ahead_by and
// behind_by, and BOTH ARE RELATIVE TO THE BASE:
//
//   ahead_by   commits in HEAD that are not in BASE
//   behind_by  commits in BASE that are not in HEAD
//
// BASE is this image's commit and HEAD is main, so commits landing on main
// make main AHEAD of the image -- ahead_by grows and behind_by stays 0.
//
// THE FIRST VERSION READ behind_by AND SO ALWAYS SAID "up to date". It was
// not a network failure or a stale manifest: the number it printed was
// correct and answered a question nobody asked, namely how many commits this
// image has that main does not -- which for an image built FROM main is
// always zero.
//
// GitHub's OWN DEFINITION SETTLES IT: the endpoint is documented as
// "equivalent to running the git log BASE..HEAD command", and git log
// BASE..HEAD lists the commits in HEAD that are not in BASE. That is the
// count this app wants, and ahead_by is the field carrying it.
//
// IT REQUIRES NETWORK AND SAYS SO WHEN IT FAILS. A machine with no wifi
// configured is the common case on a first boot, and "could not reach GitHub"
// is a different answer from "you are up to date" -- conflating them would be
// the more comfortable lie.
static void check_updates(Fl_Widget *, void *)
{
    if (!g_commit[0]) {
        g_status->copy_label("No commit recorded in " RELEASE_FILE
                             " -- cannot compare.");
        g_status->redraw();
        return;
    }

    g_status->copy_label("Checking...");
    g_status->redraw();
    Fl::check();

    char cmd[512];
    snprintf(cmd, sizeof cmd,
             "curl -sS --max-time 15 "
             "-H 'Accept: application/vnd.github+json' "
             "'https://api.github.com/repos/Joey-Fuentes/Veron/compare/"
             "%s...main' 2>&1",
             g_commit);

    FILE *p = popen(cmd, "r");
    if (!p) {
        g_status->copy_label("Could not run curl.");
        g_status->redraw();
        return;
    }

    // THE WHOLE RESPONSE, BOUNDED. A compare of many commits carries every one
    // of them; only the first ahead_by matters and it appears early, but the
    // read is capped rather than trusting that.
    static char body[65536];
    size_t n = fread(body, 1, sizeof body - 1, p);
    body[n] = '\0';
    int rc = pclose(p);

    const char *key = "\"ahead_by\":";
    char *at = strstr(body, key);

    if (!at) {
        // NAME THE FAILURE. curl writes its own errors to the same buffer
        // because of 2>&1, so a DNS failure or a rate limit is visible rather
        // than being reported as "unknown".
        char msg[300];
        if (strstr(body, "rate limit"))
            snprintf(msg, sizeof msg, "GitHub rate limit reached -- try later.");
        else if (rc != 0 || n == 0)
            snprintf(msg, sizeof msg, "Could not reach GitHub. Is wifi connected?");
        else if (strstr(body, "\"message\""))
            snprintf(msg, sizeof msg,
                     "GitHub could not compare this commit. It may not be "
                     "pushed, or the branch may have been rewritten.");
        else
            snprintf(msg, sizeof msg, "Unexpected response from GitHub.");
        g_status->copy_label(msg);
        g_status->redraw();
        return;
    }

    long ahead = strtol(at + strlen(key), 0, 10);
    char msg[300];
    if (ahead <= 0)
        snprintf(msg, sizeof msg, "Up to date with main.");
    else
        snprintf(msg, sizeof msg,
                 "%ld commit%s behind main.  Updating is not automatic yet -- "
                 "rebuild and re-flash.", ahead, ahead == 1 ? "" : "s");
    g_status->copy_label(msg);
    g_status->redraw();
}

int main(int argc, char **argv)
{
    /* THE LOOK IS SET BEFORE ANY WIDGET EXISTS. Box types and the palette are
     * read when a widget is constructed, so a widget made before this call
     * keeps the default grey. */
    veron_fltk_style();

    Fl_Window *win = new Fl_Window(620, 420, "About Veron");
    win->color(FL_BACKGROUND_COLOR);

    Fl_Box *title = new Fl_Box(16, 12, 588, 30, "Veron");
    title->labelfont(FL_HELVETICA_BOLD);
    title->labelsize(22);
    title->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE);

    Fl_Box *sub = new Fl_Box(16, 40, 588, 20,
                             "A hermetic, reproducible operating system built from source.");
    sub->labelsize(11);
    sub->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE);

    g_buf = new Fl_Text_Buffer();
    Fl_Text_Display *disp = new Fl_Text_Display(16, 70, 588, 250);
    disp->buffer(g_buf);
    disp->textfont(FL_COURIER);
    disp->textsize(12);

    char v[512];

    if (release_value("VERON_COMMIT", v, sizeof v)) {
        snprintf(g_commit, sizeof g_commit, "%s", v);
        append("Commit", v);
    } else {
        append("Commit", 0);
    }
    if (release_value("VERON_BUILD_DATE", v, sizeof v)) append("Built", v);
    if (release_value("VERON_RUN_ID", v, sizeof v))     append("CI run", v);
    if (release_value("VERON_ARCH", v, sizeof v))       append("Arch", v);
    if (release_value("VERON_REPO", v, sizeof v))       append("Repo", v);
    // THE RELEASE TAG, WHICH THE WORKFLOW KNOWS AND THE USER USED TO HUNT
    // FOR. Guarded like every row here: an image built before the key
    // existed simply does not show the row, rather than showing "(unknown)"
    // for a fact the file never claimed to carry.
    if (release_value("VERON_RELEASE_TAG", v, sizeof v)) append("Release", v);

    // NO IMAGE SHA HERE, AND IT IS NOT AN OVERSIGHT. The image's sha256 is
    // computed over the finished filesystem, so a copy of it stored INSIDE
    // that filesystem would change the value it claims to be. The published
    // IMAGE-SHA256 asset is the real one, and comparing it against the
    // partition is a thing done from outside -- which is where a checksum of
    // a disk belongs.

    g_buf->append("\n");
    append("Repository", REPO_URL);
    // THE MANIFEST CANNOT BE INSIDE THE IMAGE IT DESCRIBES, and that is not an
    // oversight. files.tsv lists every path with its sha256; adding it to the
    // image changes the image, which changes the manifest, which changes the
    // image. It ships as a release asset beside rootfs.img.tar.zst instead,
    // and this points at where to get it rather than pretending otherwise.
    append("Manifest", "files.tsv, published with the image");
    // THE EXACT RELEASE, NOT THE RELEASES INDEX. The workflow writes its own
    // tag's URL (slash encoded, because that is how a slash-in-tag release
    // page is reached), so nobody has to know which of the tags is this
    // image. The generic /releases row stays as the fallback for images
    // whose veron-release predates the key.
    if (release_value("VERON_RELEASE_URL", v, sizeof v))
        append("This release", v);
    else
        append("Releases", REPO_URL "/releases");
    // THE ATTESTATION INDEX, AND WHY IT IS THE INDEX RATHER THAN ONE
    // ATTESTATION'S URL: the attestation is minted over the finished image,
    // so its id cannot be known while this file -- inside that image -- is
    // written. Same self-reference as the missing image sha above. The
    // per-asset proof is one command, shown so it does not have to be
    // remembered.
    if (release_value("VERON_ATTESTATIONS", v, sizeof v)) {
        append("Attestation", v);
        char repo[256] = "Joey-Fuentes/Veron";
        release_value("VERON_REPO", repo, sizeof repo);
        char verify[400];
        snprintf(verify, sizeof verify,
                 "gh attestation verify <asset> --repo %s", repo);
        append("Verify", verify);
    }

    g_status = new Fl_Box(16, 330, 588, 24, "");
    g_status->labelsize(11);
    g_status->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE | FL_ALIGN_WRAP);

    Fl_Button *upd = new Fl_Button(16, 362, 150, 30, "Check for updates");
    upd->callback(check_updates);

    Fl_Button *close = new Fl_Button(454, 362, 150, 30, "Close");
    close->callback([](Fl_Widget *, void *) { exit(0); });

    win->end();
    win->show(argc, argv);
    return Fl::run();
}
