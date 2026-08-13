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

PKGS = wpe-webkit-2.0 wpe-platform-2.0 wayland-client cairo glib-2.0 gobject-2.0 xkbcommon
# THE BACKEND'S HEADER IS COPIED IN BESIDE THE SOURCE by the recipe, so this
# needs no path to it. Building by hand outside the recipe, copy
# wpe-display-veron.h here first or add -I to point at it.
CFLAGS  += -O2 -g -Wall $(shell pkg-config --cflags $(PKGS)) -I.
LIBS     = $(shell pkg-config --libs $(PKGS))

veron-browser: main.o chrome.o
	$(CC) -o $@ main.o chrome.o $(LIBS)

clean:
	rm -f *.o veron-browser

.PHONY: clean
