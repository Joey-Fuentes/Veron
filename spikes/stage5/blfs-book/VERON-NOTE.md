# BLFS book — a pinned corroboration source

**BLFS 13.0 (systemd edition), chunked HTML.** Committed rather than fetched,
for the same reason every upstream tarball is pinned: an answer that depends
on when you ran it is not an answer. `tools/blfs.py` reads this tree.

## What it is used for, and what it is not

**Used for:** the dependency graph and the build ORDER. BLFS states
dependencies as Required / Recommended / Optional, which maps directly onto
`deps.link`, `deps.build` and `optional_off` in a recipe — and it writes down
the things a graph cannot express, like which two packages need a two-pass
build to break a cycle.

**Not used for:** deciding what version Veron ships, and not treated as
authority on what a package *needs*.

BLFS builds a conventional X11 desktop with systemd and dbus present. Its
"required" therefore means "required for the way BLFS builds it", and several
of those are already known to be wrong for us:

  - Mesa is listed as REQUIRING Xorg Libraries. With `-Dplatforms=wayland`
    it does not.
  - Mesa lists LLVM as merely RECOMMENDED. For llvmpipe it is mandatory.
  - WebKitGTK is listed as requiring BOTH GTK-3 and GTK-4, and GTK-4 pulls
    librsvg, which pulls cargo, which pulls Rust.

So the book is a map to argue with. `probe url` reads the actual tarball --
its meson.build, its configure, its licence file -- and that is what settles
a disagreement.

## Stable, not development

The development book carries an explicit warning that its version set may not
be self-consistent, because a package can be bumped before its dependents are
adjusted. That is fine for a reader following instructions and bad for us,
because an inconsistent set produces a failure three packages downstream that
is indistinguishable from a Veron bug.

Stable trails upstream by roughly a release cycle -- Mesa 25.3.5 here against
26.1.6 upstream -- and that is expected. Pin upstream's current stable per
package; use this for the edges.

`images/` and `stylesheets/` were dropped: nothing here is read by a browser.
