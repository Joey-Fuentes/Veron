/* One look for every FLTK program in this system.
 *
 * WHY THIS EXISTS. FLTK's default scheme is called "none" and its own
 * documentation describes it as resembling "old Windows (95/98/Me/NT/2000)
 * and old GTK/KDE" -- grey bevels, 3D frames, a raised look nothing else on
 * this desktop has. Three programs use FLTK now (veron-about,
 * veron-filechooser, veron-edit) and each drawing its own palette would be
 * three places for the accent colour to drift.
 *
 * A HEADER RATHER THAN A LIBRARY. This is a dozen calls made once at startup;
 * a shared object would add a DT_NEEDED and a version to every FLTK program
 * for no benefit. It installs to /usr/include/veron/ and is included by
 * source.
 *
 * WHAT IT DOES NOT DO. It sets no widget sizes and creates no widgets. A
 * program's layout is its own business; this is colour, font and box shape.
 */
#ifndef VERON_FLTK_STYLE_H
#define VERON_FLTK_STYLE_H

#include <FL/Fl.H>
#include <FL/Enumerations.H>

/* THE SAME COLOURS THE BAR AND THE WALLPAPER USE, so an FLTK window looks
 * like part of this system rather than a visitor from another one.
 *
 *   1a1a1b  the bar's background
 *   4a9eff  the accent already used for the focused-window underline and the
 *           Apps launcher panel
 */
#define VERON_BG        0x22, 0x22, 0x24   /* window and widget background   */
#define VERON_BG2       0x1a, 0x1a, 0x1b   /* text fields, lists, the "well" */
#define VERON_FG        0xe6, 0xe6, 0xe6   /* label text                     */
#define VERON_ACCENT    0x4a, 0x9e, 0xff   /* selection, focus               */

static inline void veron_fltk_style(void)
{
    /* THE SCHEME COMES FROM THE ENVIRONMENT WHEN THERE IS ONE.
     *
     * Fl::scheme(NULL) reads FLTK_SCHEME (Fl_get_system_colors.cxx:198), and
     * window->show(argc, argv) already does this for programs that use that
     * form -- Fl_arg.cxx:326 calls Fl::scheme(Fl::scheme()). Calling it here
     * covers the ones that do not, such as a bare Fl_File_Chooser, and costs
     * nothing when the variable is unset.
     *
     * THE SCHEME IS NOT WHAT MAKES THIS LOOK MODERN, THOUGH. Both gleam and
     * oxy draw gradients by averaging toward FL_WHITE (fl_oxy.cxx:158), which
     * on a dark palette washes every surface out. The flat box types below
     * are what actually removes the 1995 look, and they work whatever scheme
     * is set. */
    Fl::scheme(NULL);

    Fl::background(VERON_BG);
    Fl::background2(VERON_BG2);
    Fl::foreground(VERON_FG);
    Fl::set_color(FL_SELECTION_COLOR, VERON_ACCENT);

    /* FLAT EVERYWHERE, BY REDEFINING THE BOX TYPES THEMSELVES.
     *
     * Fl::set_boxtype(to, from) copies one entry of the box table over
     * another (fl_boxtype.cxx:461), so every widget that asks for FL_UP_BOX
     * gets a flat one without a single widget being touched. That is what
     * makes this reach into Fl_File_Chooser, whose widgets this code never
     * sees.
     *
     * THE DOWN BOXES KEEP A BORDER. A pressed button and a text field need to
     * read as recessed, and with no bevel a border is the only cue left. */
    Fl::set_boxtype(FL_UP_BOX,          FL_FLAT_BOX);
    Fl::set_boxtype(FL_UP_FRAME,        FL_FLAT_BOX);
    Fl::set_boxtype(FL_THIN_UP_BOX,     FL_FLAT_BOX);
    Fl::set_boxtype(FL_THIN_UP_FRAME,   FL_FLAT_BOX);
    Fl::set_boxtype(FL_DOWN_BOX,        FL_BORDER_BOX);
    Fl::set_boxtype(FL_DOWN_FRAME,      FL_BORDER_FRAME);
    Fl::set_boxtype(FL_THIN_DOWN_BOX,   FL_BORDER_BOX);
    Fl::set_boxtype(FL_THIN_DOWN_FRAME, FL_BORDER_FRAME);

    /* A BORDER COLOUR THAT IS NOT BLACK. FL_BORDER_BOX draws with
     * FL_BLACK by default, which against 0x222224 is a hard line; a shade
     * just lighter than the background reads as an edge rather than a
     * drawing. */
    Fl::set_color(FL_BLACK, 0x3a, 0x3a, 0x3e);

    /* 13px, WHICH IS THE BAR'S SIZE. FLTK defaults to 14 and to whatever
     * fontconfig resolves "Helvetica" to; matching the bar is what stops an
     * FLTK window looking like a different application suite. */
    FL_NORMAL_SIZE = 13;
}

#endif /* VERON_FLTK_STYLE_H */
