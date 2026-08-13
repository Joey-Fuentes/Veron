# wpe-platform-veron

A fourth WPE platform backend, beside `drm`, `headless` and `wayland`. It exists
so a browser can have a URL bar.

## Why it exists

WPE's stock Wayland backend gives the page the toplevel's own `wl_surface` --
`WPEViewWayland.cpp:741`, where `wpe_view_wayland_get_wl_surface()` returns
`wpe_toplevel_wayland_get_wl_surface()`. The page **is** the window's contents,
so there is nowhere to draw chrome.

This backend gives the page a `wl_subsurface` positioned below a reserved strip.
The toplevel's surface carries the chrome; the page gets everything under it.

## Why a backend and not a patch

`WPEDisplayWayland`, `WPEToplevelWayland` and `WPEViewWayland` are all
`G_DECLARE_FINAL_TYPE`. Subclassing them would mean depending on a private
struct layout and on undocumented call ordering, and re-patching on every
upgrade. The **base** classes are `WPE_DECLARE_DERIVABLE_TYPE`, which is how the
three shipped backends are siblings rather than a hierarchy. This is a fourth
sibling, on public API only.

## Why WPE is never rebuilt

`WPEExtensions.cpp:62` scans `WPE_PLATFORMS_PATH` for GIO modules before the
built-ins. So this ships as a `.so`:

```sh
make
WPE_PLATFORMS_PATH=$PWD WPE_DISPLAY=wpe-display-veron \
  /usr/libexec/wpe-webkit-2.0/MiniBrowser https://example.com
```

One second per iteration, on the machine, with no CI involved.

## The eight vfuncs

`wpe/headless` is a complete backend in 433 lines and implements eight vfuncs
total; `wpe/wayland` is 5404 lines because it implements everything -- gamepads,
touch, input methods, presentation feedback, explicit sync, multi-screen. This
starts from the smaller shape.

| | |
|---|---|
| `connect` | Wayland connection, registry, required globals |
| `create_view` / `create_toplevel` | the two factories |
| `get_egl_display` | so WebKit can render with the GPU |
| `resize` / `set_fullscreen` / `set_title` | toplevel |
| `render_buffer` | **the one that matters** -- attaches to the page subsurface |

## What is done, and how it was checked

All five source files compile clean -- zero errors, zero warnings under
`-Wall -Wextra` -- and produce object files whose every internal symbol
resolves. That was done against stub headers generated from WPE's own sources,
because this machine has no `wayland-client` development package; the 48
remaining undefined symbols are Wayland's own and come from
`libwayland-client` plus the generated protocol code at link time.

**Every API name was verified against `Source/WebKit/WPEPlatform`**, not
recalled. Two were wrong and are recorded where they were fixed:
`wpe_toplevel_get_width`/`get_height` do not exist -- `wpe_toplevel_get_size`
returns both through out parameters -- and there is no `wpe_toplevel_get_view`,
only `wpe_toplevel_foreach_view` with a callback.

Three things were missing from the first draft and are now present: the
`xdg_wm_base` ping listener, without which the compositor kills the client as
unresponsive a few seconds in; the `zwp_linux_dmabuf_v1` registry binding, used
by the view but never bound; and the frame-callback clear before requesting a
new one, without which a second render before the first frame leaks a
`wl_callback` and leaves a stale listener pointing at a returned buffer.

## Input, and why the subsurface earns its keep

**Wayland does the hit testing.** The page is a separate surface, so the
compositor decides which one the pointer is over and says so in
`wl_pointer.enter` -- and coordinates arrive *relative to that surface*. A
click at the top of the page is `(x, 0)` even though it is 36 pixels down the
window. No arithmetic, no off-by-one on resize, and no way for a click in the
chrome to reach the page: they are different surfaces and the compositor never
confuses them.

A shell that drew chrome into the same surface would have to hit-test every
event itself and translate the ones it passed on. That is the code that goes
wrong, and this design does not have it.

**The keyboard is different and cannot be.** "The URL bar is being typed into"
is a state the browser knows and the compositor does not, so
`wpe_toplevel_veron_set_chrome_focus()` decides: with it set, keys arrive as
`chrome-key`; without it they reach the page.

**Chrome events are signals, not `WPEEvent`s.** A `WPEEvent` belongs to a
`WPEView` and the chrome is not one, so `chrome-event` and `chrome-key` carry
raw parameters instead of inventing a view to wrap them.

## What is not done

**The chrome is not drawn.** `wpe_toplevel_veron_set_chrome_height()` reserves
the strip and `wpe_toplevel_veron_get_chrome_surface()` hands over the surface;
putting pixels in it is the browser's, and is the next package.

**Touch is implemented and untested.** There is no touchscreen here to run it
against, so it claims correctness by construction and not by evidence. It is
written rather than stubbed because a bound-but-ignored `wl_touch` is worse
than an unbound one -- the compositor believes the client is handling touch and
routes it here, where it would vanish.

**Nothing has been run.** It compiles, it links against stubs, and its symbols
resolve. Whether a page appears is the first thing to find out, and
`chrome_height` defaults to 0 so that question can be asked before any chrome
exists: at 0 this should behave exactly like the stock backend.

**Input methods are not wired.** `WPEInputMethodContext` exists in the platform
API and `create_input_method_context` is a display vfunc this does not
implement, so there is no compose key, no dead keys and no CJK input. English
typing works; anything needing preedit does not.

**One `wl_seat` only.** The registry keeps the last seat it sees. A machine
with two input seats -- rare outside multi-seat kiosks -- would use one.
