#!/usr/bin/env python3
# Render the evidence bundle into a single readable HTML page for GitHub Pages.
# DEPENDENCY-FREE (python only, Veron-native -- no jq, no node), so the same
# generator runs on-device. Input: an unpacked evidence/ bundle produced by the
# stage-6 EVIDENCE-CHAIN step -- stages.tsv (stage<TAB>digest<TAB>run), one
# logs/<stage>.zip per stage, one attestations/<stage>.json per stage. Output:
# a self-contained HTML file. The whole build chain, seed to release, laid out
# so anyone can read each stage's attestation identity and its build log
# WITHOUT downloading or dissecting a thing.
import base64
import html
import json
import os
import re
import sys
import zipfile

REPO = os.environ.get("GITHUB_REPOSITORY", "Joey-Fuentes/Veron")

# Human titles + one-line descriptions per stage label. Order is seed -> release.
STAGE_INFO = [
    ("1-self-assembler", "Stage 1 — Self-Assembly (the trust root)",
     "A hand-written ARM64 assembler that assembles itself to a fixpoint: "
     "gen1 == gen2 == gen3. Nothing built it but itself. Everything above "
     "descends from these bytes."),
    ("2-pico-c", "Stage 2 — pico-c",
     "The first C-ish compiler, built by the self-assembler. The seed grows a "
     "language."),
    ("3-micro-c", "Stage 3 — micro-c → tcc (arm64)",
     "micro-c compiles a real tcc for arm64. The toolchain becomes a compiler "
     "that can build compilers."),
    ("3-cross-tcc-amd64", "Stage 3 — cross to tcc (amd64)",
     "tcc is carried across to x86_64 and verified natively: it compiled and "
     "ran a program on this architecture before publishing."),
    ("4-sysroot", "Stage 4 — Toolchain & Sysroot",
     "From tcc, through gcc, in a box holding busybox and tcc and nothing "
     "else. The full seed-true sysroot the system is built on. No host "
     "compiler anywhere in the lineage."),
    ("4-kernel", "Stage 4 — Generic Kernel",
     "The generic-hardware kernel, built on the same sysroot: a sibling of the "
     "rootfs that rejoins the chain here."),
    ("5-provenance", "Stage 5 — User-Space System Image",
     "The full glibc user-space, every package compiled against the stage-4 "
     "sysroot. This is the rootfs the device runs."),
    ("6-release", "Stage 6 — Release",
     "The consumer release: the image and kernel bound together, attested, and "
     "published. The thing you flashed."),
]


def read_stages(bundle):
    rows = {}
    path = os.path.join(bundle, "stages.tsv")
    if os.path.exists(path):
        for line in open(path):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                rows[parts[0]] = {"digest": parts[1], "run": parts[2]}
    return rows


def read_log(bundle, label):
    """Return the decoded text of a stage's build log, or None."""
    zp = os.path.join(bundle, "logs", label + ".zip")
    if not os.path.exists(zp):
        return None
    try:
        with zipfile.ZipFile(zp) as z:
            # pick the largest .txt member -- the actual job log
            members = [(n, z.getinfo(n).file_size) for n in z.namelist()
                       if n.endswith(".txt")]
            if not members:
                return None
            name = max(members, key=lambda m: m[1])[0]
            raw = z.read(name).decode("utf-8", "replace")
    except Exception:
        return None
    # strip the leading ISO timestamp GitHub prefixes on every line
    out = []
    for ln in raw.splitlines():
        out.append(re.sub(r"^\S+Z\s", "", ln))
    return "\n".join(out)


def rekor_index(bundle, label):
    """Pull the Rekor tlog index from the stage's attestation, if present."""
    ap = os.path.join(bundle, "attestations", label + ".json")
    if not os.path.exists(ap):
        return None
    try:
        d = json.load(open(ap))
        for a in d.get("attestations", []):
            tl = a["bundle"]["verificationMaterial"]["tlogEntries"][0]
            return tl.get("logIndex")
    except Exception:
        return None
    return None


def esc(s):
    return html.escape(str(s)) if s is not None else ""


def render(bundle, out_path):
    stages = read_stages(bundle)
    sections = []
    for label, title, desc in STAGE_INFO:
        row = stages.get(label, {})
        digest = row.get("digest", "")
        run = row.get("run", "")
        log = read_log(bundle, label)
        rekor = rekor_index(bundle, label)

        run_url = "https://github.com/%s/actions/runs/%s" % (REPO, run) if run and run.isdigit() else None
        rekor_url = "https://search.sigstore.dev/?logIndex=%s" % rekor if rekor else None

        ident = []
        if digest and digest not in ("this-release",):
            ident.append('<div class="kv"><span>artifact digest</span>'
                         '<code>%s</code></div>' % esc(digest))
        if run_url:
            ident.append('<div class="kv"><span>build run</span>'
                         '<a href="%s">run %s ↗</a></div>' % (esc(run_url), esc(run)))
        elif run:
            ident.append('<div class="kv"><span>build run</span>'
                         '<code>%s</code></div>' % esc(run))
        if rekor_url:
            ident.append('<div class="kv"><span>transparency log</span>'
                         '<a href="%s">Rekor #%s ↗</a></div>' % (esc(rekor_url), esc(rekor)))

        if log:
            log_block = ('<details class="log"><summary>build log '
                         '(%d lines)</summary><pre>%s</pre></details>'
                         % (log.count("\n") + 1, esc(log)))
        else:
            log_block = ('<p class="nolog">Build log not captured in this '
                         'bundle (a run whose Actions logs have aged out, or '
                         'this release\'s own run whose log attaches on '
                         'completion).</p>')

        sections.append(
            '<section class="stage">'
            '<h2>%s</h2>'
            '<p class="desc">%s</p>'
            '<div class="ident">%s</div>'
            '%s'
            '</section>'
            % (esc(title), esc(desc), "".join(ident), log_block)
        )

    page = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Veron — Evidence Chain</title>
<style>
  :root { --bg:#0d1117; --fg:#e6edf3; --dim:#8b949e; --line:#30363d;
          --accent:#58a6ff; --code:#7ee787; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
         font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
  header { padding:2.5rem 1.25rem 1.5rem; border-bottom:1px solid var(--line);
           max-width:900px; margin:0 auto; }
  header h1 { margin:0 0 .4rem; font-size:1.8rem; }
  header p { margin:.2rem 0; color:var(--dim); }
  main { max-width:900px; margin:0 auto; padding:1rem 1.25rem 4rem; }
  .intro { color:var(--dim); border-left:3px solid var(--accent);
           padding:.5rem 0 .5rem 1rem; margin:1.5rem 0; }
  .stage { border:1px solid var(--line); border-radius:10px;
           padding:1.1rem 1.25rem; margin:1.1rem 0; background:#0f151d; }
  .stage h2 { margin:0 0 .3rem; font-size:1.15rem; }
  .desc { margin:.2rem 0 .9rem; color:var(--dim); }
  .ident { display:flex; flex-direction:column; gap:.35rem; margin-bottom:.8rem; }
  .kv { display:flex; gap:.6rem; flex-wrap:wrap; font-size:.9rem; }
  .kv > span { color:var(--dim); min-width:130px; }
  .kv code { color:var(--code); word-break:break-all; }
  .kv a { color:var(--accent); text-decoration:none; }
  .kv a:hover { text-decoration:underline; }
  details.log { margin-top:.5rem; border-top:1px solid var(--line); padding-top:.5rem; }
  details.log summary { cursor:pointer; color:var(--accent); font-size:.9rem; }
  details.log pre { background:#010409; border:1px solid var(--line);
                    border-radius:8px; padding:1rem; overflow-x:auto;
                    font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;
                    color:#c9d1d9; margin-top:.6rem; max-height:640px; }
  .nolog { color:var(--dim); font-size:.9rem; font-style:italic; }
  .chain-line { text-align:center; color:var(--dim); margin:.2rem 0; font-size:1.3rem; }
  footer { max-width:900px; margin:0 auto; padding:2rem 1.25rem;
           color:var(--dim); border-top:1px solid var(--line); font-size:.85rem; }
  a { color:var(--accent); }
</style></head><body>
<header>
  <h1>The Evidence Chain</h1>
  <p>Every stage of Veron, from the hand-assembled seed to the release you run —
     each one's signed attestation and its complete build log, laid out here to
     read. Nothing to download, nothing to dissect.</p>
</header>
<main>
  <p class="intro">The chain descends: the image you run was built from the
  stage-5 system, on the stage-4 sysroot and kernel, from a tcc that came across
  from arm64, from micro-c, from pico-c, from a self-assembler that assembles
  itself and nothing else. Each link below is verifiable against the public
  Rekor transparency log.</p>
  __SECTIONS__
</main>
<footer>
  Generated from the release's evidence bundle. Each attestation is a Sigstore
  bundle you can verify independently:
  <code>gh attestation verify &lt;artifact&gt; --repo __REPO__</code>.
  The build logs are the exact Actions output of each stage's run, preserved
  here past GitHub's artifact-retention window.
</footer>
</body></html>"""

    joiner = '<div class="chain-line">↓</div>'
    page = page.replace("__SECTIONS__", joiner.join(sections))
    page = page.replace("__REPO__", esc(REPO))
    open(out_path, "w").write(page)
    print("evidence page written: %s (%d stages)" % (out_path, len(STAGE_INFO)))


if __name__ == "__main__":
    bundle = sys.argv[1] if len(sys.argv) > 1 else "evidence"
    out = sys.argv[2] if len(sys.argv) > 2 else "evidence.html"
    render(bundle, out)
