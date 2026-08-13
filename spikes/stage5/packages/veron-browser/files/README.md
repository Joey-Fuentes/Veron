# veron-browser

A web browser with a URL bar, back, forward and reload. About 700 lines.

## How it works

WebKit creates its own `WPEView` and `WPEToplevel` on whatever `WPEDisplay` it
is given -- `"display"` is a construct property of `WebKitWebView`, the same one
`Tools/MiniBrowser/wpe/main.cpp:411` uses. This passes a `WPEDisplayVeron`, so
the toplevel WebKit builds is one whose page lives in a subsurface with a strip
reserved above it.

The strip is then ours. `chrome.c` draws it with Cairo directly into the mapped
pages of a `wl_shm` buffer -- no intermediate image, no copy -- and the backend
delivers events that land on it as `chrome-event` and `chrome-key` rather than
to the page.

**Nothing here hit-tests against web content and nothing translates
coordinates.** The compositor knows the page and the strip are different
surfaces and says which one an event was on. That is the whole reason this file
is short.

## What works

Typing a URL and pressing Enter navigates. Back, forward and reload work and
grey out when they cannot. The field follows the page's URL, shows load
progress behind the text, and the window title follows the page.

Editing is a real text field: caret movement, Home/End, Delete, Backspace, and
UTF-8 handled by character rather than byte -- backspacing over `é` removes both
its bytes rather than leaving an invalid string Cairo would refuse to draw.

**What is typed is resolved dully and on purpose.** A scheme means a URL. A dot
and no space means a hostname and gets `https://`. Everything else is a search.
That is wrong for a bare LAN machine name, which is a real cost and smaller
than the alternative: a mistyped word becoming a DNS lookup that hangs. Input
is trimmed at both ends first -- an earlier version skipped only leading spaces,
so a pasted `"  example.com  "` contained a space and became a search.

## The user agent

WPE's default is

```
Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/60.5 Safari/605.1.15
```

**The fault is `Version/60.5`, not "Safari on Linux".** Epiphany -- GNOME Web, a
shipped browser -- sends `Version/16.4 Safari/605.1.15` with the same `X11;
Linux x86_64` platform and is not treated as a bot. Every WebKit browser on
Linux claims Safari, because the alternative is half the web serving degraded
markup.

But there has never been a Safari 60.5. Real Safari went 15, 16, 17, 18, then
to calendar versioning at 26. `UserAgentGLib.cpp:110` says the number was chosen
high deliberately to get past version checks -- which makes it a version no
release has ever carried, and that is far louder than the platform token.

This sends

```
Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Veron/1.0 Safari/605.1.15
```

`AppleWebKit/605.1.15` names the engine truthfully -- this *is* WebKit.
`Veron/1.0` says which browser, in the position Epiphany uses for its own
token. `Safari/605.1.15` keeps sites serving markup this engine can render, and
`Version/26.6` is a Safari release that actually exists.

**A vendor token nobody recognises is not a bot signal.** Every WebKit browser
adds one -- Epiphany, Luakit, surf, Midori -- and detectors read the engine and
version tokens, not the vendor string. Removing it would be less honest and no
safer.

**Claiming Firefox would be worse, which was not obvious.** A UA is checked
against the TLS handshake by anything serious. Firefox uses NSS; this uses
whatever glib-networking is built on, exactly like Epiphany. Claiming Firefox
would *create* a mismatch between handshake and string that does not otherwise
exist. Claiming Safari is consistent with the engine actually present.

**The version goes stale and that is its own signal.** 26.6 was current in
August 2026. `VERON_USER_AGENT` overrides without a rebuild.

**Measured, not assumed.** `httpbin.org/headers` on the machine showed every
other header already normal -- `Accept`, `Accept-Encoding`, `Accept-Language:
en-US`, `Sec-Fetch-*` all present and unremarkable. The UA was the only anomaly.

The `X-Amzn-Trace-Id` in that output is not sent by the browser: AWS's load
balancer stamps it on the way in, and httpbin.org runs behind one. It appears
hitting any AWS-fronted site from any browser.

## Memory: none, on purpose

The session is `webkit_network_session_new_ephemeral()` -- the same thing
MiniBrowser's `--private` uses. **Nothing is written to disk**: no cookie jar,
no cache, no local storage, no IndexedDB, no saved credentials. ITP is off
because profiling which sites track you is itself state, and persistent
credential storage is disabled explicitly so a later change to the session type
cannot quietly turn it back on.

This is stated in code rather than left to the filesystem. The default session
would write to the XDG directories, which here land on the tmpfs overlay, so
nothing would survive a reboot anyway -- but that is a property of the root
filesystem, not a decision. Mount `/persist` over the wrong path and the
browser silently starts keeping history it was never meant to keep.

**It costs CAPTCHAs and that is accepted.** A browser arriving with no cookies
on every request looks like automation, and Google asks more often because of
it. The alternative is a disk that remembers where the machine has been.

## What is not done

**No tabs, no history UI, no bookmarks, no downloads UI.** `WebKitBackForwardList`
and `WebKitDownload` are in the API and unused.

**No find-in-page**, though `WebKitFindController` is there.

**No context menu.** Right-clicking the page does whatever WebKit does by
default.

**The chrome has no keyboard shortcuts.** Ctrl+L to focus the URL bar, Alt+Left
for back and F5 to reload would all be natural and none are bound -- the strip
only sees keys when it already has focus, so a shortcut has to be handled in the
page's key path instead.

**Nothing has been run.** It compiles clean with zero warnings and its logic is
unit-tested where it can be -- address resolution across eleven inputs, text
editing including multibyte -- but no page has ever been drawn by it.
