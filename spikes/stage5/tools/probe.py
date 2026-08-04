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
import socket
import subprocess
import sys
import tarfile
import urllib.request

UA = {"User-Agent": "veron-probe"}

# FORCE IPv4.
#
# ftp.gnu.org publishes an AAAA record. Python prefers IPv6 when the resolver
# offers it, and a runner with no IPv6 route then fails INSTANTLY with
# "[Errno 101] Network is unreachable" -- not a timeout, so retrying and
# waiting do not help. Five of the nine group-1 packages live on ftp.gnu.org,
# and the failure is intermittent because it depends on what the resolver
# happens to return, which is the worst kind: it works until it does not, and
# looks like the site is down.
#
# GitHub kept working through the same failure, which is how the cause was
# isolated -- a general outage would have taken both.
_real_getaddrinfo = socket.getaddrinfo


def _ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
    return _real_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)


if os.environ.get("VERON_ALLOW_IPV6") != "1":
    socket.getaddrinfo = _ipv4_only

# THE FIRST MIRROR THAT ANSWERS. tools/clone-pinned.sh already does this for
# git and the airlock fetch does it for tarballs, after a run died taking 134
# seconds to fail reaching one host. ftpmirror.gnu.org redirects to whichever
# mirror is closest and alive.
GNU_HOSTS = ("https://ftp.gnu.org/gnu", "https://ftpmirror.gnu.org/gnu")


def get(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def try_get(url, timeout=20, quiet=False):
    """Fetch, or say why not -- and say WHICH url, while it is happening.

    Every print in this tool goes to a pipe under CI (`| tee`), and Python
    block-buffers a pipe: the job looked hung for minutes with no output while
    it was working normally. flush=True on progress lines is what makes a slow
    fetch distinguishable from a stuck one.

    A short timeout matters for the same reason a dead mirror should cost
    seconds rather than a run -- the airlock fetch already learned this after
    a run died taking 134 seconds to fail reaching one host.
    """
    if not quiet:
        print(f"   .. {url}", flush=True)
    try:
        return get(url, timeout=timeout)
    except Exception as e:
        if not quiet:
            print(f"      {type(e).__name__}: {str(e)[:70]}", flush=True)
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


def latest_gitlab(path, host="gitlab.com"):
    """Newest release on a GitLab instance.

    bzip2's canonical home is now gitlab.com/bzip2/bzip2, not sourceware --
    so a probe that only knew GNU and GitHub would quietly send you to a
    stale mirror. Three forges is not a pattern worth abstracting yet, but
    "wherever upstream actually lives" is, so each gets its own lookup rather
    than a guess.
    """
    import urllib.parse
    pid = urllib.parse.quote(path, safe="")
    d = try_get(f"https://{host}/api/v4/projects/{pid}/releases")
    if not d:
        return None
    j = json.loads(d)
    if not j:
        return None
    r = j[0]
    assets = []
    # MAINTAINER-UPLOADED LINKS FIRST. GitLab's `sources` are auto-generated
    # archives regenerated on demand -- the same hazard as GitHub's "Source
    # code (tar.gz)", whose checksums shifted under the whole ecosystem when
    # the compression settings changed. Never pin one.
    for a in r.get("assets", {}).get("links", []):
        assets.append({"name": a.get("name", ""), "url": a.get("url", "")})
    for a in r.get("assets", {}).get("sources", []):
        assets.append({"name": f"AUTO-GENERATED {a.get('format')} -- DO NOT PIN",
                       "url": a.get("url", "")})
    return {"version": r.get("tag_name", ""), "assets": assets,
            "published": r.get("released_at", "")}


def latest_gnu(project):
    """GNU projects publish a directory index; read it rather than guess."""
    d = base = None
    for host in GNU_HOSTS:
        d = try_get(f"{host}/{project}/")
        if d:
            base = f"{host}/{project}"
            break
    if not d:
        return None
    html = d.decode("utf-8", "replace")
    # .tar.lz and .tar.bz2 are common on ftp.gnu.org too; the first pattern
    # only matched gz/xz and would have silently reported "not found" for a
    # project that publishes neither.
    names = re.findall(
        rf'href="({re.escape(project)}-[0-9][^"]*\.tar\.(?:gz|xz|bz2|lz))"', html)
    if not names:
        return None

    def ver(n):
        # The trailing dot matters: "[0-9][0-9.]*" greedily eats the "." in
        # ".tar.xz" and yields "1.4.20." -- which then sorts and prints wrong.
        return re.search(rf"{re.escape(project)}-([0-9]+(?:\.[0-9]+)*)", n).group(1)

    def key(n):
        return [int(x) for x in ver(n).strip(".").split(".") if x.isdigit()]

    names = sorted(set(names), key=key)
    # VERSION AS A STRING. This returned the sort key -- a list of ints -- so
    # the report printed "[1, 4, 20]" where a version belonged.
    return {"version": ver(names[-1]), "assets":
            [{"name": n, "url": f"{base}/{n}"}
             for n in names if key(n) == key(names[-1])]}


def latest_index(url, name=None):
    """Newest tarball in any HTML directory listing.

    bzip2 (sourceware) and xz (tukaani) are neither GNU nor on GitHub, so the
    two specific lookups cannot reach them. Rather than special-case each
    project forever, read whatever index the URL serves.
    """
    d = try_get(url if url.endswith("/") else url + "/")
    if not d:
        return None
    html = d.decode("utf-8", "replace")
    pat = rf'href="({re.escape(name)}-[0-9][^"]*\.tar\.(?:gz|xz|bz2|lz))"' if name \
        else r'href="([A-Za-z0-9_.+-]+-[0-9][^"]*\.tar\.(?:gz|xz|bz2|lz))"'
    names = sorted(set(re.findall(pat, html)))
    if not names:
        return None

    def key(n):
        m = re.search(r"-([0-9]+(?:\.[0-9]+)*)", n)
        return [int(x) for x in m.group(1).split(".")] if m else [0]

    names.sort(key=key)
    base = url if url.endswith("/") else url + "/"
    top = key(names[-1])
    return {"version": ".".join(str(x) for x in top),
            "assets": [{"name": n, "url": base + n}
                       for n in names if key(n) == top]}


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
                # ORDER MATTERS: the zlib licence contains "Permission is
                # granted to anyone to use", which a looser MIT pattern would
                # swallow. zlib-1.3.2 came back "PRESENT but unrecognised"
                # precisely because this list did not know it.
                # DISCRIMINATE BEFORE GENERALISING. bzip2 and zlib share the
                # "altered source versions must be plainly marked" clause, so
                # the distinctive names come first -- otherwise bzip2 is
                # reported as Zlib, confidently and wrongly.
                (r"Julian Seward", "bzip2-1.0.6"),
                (r"Jean-loup Gailly|Mark Adler", "Zlib"),
                (r"altered source versions must be plainly marked", "Zlib-or-bzip2-like -- READ IT"),
                (r"GNU GENERAL PUBLIC LICENSE.*Version 3", "GPL-3.0-or-later"),
                (r"GNU GENERAL PUBLIC LICENSE.*Version 2", "GPL-2.0-or-later"),
                (r"GNU LESSER GENERAL PUBLIC LICENSE.*Version 3", "LGPL-3.0-or-later"),
                (r"GNU LESSER GENERAL", "LGPL-2.1-or-later"),
                (r"Apache License.*Version 2\.0", "Apache-2.0"),
                (r"Mozilla Public License.*2\.0", "MPL-2.0"),
                (r"THIS SOFTWARE IS PROVIDED.*ISC", "ISC"),
                (r"Permission to use, copy, modify, and/or distribute", "ISC"),
                (r"Permission to use, copy, modify, and distribute", "ISC-or-MIT-like"),
                (r"Redistribution and use in source and binary.*3\. Neither", "BSD-3-Clause"),
                (r"Redistribution and use in source and binary", "BSD-2-or-3-Clause"),
                (r"Permission is hereby granted, free of charge", "MIT"),
                (r"public domain", "public-domain-claimed -- read it"),
            ):
                if re.search(pat, head, re.S | re.I):
                    return n, spdx
            return n, "PRESENT but unrecognised -- read it"
    return None, "NO LICENSE FILE FOUND -- read the source headers"


def spdx_tags(root, limit=4000):
    """SPDX-License-Identifier tags in the source.

    A COPYING file says what the project ships under; per-file tags say what
    each part is, and a package with several is worth knowing about before it
    reaches a GPL corresponding-source manifest.
    """
    seen = {}
    n = 0
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in files:
            if n >= limit:
                break
            if not fn.endswith((".c", ".h", ".cc", ".cpp", ".sh", ".am", ".ac", ".py")):
                continue
            n += 1
            try:
                head = open(os.path.join(dirpath, fn), "rb").read(2048)
            except OSError:
                continue
            m = re.search(rb"SPDX-License-Identifier:\s*([^\r\n*/]+)", head)
            if m:
                tag = m.group(1).decode("utf-8", "replace").strip()
                seen[tag] = seen.get(tag, 0) + 1
    return seen


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
    found = {"pkg_config": set(), "check_lib": set(), "pc_requires": set(),
             "vcpkg": set(), "cmake_find": set(), "cargo": set()}
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "tests", "test", "Tests")]
        for fn in files:
            # VCPKG MANIFESTS ARE THE ONLY HONEST SOURCE FOR SOME PROJECTS.
            # Ladybird has no distro packaging and is not in BLFS, so nothing
            # corroborates its dependency list -- but it DECLARES one, in
            # vcpkg.json, and that file is the closest thing to authoritative
            # there is. STAGE5.md calls the tier-3 estimate "the softest
            # number in this document" precisely because vcpkg vendors these;
            # reading the manifest is what turns the guess into a list.
            if fn == "vcpkg.json":
                try:
                    j = json.loads(open(os.path.join(dirpath, fn),
                                        encoding="utf-8", errors="replace").read())
                except Exception:
                    continue
                for d in j.get("dependencies", []):
                    found["vcpkg"].add(d if isinstance(d, str) else d.get("name", ""))
                for ov in j.get("overrides", []):
                    nm, v = ov.get("name", ""), ov.get("version", "")
                    if nm:
                        found["vcpkg"].add(f"{nm}=={v}" if v else nm)
                continue
            if fn == "Cargo.toml":
                t = open(os.path.join(dirpath, fn), "rb").read().decode("utf-8", "replace")
                m = re.search(r"^\[dependencies\](.*?)(^\[|\Z)", t, re.M | re.S)
                if m:
                    for line in m.group(1).splitlines():
                        mm = re.match(r"\s*([A-Za-z0-9_-]+)\s*=", line)
                        if mm:
                            found["cargo"].add(mm.group(1))
                continue
            if fn == "CMakeLists.txt" or fn.endswith(".cmake"):
                t = open(os.path.join(dirpath, fn), "rb").read().decode("utf-8", "replace")
                for m in re.finditer(r"find_package\s*\(\s*([A-Za-z0-9_.+-]+)", t):
                    nm = m.group(1)
                    if nm.lower() not in ("pkgconfig",):
                        found["cmake_find"].add(nm)
                continue
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


def signature_key(url, sig_url, blob, sig_blob):
    """WHICH KEY signed it -- not merely that a signature exists.

    "a .sig is present" is nearly worthless on its own: anyone can upload a
    signature made by any key. The useful fact is the key id, because that is
    what a human compares against the project's published fingerprint before
    pinning.

    gpg reports the key id even with an EMPTY KEYRING -- it says "using RSA
    key X" and then "No public key". So this deliberately does NOT import
    anything: importing a key fetched alongside the artifact it signs proves
    nothing, and doing it automatically would manufacture a green check out of
    circular evidence. Verification stays a human step; this just names the
    key to check.
    """
    if sig_blob is None:
        return None
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        f = os.path.join(td, "a"); open(f, "wb").write(blob)
        sf = os.path.join(td, "a.sig"); open(sf, "wb").write(sig_blob)
        env = dict(os.environ, GNUPGHOME=td)
        try:
            p = subprocess.run(["gpg", "--batch", "--status-fd", "1",
                                "--verify", sf, f],
                               capture_output=True, text=True, env=env, timeout=60)
        except FileNotFoundError:
            return {"key": None, "note": "gpg not available on this runner"}
        out = p.stdout + p.stderr
        key = None
        m = re.search(r"using \w+ key ([0-9A-Fa-f]{16,40})", out)
        if m:
            key = m.group(1)
        m = re.search(r"NO_PUBKEY ([0-9A-Fa-f]+)", out)
        if not key and m:
            key = m.group(1)
        good = "GOODSIG" in out
        return {"key": key, "good": good,
                "note": ("VERIFIED against a key already in this keyring"
                         if good else
                         "key not held here -- compare this id with the "
                         "project's published fingerprint, then verify locally")}


def crosscheck(name, version):
    """What independent packagers recorded for this release.

    A checksum published beside a tarball protects against nothing that could
    replace the tarball. Independent packagers downloaded at different times,
    from different networks, without knowing about each other -- agreement
    between them is real evidence. This is diverse double-compilation applied
    to provenance, the same reasoning the seed already uses with two
    disassemblers.

    IT REPORTS, IT DOES NOT DECIDE. A version match is weaker than a digest
    match, and both are weaker than a signature. All three are printed so a
    person can weigh them.
    """
    out = {}
    arch = try_get("https://gitlab.archlinux.org/archlinux/packaging/packages/"
                   f"{name}/-/raw/main/PKGBUILD", quiet=True)
    if arch:
        t = arch.decode("utf-8", "replace")
        m = re.search(r"^pkgver=(\S+)", t, re.M)
        out["arch"] = {"version": m.group(1) if m else None,
                       "sha256": re.findall(r"[0-9a-f]{64}", t)[:4]}
    alp = try_get("https://gitlab.alpinelinux.org/alpine/aports/-/raw/master/"
                  f"main/{name}/APKBUILD", quiet=True)
    if alp:
        t = alp.decode("utf-8", "replace")
        m = re.search(r"^pkgver=(\S+)", t, re.M)
        out["alpine"] = {"version": m.group(1) if m else None,
                         "sha512": re.findall(r"[0-9a-f]{128}", t)[:2]}
    return out


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
    sig = sig_blob = None
    for ext in (".sig", ".asc", ".sign"):
        b = try_get(url + ext, quiet=True)
        if b is not None:
            sig, sig_blob = url + ext, b
            break
    print(f"   signature {sig or 'NONE FOUND (.sig/.asc/.sign) -- declare the deferral'}")
    if sig:
        k = signature_key(url, sig, blob, sig_blob)
        if k:
            print(f"   signed by {k.get('key') or 'could not determine'}")
            print(f"             {k['note']}")

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
    tags = spdx_tags(root)
    if tags:
        print("   spdx tags in source: "
              + ", ".join(f"{k} x{v}" for k, v in sorted(tags.items())))
    print(f"   tests     {test_target(root)}")

    d = declared_deps(root)
    print("\n   dependencies the SOURCE declares")
    print("     (static only -- run `probe linked` after a build for the real list)")
    WORTH = {
        "vcpkg":      "AUTHORITATIVE where it exists -- the project's own manifest",
        "pkg_config": "hard link deps, usually reliable",
        "pc_requires": "becomes a dep of everything that consumes this",
        "cmake_find": "may be optional -- find_package without REQUIRED is a hint",
        "check_lib":  "probed, often optional",
        "cargo":      "crates, not system packages -- a separate bootstrap problem",
    }
    for k, v in d.items():
        if not v:
            continue
        print(f"     {k:<12} {', '.join(v)}")
        print(f"     {'':<12} ^ {WORTH.get(k, '')}")
    if not any(d.values()):
        print("     nothing declared -- either a leaf, or it vendors everything")

    opts = configure_options(root)
    if opts is None:
        print("\n   configure --help: no configure script to ask")
    else:
        print(f"\n   {len(opts)} optional features -- EACH IS A DECISION, not a default")
        for o in opts[:40]:
            print(f"     {o}")
        if len(opts) > 40:
            print(f"     ... and {len(opts) - 40} more")

    # SPLIT ON THE LAST DASH, not on a leading-letters pattern: the pattern
    # form silently failed for m4, emitting version = "m4-1.4.21".
    pname, _, pver = top.rpartition("-")
    if not pname:
        pname, pver = top, ""
    xc = crosscheck(pname, pver)
    print("\n   independent packagers (corroboration, not proof)")
    if not xc:
        print("     none found -- cross-check by hand before pinning")
    for who, d in sorted(xc.items()):
        agree = "SAME" if d.get("version") == pver else f"DIFFERENT ({d.get('version')})"
        print(f"     {who:<8} version {agree}")
        for h in d.get("sha256", []):
            print(f"              sha256 {h} {'<-- MATCHES' if h == digest else ''}")

    print("\n   --- recipe skeleton (INCOMPLETE BY DESIGN) ---")
    print(f'''
name    = "{pname}"
version = "{pver}"
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
        # THE PREFIX WAS DOCUMENTED AND NEVER PARSED. "gnu:m4" was passed
        # whole to the GNU lookup, which fetched /gnu/gnu:m4/ and reported
        # "could not determine" -- the doubled "gnu:gnu:" in the output was
        # the tell. Accept the documented form, a bare name, and owner/repo.
        if spec.startswith("gitlab:"):
            name = spec[7:]
            r, src = latest_gitlab(name), f"gitlab:{name}"
        elif spec.startswith("gnu:"):
            name = spec[4:]
            r, src = latest_gnu(name), f"gnu:{name}"
        elif spec.startswith("github:"):
            name = spec[7:]
            r, src = latest_github(name), f"github:{name}"
        elif "/" in spec:
            r, src = latest_github(spec), f"github:{spec}"
        else:
            r, src = latest_gnu(spec), f"gnu:{spec}"
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


def cmd_index(a):
    r = latest_index(a.url, a.name)
    print(f"== {a.url}")
    if not r:
        print("   no tarball found in that listing")
        return 1
    print(f"   latest    {r['version']}")
    for asset in r["assets"]:
        print(f"   asset     {asset['name']}")
        print(f"             {asset['url']}")
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

    p = sub.add_parser("index", help="newest tarball in any directory listing")
    p.add_argument("url")
    p.add_argument("--name", help="restrict to this project name")
    p.set_defaults(fn=cmd_index)

    p = sub.add_parser("linked", help="the real deps: what a built DESTDIR links")
    p.add_argument("destdir")
    p.set_defaults(fn=cmd_linked)

    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    # RECONFIGURE RATHER THAN RELY ON `python3 -u`. The caller should not have
    # to know that this tool prints progress, and a workflow that forgets the
    # flag looks hung rather than slow.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    main()
