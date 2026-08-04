#!/usr/bin/env python3
"""Read the LFS book's package list.

BLFS puts a download URL on each package's own page; LFS puts them all on
chapter03/packages.html, in a flat run of "Name (version) ... Download: URL ...
MD5 sum: HEX" entries. tools/blfs.py therefore parses LFS titles fine and
returns url=None for every one of them -- which is how expat, readline, ninja,
meson, gperf, libffi and pcre2 came to be missing from a batch that was
supposed to be complete.
"""
import argparse
import html
import re
import sys

TAGS = re.compile(r"<[^>]+>")


def entries(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    text = html.unescape(TAGS.sub(" ", raw))
    text = re.sub(r"\s+", " ", text)
    out = {}
    # "Expat (2.7.4) - 496 KB: Home page: ... Download: URL MD5 sum: HEX"
    for m in re.finditer(
            r"([A-Za-z][A-Za-z0-9_+.-]*)\s*\(([0-9][0-9A-Za-z._-]*)\)"
            r".{0,400}?Download:\s*(\S+)"
            r".{0,200}?MD5 sum:\s*([0-9a-f]{32})", text):
        name, ver, url, md5 = m.groups()
        out.setdefault(name.lower(), {"name": name, "version": ver,
                                      "url": url, "md5": md5})
    return out


def main():
    ap = argparse.ArgumentParser(prog="lfs")
    ap.add_argument("--book", required=True, help="unpacked LFS book directory")
    ap.add_argument("cmd", choices=("list", "urls", "show"))
    ap.add_argument("--canonical", action="store_true",
                    help="rewrite ftpmirror.gnu.org to ftp.gnu.org")
    ap.add_argument("pkg", nargs="*")
    a = ap.parse_args()
    idx = entries(f"{a.book}/chapter03/packages.html")
    print(f"  lfs book: {len(idx)} packages", file=sys.stderr)
    if a.cmd == "list":
        for k in sorted(idx):
            print(f"{idx[k]['name']:22} {idx[k]['version']:14} {idx[k]['url']}")
        return 0
    for want in a.pkg:
        e = idx.get(want.lower())
        if not e:
            print(f"# NOT IN LFS: {want}", file=sys.stderr)
            continue
        url = e["url"]
        if a.canonical:
            # LFS lists GNU packages through ftpmirror.gnu.org, the redirector
            # that already failed outright for libtasn1 and nettle. A recipe
            # should pin a host that answers, not one that picks one.
            url = url.replace("https://ftpmirror.gnu.org/",
                              "https://ftp.gnu.org/gnu/")
        if a.cmd == "urls":
            print(url)
        else:
            print(f"== {e['name']} {e['version']}\n   url {url}\n   md5 {e['md5']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
