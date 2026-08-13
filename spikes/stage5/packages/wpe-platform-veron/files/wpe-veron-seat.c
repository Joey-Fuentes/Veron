/* Input: pointer, keyboard and touch, and the chrome/page split.
 *
 * WAYLAND DOES THE HIT TESTING, WHICH IS THE WHOLE REASON THIS IS SHORT.
 * The page lives in a wl_subsurface, so the compositor decides which surface
 * the pointer is over and says so in wl_pointer.enter. Coordinates arrive
 * RELATIVE TO THAT SURFACE, so a click at the top of the page is (x, 0) even
 * though it is 36 pixels down the window. No arithmetic, no off-by-one, and
 * no way for a click in the chrome to reach the page by accident: they are
 * different surfaces and the compositor never confuses them.
 *
 * That is why the subsurface design is worth more than reserving a strip. A
 * shell that drew chrome into the same surface would have to hit-test every
 * event itself and translate coordinates for the ones it passed on -- the
 * exact code that goes wrong on a resize.
 *
 * THE CHROME GETS A SIGNAL, NOT A WPEEvent. Events over the toplevel's own
 * surface are not the page's, and wrapping them in a WPEView event would mean
 * inventing a view for them. WPEToplevelVeron emits "chrome-event" with the
 * raw parameters instead, and a browser connects to it.
 */
#include "wpe-display-veron.h"
#include "wpe-veron-private.h"

#include <wayland-client.h>
#include <linux/input-event-codes.h>
#include <xkbcommon/xkbcommon.h>

struct _VeronSeat {
    WPEDisplayVeron  *display;
    struct wl_seat   *wlSeat;

    struct wl_pointer  *pointer;
    struct wl_keyboard *keyboard;
    struct wl_touch    *touch;

    /* WHICH SURFACE THE POINTER IS OVER, and therefore where events go. NULL
     * means it has left the window entirely. */
    struct wl_surface  *pointerSurface;
    WPEToplevelVeron   *pointerToplevel;
    double              pointerX, pointerY;
    guint32             lastSerial;

    struct wl_surface  *keyboardSurface;
    WPEToplevelVeron   *keyboardToplevel;

    WPEKeymap          *keymap;
    WPEModifiers        modifiers;

    /* PRESS COUNT FOR DOUBLE CLICKS. WebKit wants to know whether this is the
     * first, second or third click of a sequence; nothing below the toolkit
     * tracks that, so the seat does. */
    guint32             lastButtonTime;
    guint               lastButton;
    guint               pressCount;

    /* SCROLL IS ACCUMULATED ACROSS A FRAME, NOT DISPATCHED PER AXIS EVENT.
     * wl_pointer sends axis, axis_source, axis_discrete and axis_stop as
     * separate events and then a frame to say "that was one gesture". Acting
     * on each in turn means a diagonal touchpad scroll arrives as two
     * unrelated single-axis scrolls, and the source -- which decides whether
     * the deltas are precise -- arrives AFTER the delta it describes. */
    struct {
        gboolean active;
        double   dx, dy;
        gboolean haveDiscrete;
        double   discreteX, discreteY;
        uint32_t source;
        gboolean isStop;
        guint32  time;
    } axis;

    /* TOUCH POINTS, BY ID. Wayland reports down/motion/up with an id and only
     * gives coordinates on down and motion, so up has to look up where the
     * finger was. A finger lifted at an unknown position is a tap that lands
     * in the wrong place. */
    GHashTable         *touchPoints;
    struct wl_surface  *touchSurface;
    WPEToplevelVeron   *touchToplevel;
};

typedef struct { double x, y; } VeronTouchPoint;

/* ---- helpers --------------------------------------------------------- */

static WPEView *seatViewFor(VeronSeat *seat, WPEToplevelVeron *toplevel);

static guint veronButtonFromLinux(uint32_t button)
{
    /* WPE NUMBERS BUTTONS FROM 1, linux/input-event-codes.h from 0x110. The
     * middle and right buttons are also swapped between the two orders, which
     * is the kind of thing that presents as "paste happens on right-click". */
    switch (button) {
    case BTN_LEFT:   return 1;
    case BTN_MIDDLE: return 2;
    case BTN_RIGHT:  return 3;
    default:         return button - BTN_LEFT + 1;
    }
}

/* ---- pointer --------------------------------------------------------- */

static void pointerEnter(void *data, struct wl_pointer *pointer, uint32_t serial,
                         struct wl_surface *surface, wl_fixed_t sx, wl_fixed_t sy)
{
    VeronSeat *seat = data;
    if (!surface)
        return;

    seat->lastSerial     = serial;
    seat->pointerSurface = surface;
    seat->pointerToplevel = wpeVeronToplevelForSurface(surface);
    seat->pointerX = wl_fixed_to_double(sx);
    seat->pointerY = wl_fixed_to_double(sy);
}

static void pointerLeave(void *data, struct wl_pointer *pointer, uint32_t serial,
                         struct wl_surface *surface)
{
    VeronSeat *seat = data;
    seat->lastSerial      = serial;
    seat->pointerSurface  = NULL;
    seat->pointerToplevel = NULL;
}

/* THE ONE FUNCTION THAT DECIDES WHERE AN EVENT GOES. Everything below calls
 * it: if the surface under the pointer is a toplevel's page subsurface the
 * event becomes a WPEEvent for that view; if it is the toplevel's own surface
 * the event is chrome and is emitted as a signal instead. */
static gboolean seatDispatch(VeronSeat *seat, WPEEventType type, guint32 time,
                             guint button, double dx, double dy, gboolean isScroll)
{
    if (!seat->pointerToplevel)
        return FALSE;

    gboolean onPage = wpeVeronToplevelIsPageSurface(seat->pointerToplevel,
                                                    seat->pointerSurface);
    if (!onPage) {
        wpeVeronToplevelEmitChromeEvent(seat->pointerToplevel, type, time,
                                        seat->modifiers, button,
                                        seat->pointerX, seat->pointerY, dx, dy);
        return TRUE;
    }

    WPEView *view = seatViewFor(seat, seat->pointerToplevel);
    if (!view)
        return FALSE;

    WPEEvent *event = NULL;
    switch (type) {
    case WPE_EVENT_POINTER_DOWN:
    case WPE_EVENT_POINTER_UP:
        event = wpe_event_pointer_button_new(type, view, WPE_INPUT_SOURCE_MOUSE,
            time, seat->modifiers, button, seat->pointerX, seat->pointerY,
            type == WPE_EVENT_POINTER_DOWN ? seat->pressCount : 0);
        break;
    case WPE_EVENT_POINTER_MOVE:
        event = wpe_event_pointer_move_new(type, view, WPE_INPUT_SOURCE_MOUSE,
            time, seat->modifiers, seat->pointerX, seat->pointerY, dx, dy);
        break;
    case WPE_EVENT_SCROLL:
        /* PRECISE DELTAS FALSE, is_stop FALSE. wl_pointer.axis gives a value
         * in surface units; a touchpad sends axis_source and axis_stop, which
         * this does not yet handle -- kinetic scrolling will feel like a
         * mouse wheel until it does. */
        event = wpe_event_scroll_new(view, WPE_INPUT_SOURCE_MOUSE, time,
            seat->modifiers, dx, dy, FALSE, FALSE,
            seat->pointerX, seat->pointerY);
        break;
    default:
        return FALSE;
    }

    if (!event)
        return FALSE;

    wpe_view_event(view, event);
    wpe_event_unref(event);
    return TRUE;
}

static void pointerMotion(void *data, struct wl_pointer *pointer, uint32_t time,
                          wl_fixed_t sx, wl_fixed_t sy)
{
    VeronSeat *seat = data;
    double x = wl_fixed_to_double(sx), y = wl_fixed_to_double(sy);
    double dx = x - seat->pointerX, dy = y - seat->pointerY;
    seat->pointerX = x;
    seat->pointerY = y;
    seatDispatch(seat, WPE_EVENT_POINTER_MOVE, time, 0, dx, dy, FALSE);
}

static void pointerButton(void *data, struct wl_pointer *pointer, uint32_t serial,
                          uint32_t time, uint32_t button, uint32_t state)
{
    VeronSeat *seat = data;
    seat->lastSerial = serial;

    guint b = veronButtonFromLinux(button);
    gboolean pressed = (state == WL_POINTER_BUTTON_STATE_PRESSED);

    if (pressed) {
        /* 400 ms AND THE SAME BUTTON MAKES IT A DOUBLE CLICK. Wayland does not
         * report click counts; every toolkit invents this threshold and 400 ms
         * is the common one. Without it, selecting a word by double-clicking
         * does nothing. */
        if (b == seat->lastButton && time - seat->lastButtonTime < 400)
            seat->pressCount++;
        else
            seat->pressCount = 1;
        seat->lastButton = b;
        seat->lastButtonTime = time;

        seat->modifiers |= (b == 1 ? WPE_MODIFIER_POINTER_BUTTON1
                          : b == 2 ? WPE_MODIFIER_POINTER_BUTTON2
                                   : WPE_MODIFIER_POINTER_BUTTON3);
    } else {
        seat->modifiers &= ~(b == 1 ? WPE_MODIFIER_POINTER_BUTTON1
                           : b == 2 ? WPE_MODIFIER_POINTER_BUTTON2
                                    : WPE_MODIFIER_POINTER_BUTTON3);
    }

    seatDispatch(seat, pressed ? WPE_EVENT_POINTER_DOWN : WPE_EVENT_POINTER_UP,
                 time, b, 0, 0, FALSE);
}

static void pointerAxis(void *data, struct wl_pointer *pointer, uint32_t time,
                        uint32_t axis, wl_fixed_t value)
{
    VeronSeat *seat = data;
    double v = wl_fixed_to_double(value);

    /* THE SIGN IS INVERTED RELATIVE TO WHAT WEBKIT WANTS. wl_pointer.axis
     * reports the direction the SURFACE moves; a wheel pushed away gives a
     * negative value and the page should move up. */
    seat->axis.active = TRUE;
    seat->axis.time = time;
    if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL)
        seat->axis.dy -= v;
    else
        seat->axis.dx -= v;
}

static void pointerAxisSource(void *data, struct wl_pointer *p, uint32_t source)
{
    VeronSeat *seat = data;
    seat->axis.active = TRUE;
    seat->axis.source = source;
}

static void pointerAxisStop(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis)
{
    VeronSeat *seat = data;
    /* A STOP IS ITS OWN EVENT AND WEBKIT WANTS IT. It marks the end of a
     * kinetic gesture -- the moment fingers left the touchpad -- and a page
     * that never sees one keeps waiting for more scroll. */
    seat->axis.active = TRUE;
    seat->axis.isStop = TRUE;
    seat->axis.time = time;
}

static void pointerAxisDiscrete(void *data, struct wl_pointer *p, uint32_t axis, int32_t discrete)
{
    VeronSeat *seat = data;
    seat->axis.active = TRUE;
    seat->axis.haveDiscrete = TRUE;
    if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL)
        seat->axis.discreteY -= discrete;
    else
        seat->axis.discreteX -= discrete;
}

static void pointerFrame(void *data, struct wl_pointer *p)
{
    VeronSeat *seat = data;
    if (!seat->axis.active)
        return;

    /* PRECISE MEANS "A FINGER, NOT A NOTCH". A wheel moves in discrete clicks
     * and WebKit should scroll by lines; a touchpad moves continuously and
     * should scroll by the distance travelled. Reporting a touchpad as
     * imprecise makes every gesture jump a line at a time, which is the
     * usual symptom of getting this wrong. */
    gboolean precise = (seat->axis.source == WL_POINTER_AXIS_SOURCE_FINGER
                     || seat->axis.source == WL_POINTER_AXIS_SOURCE_CONTINUOUS);

    double dx = seat->axis.dx, dy = seat->axis.dy;

    /* FOR A WHEEL, THE DISCRETE COUNT IS THE TRUTH. The continuous value a
     * compositor sends alongside it is a synthesised approximation -- usually
     * 10 or 15 per notch -- and differs between compositors. One notch is one
     * unit of scroll and WebKit multiplies by its own line height. */
    if (!precise && seat->axis.haveDiscrete) {
        dx = seat->axis.discreteX;
        dy = seat->axis.discreteY;
    }

    if (dx != 0.0 || dy != 0.0 || seat->axis.isStop) {
        if (seat->pointerToplevel) {
            gboolean onPage = wpeVeronToplevelIsPageSurface(seat->pointerToplevel,
                                                            seat->pointerSurface);
            if (!onPage) {
                wpeVeronToplevelEmitChromeEvent(seat->pointerToplevel, WPE_EVENT_SCROLL,
                    seat->axis.time, seat->modifiers, 0,
                    seat->pointerX, seat->pointerY, dx, dy);
            } else {
                WPEView *view = seatViewFor(seat, seat->pointerToplevel);
                if (view) {
                    WPEInputSource src = precise ? WPE_INPUT_SOURCE_TOUCHPAD
                                                 : WPE_INPUT_SOURCE_MOUSE;
                    WPEEvent *event = wpe_event_scroll_new(view, src,
                        seat->axis.time, seat->modifiers, dx, dy,
                        precise, seat->axis.isStop,
                        seat->pointerX, seat->pointerY);
                    wpe_view_event(view, event);
                    wpe_event_unref(event);
                }
            }
        }
    }

    memset(&seat->axis, 0, sizeof(seat->axis));
}

static const struct wl_pointer_listener pointerListener = {
    pointerEnter, pointerLeave, pointerMotion, pointerButton, pointerAxis,
    pointerFrame, pointerAxisSource, pointerAxisStop, pointerAxisDiscrete
};

/* ---- keyboard -------------------------------------------------------- */

static void keyboardKeymap(void *data, struct wl_keyboard *kb, uint32_t format,
                           int32_t fd, uint32_t size)
{
    VeronSeat *seat = data;

    /* THE FD GOES STRAIGHT THROUGH. WPEKeymapXKB.h:44 takes (keymap, format,
     * fd, size) and does the mmap itself; an earlier version of this function
     * mapped the descriptor here and passed a char*, which does not even
     * compile against the real header -- it was written against a stub and the
     * stub was wrong.
     *
     * IT ALSO OWNS THE DESCRIPTOR AFTER THIS CALL. The stock backend --
     * WPEWaylandSeat.cpp:298 -- passes fd on and neither maps nor closes it,
     * so closing here would pull the file out from under WPE. */
    if (!seat->keymap)
        seat->keymap = wpe_keymap_xkb_new();

    wpe_keymap_xkb_update(WPE_KEYMAP_XKB(seat->keymap), format, fd, size);
}

static void keyboardEnter(void *data, struct wl_keyboard *kb, uint32_t serial,
                          struct wl_surface *surface, struct wl_array *keys)
{
    VeronSeat *seat = data;
    seat->lastSerial       = serial;
    seat->keyboardSurface  = surface;
    seat->keyboardToplevel = surface ? wpeVeronToplevelForSurface(surface) : NULL;
}

static void keyboardLeave(void *data, struct wl_keyboard *kb, uint32_t serial,
                          struct wl_surface *surface)
{
    VeronSeat *seat = data;
    seat->lastSerial       = serial;
    seat->keyboardSurface  = NULL;
    seat->keyboardToplevel = NULL;
}

static void keyboardKey(void *data, struct wl_keyboard *kb, uint32_t serial,
                        uint32_t time, uint32_t key, uint32_t state)
{
    VeronSeat *seat = data;
    seat->lastSerial = serial;

    if (!seat->keyboardToplevel || !seat->keymap)
        return;

    /* +8 IS THE EVDEV-TO-XKB OFFSET and it is not negotiable. XKB keycodes
     * begin at 8 because X11 reserved the first eight; every Wayland client
     * adds this, and getting it wrong shifts the entire keyboard by eight
     * positions -- 'a' becomes something else and nothing looks obviously
     * broken until someone types. */
    guint keycode = key + 8;

    guint keyval = 0;
    struct xkb_state *xkbState = wpe_keymap_xkb_get_xkb_state(WPE_KEYMAP_XKB(seat->keymap));
    if (xkbState)
        keyval = xkb_state_key_get_one_sym(xkbState, keycode);

    /* THE KEYBOARD GOES TO THE PAGE UNLESS THE CHROME HAS FOCUS, and the
     * toplevel decides that -- a URL bar being typed into is a state the
     * browser knows and the compositor does not. Wayland's hit testing solves
     * the pointer for us and cannot solve this. */
    WPEEventType type = (state == WL_KEYBOARD_KEY_STATE_PRESSED)
        ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP;

    if (wpeVeronToplevelChromeHasFocus(seat->keyboardToplevel)) {
        wpeVeronToplevelEmitChromeKey(seat->keyboardToplevel, type, time,
                                      seat->modifiers, keycode, keyval);
        return;
    }

    WPEView *view = seatViewFor(seat, seat->keyboardToplevel);
    if (!view)
        return;

    WPEEvent *event = wpe_event_keyboard_new(type, view, WPE_INPUT_SOURCE_KEYBOARD,
        time, seat->modifiers, keycode, keyval);
    wpe_view_event(view, event);
    wpe_event_unref(event);
}

static void keyboardModifiers(void *data, struct wl_keyboard *kb, uint32_t serial,
                              uint32_t depressed, uint32_t latched, uint32_t locked,
                              uint32_t group)
{
    VeronSeat *seat = data;
    seat->lastSerial = serial;
    if (!seat->keymap)
        return;

    struct xkb_state *xkbState = wpe_keymap_xkb_get_xkb_state(WPE_KEYMAP_XKB(seat->keymap));
    if (xkbState)
        xkb_state_update_mask(xkbState, depressed, latched, locked, 0, 0, group);

    /* THE POINTER BUTTON BITS ARE PRESERVED. wpe_keymap_get_modifiers reports
     * keyboard state only, and overwriting the whole field here would drop a
     * button that is still held -- so a drag would stop being a drag the
     * moment Shift was pressed. */
    WPEModifiers buttons = seat->modifiers &
        (WPE_MODIFIER_POINTER_BUTTON1 | WPE_MODIFIER_POINTER_BUTTON2 | WPE_MODIFIER_POINTER_BUTTON3);
    seat->modifiers = wpe_keymap_get_modifiers(seat->keymap) | buttons;
}

static void keyboardRepeatInfo(void *data, struct wl_keyboard *kb, int32_t rate, int32_t delay) { }

static const struct wl_keyboard_listener keyboardListener = {
    keyboardKeymap, keyboardEnter, keyboardLeave, keyboardKey,
    keyboardModifiers, keyboardRepeatInfo
};

/* ---- touch ----------------------------------------------------------- */

/* WHY THIS IS WRITTEN AT ALL, given no touchscreen to test it on. The seat
 * binds wl_touch when the compositor advertises it, and a bound-but-ignored
 * protocol object is worse than an unbound one: the compositor believes the
 * client is handling touch and routes it here, where it vanishes. Either
 * implement it or do not bind it.
 *
 * It follows the pointer's shape exactly -- Wayland hit-tests, coordinates
 * arrive relative to the surface touched, and the page being a subsurface
 * means a tap in the chrome cannot reach the page. Nothing here is
 * touch-specific reasoning; that is the point.
 *
 * UNTESTED, AND SAID SO IN THE README. The libudev-zero EV_ABS bug in this
 * project came from code that looked right for hardware nobody had run it
 * against, so this claims correctness by construction and not by evidence. */

static void touchDispatch(VeronSeat *seat, WPEEventType type, guint32 time,
                          guint32 id, double x, double y)
{
    if (!seat->touchToplevel)
        return;

    if (!wpeVeronToplevelIsPageSurface(seat->touchToplevel, seat->touchSurface)) {
        /* A TAP IN THE CHROME IS A CLICK AS FAR AS A URL BAR IS CONCERNED.
         * Passing it as a pointer event means the browser needs no separate
         * touch path for its own widgets. */
        WPEEventType asPointer = (type == WPE_EVENT_TOUCH_DOWN) ? WPE_EVENT_POINTER_DOWN
                               : (type == WPE_EVENT_TOUCH_UP)   ? WPE_EVENT_POINTER_UP
                                                                : WPE_EVENT_POINTER_MOVE;
        wpeVeronToplevelEmitChromeEvent(seat->touchToplevel, asPointer, time,
                                        seat->modifiers, 1, x, y, 0, 0);
        return;
    }

    WPEView *view = seatViewFor(seat, seat->touchToplevel);
    if (!view)
        return;

    WPEEvent *event = wpe_event_touch_new(type, view, WPE_INPUT_SOURCE_TOUCHSCREEN,
        time, seat->modifiers, id, x, y);
    wpe_view_event(view, event);
    wpe_event_unref(event);
}

static void touchDown(void *data, struct wl_touch *touch, uint32_t serial, uint32_t time,
                      struct wl_surface *surface, int32_t id, wl_fixed_t sx, wl_fixed_t sy)
{
    VeronSeat *seat = data;
    if (!surface)
        return;

    seat->lastSerial    = serial;
    seat->touchSurface  = surface;
    seat->touchToplevel = wpeVeronToplevelForSurface(surface);

    double x = wl_fixed_to_double(sx), y = wl_fixed_to_double(sy);

    VeronTouchPoint *pt = g_new0(VeronTouchPoint, 1);
    pt->x = x; pt->y = y;
    g_hash_table_insert(seat->touchPoints, GUINT_TO_POINTER(id), pt);

    touchDispatch(seat, WPE_EVENT_TOUCH_DOWN, time, (guint32)id, x, y);
}

static void touchUp(void *data, struct wl_touch *touch, uint32_t serial,
                    uint32_t time, int32_t id)
{
    VeronSeat *seat = data;
    seat->lastSerial = serial;

    /* UP CARRIES NO COORDINATES, which is why the points are tracked at all.
     * A tap dispatched at (0,0) lands in the corner of the page. */
    VeronTouchPoint *pt = g_hash_table_lookup(seat->touchPoints, GUINT_TO_POINTER(id));
    if (!pt)
        return;

    touchDispatch(seat, WPE_EVENT_TOUCH_UP, time, (guint32)id, pt->x, pt->y);
    g_hash_table_remove(seat->touchPoints, GUINT_TO_POINTER(id));

    if (!g_hash_table_size(seat->touchPoints)) {
        seat->touchSurface  = NULL;
        seat->touchToplevel = NULL;
    }
}

static void touchMotion(void *data, struct wl_touch *touch, uint32_t time,
                        int32_t id, wl_fixed_t sx, wl_fixed_t sy)
{
    VeronSeat *seat = data;
    VeronTouchPoint *pt = g_hash_table_lookup(seat->touchPoints, GUINT_TO_POINTER(id));
    if (!pt)
        return;

    pt->x = wl_fixed_to_double(sx);
    pt->y = wl_fixed_to_double(sy);
    touchDispatch(seat, WPE_EVENT_TOUCH_MOVE, time, (guint32)id, pt->x, pt->y);
}

static void touchFrame(void *data, struct wl_touch *touch) { }

static void touchCancel(void *data, struct wl_touch *touch)
{
    VeronSeat *seat = data;

    /* CANCEL MEANS THE COMPOSITOR TOOK THE GESTURE -- an edge swipe, a system
     * gesture. Every point must be withdrawn or the page believes fingers are
     * still down and the next tap is treated as a continuation. */
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, seat->touchPoints);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        VeronTouchPoint *pt = value;
        touchDispatch(seat, WPE_EVENT_TOUCH_CANCEL, 0,
                      GPOINTER_TO_UINT(key), pt->x, pt->y);
    }
    g_hash_table_remove_all(seat->touchPoints);
    seat->touchSurface  = NULL;
    seat->touchToplevel = NULL;
}

static const struct wl_touch_listener touchListener = {
    touchDown, touchUp, touchMotion, touchFrame, touchCancel
};

/* ---- capabilities ---------------------------------------------------- */

static void seatCapabilities(void *data, struct wl_seat *wlSeat, uint32_t caps)
{
    VeronSeat *seat = data;

    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !seat->pointer) {
        seat->pointer = wl_seat_get_pointer(wlSeat);
        wl_pointer_add_listener(seat->pointer, &pointerListener, seat);
    } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && seat->pointer) {
        wl_pointer_release(seat->pointer);
        seat->pointer = NULL;
    }

    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !seat->keyboard) {
        seat->keyboard = wl_seat_get_keyboard(wlSeat);
        wl_keyboard_add_listener(seat->keyboard, &keyboardListener, seat);
    } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && seat->keyboard) {
        wl_keyboard_release(seat->keyboard);
        seat->keyboard = NULL;
    }

    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !seat->touch) {
        seat->touch = wl_seat_get_touch(wlSeat);
        wl_touch_add_listener(seat->touch, &touchListener, seat);
    } else if (!(caps & WL_SEAT_CAPABILITY_TOUCH) && seat->touch) {
        wl_touch_release(seat->touch);
        seat->touch = NULL;
    }
}

static void seatName(void *data, struct wl_seat *wlSeat, const char *name) { }

static const struct wl_seat_listener seatListener = { seatCapabilities, seatName };

/* ---- the view a toplevel is showing ---------------------------------- */

static gboolean firstViewCb(WPEToplevel *toplevel, WPEView *view, gpointer data)
{
    *(WPEView **)data = view;
    return TRUE; /* TRUE stops the iteration -- the first is the one we want */
}

static WPEView *seatViewFor(VeronSeat *seat, WPEToplevelVeron *toplevel)
{
    WPEView *view = NULL;
    wpe_toplevel_foreach_view(WPE_TOPLEVEL(toplevel), firstViewCb, &view);
    return view;
}

/* ---- lifetime -------------------------------------------------------- */

VeronSeat *wpeVeronSeatNew(WPEDisplayVeron *display, struct wl_seat *wlSeat)
{
    VeronSeat *seat = g_new0(VeronSeat, 1);
    seat->display = display;
    seat->wlSeat  = wlSeat;
    seat->touchPoints = g_hash_table_new_full(NULL, NULL, NULL, g_free);
    wl_seat_add_listener(wlSeat, &seatListener, seat);
    return seat;
}

void wpeVeronSeatFree(VeronSeat *seat)
{
    if (!seat)
        return;
    g_clear_pointer(&seat->pointer, wl_pointer_release);
    g_clear_pointer(&seat->keyboard, wl_keyboard_release);
    g_clear_pointer(&seat->touch, wl_touch_release);
    g_clear_pointer(&seat->touchPoints, g_hash_table_destroy);
    g_clear_object(&seat->keymap);
    g_free(seat);
}

WPEKeymap *wpeVeronSeatGetKeymap(VeronSeat *seat)
{
    return seat ? seat->keymap : NULL;
}
