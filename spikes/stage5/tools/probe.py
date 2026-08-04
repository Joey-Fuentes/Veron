#!/usr/bin/env python3
# probe.py -- find out what a package actually is, instead of guessing.
#
# WHY THIS EXISTS. Writing a recipe needs a version, a digest, a build system,
# a license, a test target and a dependency list. Every one of those is a FACT
# about the tarball, and every one of them is something an author is tempted
# to supply from memory. A digest from memory is laundered provenance; a
# dependency list from memory is a build failure three packages later.
#
# So: fetch it, unpack it, look.
#
# WHAT THIS IS NOT. It is not a recipe generator, and the skeleton it emits is
# deliberately incomplete. Configure flags are JUDGEMENT -- which optional
# feature to disable is a policy decision about the system being built, not a
# property of the tarball. The probe lists what COULD be turned off and leaves
# the choosing to a person. Anything it cannot determine it says so about,
# rather than filling in a plausible default.
#
# RUNS IN THE AIRLOCK. Network lives here. Nothing it produces enters a build
# without a human reading it first.

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

UA = {"User-Agent": "veron-probe"}


def get(url, timeout=30):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def try_get(url):
    try:
        return get(url)
    except Exception as e:
        return None


# ------------------------------------------------------------ discovery


def latest_github(repo):
    """Newest release tag and its assets."""
    d = try_get(f"https://api.github.com/repos/{repo}/releases/latest")
    if not d:
        return None
    j = json.loads(d)
    return {
        "version": j.get("tag_name", ""),
        "assets": [{"name": a["name"], "url": a["browser_download_url"]}
                   for a in j.get("assets", [])],
        "published": j.get("published_at", ""),
    }


def latest_gnu(project):
    """GNU projects publish a directory index; read it rather than guess."""
    d = try_get(f"https://ftp.gnu.org/gnu/{project}/")
    if not d:
        return None
    names = re.findall(rf'href="({re.escape(project)}-[0-9][^"]*\.tar\.[gx]z)"',
                       d.decode("utf-8", "replace"))
    if not names:
        return None

    def key(n):
        v = re.search(rf"{re.escape(project)}-([0-9.]+)", n).group(1)
        return [int(x) for x in v.strip(".").split(".") if x.isdigit()]

    names = sorted(set(names), key=key)
    return {"version": key(names[-1]), "assets":
            [{"name": n, "url": f"https://ftp.gnu.org/gnu/{project}/{n}"}
             for n in names[-3:]]}


# ------------------------------------------------------------ inspection


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def build_system(root):
    """What actually builds this, determined by looking."""
    has = lambda *p: os.path.exists(os.path.join(root, *p))
    out = []
    if has("configure"):
        out.append("autotools (configure SHIPPED -- generated, not in git)")
    elif has("configure.ac") or has("configure.in"):
        out.append("autotools (configure.ac only -- NEEDS autoreconf)")
    if has("meson.build"):
        out.append("meson")
    if has("CMakeLists.txt"):
        out.append("cmake")
    if has("Makefile") and not has("configure"):
        out.append("plain Makefile (no configure)")
    return out or ["UNKNOWN -- none of configure/meson.build/CMakeLists/Makefile"]


def license_of(root):
    for n in ("COPYING", "LICENSE", "LICENCE", "COPYING.LIB", "LICENSE.txt",
              "COPYING.txt"):
        p = os.path.join(root, n)
        if os.path.exists(p):
            head = open(p, "rb").read(4000).decode("utf-8", "replace")
            for pat, spdx in (
                (r"GNU GENERAL PUBLIC LICENSE.*Version 3", "GPL-3.0-or-later"),
                (r"GNU GENERAL PUBLIC LICENSE.*Version 2", "GPL-2.0-or-later"),
                (r"GNU LESSER GENERAL", "LGPL-2.1-or-later"),
                (r"Permission to use, copy, modify, and distribute", "ISC-or-MIT-like"),
                (r"Redistribution and use in source and binary", "BSD-like"),
                (r"Permission is hereby granted, free of charge", "MIT"),
            ):
                if re.search(pat, head, re.S | re.I):
                    return n, spdx
            return n, "PRESENT but unrecognised -- read it"
    return None, "NO LICENSE FILE FOUND -- read the source headers"


def test_target(root):
    """Is there a check target, and does it look real?"""
    for mk in ("Makefile.am", "Makefile.in", "Makefile", "GNUmakefile"):
        p = os.path.join(root, mk)
        if not os.path.exists(p):
            continue
        t = open(p, "rb").read().decode("utf-8", "replace")
        if re.search(r"^(check|test)\s*:", t, re.M) or "TESTS" in t:
            return f"yes (in {mk})"
    return "NONE FOUND -- declare verification as none rather than omitting it"


def declared_deps(root):
    """Dependencies the SOURCE declares. Not the whole story, and says so.

    Static inspection finds what the build system asks for. It cannot find a
    dependency discovered at runtime, nor tell a hard requirement from an
    optional one. The authoritative list comes from ldd and the .pc files
    AFTER a build -- see `probe linked`.
    """
    found = {"pkg_config": set(), "check_lib": set(), "pc_requires": set()}
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "tests", "test")]
        for fn in files:
            if fn in ("configure.ac", "configure.in", "meson.build") or fn.endswith(".pc.in"):
                t = open(os.path.join(dirpath, fn), "rb").read().decode("utf-8", "replace")
                for m in re.finditer(r"PKG_CHECK_MODULES\(\[?\w+\]?,\s*\[?([^\],\)]+)", t):
                    found["pkg_config"].add(m.group(1).strip())
                for m in re.finditer(r"AC_CHECK_LIB\(\[?([\w.+-]+)\]?", t):
                    found["check_lib"].add(m.group(1))
                for m in re.finditer(r"^Requires(?:\.private)?:\s*(.+)$", t, re.M):
                    found["pc_requires"].add(m.group(1).strip())
                for m in re.finditer(r"dependency\(\s*'([^']+)'", t):
                    found["pkg_config"].add(m.group(1))
    return {k: sorted(v) for k, v in found.items()}


def configure_options(root):
    """What COULD be turned off. Choosing is judgement, not a fact."""
    cfg = os.path.join(root, "configure")
    if not os.path.exists(cfg):
        return None
    try:
        p = subprocess.run(["sh", cfg, "--help"], cwd=root,
                           capture_output=True, text=True, timeout=120)
    except Exception as e:
        return [f"could not run configure --help: {e}"]
    opts = []
    for ln in p.stdout.splitlines():
        m = re.match(r"\s+(--(?:with|enable|disable|without)-[\w-]+)", ln)
        if m:
            opts.append(f"{m.group(1):<34}{ln.strip()[len(m.group(1)):].strip()[:60]}")
    return opts


# ------------------------------------------------------------ report


def probe(url, keep=False):
    name = url.rsplit("/", 1)[-1]
    print(f"== {name}")
    print(f"   {url}")

    blob = try_get(url)
    if blob is None:
        print("   FETCH FAILED -- cannot probe what cannot be downloaded")
        return None
    digest = sha256_bytes(blob)
    print(f"\n   sha256    {digest}")
    print(f"   bytes     {len(blob)}")

    # A signature, if upstream publishes one. Absence is a criterion-1 gap
    # and belongs in the record as a declared deferral, not as silence.
    sig = None
    for ext in (".sig", ".asc", ".sign"):
        if try_get(url + ext) is not None:
            sig = url + ext
            break
    print(f"   signature {sig or 'NONE FOUND (.sig/.asc/.sign) -- declare the deferral'}")

    work = os.path.join(os.environ.get("TMPDIR", "/tmp"), "veron-probe", name)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    tb = os.path.join(work, name)
    open(tb, "wb").write(blob)
    try:
        with tarfile.open(tb) as tf:
            top = os.path.commonprefix([m.name for m in tf.getmembers()]).strip("/")
            tf.extractall(work, filter="data")
    except Exception as e:
        print(f"   UNPACK FAILED: {e}")
        return None
    root = os.path.join(work, top)
    print(f"   unpacks to {top}/")

    print("\n   build system")
    for b in build_system(root):
        print(f"     {b}")

    lf, spdx = license_of(root)
    print(f"\n   license   {spdx}" + (f"  (from {lf})" if lf else ""))
    print(f"   tests     {test_target(root)}")

    d = declared_deps(root)
    print("\n   dependencies the SOURCE declares")
    print("     (static only -- run `probe linked` after a build for the real list)")
    for k, v in d.items():
        print(f"     {k:<12} {', '.join(v) if v else '-'}")

    opts = configure_options(root)
    if opts is None:
        print("\n   configure --help: no configure script to ask")
    else:
        print(f"\n   {len(opts)} optional features -- EACH IS A DECISION, not a default")
        for o in opts[:40]:
            print(f"     {o}")
        if len(opts) > 40:
            print(f"     ... and {len(opts) - 40} more")

    print("\n   --- recipe skeleton (INCOMPLETE BY DESIGN) ---")
    ver = re.sub(r"^[a-zA-Z_+-]*-", "", top)
    print(f'''
name    = "{top.rsplit('-', 1)[0]}"
version = "{ver}"
group   = "build-substrate"
license = "{spdx}"

[source]
url       = "{url}"
sha256    = "{digest}"
signature = "{sig or 'none -- upstream publishes no detached signature'}"
crosschecked_against = []   # name the distros whose digest you compared

[deps]
build        = []   # FILL IN -- see the declared list above
link         = []
runtime      = []
optional_off = []   # FILL IN -- every feature you disable, named

[declared]
configure_flags = []   # JUDGEMENT: the probe lists options, you choose
verification    = ""   # what `make check` actually reports, once run
deferral        = ""   # REQUIRED -- what was not verified, stated
''')
    if not keep:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"   (unpacked tree kept at {root})")
    return digest


def cmd_probe(a):
    for url in a.url:
        probe(url, a.keep)
        print()
    return 0


def cmd_latest(a):
    for spec in a.spec:
        if "/" in spec:
            r = latest_github(spec)
            src = f"github:{spec}"
        else:
            r = latest_gnu(spec)
            src = f"gnu:{spec}"
        print(f"== {src}")
        if not r:
            print("   could not determine -- check the project's release page by hand")
            continue
        print(f"   latest    {r['version']}")
        for asset in r["assets"]:
            print(f"   asset     {asset['name']}")
            print(f"             {asset['url']}")
        print()
    return 0


def cmd_linked(a):
    """The authoritative dependency list: what the built binaries actually need.

    Static inspection guesses; this reads the ELF. Run it against a DESTDIR
    after a build -- what shows up here is `deps.link`, and anything the
    source declared that does NOT show up was optional and got detected off.
    """
    needed, pcs = {}, {}
    for dirpath, _, files in os.walk(a.destdir):
        for fn in files:
            p = os.path.join(dirpath, fn)
            if fn.endswith(".pc"):
                t = open(p, encoding="utf-8", errors="replace").read()
                req = re.findall(r"^Requires(?:\.private)?:\s*(.+)$", t, re.M)
                if req:
                    pcs[os.path.relpath(p, a.destdir)] = req
            if os.path.islink(p):
                continue
            with open(p, "rb") as f:
                if f.read(4) != b"\x7fELF":
                    continue
            try:
                out = subprocess.run(["readelf", "-d", p], capture_output=True,
                                     text=True).stdout
            except FileNotFoundError:
                print("readelf not available"); return 1
            for m in re.finditer(r"\(NEEDED\).*\[([^\]]+)\]", out):
                needed.setdefault(m.group(1), []).append(os.path.relpath(p, a.destdir))

    print("  shared libraries actually linked (this is deps.link):")
    for lib in sorted(needed):
        print(f"    {lib:<28} {needed[lib][0]}"
              + (f" (+{len(needed[lib]) - 1} more)" if len(needed[lib]) > 1 else ""))
    if pcs:
        print("\n  .pc files this package installs -- their Requires become")
        print("  dependencies of everything that consumes it:")
        for f, req in sorted(pcs.items()):
            print(f"    {f}: {', '.join(req)}")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="probe")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("latest", help="newest release for gnu:<project> or <owner>/<repo>")
    p.add_argument("spec", nargs="+")
    p.set_defaults(fn=cmd_latest)

    p = sub.add_parser("url", help="fetch, unpack and report on a tarball")
    p.add_argument("url", nargs="+")
    p.add_argument("--keep", action="store_true", help="keep the unpacked tree")
    p.set_defaults(fn=cmd_probe)

    p = sub.add_parser("linked", help="the real deps: what a built DESTDIR links")
    p.add_argument("destdir")
    p.set_defaults(fn=cmd_linked)

    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
