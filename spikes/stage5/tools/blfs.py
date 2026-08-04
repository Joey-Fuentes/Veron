#!/usr/bin/env python3
# blfs.py -- read the BLFS book as a dependency graph.
#
# WHY THIS BEATS DISTRO METADATA. closure.py consumes Arch or Alpine, and
# their lists reflect THEIR packaging: split packages, soname providers,
# -dev subpackages, and dependencies that exist because of how the distro
# ships things rather than because the source needs them. Three of those cost
# real bugs -- split packages parsed as leaves, sonames counted as packages,
# and systemd walking into the closure under names the exclude list did not
# match.
#
# BLFS has none of that shape. It is a FROM-SOURCE book: one page per upstream
# tarball, dependencies stated as Required / Recommended / Optional, which is
# exactly the distinction the recipe schema already draws between deps.link,
# deps.build and optional_off. It also writes down the things a graph cannot
# express -- "there is a circular dependency, build libva first without mesa's
# EGL support" -- which is the part that costs an afternoon to rediscover.
#
# AND IT IS OFFLINE. A pinned snapshot of the book, so the answer is
# reproducible and does not depend on a live API, a rate limit, or what a
# distro changed this morning.
#
# STILL A HYPOTHESIS. BLFS builds a conventional desktop with X11, systemd and
# dbus present. Veron excludes those, so its real closure should be smaller --
# and every difference is a flag decision that has not been made yet.

import argparse
import html
import json
import os
import re
import sys

# ATTRIBUTES ARE LINE-BROKEN IN THIS BOOK. The HTML is wrapped, so `href=`
# and its value routinely sit on different lines:
#     <a class="xref" href=
#     "../general/python-modules.html#Mako" title=
# A regex requiring `href="` adjacent silently DROPPED those links -- mesa's
# required list came back as two entries instead of four, with Mako and
# PyYAML missing and nothing to indicate a parse failure. Allow whitespace
# after every `=`, and match the anchor first rather than requiring the class
# attribute to precede href.
ANCHOR = re.compile(r"<a\s([^>]*?)>(.*?)</a>", re.S)
HREF = re.compile(r'href=\s*"([^"]+)"', re.S)
H4 = re.compile(r"<h4[^>]*>(.*?)</h4>", re.S)
TAGS = re.compile(r"<[^>]+>")


def text(s):
    return html.unescape(TAGS.sub("", s)).strip()


def norm(base, href):
    """A page id: path from the book root, anchor kept.

    The anchor matters -- BLFS puts many python modules on one page, so
    `python-modules.html#Mako` and `python-modules.html#PyYAML` are different
    packages sharing a file. Dropping it would silently merge them.
    """
    href = href.split("?")[0]
    p = os.path.normpath(os.path.join(os.path.dirname(base), href.split("#")[0]))
    anchor = href.split("#")[1] if "#" in href else ""
    return f"{p}#{anchor}" if anchor else p


def parse_page(root, rel):
    t = open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()

    m = re.search(r"<h1[^>]*>(.*?)</h1>", t, re.S)
    title = text(m.group(1)) if m else ""
    if not title or "Chapter" in title or title.startswith("Beyond"):
        return None
    mv = re.match(r"^(.*?)-([0-9][0-9A-Za-z.+_-]*)$", title)
    name, version = (mv.group(1), mv.group(2)) if mv else (title, "")

    # Same line-break problem for the download link, which came back None for
    # every single package -- a whole column of the answer missing.
    url = None
    mu = re.search(r"Download \(HTTP\).{0,200}?<a\s([^>]*?)>", t, re.S)
    if mu:
        mh = HREF.search(mu.group(1))
        if mh:
            url = mh.group(1)
    md5 = None
    mm = re.search(r"Download MD5 sum:\s*([0-9a-f]{32})", TAGS.sub("", t))
    if mm:
        md5 = mm.group(1)

    seg = re.search(r"Dependencies(.*?)(Installation of|Command Explanations|"
                    r"Contents|User Notes)", t, re.S)
    deps = {"required": [], "recommended": [], "optional": []}
    if seg:
        body = seg.group(1)
        # Split on the <h4> labels; everything until the next label belongs to
        # the current kind. The class="required" paragraph alone is not enough
        # -- Recommended and Optional entries often sit in an itemizedlist
        # AFTER an empty paragraph, which a class-only parser would miss.
        parts = H4.split(body)
        kind = None
        for i, chunk in enumerate(parts):
            label = text(chunk).lower()
            if label in deps:
                kind = label
                continue
            if kind is None:
                continue
            for attrs, label_text in ANCHOR.findall(chunk):
                if "xref" not in attrs:
                    continue
                mh = HREF.search(attrs)
                if not mh:
                    continue
                deps[kind].append({"page": norm(rel, mh.group(1)),
                                   "text": text(label_text)})
    return {"page": rel, "name": name, "version": version,
            "url": url, "md5": md5, "deps": deps}


def load(root):
    idx = {}
    for dirpath, dirnames, files in os.walk(root):
        dirnames.sort()
        for fn in sorted(files):
            if not fn.endswith(".html"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), root)
            try:
                p = parse_page(root, rel)
            except Exception:
                continue
            if p:
                idx[p["page"]] = p
    return idx


def resolve(idx, key):
    """Find a page by name, page id, or file stem -- case-insensitively."""
    if key in idx:
        return key
    k = key.lower()
    for page, p in idx.items():
        if p["name"].lower() == k or page.lower().endswith(f"/{k}.html"):
            return page
    for page, p in idx.items():
        if p["name"].lower().startswith(k):
            return page
    return None


def closure(idx, targets, have, exclude, kinds):
    seen, edges, missing, pruned = {}, {}, set(), {}
    frontier = list(targets)
    while frontier:
        page = frontier.pop(0)
        if page in seen:
            continue
        p = idx.get(page)
        if not p:
            missing.add(page)
            continue
        nm = p["name"].lower()
        if nm in have:
            continue
        if nm in exclude:
            pruned.setdefault(p["name"], set())
            continue
        seen[page] = p
        out = []
        for kind in kinds:
            for d in p["deps"][kind]:
                dp = idx.get(d["page"])
                dn = (dp["name"] if dp else d["text"].rsplit("-", 1)[0]).lower()
                if dn in exclude:
                    pruned.setdefault(dp["name"] if dp else d["text"], set()).add(p["name"])
                    continue
                if dn in have:
                    continue
                out.append(d["page"])
                if d["page"] not in seen:
                    frontier.append(d["page"])
        edges[page] = out
    return seen, edges, missing, pruned


def sccs(nodes, edges):
    index, low, onstack, stack, out, c = {}, {}, set(), [], [], [0]

    def strong(v):
        index[v] = low[v] = c[0]; c[0] += 1
        stack.append(v); onstack.add(v)
        for w in edges.get(v, []):
            if w not in nodes:
                continue
            if w not in index:
                strong(w); low[v] = min(low[v], low[w])
            elif w in onstack:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); onstack.discard(w); comp.append(w)
                if w == v:
                    break
            out.append(sorted(comp))

    sys.setrecursionlimit(20000)
    for v in sorted(nodes):
        if v not in index:
            strong(v)
    return out


def order(seen, edges):
    comps = sccs(set(seen), edges)
    member = {p: i for i, c in enumerate(comps) for p in c}
    ce = {i: set() for i in range(len(comps))}
    for p in seen:
        for d in edges.get(p, []):
            if d in member and member[d] != member[p]:
                ce[member[p]].add(member[d])
    done, out, rem = set(), [], dict(ce)
    while rem:
        ready = sorted((i for i in rem if rem[i] <= done), key=lambda i: comps[i][0])
        if not ready:
            break
        for i in ready:
            out.extend(comps[i]); done.add(i); rem.pop(i)
    return out, [c for c in comps if len(c) > 1]


def main():
    ap = argparse.ArgumentParser(prog="blfs")
    ap.add_argument("--book", required=True, help="unpacked BLFS book directory")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("show", help="one package, as the book states it")
    p.add_argument("pkg", nargs="+")

    p = sub.add_parser("closure", help="backward closure over the book")
    p.add_argument("targets", nargs="+")
    p.add_argument("--have", default="")
    p.add_argument("--exclude", default="")
    p.add_argument("--kinds", default="required",
                   help="comma-separated: required,recommended,optional")
    p.add_argument("--json")

    a = ap.parse_args()
    idx = load(a.book)
    print(f"  book: {len(idx)} package pages", flush=True)

    if a.cmd == "show":
        for key in a.pkg:
            page = resolve(idx, key)
            if not page:
                print(f"  {key}: not in the book")
                continue
            p = idx[page]
            print(f"\n== {p['name']} {p['version']}   ({p['page']})")
            print(f"   url  {p['url']}")
            print(f"   md5  {p['md5']}")
            for kind in ("required", "recommended", "optional"):
                v = [d["text"] for d in p["deps"][kind]]
                print(f"   {kind:<12} {', '.join(v) if v else '-'}")
        return 0

    have = {x.strip().lower() for x in a.have.split(",") if x.strip()}
    exclude = {x.strip().lower() for x in a.exclude.split(",") if x.strip()}
    kinds = [k.strip() for k in a.kinds.split(",") if k.strip()]

    targets = []
    for t in a.targets:
        page = resolve(idx, t)
        if page:
            targets.append(page)
        else:
            print(f"  TARGET NOT IN BOOK: {t}")
    seen, edges, missing, pruned = closure(idx, targets, have, exclude, kinds)
    ordered, cyclic = order(seen, edges)

    print(f"\n  kinds followed: {', '.join(kinds)}")
    print(f"  have: {len(have)}   excluded: {len(exclude)}")
    print(f"\n  === CLOSURE: {len(seen)} packages, in build order ===")
    for i, page in enumerate(ordered, 1):
        p = seen[page]
        deps = [seen[d]["name"] for d in edges.get(page, []) if d in seen]
        print(f"    {i:3}. {p['name']:<26} {p['version']:<12}"
              f" <- {', '.join(deps[:4]) or '(leaf)'}{' ...' if len(deps) > 4 else ''}")

    if cyclic:
        print(f"\n  === CYCLES: {len(cyclic)} ===")
        print("    BLFS documents how to break these in prose on the page --")
        print("    usually build one side without the other, then rebuild.")
        for c in cyclic:
            print(f"    {' <-> '.join(seen[x]['name'] for x in c)}")

    if pruned:
        print(f"\n  === EXCLUDED BY POLICY: {len(pruned)} ===")
        for k, by in sorted(pruned.items()):
            print(f"    {k:<26} wanted by: {', '.join(sorted(by))[:60] or '(a target)'}")

    if missing:
        print(f"\n  === LINKED BUT NOT PARSED: {len(missing)} ===")
        for m in sorted(missing)[:20]:
            print(f"    {m}")

    if a.json:
        json.dump({"order": [seen[p]["name"] for p in ordered],
                   "packages": {seen[p]["name"]: {
                       "version": seen[p]["version"], "url": seen[p]["url"],
                       "md5": seen[p]["md5"],
                       "deps": [seen[d]["name"] for d in edges.get(p, []) if d in seen]}
                       for p in ordered},
                   "cycles": [[seen[x]["name"] for x in c] for c in cyclic],
                   "excluded": {k: sorted(v) for k, v in pruned.items()}},
                  open(a.json, "w"), indent=2)
        print(f"\n  graph written to {a.json}")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    sys.exit(main())
