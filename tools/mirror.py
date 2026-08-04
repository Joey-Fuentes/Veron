#!/usr/bin/env python3
# mirror.py -- the pinned-source mirror.
#
# ONE LOOKUP PATH FOR BOTH KINDS OF HOST. MIRRORS.tsv is canonical: every row
# is (sha256, name, host, locator). Derivable hosts get their rows generated
# from a template; opaque hosts (Zenodo DOI, IPFS CID, SWHID) have theirs
# written when the artifact is uploaded. The resolver does not care which is
# which, which is what keeps hosts interchangeable.
#
# VERIFICATION IS UNCONDITIONAL. Every fetch hashes what it got and discards a
# mismatch. No host is trusted, so adding one is an availability decision, not
# a security one -- and a compromised mirror can waste time and nothing else.
#
# Python 3.11+ (tomllib), standard library only: this has to run in the airlock
# AND on a user's machine, where the only guaranteed interpreter is the one
# Veron ships.

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import socket
import tomllib
import urllib.request

# FORCE IPv4. ftp.gnu.org publishes an AAAA record; a runner with no IPv6
# route fails INSTANTLY with "[Errno 101] Network is unreachable" rather than
# timing out, so retries and mirrors do not help. Intermittent, because it
# depends on what the resolver returns -- which is the worst kind: it works
# until it does not, and looks like the site is down. Five of the nine
# group-1 packages live on ftp.gnu.org.
_real_getaddrinfo = socket.getaddrinfo


def _ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
    return _real_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)


if os.environ.get("VERON_ALLOW_IPV6") != "1":
    socket.getaddrinfo = _ipv4_only

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HOSTS = os.path.join(ROOT, "sources", "HOSTS.toml")
TABLE = os.path.join(ROOT, "sources", "MIRRORS.tsv")

COLS = ("sha256", "name", "host", "locator")


def die(m):
    print(f"mirror: {m}", file=sys.stderr)
    sys.exit(1)


def load_hosts():
    with open(HOSTS, "rb") as f:
        cfg = tomllib.load(f)
    hosts = cfg.get("host", {})
    for h in hosts.values():
        h.setdefault("enabled", True)
        h.setdefault("priority", 100)
    return hosts, cfg.get("policy", {})


def load_table():
    rows = []
    if not os.path.exists(TABLE):
        return rows
    with open(TABLE) as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("#"):
                continue
            p = ln.split("\t")
            if len(p) != 4:
                die(f"malformed row (want {len(COLS)} tab-separated fields): {ln!r}")
            rows.append(dict(zip(COLS, p)))
    return rows


def save_table(rows):
    # SORTED AND DEDUPED. This file is generated-and-committed, so it must
    # regenerate identically or the diff gate produces false failures and
    # someone turns it off. Same discipline as PLAN.txt.
    seen, out = set(), []
    for r in sorted(rows, key=lambda r: (r["name"], r["sha256"], r["host"])):
        k = (r["sha256"], r["host"])
        if k in seen:
            continue
        seen.add(k)
        out.append(r)
    with open(TABLE, "w") as f:
        f.write("# sha256\tname\thost\tlocator\n")
        f.write("# Generated and committed. Regenerate, never hand-merge.\n")
        for r in out:
            f.write("\t".join(r[c] for c in COLS) + "\n")
    return out


def expand(tpl, host, sha256, name):
    return (tpl.replace("{sha256}", sha256)
               .replace("{sha8}", sha256[:8])
               .replace("{name}", name)
               .replace("{repo}", host.get("repo", ""))
               .replace("{bucket}", host.get("bucket", "")))


def locators(sha256, name, rows, hosts):
    """Every route to these bytes, best first.

    Upstream is tried FIRST on purpose: a normal fetch should never touch our
    mirror, so the mirror stays a fallback rather than a bandwidth bill, and
    upstream going dark is something we notice rather than mask.
    """
    found = []
    for r in rows:
        if r["sha256"] != sha256:
            continue
        h = hosts.get(r["host"], {})
        if not h.get("enabled", True):
            continue
        found.append((h.get("priority", 100), r["host"], r["locator"]))
    # Derivable hosts need no row; compute them if one is missing.
    have = {h for _, h, _ in found}
    for hname, h in hosts.items():
        if hname in have or not h.get("enabled", True):
            continue
        if h.get("kind") == "derivable" and h.get("template"):
            found.append((h["priority"], hname,
                          expand(h["template"], h, sha256, name)))
    return [(hn, loc) for _, hn, loc in sorted(found)]


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def try_get(url, dest, timeout):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "veron-mirror"})
        with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as o:
            shutil.copyfileobj(r, o)
        return True, ""
    except Exception as e:
        return False, str(e)[:120]


# ------------------------------------------------------------------ commands


def cmd_fetch(a):
    hosts, policy = load_hosts()
    rows = load_table()
    t = policy.get("connect_timeout", 20)
    os.makedirs(a.dest, exist_ok=True)
    out = os.path.join(a.dest, a.name)

    if os.path.exists(out) and sha256_file(out) == a.sha256:
        print(f"  cached  {a.name}")
        return 0

    routes = locators(a.sha256, a.name, rows, hosts)
    if a.url and not any(u == a.url for _, u in routes):
        # THE RECIPE'S OWN UPSTREAM, tried first. A package that has not been
        # mirrored yet still has provenance, and refusing to fetch it would
        # make mirroring a PREREQUISITE for building rather than a fallback.
        routes.insert(0, ("upstream", a.url))
    if not routes:
        die(f"no route to {a.sha256[:12]} ({a.name})")

    for host, url in routes:
        ok, err = try_get(url, out + ".part", t)
        if not ok:
            print(f"  miss    {host:<10} {err}")
            continue
        got = sha256_file(out + ".part")
        if got != a.sha256:
            # A MISMATCH IS NOT A FAILED DOWNLOAD. It means this host served
            # different bytes under the right name, which is exactly what the
            # hash is here to catch. Discard and keep going.
            print(f"  BAD     {host:<10} sha256 {got[:12]} != {a.sha256[:12]}")
            os.remove(out + ".part")
            continue
        os.replace(out + ".part", out)
        print(f"  ok      {host:<10} {a.name}")
        return 0
    die(f"every route failed for {a.name}")


def cmd_add(a):
    """Upload to a host and record the locator.

    The only host-specific code in this tool is the `put` command from
    HOSTS.toml. Adding a host is writing one of those -- no change here.
    """
    hosts, _ = load_hosts()
    h = hosts.get(a.host) or die(f"unknown host {a.host}")
    if not os.path.exists(a.file):
        die(f"no such file {a.file}")
    sha = sha256_file(a.file)
    name = os.path.basename(a.file)
    rows = load_table()

    if h.get("kind") == "opaque" and not a.locator:
        die(f"{a.host} is opaque: its locator is assigned by the host and "
            f"cannot be computed. Upload, then pass --locator.")

    if a.locator:
        loc = a.locator
    else:
        loc = expand(h["template"], h, sha, name)
        # Some hosts want the asset named by hash; stage a copy so the
        # uploaded name matches the template rather than the local filename.
        staged = os.path.join(os.path.dirname(a.file) or ".", f"{sha[:8]}-{name}")
        if not a.dry_run and staged != a.file:
            shutil.copy2(a.file, staged)
        for cmd in (h.get("create"), h.get("put")):
            if not cmd:
                continue
            argv = [expand(x.replace("{file}", a.file).replace("{staged}", staged)
                           .replace("{tag}", expand(h.get("tag", ""), h, sha, name)),
                           h, sha, name) for x in cmd]
            print("  +", " ".join(argv))
            if not a.dry_run:
                r = subprocess.run(argv, capture_output=True, text=True)
                if r.returncode != 0:
                    # A `create` that fails because the tag already exists is
                    # the normal second-run case and must not look like an
                    # error. Anything else is worth seeing -- the previous
                    # code discarded both alike, so a genuinely failed upload
                    # was recorded in the table as though it had worked.
                    msg = (r.stderr or r.stdout or "").strip()
                    if "already exists" in msg or "already_exists" in msg:
                        print("    (release already exists)")
                    else:
                        print(f"    FAILED rc={r.returncode}: {msg[:200]}")
                        die(f"{a.host}: upload failed, refusing to record a "
                            f"route that does not work")

    rows.append({"sha256": sha, "name": name, "host": a.host, "locator": loc})
    if not a.dry_run:
        save_table(rows)
    print(f"  recorded {a.host}: {loc}")
    return 0


def cmd_check(a):
    """Scheduled re-verify.

    THIS IS THE PART NOT TO SKIP. It turns link rot and silent asset
    replacement into something found on a schedule rather than when a user's
    build fails. It is also the only thing that detects a host quietly
    swapping bytes, since nothing else re-reads them.
    """
    hosts, policy = load_hosts()
    rows = load_table()
    t = policy.get("connect_timeout", 20)
    minh = policy.get("min_hosts_warn", 2)

    by_hash = {}
    for r in rows:
        by_hash.setdefault((r["sha256"], r["name"]), []).append(r)

    bad = thin = 0
    for (sha, name), rs in sorted(by_hash.items(), key=lambda kv: kv[0][1]):
        mirrors = [r for r in rs if hosts.get(r["host"], {}).get("kind") != "provenance"]
        if len(mirrors) < minh:
            print(f"  THIN    {name}: {len(mirrors)} mirror(s), want >= {minh}")
            thin += 1
        if a.offline:
            continue
        for r in rs:
            tmp = os.path.join(a.tmp, "chk")
            os.makedirs(a.tmp, exist_ok=True)
            ok, err = try_get(r["locator"], tmp, t)
            if not ok:
                print(f"  DEAD    {r['host']:<10} {name}: {err}")
                bad += 1
                continue
            got = sha256_file(tmp)
            if got != sha:
                print(f"  CHANGED {r['host']:<10} {name}: {got[:12]} != {sha[:12]}")
                bad += 1
            else:
                print(f"  ok      {r['host']:<10} {name}")
            os.remove(tmp)
    print(f"\n  {len(by_hash)} artifact(s), {bad} problem(s), {thin} under-mirrored")
    return 1 if bad else 0


def cmd_list(a):
    hosts, _ = load_hosts()
    rows = load_table()
    seen = set()
    for r in sorted(rows, key=lambda r: r["name"]):
        k = (r["sha256"], r["name"])
        if k in seen:
            continue
        seen.add(k)
        print(f"  {r['name']}  {r['sha256'][:16]}")
        for hn, loc in locators(r["sha256"], r["name"], rows, hosts):
            print(f"      {hn:<10} {loc}")
    return 0


REQUIRED_SURFACE = {
    "fetch": ["--dest", "--url"],
    "add": ["--locator", "--dry-run"],
    "check": ["--offline", "--tmp"],
    "list": [],
}


def cmd_selftest(a):
    """Assert every documented subcommand and flag still exists."""
    ok = True
    ap = build_parser()
    subs = {}
    for act in ap._actions:
        if hasattr(act, "choices") and act.choices:
            subs = act.choices
    for name, flags in sorted(REQUIRED_SURFACE.items()):
        if name not in subs:
            print(f"  FAIL  subcommand missing: {name}")
            ok = False
            continue
        have = {o for act in subs[name]._actions for o in act.option_strings}
        for f in flags:
            if f in have:
                print(f"  ok    {name} {f}")
            else:
                print(f"  FAIL  {name} lost the {f} flag")
                ok = False
    print("VERON-MIRROR-SELFTEST-OK" if ok else "VERON-MIRROR-SELFTEST-FAIL")
    return 0 if ok else 1


def build_parser():
    ap = argparse.ArgumentParser(prog="mirror")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("fetch", help="first route that answers, hash verified")
    p.add_argument("sha256")
    p.add_argument("name")
    p.add_argument("--dest", default="dl")
    p.add_argument("--url", help="upstream URL from the recipe, used if the table has no row")
    p.set_defaults(fn=cmd_fetch)

    p = sub.add_parser("add", help="upload to a host and record the locator")
    p.add_argument("host")
    p.add_argument("file")
    p.add_argument("--locator", help="required for opaque hosts (DOI, CID, SWHID)")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("check", help="re-download everything and re-verify")
    p.add_argument("--offline", action="store_true", help="only check mirror counts")
    p.add_argument("--tmp", default=os.path.join(
        os.environ.get("TMPDIR") or ("/tmp" if os.access("/tmp", os.W_OK) else
                                     os.path.expanduser("~")), "veron-mirror"))
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("list", help="every artifact and every route to it")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("selftest", help="assert the documented CLI surface exists")
    p.set_defaults(fn=cmd_selftest)

    return ap


def main():
    ap = build_parser()
    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
