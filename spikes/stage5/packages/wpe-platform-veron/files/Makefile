# Build the module. NOT a recipe -- this is what you run on the laptop to
# iterate, and the whole point of the backend being a GIO module rather than a
# WPE patch: this takes about a second.
#
#   make && WPE_PLATFORMS_PATH=$PWD WPE_DISPLAY=wpe-display-veron \
#     /usr/libexec/wpe-webkit-2.0/MiniBrowser https://example.com
#
# WPE_PLATFORMS_PATH IS READ BY WPEExtensions.cpp:62, which scans each
# directory for GIO modules before falling back to the built-in backends.
# WPE_DISPLAY names the extension -- WPEDisplay.cpp:272 -- and without it the
# highest-priority extension that connects wins, which is this one at 100.

PKGS  = wpe-platform-2.0 wayland-client glib-2.0 gobject-2.0 gio-2.0 epoxy xkbcommon
CFLAGS  += -O2 -g -fPIC -Wall $(shell pkg-config --cflags $(PKGS))
# -soname SO THE BROWSER CAN LINK THIS. veron-browser calls
# wpe_toplevel_veron_set_chrome_height and friends directly; without a soname
# its DT_NEEDED would carry the full build path. The same file is installed
# twice -- once in /usr/lib where the linker and ld.so find it, once under the
# module directory where WPE dlopens it -- so there is one copy, not two.
LDFLAGS += -shared -Wl,-soname,libwpe-display-veron.so
LIBS     = $(shell pkg-config --libs $(PKGS))

# THE PROTOCOL HEADERS ARE GENERATED, NOT SHIPPED. xdg-shell and
# linux-dmabuf are XML in wayland-protocols; wayland-scanner turns them into
# the client stubs this links against. Both are already in the package set --
# wayland-protocols 1.49 covers everything used here.
PROTO_DIR = $(shell pkg-config --variable=pkgdatadir wayland-protocols)
SCANNER   = wayland-scanner

GEN = xdg-shell-client-protocol.h xdg-shell-protocol.c \
      linux-dmabuf-unstable-v1-client-protocol.h linux-dmabuf-unstable-v1-protocol.c

OBJS = wpe-display-veron.o wpe-toplevel-veron.o wpe-view-veron.o \
       wpe-veron-seat.o wpe-veron-shm.o wpe-veron-source.o \
       xdg-shell-protocol.o linux-dmabuf-unstable-v1-protocol.o

all: libwpe-display-veron.so

xdg-shell-client-protocol.h:
	$(SCANNER) client-header $(PROTO_DIR)/stable/xdg-shell/xdg-shell.xml $@
xdg-shell-protocol.c:
	$(SCANNER) private-code  $(PROTO_DIR)/stable/xdg-shell/xdg-shell.xml $@
linux-dmabuf-unstable-v1-client-protocol.h:
	$(SCANNER) client-header $(PROTO_DIR)/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml $@
linux-dmabuf-unstable-v1-protocol.c:
	$(SCANNER) private-code  $(PROTO_DIR)/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml $@

$(OBJS): $(GEN)

libwpe-display-veron.so: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBS)

clean:
	rm -f $(OBJS) $(GEN) libwpe-display-veron.so

.PHONY: all clean
