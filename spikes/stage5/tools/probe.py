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
import urllib.error
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


PRERELEASE = re.compile(r"(?:^|[-._])(?:alpha|beta|rc|pre|dev|snapshot)"
                        r"[-._]?\d*$", re.I)


def latest_github(repo):
    """Newest STABLE release and its assets.

    GITHUB'S "LATEST" IS NOT NECESSARILY STABLE. Asked for libxkbcommon it
    returned xkbcommon-1.14.0-beta1 -- a pre-release, with no uploaded assets,
    only the auto-generated archive that must never be pinned. Pinning a beta
    into a distribution because an API called it "latest" is exactly the kind
    of quiet wrong answer this whole probe exists to prevent.
    
    The directory-listing path already filtered pre-releases -- it dropped 53
    of them when resolving mesa -- and this path never did. Same mistake, two
    code paths, one of them fixed a month ago.
    """
    d = try_get(f"https://api.github.com/repos/{repo}/releases/latest")
    j = json.loads(d) if d else None

    if j is None or j.get("prerelease") or PRERELEASE.search(j.get("tag_name", "")):
        # Walk the full list and take the newest release that is neither
        # flagged as a pre-release nor named like one.
        d2 = try_get(f"https://api.github.com/repos/{repo}/releases?per_page=100")
        if not d2:
            return None
        for cand in json.loads(d2):
            if cand.get("draft") or cand.get("prerelease"):
                continue
            if PRERELEASE.search(cand.get("tag_name", "")):
                continue
            if j is not None and cand["tag_name"] != j.get("tag_name"):
                print(f"   skipped pre-release {j.get('tag_name')}, "
                      f"using {cand['tag_name']}")
            j = cand
            break
        else:
            return None
    if j is None:
        return None
    assets = [{"name": a["name"], "url": a["browser_download_url"]}
              for a in j.get("assets", [])]
    if not assets and j.get("tarball_url"):
        # NO UPLOADED ASSETS. GitHub still serves an auto-generated archive,
        # and saying so beats printing a version with nothing under it -- but
        # these are regenerated on demand and their checksums have shifted
        # under the whole ecosystem before, so they are flagged, not pinned.
        assets = [{"name": f"AUTO-GENERATED {j.get('tag_name','')} -- DO NOT PIN",
                   "url": j["tarball_url"]}]
    return {"version": j.get("tag_name", ""), "assets": assets,
            "published": j.get("published_at", "")}


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


def latest_forgejo(path, host="codeberg.org"):
    """Newest release on a Forgejo/Gitea instance.

    Five of the packages this desktop needs -- foot, fcft, tllist, fuzzel,
    yambar -- are all by the same author on Codeberg, which is neither GitHub
    nor GitLab. A probe that only knew the big two would have sent us to
    mirrors or to guessing, which is the exact failure the bzip2/GitLab case
    already demonstrated once.
    """
    d = try_get(f"https://{host}/api/v1/repos/{path}/releases?limit=1")
    if not d:
        return None
    try:
        j = json.loads(d)
    except Exception:
        return None
    if not j:
        return None
    r = j[0]
    assets = [{"name": a.get("name", ""), "url": a.get("browser_download_url", "")}
              for a in r.get("assets", [])]
    if not assets:
        # Forgejo serves generated archives when a project publishes no
        # assets. Same hazard as GitHub's "Source code (tar.gz)" -- flagged,
        # not silently pinned.
        tag = r.get("tag_name", "")
        assets = [{"name": f"AUTO-GENERATED {tag}.tar.gz -- verify before pinning",
                   "url": f"https://{host}/{path}/archive/{tag}.tar.gz"}]
    return {"version": r.get("tag_name", ""), "assets": assets,
            "published": r.get("published_at", "")}


def latest_sourcehut(path, host="git.sr.ht"):
    """Newest tag on a sourcehut repository.

    seatd lives on git.sr.ht/~kennylevinsen/seatd and nowhere else -- not
    GitHub, not GitLab, not Codeberg. It is a required piece of the compositor
    stack (labwc's session management), so "the probe does not speak this
    forge" would mean pinning it by hand, which is how a wrong digest gets in.
    Sourcehut has no releases concept at all, only tags, so this returns tags
    and says plainly that the download URL still needs finding.
    """
    owner, _, repo = path.partition("/")
    if not owner.startswith("~"):
        owner = "~" + owner
    d = try_get(f"https://{host}/{owner}/{repo}/refs")
    if not d:
        return None
    html = d.decode("utf-8", "replace")
    tags = re.findall(rf'/{re.escape(owner)}/{re.escape(repo)}/refs/([0-9][^"/]*)"', html)
    if not tags:
        tags = re.findall(r'refs/tags/([0-9][^"/<]*)', html)
    if not tags:
        return None
    seen, out = set(), []
    for t in tags:
        if t not in seen:
            seen.add(t); out.append(t)
    top = out[0]
    return {"version": top,
            "assets": [{"name": f"{repo}-{top}.tar.gz",
                        "url": f"https://{host}/{owner}/{repo}/archive/{top}.tar.gz"}],
            "published": ""}


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


def _looks_like_html(b):
    """A 404 page is not a build file.

    GitLab serves a full HTML error page with HTTP 200-looking content for a
    missing raw file, and the URL regex scraped it -- dinit was reported as
    sourced from about.gitlab.com and forum.gitlab.com. Anything that opens
    with a doctype or an html tag is not a PKGBUILD.
    """
    head = b[:400].lower()
    return b"<!doctype" in head or b"<html" in head


def packager_source(name):
    """Where do Arch and Alpine actually FETCH this from?

    Some projects publish no release assets at all -- libinput is the case
    that forced this: its GitLab has tags but no releases, and the
    freedesktop.org software directory that looks canonical is stale by four
    years (1.19.4 against a 1.30.4 tag). Guessing a URL from that situation is
    how you pin a four-year-old version or an auto-generated archive whose
    checksum moves.
    
    Distro packagers had to solve this already, and they wrote the answer
    down. Two independent packagers agreeing on a URL is real evidence; it is
    the same corroboration argument the digest cross-check uses.
    """
    out = {}
    arch = try_get("https://gitlab.archlinux.org/archlinux/packaging/packages/"
                   f"{name}/-/raw/main/PKGBUILD", quiet=True)
    if arch and not _looks_like_html(arch):
        t = arch.decode("utf-8", "replace")
        ver = re.search(r"^pkgver=(\S+)", t, re.M)
        urls = re.findall(r"(?:https?|ftp)://[^\s\"')]+", t)
        out["arch"] = {"version": ver.group(1) if ver else None,
                       "urls": sorted(set(u for u in urls if "://" in u))[:6]}
    for repo in ("main", "community"):
        alp = try_get("https://gitlab.alpinelinux.org/alpine/aports/-/raw/master/"
                      f"{repo}/{name}/APKBUILD", quiet=True)
        if alp and not _looks_like_html(alp):
            t = alp.decode("utf-8", "replace")
            ver = re.search(r"^pkgver=(\S+)", t, re.M)
            urls = re.findall(r"(?:https?|ftp)://[^\s\"')]+", t)
            out["alpine"] = {"version": ver.group(1) if ver else None,
                             "urls": sorted(set(urls))[:6]}
            break
    return out


def cmd_source(a):
    for name in a.name:
        print(f"== {name}")
        d = packager_source(name)
        if not d:
            print("   neither Arch nor Alpine packages this under that name")
            continue
        for who, v in sorted(d.items()):
            print(f"   {who}  version {v['version']}")
            for u in v["urls"]:
                mark = ""
                if "/-/archive/" in u or "/archive/refs/" in u:
                    mark = "   <-- AUTO-GENERATED, checksum can move"
                print(f"          {u}{mark}")
        if len(d) > 1:
            print("   ^ TWO independent packagers -- agreement here is real evidence.")
        else:
            print(f"   ^ ONLY {list(d)[0]} answered. One packager is a LEAD, not")
            print("     corroboration -- the whole point of asking two is that")
            print("     they downloaded at different times from different networks.")
    return 0


def latest_index(url, name=None, include_pre=False):
    """Newest tarball in any HTML directory listing.

    bzip2 (sourceware) and xz (tukaani) are neither GNU nor on GitHub, so the
    two specific lookups cannot reach them. Rather than special-case each
    project forever, read whatever index the URL serves.
    """
    d = try_get(url if url.endswith("/") else url + "/")
    if not d:
        return None
    html = d.decode("utf-8", "replace")
    # AN HREF MAY CARRY A PATH. This required a BARE FILENAME, and
    # archive.mozilla.org serves
    #   href="/pub/nspr/releases/v4.39/src/nspr-4.39.tar.gz"
    # so every entry was rejected and a directory full of tarballs reported
    # "no tarball found in that listing". Exactly the bug already fixed in
    # list_dirs and not here -- the same wrong assumption, twice, in two
    # functions parsing the same HTML.
    pat = (rf'href="(?:[^"]*/)?({re.escape(name)}-[0-9][^"/]*\.tar\.(?:gz|xz|bz2|lz))"'
           if name else
           r'href="(?:[^"]*/)?([A-Za-z0-9_.+-]+-[0-9][^"/]*\.tar\.(?:gz|xz|bz2|lz))"')
    names = sorted(set(re.findall(pat, html)))
    if not names:
        return None

    # PRE-RELEASES ARE NOT RELEASES. mesa's archive listed 26.2.0-rc1/rc2/rc3
    # alongside stable 26.1.x, and the version key read "26.2.0" out of the
    # rc names -- so the newest STABLE release lost to a release candidate and
    # the probe offered three rcs as the thing to pin. A directory index has
    # no metadata saying which is which; the name is the only signal.
    PRE = re.compile(r"-(rc|alpha|beta|pre|dev|snapshot)[0-9.]*\.tar\.", re.I)
    stable = [n for n in names if not PRE.search(n)]
    dropped = len(names) - len(stable)
    if stable:
        names = stable
    elif not include_pre:
        return {"version": None, "prerelease_only": True,
                "assets": [], "dropped": dropped}

    def key(n):
        m = re.search(r"-([0-9]+(?:\.[0-9]+)*)", n)
        return [int(x) for x in m.group(1).split(".")] if m else [0]

    names.sort(key=key)
    base = url if url.endswith("/") else url + "/"
    top = key(names[-1])
    return {"version": ".".join(str(x) for x in top),
            "dropped": dropped,
            "assets": [{"name": n, "url": base + n}
                       for n in names if key(n) == top]}


def latest_tag(spec):
    """Newest git tag, for projects that tag but publish no releases.

    dinit, libevdev, mesa and libdrm all do this. The tag gives the version;
    it does NOT give a pinnable artifact, because the archive a forge builds
    from a tag is generated on demand. So this reports the version and says
    plainly that the download URL still has to be found.
    """
    kind, _, path = spec.partition(":")
    if kind == "codeberg":
        url = f"https://codeberg.org/api/v1/repos/{path}/tags?limit=5"
    elif kind == "fdo":
        import urllib.parse
        pid = urllib.parse.quote(path, safe="")
        url = ("https://gitlab.freedesktop.org/api/v4/projects/"
               f"{pid}/repository/tags?per_page=5")
    elif kind == "gitlab":
        import urllib.parse
        pid = urllib.parse.quote(path, safe="")
        url = f"https://gitlab.com/api/v4/projects/{pid}/repository/tags?per_page=5"
    else:
        url = f"https://api.github.com/repos/{spec}/tags?per_page=5"
    d = try_get(url)
    if not d:
        return None
    try:
        j = json.loads(d)
    except Exception:
        return None
    names = [t.get("name", "") for t in j if t.get("name")]
    return names or None


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


MIRROR_FALLBACK = [("https://ftpmirror.gnu.org/", "https://ftp.gnu.org/gnu/")]


def probe(url, keep=False, quiet_report=False):
    name = url.rsplit("/", 1)[-1]
    print(f"== {name}")
    print(f"   {url}")

    blob = try_get(url)
    if blob is None:
        for frm, to in MIRROR_FALLBACK:
            if url.startswith(frm):
                alt = url.replace(frm, to, 1)
                print(f"   retrying via the canonical host: {alt}")
                blob = try_get(alt)
                if blob is not None:
                    url = alt
                break
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
        # NO TOP-LEVEL DIRECTORY. tzdata and tzcode extract flat into the
        # current directory, so there is no "name-version/" to split. Fall
        # back to the filename, which is the only naming information there is.
        base = re.sub(r"\.tar\.[a-z]+$|\.tgz$|\.zip$", "", name)
        m = re.match(r"^([A-Za-z_+-]*[A-Za-z_+])[-_]?([0-9][0-9A-Za-z.]*)$", base)
        pname, pver = (m.group(1), m.group(2)) if m else (base, "")
    xc = crosscheck(pname, pver)
    print("\n   independent packagers (corroboration, not proof)")
    if not xc:
        print("     none found -- cross-check by hand before pinning")
    for who, xd in sorted(xc.items()):
        agree = "SAME" if xd.get("version") == pver else f"DIFFERENT ({xd.get('version')})"
        print(f"     {who:<8} version {agree}")
        for h in xd.get("sha256") or []:
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
    result = {"name": pname, "version": pver, "sha256": digest,
              "signature": sig, "license": spdx,
              "build": "; ".join(build_system(root)),
              "tests": test_target(root),
              "deps": {x for v in d.values() for x in v}}
    if not keep:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"   (unpacked tree kept at {root})")
    return result


def cmd_batch(a):
    """Probe a list of URLs sequentially, isolating every failure.

    46 packages in one pass, and the point is that ONE bad URL must not cost
    the other 45 -- the apt step already taught that lesson when a single
    wrong package name killed a five-hour measurement. Each probe is wrapped,
    failures are recorded as rows rather than exceptions, and the run
    continues.

    RESUMABLE. A partial TSV is read back on start and already-probed URLs
    are skipped, so a timeout or a cancelled job costs only what it had not
    reached yet.
    """
    done = {}
    if a.out and os.path.exists(a.out):
        for ln in open(a.out):
            f = ln.rstrip("\n").split("\t")
            if len(f) > 1 and not ln.startswith("#"):
                done[f[1]] = ln
        print(f"  resuming: {len(done)} already probed", flush=True)

    urls = [u.strip() for u in open(a.list) if u.strip() and not u.startswith("#")]
    rows = []
    ok = fail = 0
    for i, url in enumerate(urls, 1):
        if url in done:
            rows.append(done[url].rstrip("\n"))
            continue
        print(f"\n===== [{i}/{len(urls)}] {url}", flush=True)
        try:
            r = probe(url, keep=False, quiet_report=a.quiet)
        except Exception as e:
            print(f"   PROBE RAISED: {type(e).__name__}: {str(e)[:120]}", flush=True)
            r = None
        if r:
            rows.append("\t".join([
                r["name"], url, r["version"], r["sha256"],
                r["signature"] or "none", r["license"], r["build"],
                r["tests"], ";".join(sorted(r["deps"]))]))
            ok += 1
        else:
            rows.append("\t".join(["FAILED", url, "", "", "", "", "", "", ""]))
            fail += 1
        if a.out:
            with open(a.out, "w") as f:
                f.write("# name\turl\tversion\tsha256\tsignature\tlicense\t"
                        "build\ttests\tdeps\n")
                f.write("\n".join(rows) + "\n")

    print(f"\n  ===== BATCH DONE: {ok} probed, {fail} failed =====")
    if fail:
        print("  Failures are ROWS, not a stopped run -- each one needs a look,")
        print("  and the other results are already written.")
        for r in rows:
            if r.startswith("FAILED"):
                print(f"    {r.split(chr(9))[1]}")
    return 1 if fail else 0


# ---------------------------------------------------------------- mirrors

# ALTERNATE ROUTES TO THE SAME BYTES, derived from the upstream URL.
#
# Every one of these is a host family that publishes the same file at more
# than one name. None requires uploading anything: they are rewrites, so the
# cost of adding a route is zero and the benefit is that one slow host stops
# costing a run.
#
# THIS IS NOT A TRUST DECISION. Every candidate below is downloaded and its
# sha256 compared against the pin before it is written to the table, so a
# hostile or broken mirror can waste time and nothing else. That is exactly
# what sources/HOSTS.toml's header claims and what makes "add any host you
# like" an availability question.
MIRROR_FAMILIES = [
    # kernel.org. A `git` fetch died on www.kernel.org timing out while both
    # of these carried the same tarball, and stage 4 already rewrites
    # cdn -> mirrors.edge for the same reason.
    ("https://www.kernel.org/pub/",   ["https://cdn.kernel.org/pub/",
                                       "https://mirrors.edge.kernel.org/pub/"]),
    ("https://cdn.kernel.org/pub/",   ["https://www.kernel.org/pub/",
                                       "https://mirrors.edge.kernel.org/pub/"]),
    # GNU. ftpmirror redirects to whichever mirror is closest and alive, and
    # ftp.gnu.org is the canonical host -- each is the other's fallback.
    ("https://ftp.gnu.org/gnu/",      ["https://ftpmirror.gnu.org/",
                                       "https://mirrors.kernel.org/gnu/"]),
    ("https://ftpmirror.gnu.org/",    ["https://ftp.gnu.org/gnu/",
                                       "https://mirrors.kernel.org/gnu/"]),
    # SourceForge is handled separately -- see sourceforge_candidates(). A
    # prefix rewrite does not work: downloads.sourceforge.net/<proj>/<file>
    # and <mirror>.dl.sourceforge.net/project/<proj>/<subdirs>/<file> are
    # different path shapes, so rewriting produces a 404 that looks like a
    # dead mirror rather than a wrong URL.
    # GNOME.
    ("https://download.gnome.org/",   ["https://ftp.acc.umu.se/pub/gnome/"]),
    # Xiph.
    ("https://downloads.xiph.org/releases/",
                                      ["https://ftp.osuosl.org/pub/xiph/releases/"]),
]


def sourceforge_candidates(url):
    """SourceForge alternates, via the mirror parameter rather than a rewrite.

    `downloads.sourceforge.net` is a redirector that picks a mirror for you,
    and its TLS handshake can simply time out -- which is how a freetype fetch
    died. Naming a mirror with ?use_mirror= keeps the path exactly as it is
    and removes the redirect step, so it works where a prefix rewrite cannot.
    """
    if "sourceforge.net" not in url:
        return []
    base = url.split("?")[0]
    return [f"{base}?use_mirror={m}"
            for m in ("netcologne", "master", "phoenixnap", "altushost-swe")]


def mirror_candidates(url, name):
    """Alternate URLs for the same artifact, by host family."""
    out = sourceforge_candidates(url)
    for prefix, alts in MIRROR_FAMILIES:
        if url.startswith(prefix):
            tail = url[len(prefix):]
            for a in alts:
                if a.endswith("/project/") and "/project/" not in tail:
                    # SourceForge's named mirrors want the /project/ form,
                    # which the redirector hides. Without this the rewrite
                    # produces a 404 that looks like a dead mirror.
                    continue
                out.append(a + tail)
    return out


def head(url, timeout=8):
    """Status and Content-Length, with no body.

    A HEAD is all a route table needs. The question here is "is the artifact
    there", not "are the bytes right" -- `mirror fetch` verifies sha256 before
    anything uses them, which is the property HOSTS.toml states outright: no
    host is trusted, so a broken mirror wastes time and nothing else.
    Downloading every candidate to re-establish that was work nobody needed.

    EIGHT SECONDS, NOT FORTY-FIVE. A mirror that cannot answer a HEAD in eight
    seconds is not a mirror worth recording. The first version waited 45s per
    candidate and the job crawled for minutes at a time on hosts that were
    simply not going to answer.
    """
    req = urllib.request.Request(url, headers=UA, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            n = r.headers.get("Content-Length")
            return r.status, (int(n) if n and n.isdigit() else None), None
    except urllib.error.HTTPError as e:
        return e.code, None, None
    except Exception as e:
        return None, None, f"{type(e).__name__}"


def cmd_mirrors(a):
    """Find alternate routes for every pinned artifact, by asking not fetching.

    A package is not properly pinned until there is more than one place to get
    it. Until this existed every recipe had exactly one working route plus a
    template pointing at a mirror nothing was uploaded to, and it cost two runs
    in a row -- git timed out at kernel.org, then freetype's SourceForge
    handshake timed out. Different package each time, same cause, and in both
    cases the bytes were sitting on a mirror the fetch never tried.

    WHAT THIS CHECKS AND WHAT IT DOES NOT. It checks that a URL exists and
    returns the same Content-Length as upstream. It does NOT verify the bytes,
    because `mirror fetch` already does that before use and doing it twice
    means downloading the whole set several times over. A route that lies
    about its length is caught here; a route that serves the wrong bytes at
    the right length is caught at fetch time, harmlessly.
    """
    import tomllib
    from concurrent.futures import ThreadPoolExecutor

    rows, checked, found = [], 0, 0
    for pkg in sorted(os.listdir(a.packages)):
        rp = os.path.join(a.packages, pkg, "recipe.toml")
        if not os.path.exists(rp):
            continue
        r = tomllib.load(open(rp, "rb"))
        src = r.get("source", {})
        if src.get("kind") == "git" or "sha256" not in src:
            continue
        sha, url = src["sha256"], src["url"]
        fname = os.path.basename(url)

        cands = mirror_candidates(url, fname)
        d = packager_source(r["name"])
        for who, v in sorted(d.items()):
            for u in v.get("urls", []):
                if u.startswith(("http://", "https://")) and "$" not in u \
                        and u.endswith((".tar.gz", ".tar.xz", ".tar.bz2",
                                        ".tgz", ".zip")):
                    cands.append(u)
        cands = [c for c in dict.fromkeys(cands) if c != url]
        if not cands:
            print(f"== {r['name']} {r['version']}: upstream only", flush=True)
            continue

        print(f"\n== {r['name']} {r['version']}  ({fname})", flush=True)

        # ONE HEAD TO UPSTREAM for the canonical size. Without it there is
        # nothing to compare a candidate's Content-Length against, and a host
        # serving a stub or an error page would look like a working route.
        _, want_len, _ = head(url, a.timeout)
        if want_len is None:
            print("   upstream gave no Content-Length -- length cannot be compared")

        # CANDIDATES IN PARALLEL. They are independent, and doing them one at
        # a time means the slowest host sets the pace for every package.
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            results = list(ex.map(lambda c: (c,) + head(c, a.timeout), cands))

        for c, status, length, err in results:
            checked += 1
            if err:
                print(f"   unreachable  {c}   ({err})")
            elif status != 200:
                print(f"   HTTP {status:<8} {c}")
            elif want_len is not None and length is not None and length != want_len:
                # SAME NAME, DIFFERENT SIZE. Not a mirror -- a repackaged
                # tarball, a different release, or an error page with a
                # 200. Either way it must not go in the table.
                print(f"   WRONG SIZE   {c}")
                print(f"                {length} bytes, upstream has {want_len}")
            else:
                print(f"   ok           {c}")
                rows.append((sha, fname, "mirror", c))
                found += 1

    print(f"\n  === {found} routes recorded from {checked} candidates ===")
    print("  Existence and length only. Correctness is `mirror fetch`'s job,")
    print("  and it verifies sha256 before any byte is used.")
    if not a.out:
        return 0

    # MERGE INTO THE CANONICAL TABLE, DO NOT WRITE BESIDE IT. A first version
    # wrote to a separate file and nothing read it, so freetype had four
    # verified routes recorded while `mirror fetch` still saw only the
    # redirector -- and the next run died on its TLS handshake.
    existing, header = [], []
    if os.path.exists(a.out):
        for ln in open(a.out):
            if ln.startswith("#"):
                header.append(ln.rstrip("\n"))
            elif ln.strip():
                existing.append(tuple(ln.rstrip("\n").split("\t")))
    if not header:
        header = ["# sha256\tname\thost\tlocator",
                  "# Generated and committed. Regenerate, never hand-merge."]
    merged = list(dict.fromkeys(existing + [tuple(x) for x in rows]))
    with open(a.out, "w") as f:
        f.write("\n".join(header) + "\n")
        for row in sorted(merged, key=lambda r: (r[1], r[2], r[3])):
            f.write("\t".join(row) + "\n")
    print(f"  {a.out}: {len(existing)} rows in, "
          f"{len(merged) - len(existing)} added, {len(merged)} total")
    return 0


def cmd_deps(a):
    """Diff what every package DECLARES against what the set contains.

    "PROBED" HAS MEANT "WE HAVE A DIGEST", WHICH IS NOT THE SAME AS KNOWING
    WHAT A PACKAGE NEEDS. Three dependencies have surfaced only by reading a
    tarball rather than planning:

      gst-plugins-ugly wants dvdread and nothing a browser needs -- which
        dropped it, and took x264, the one package with no release tarball at
        all, out of the set entirely
      gst-plugins-base declares alsa, so audio output needs a library that
        was in no batch
      wlroots needs hwdata and libdisplay-info for its DRM backend's EDID
        parsing, and neither was on any list

    `probe batch` already fetches, unpacks and records the declared
    dependencies of each package in column 9. Nothing has ever READ that
    column. This does, across the whole remaining set at once, so the gaps
    appear before recipes are written rather than in the middle of a batch.

    READ THE OUTPUT AS "COULD REACH FOR", NOT "REQUIRES". meson and autotools
    list every optional dependency of every feature, so some of what appears
    is something we will explicitly disable. The value is that none of it is
    invisible.
    """
    have = set()
    if a.have:
        for w in open(a.have).read().split():
            w = w.strip().lower()
            if w and not w.startswith("#"):
                have.add(w)

    wanted, per_pkg = {}, {}
    for tsv in a.tsv:
        if not os.path.exists(tsv):
            print(f"  no such file: {tsv}", file=sys.stderr)
            continue
        with open(tsv) as f:
            head = f.readline().rstrip("\n").split("\t")
            try:
                i_name = head.index("name")
                i_deps = head.index("deps")
            except ValueError:
                i_name, i_deps = 0, 8
            for ln in f:
                p_ = ln.rstrip("\n").split("\t")
                if len(p_) <= i_deps or p_[i_name] == "FAILED":
                    continue
                pkg = p_[i_name]
                names = [d for d in p_[i_deps].split(";") if d.strip()]
                per_pkg[pkg] = names
                for d in names:
                    base = re.split(r"[-_ >=<(]", d.strip())[0].lower()
                    if base:
                        wanted.setdefault(base, set()).add(pkg)

    print(f"  {len(per_pkg)} packages read, {len(wanted)} distinct names declared")
    print(f"  {len(have)} names already in the set\n")

    unknown = {k: v for k, v in wanted.items() if k not in have}
    print("  ======================================================")
    print("  NAMED BY SOMETHING, PRESENT IN NOTHING")
    print("  ======================================================")
    print("  Each is a name some package asked for that the set does not")
    print("  contain. Some are features to disable, some are packages we do")
    print("  not have. Both need a decision, and neither should be discovered")
    print("  halfway through writing a batch.\n")
    for base in sorted(unknown, key=lambda k: (-len(unknown[k]), k)):
        who = sorted(unknown[base])
        shown = ", ".join(w.split("-")[0].split("_")[0] for w in who[:4])
        more = f" (+{len(who) - 4})" if len(who) > 4 else ""
        print(f"    {base:<26} {len(who):>2}x  {shown}{more}")
    print(f"\n  {len(unknown)} distinct names not in the set")

    if a.out:
        with open(a.out, "w") as f:
            f.write("# name\twanted_by_count\twanted_by\n")
            for base in sorted(unknown, key=lambda k: (-len(unknown[k]), k)):
                f.write(f"{base}\t{len(unknown[base])}\t"
                        f"{','.join(sorted(unknown[base]))}\n")
        print(f"  wrote {a.out}")
    return 0


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
        if spec.startswith("sourcehut:") or spec.startswith("srht:"):
            name = spec.split(":", 1)[1]
            r, src = latest_sourcehut(name), f"sourcehut:{name}"
        elif spec.startswith("codeberg:"):
            name = spec[9:]
            r, src = latest_forgejo(name), f"codeberg:{name}"
        elif spec.startswith("fdo:"):
            # gitlab.freedesktop.org hosts libinput, libevdev, wayland,
            # mesa, libdrm, drm -- enough of the graphics stack to be worth
            # its own prefix rather than a --host flag nobody remembers.
            name = spec[4:]
            r, src = latest_gitlab(name, host="gitlab.freedesktop.org"), f"fdo:{name}"
        elif spec.startswith("gitlab:"):
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
            tags = latest_tag(spec)
            if tags:
                print(f"   no RELEASES, but tagged: {', '.join(tags[:5])}")
                print("   ^ the version is known; the download URL is not.")
                print("     Find the project's own archive (many freedesktop")
                print("     projects publish to a plain directory index) and")
                print("     probe that with `probe index`.")
            else:
                print("   could not determine -- check the release page by hand")
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


def list_dirs(url):
    """Subdirectories in an HTTP directory listing.

    SOME PROJECTS PUT A DIRECTORY PER RELEASE, not a tarball per release.
    Mozilla is the case in point: /pub/security/nss/releases/ contains
    NSS_3_112_RTM/ and the tarball lives another level down in src/. Asked to
    find a tarball there, `index` correctly reported "no tarball found in that
    listing" -- and because it printed nothing else, the caller had nothing to
    walk into. Two runs were spent grepping for directory names in output that
    never contained any.
    """
    d = try_get(url)
    if not d:
        return []
    html = d.decode("utf-8", "replace")
    # ABSOLUTE-PATH HREFS ARE THE COMMON CASE, not the exception. Mozilla's
    # archive lists /pub/nspr/releases/v4.39/ -- a path, not a full URL -- and
    # rejecting anything starting with "/" unless it began with the full URL
    # meant every entry was discarded and the listing looked empty. Two runs
    # were spent concluding Mozilla "returned nothing" when it had returned
    # everything.
    from urllib.parse import urlparse
    base_path = urlparse(url).path.rstrip("/") + "/"
    out, seen = [], set()
    for m in re.finditer(r'href="([^"?#]+/)"', html):
        href = m.group(1)
        if href.startswith(("http://", "https://", "//")):
            if not href.startswith(url):
                continue
            href = href[len(url):]
        elif href.startswith("/"):
            # A path from the server root. Keep it only if it is BELOW the
            # directory being listed -- otherwise "/" and "/pub/" come back
            # as navigation links and read as releases.
            if not href.startswith(base_path) or href == base_path:
                continue
            href = href[len(base_path):]
        if ".." in href or not href.strip("/"):
            continue
        # One level only: a listing entry is a child, not a grandchild.
        name = href.strip("/").split("/")[0]
        if not name or name in seen or name.startswith("."):
            continue
        seen.add(name)
        out.append(name)
    return out


def cmd_index(a):
    r = latest_index(a.url, a.name, a.include_pre)
    print(f"== {a.url}")
    if not r:
        print("   no tarball found in that listing")
        # SAY WHAT IS THERE INSTEAD OF STOPPING. A listing of directories is
        # a perfectly good answer to "where is this published" -- it just is
        # not the answer to "which tarball". Printing them lets a caller
        # descend rather than guess the layout.
        dirs = list_dirs(a.url)
        if dirs:
            stable = [d for d in dirs if not PRERELEASE.search(d)]
            print(f"   {len(dirs)} subdirector{'y' if len(dirs) == 1 else 'ies'}"
                  f" -- the release is probably one level down")
            # Sort by the numbers in the name, so NSS_3_112_RTM beats
            # NSS_3_99_RTM -- a lexical sort would put 99 last.
            def vkey(n):
                return [int(x) for x in re.findall(r"\d+", n)] or [0]
            for d in sorted(stable, key=vkey)[-8:]:
                print(f"   dir       {d}")
                print(f"             {a.url.rstrip('/')}/{d}/")
        return 1
    if r.get("prerelease_only"):
        print("   ONLY PRE-RELEASES found -- nothing stable to pin here.")
        print("   Re-run with --include-pre if that is genuinely what you want.")
        return 1
    print(f"   latest    {r['version']}")
    if r.get("dropped"):
        print(f"   ({r['dropped']} pre-release file(s) ignored -- rc/alpha/beta)")
    for asset in r["assets"]:
        print(f"   asset     {asset['name']}")
        print(f"             {asset['url']}")
    return 0


def cmd_selftest(a):
    """Check the parsers against the HTML shapes hosts actually serve.

    THE SAME WRONG ASSUMPTION APPEARED TWICE, A WEEK APART, in two functions
    reading the same HTML. Both list_dirs and latest_index required an href to
    be a BARE FILENAME, while archive.mozilla.org writes
        href="/pub/nspr/releases/v4.39/src/nspr-4.39.tar.gz"
    so a directory full of tarballs reported "no tarball found in that
    listing" and a listing full of releases reported nothing at all. Four runs
    went into concluding Mozilla was returning nothing when it was returning
    everything.

    A fixture is cheap and does not depend on a host being up.
    """
    global try_get
    saved, ok = try_get, True

    for label, html, base in (
        ("an absolute path",
         '<a href="/pub/nspr/releases/v4.39/src/nspr-4.39.tar.gz">x</a>',
         "https://archive.mozilla.org/pub/nspr/releases/v4.39/src/"),
        ("a bare filename",
         '<a href="nspr-4.39.tar.gz">x</a>', "https://example.org/releases/"),
        ("a full url",
         '<a href="https://example.org/releases/nspr-4.39.tar.gz">x</a>',
         "https://example.org/releases/"),
    ):
        try_get = lambda u, timeout=20, quiet=False, _h=html: _h.encode()
        r = latest_index(base, "nspr")
        if r and r["version"] == "4.39":
            print(f"  ok    latest_index reads an href given as {label}")
        else:
            print(f"  FAIL  latest_index misses an href given as {label}")
            ok = False

    try_get = lambda u, timeout=20, quiet=False: (
        b'<a href="/pub/nspr/releases/v4.39/">v4.39/</a>'
        b'<a href="/pub/nspr/releases/v4.40-beta1/">b</a>'
        b'<a href="/pub/">nav</a><a href="/">root</a>')
    d = list_dirs("https://archive.mozilla.org/pub/nspr/releases/")
    if d == ["v4.39", "v4.40-beta1"]:
        print("  ok    list_dirs reads absolute paths and drops navigation")
    else:
        print(f"  FAIL  list_dirs returned {d}")
        ok = False

    # A pre-release must never be offered as the thing to pin: GitHub called
    # xkbcommon-1.14.0-beta1 "latest" and the probe would have pinned it.
    for tag, want in (("xkbcommon-1.14.0-beta1", True), ("v1.13.2", False),
                      ("1.5.0-rc1", True), ("0.9.3", False),
                      ("24.0.0-dev", True), ("v2.11.3", False)):
        if bool(PRERELEASE.search(tag)) != want:
            print(f"  FAIL  pre-release check wrong for {tag}")
            ok = False
    else:
        print("  ok    pre-releases are recognised by name")

    try_get = saved
    print("VERON-PROBE-SELFTEST-OK" if ok else "VERON-PROBE-SELFTEST-FAIL")
    return 0 if ok else 1


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

    p = sub.add_parser("source", help="where Arch and Alpine actually fetch a package from")
    p.add_argument("name", nargs="+")
    p.set_defaults(fn=cmd_source)

    p = sub.add_parser("index", help="newest tarball in any directory listing")
    p.add_argument("url")
    p.add_argument("--name", help="restrict to this project name")
    p.add_argument("--include-pre", action="store_true",
                   help="do not filter out rc/alpha/beta/dev tarballs")
    p.set_defaults(fn=cmd_index)

    p = sub.add_parser("batch", help="probe a file of URLs sequentially, resumable")
    p.add_argument("list", help="file with one URL per line")
    p.add_argument("--out", help="TSV to write (and resume from)")
    p.add_argument("--quiet", action="store_true")
    p.set_defaults(fn=cmd_batch)

    p = sub.add_parser("selftest",
                       help="check the parsers against real HTML shapes")
    p.set_defaults(fn=cmd_selftest)

    p = sub.add_parser("deps",
                       help="diff declared dependencies against the set")
    p.add_argument("tsv", nargs="+", help="TSV files written by `probe batch`")
    p.add_argument("--have", help="file listing names already in the set")
    p.add_argument("--out", help="TSV of unmet names to write")
    p.set_defaults(fn=cmd_deps)

    p = sub.add_parser("mirrors",
                       help="find and verify alternate routes for every pin")
    p.add_argument("--packages", default="packages")
    p.add_argument("--out", help="MIRRORS.tsv to write")
    p.add_argument("--timeout", type=int, default=8,
                   help="per-request seconds; a slower mirror is not a mirror")
    p.add_argument("--jobs", type=int, default=8,
                   help="candidates checked in parallel")
    p.set_defaults(fn=cmd_mirrors)

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
