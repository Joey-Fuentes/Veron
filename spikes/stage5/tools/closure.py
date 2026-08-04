#!/usr/bin/env python3
# closure.py -- work BACKWARDS from what the system must do.
#
# THE PROBLEM WITH FORWARD GROUPS. STAGE5.md's groups 1-8 were written by
# reading dependency graphs by hand, and its own note says so: "counts below
# are from reading dependency graphs, not from building them... 200+ is the
# honest budget once dependency tails are resolved rather than estimated." A
# forward list discovers what it is missing when a build fails, one package at
# a time, at the bottom of a stack.
#
# Backwards is cheaper: name the things the system must DO -- browse the web,
# run a terminal, log in -- and let the closure say what that costs.
#
# WHERE THE EDGES COME FROM. Arch and Alpine have already solved "what does
# Ladybird need", and their lists are curated by people who actually built it.
# This consumes them as a HYPOTHESIS, not as truth:
#
#   - their deps reflect THEIR configure flags. We disable more, so our real
#     closure should be smaller -- every difference is a flag decision we have
#     not made yet.
#   - package names are distro names, not upstream names.
#   - Alpine splits -dev packages; Arch does not.
#   - both will pull in things this project has DELIBERATELY EXCLUDED, and
#     that is the single most useful thing this tool prints: not "you need
#     dbus" but "Arch reaches dbus through these three packages, so excluding
#     it costs you exactly this".
#
# So the output is a map to argue with, not an answer to accept.

import argparse
import json
import os
import re
import socket
import sys
import urllib.request

_real_getaddrinfo = socket.getaddrinfo


def _ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
    return _real_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)


if os.environ.get("VERON_ALLOW_IPV6") != "1":
    socket.getaddrinfo = _ipv4_only

CACHE = os.path.join(os.environ.get("TMPDIR", "/tmp"), "veron-closure-cache")


def fetch(url, timeout=20):
    os.makedirs(CACHE, exist_ok=True)
    key = os.path.join(CACHE, re.sub(r"[^A-Za-z0-9]", "_", url)[-180:])
    if os.path.exists(key):
        return open(key, "rb").read() or None
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "veron-closure"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
    except Exception:
        data = b""
    open(key, "wb").write(data)
    return data or None


def bash_array(text, name):
    """Pull `name=(a b c)` out of a PKGBUILD/APKBUILD, multiline included."""
    m = re.search(rf"^{name}=\(([^)]*)\)", text, re.M | re.S)
    if not m:
        m = re.search(rf"^{name}=\"([^\"]*)\"", text, re.M | re.S)
    if not m:
        return []
    body = re.sub(r"#.*", "", m.group(1))
    out = []
    for tok in body.split():
        tok = tok.strip("'\"")
        # Strip version constraints and Alpine's !conflict / package:subpkg.
        tok = re.split(r"[<>=]", tok)[0]
        if not tok or tok.startswith("!") or tok.startswith("$"):
            continue
        out.append(tok)
    return out


def arch_deps(pkg):
    t = fetch("https://gitlab.archlinux.org/archlinux/packaging/packages/"
              f"{pkg}/-/raw/main/PKGBUILD")
    if not t:
        return None
    t = t.decode("utf-8", "replace")
    return {"runtime": bash_array(t, "depends"),
            "build": bash_array(t, "makedepends")}


def alpine_deps(pkg):
    for repo in ("main", "community"):
        t = fetch("https://gitlab.alpinelinux.org/alpine/aports/-/raw/master/"
                  f"{repo}/{pkg}/APKBUILD")
        if t:
            t = t.decode("utf-8", "replace")
            return {"runtime": bash_array(t, "depends"),
                    "build": bash_array(t, "makedepends")}
    return None


def walk(targets, have, exclude, source, max_depth, include_build):
    """Breadth-first from the targets down to things already provided."""
    getter = {"arch": arch_deps, "alpine": alpine_deps}[source]
    seen, unknown, pruned, edges = {}, set(), {}, {}
    frontier = [(t, 0) for t in targets]
    while frontier:
        pkg, depth = frontier.pop(0)
        if pkg in seen or pkg in have:
            continue
        if pkg in exclude:
            pruned.setdefault(pkg, set())
            continue
        if depth > max_depth:
            unknown.add(pkg)
            continue
        d = getter(pkg)
        if d is None:
            unknown.add(pkg)
            seen[pkg] = depth
            continue
        seen[pkg] = depth
        deps = list(d["runtime"]) + (list(d["build"]) if include_build else [])
        edges[pkg] = sorted(set(deps))
        for x in edges[pkg]:
            if x in exclude:
                pruned.setdefault(x, set()).add(pkg)
                continue
            if x not in seen and x not in have:
                frontier.append((x, depth + 1))
    return seen, edges, unknown, pruned


def sccs(nodes, edges):
    """Tarjan: the ACTUAL cycles, not everything blocked by one.

    The first version reported six packages as cyclic when the real loop was
    freetype2 <-> harfbuzz and the other four merely sat above it. That is the
    difference between "four extra packages need investigating" and "one pair
    needs a two-pass build" -- and at 200 packages the blunt version would
    report most of the graph.
    """
    index, low, onstack, stack, out, counter = {}, {}, set(), [], [], [0]

    def strong(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v); onstack.add(v)
        for w in edges.get(v, []):
            if w not in nodes:
                continue
            if w not in index:
                strong(w)
                low[v] = min(low[v], low[w])
            elif w in onstack:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); onstack.discard(w); comp.append(w)
                if w == v:
                    break
            out.append(sorted(comp))

    sys.setrecursionlimit(10000)
    for v in sorted(nodes):
        if v not in index:
            strong(v)
    return out


def order(seen, edges, have, exclude):
    """Topological order over the CONDENSATION, so a cycle blocks only itself.

    Tie-broken by name -- the same rule the build driver uses, and for the
    same reason: two independent packages have no natural order, and an
    unstable one makes the output differ run to run.
    """
    nodes = set(seen)
    comps = sccs(nodes, edges)
    cyclic = [c for c in comps if len(c) > 1]
    member = {p: i for i, c in enumerate(comps) for p in c}

    cedges = {i: set() for i in range(len(comps))}
    for p in nodes:
        for d in edges.get(p, []):
            if d in member and member[d] != member[p]:
                cedges[member[p]].add(member[d])

    done, out, remaining = set(), [], dict(cedges)
    while remaining:
        ready = sorted((i for i in remaining if remaining[i] <= done),
                       key=lambda i: comps[i][0])
        if not ready:
            break
        for i in ready:
            out.extend(comps[i])
            done.add(i)
            remaining.pop(i)
    return out, cyclic


def main():
    ap = argparse.ArgumentParser(prog="closure")
    ap.add_argument("targets", nargs="+", help="what the system must do, as packages")
    ap.add_argument("--have", default="",
                    help="comma-separated: already built or provided by stage 4")
    ap.add_argument("--exclude", default="systemd,dbus,polkit,elogind,libx11,xorg-server",
                    help="comma-separated: excluded by policy, not by absence")
    ap.add_argument("--source", default="arch", choices=("arch", "alpine"))
    ap.add_argument("--max-depth", type=int, default=8)
    ap.add_argument("--build-deps", action="store_true",
                    help="follow makedepends too (much larger closure)")
    ap.add_argument("--json", help="write the graph here")
    a = ap.parse_args()

    have = {x for x in a.have.split(",") if x}
    exclude = {x for x in a.exclude.split(",") if x}

    print(f"  source      {a.source} package metadata (a hypothesis, not truth)")
    print(f"  targets     {', '.join(a.targets)}")
    print(f"  have        {len(have)} already provided")
    print(f"  excluded    {', '.join(sorted(exclude))}")
    print(f"  build deps  {'followed' if a.build_deps else 'NOT followed (runtime only)'}")
    print()

    seen, edges, unknown, pruned = walk(a.targets, have, exclude, a.source,
                                        a.max_depth, a.build_deps)
    ordered, cyclic = order(seen, edges, have, exclude)

    print(f"  === CLOSURE: {len(seen)} packages ===")
    for i, p in enumerate(ordered, 1):
        deps = [d for d in edges.get(p, []) if d not in have and d not in exclude]
        print(f"    {i:3}. {p:<28} <- {', '.join(deps[:5]) or '(leaf)'}"
              + (" ..." if len(deps) > 5 else ""))

    if cyclic:
        n = sum(len(c) for c in cyclic)
        print(f"\n  === CYCLES: {len(cyclic)} loop(s), {n} packages ===")
        print("    Real bootstrap loops, not everything blocked by one. Each")
        print("    needs a two-pass build or an edge broken by a flag --")
        print("    freetype/harfbuzz is the classic and it is solved by")
        print("    building freetype once without harfbuzz first.")
        for c in cyclic:
            print(f"    {' <-> '.join(c)}")

    if pruned:
        print(f"\n  === EXCLUDED BY POLICY: {len(pruned)} ===")
        print("    THE MOST USEFUL SECTION. Not 'you need dbus' but 'here is")
        print("    exactly what reaches for it', so the cost of the exclusion")
        print("    is a list rather than a feeling.")
        for p, wanted_by in sorted(pruned.items()):
            print(f"    {p:<24} wanted by: {', '.join(sorted(wanted_by)) or '(a target)'}")

    if unknown:
        print(f"\n  === NOT FOUND: {len(unknown)} ===")
        print("    No metadata under that name -- a distro-specific name, a")
        print("    virtual provider, or genuinely absent. Each needs a look.")
        for p in sorted(unknown):
            print(f"    {p}")

    if a.json:
        json.dump({"order": ordered, "edges": edges, "cyclic": cyclic,
                   "pruned": {k: sorted(v) for k, v in pruned.items()},
                   "unknown": sorted(unknown)}, open(a.json, "w"), indent=2)
        print(f"\n  graph written to {a.json}")

    print()
    print("  READ THIS AS A MAP TO ARGUE WITH. These are Arch's or Alpine's")
    print("  dependencies, which follow THEIR configure flags. Veron disables")
    print("  more, so the real closure should be smaller -- and every")
    print("  difference is a flag decision that has not been made yet.")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    sys.exit(main())
