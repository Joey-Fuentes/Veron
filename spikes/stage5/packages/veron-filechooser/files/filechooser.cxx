// A file chooser, because this system has none and a web page asked for one.
//
// WHY A SEPARATE PROGRAM. `<input type="file">` makes WebKit emit
// run-file-chooser, whose documented default handler runs a GtkFileChooserDialog
// -- and there is no GTK here, no D-Bus and no portal, so the default does
// nothing and the element is dead. Something has to draw a dialog, and the
// only toolkit in this image is FLTK, already built for veron-edit.
//
// A PROGRAM RATHER THAN CODE INSIDE THE BROWSER, for three reasons. FLTK and
// WPE both want to own the main loop, and running Fl::run() inside a WebKit
// signal handler would nest one inside the other. A crash in a file dialog
// should not take the browser down. And a chooser that prints paths on stdout
// is testable from a shell, which code buried in a signal handler is not.
//
// THE CONTRACT IS DELIBERATELY THIN: selected paths on stdout, one per line,
// exit 0. Nothing selected -> exit 1 and no output. That is all the browser
// needs to know, and it means the chooser can be replaced -- with fuzzel, with
// anything -- without touching the browser.

#include <FL/Fl.H>
#include <FL/Fl_File_Chooser.H>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    const char *title = "Select a file";
    const char *filter = "*";
    const char *start = getenv("HOME");
    int multiple = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--multiple"))
            multiple = 1;
        else if (!strcmp(argv[i], "--title") && i + 1 < argc)
            title = argv[++i];
        // A PATTERN, NOT A MIME TYPE. WebKit hands the page's `accept`
        // attribute over as MIME types; translating those to glob patterns is
        // the caller's job, because it is the caller that knows what the page
        // asked for and this program should not carry a MIME database.
        else if (!strcmp(argv[i], "--filter") && i + 1 < argc)
            filter = argv[++i];
        else if (!strcmp(argv[i], "--start") && i + 1 < argc)
            start = argv[++i];
    }

    if (!start || !*start)
        start = "/";

    // THE TRAILING SLASH MATTERS. Fl_File_Chooser treats a value without one
    // as a preselected FILE and with one as a starting DIRECTORY; passing
    // "/home/veron" opens the parent with the directory highlighted, which is
    // one level up from what anyone means.
    char startdir[4096];
    snprintf(startdir, sizeof startdir, "%s/", start);

    Fl_File_Chooser chooser(startdir, filter,
                            multiple ? Fl_File_Chooser::MULTI
                                     : Fl_File_Chooser::SINGLE,
                            title);
    chooser.preview(0);
    chooser.show();

    // Fl::wait() UNTIL THE WINDOW GOES AWAY, which is how Fl_File_Chooser is
    // meant to be driven -- it is not modal by itself and has no run() of its
    // own. Fl::run() would return only when every window closed, which is the
    // same thing here but says less about the intent.
    while (chooser.shown())
        Fl::wait();

    if (chooser.value() == NULL)
        return 1;

    for (int i = 1; i <= chooser.count(); i++) {
        const char *v = chooser.value(i);
        if (v && *v)
            printf("%s\n", v);
    }
    return 0;
}
