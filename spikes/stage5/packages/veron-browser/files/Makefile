# veron-browser. Builds in about a second against the installed WPE.
#
#   make
#   ./veron-browser https://example.com
#
# The backend is found without any environment variable once installed: it goes
# to /usr/lib/wpe-platform-2.0/modules, which WPEExtensions.cpp:69 scans before
# the built-ins. WPE_PLATFORMS_PATH is for development -- a module built in a
# working directory and tried without installing it.
#
# WPE IS NEVER REBUILT for any of this. The browser links libWPEWebKit-2.0 and
# the backend is a GIO module loaded at runtime; both are already installed.

# libsoup-3.0 IS DECLARED NOW RATHER THAN ARRIVING BY ACCIDENT. It was already
# linked -- VERON-LINKED has been reporting `veron-browser links libsoup
# (libsoup-3.0.so.0) and deps.link does not say so` on every run -- because
# wpe-webkit-2.0 pulls it in transitively. The cookie dump uses SoupCookie
# directly, so the header is needed as well as the library, and an undeclared
# dependency that a gate has been naming for weeks is worth closing while the
# file is open.
PKGS = wpe-webkit-2.0 wpe-platform-2.0 wayland-client cairo glib-2.0 gobject-2.0 xkbcommon libsoup-3.0
# THE BACKEND'S HEADER IS COPIED IN BESIDE THE SOURCE by the recipe, so this
# needs no path to it. Building by hand outside the recipe, copy
# wpe-display-veron.h here first or add -I to point at it.
CFLAGS  += -O2 -g -Wall $(shell pkg-config --cflags $(PKGS)) -I.
# -lwpe-display-veron BECAUSE THIS CALLS INTO THE BACKEND DIRECTLY.
# wpe_toplevel_veron_set_chrome_height, _get_chrome_surface, _set_chrome_focus
# and wpe_display_veron_get_shm are ours, not WPE's, and they live in the
# platform module. It is installed in /usr/lib as well as under the module
# directory precisely so this link works; the module path is a symlink to the
# same file, so WPE dlopens the one this is linked against rather than a
# second copy with its own GTypes.
LIBS     = $(shell pkg-config --libs $(PKGS)) -lwpe-display-veron

veron-browser: main.o chrome.o settings.o
	$(CC) -o $@ main.o chrome.o settings.o $(LIBS)

clean:
	rm -f *.o veron-browser

.PHONY: clean
