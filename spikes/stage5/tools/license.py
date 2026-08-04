#!/usr/bin/env python3
# license.py -- find every licence file in a source tree and say what it is.
#
# WHY THE OLD ONE WAS WRONG, precisely, because each failure maps to a design
# choice worth not repeating:
#
#   six exact filenames      missed freetype's LICENSE.TXT, cmake's
#                            Copyright.txt, libjpeg-turbo's LICENSE.md,
#                            nettle's COPYINGv3 -- seven packages reported as
#                            having no licence at all
#   top level only           missed LICENSES/ directories entirely
#   first 4000 bytes         a file with a preamble hides its identifying text
#   ~14 prose regexes        returned "PRESENT but unrecognised" for seven more
#   FIRST match wins         returned "Zlib" for bzip2, confidently and wrongly,
#                            because both texts contain "altered source
#                            versions must be plainly marked as such"
#   ONE string returned      cannot express xz (0BSD AND GPL AND LGPL), cairo
#                            (LGPL OR MPL), or ffmpeg (depends on ./configure)
#
# A CONFIDENT WRONG ANSWER IS WORSE THAN NO ANSWER. That is the whole reason
# this exists: below the threshold it says NEEDS REVIEW and names what it saw,
# rather than picking the nearest thing.
#
# WHAT IT DOES NOT DO. It does not decide the package's licence. It proposes
# one, with evidence, for a human to confirm once -- and then the recipe pins
# the file checksums so a silent upstream relicensing breaks the build. That
# split is Yocto's LIC_FILES_CHKSUM model and it is deliberate: a detector
# that is load-bearing is a detector that cannot be allowed to say "I do not
# know".

import argparse
import hashlib
import json
import os
import re
import sys

# ---------------------------------------------------------------- finding

# EVERY CONVENTION, NOT SIX NAMES. Case-insensitive, any extension, and the
# REUSE LICENSES/ directory where each file is named for its SPDX id.
NAME_PATTERNS = [
    r"^copying.*$", r"^licen[cs]e.*$", r"^notice.*$", r"^copyright.*$",
    r"^legal.*$", r"^unlicense.*$", r"^patents.*$",
]
SEARCH_DIRS = [".", "LICENSES", "licenses", "License", "doc", "docs",
               "debian", ".reuse"]

# IN A REUSE LICENSES/ DIRECTORY, EVERY FILE IS A LICENCE FILE. The spec says
# so: "The name of the License File MUST be the SPDX identifier of the license
# followed by an appropriate file extension" -- so they are called Zlib.txt and
# MIT.txt, and a filename pattern looking for copying*/licen[cs]e* finds none
# of them. A fixture caught this; the pattern list alone would have reported
# a REUSE-compliant project as having no licence at all, which is the exact
# failure this rewrite exists to end.
ANY_FILE_DIRS = {"LICENSES", "licenses", ".reuse"}
MAX_BYTES = 2_000_000


def find_license_files(root):
    """Every candidate licence file, with its digest."""
    out = []
    seen = set()
    for d in SEARCH_DIRS:
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        for fn in sorted(os.listdir(p)):
            full = os.path.join(p, fn)
            if not os.path.isfile(full):
                continue
            low = fn.lower()
            if d not in ANY_FILE_DIRS and \
                    not any(re.match(pat, low) for pat in NAME_PATTERNS):
                continue
            rel = os.path.relpath(full, root)
            if rel in seen:
                continue
            seen.add(rel)
            try:
                raw = open(full, "rb").read(MAX_BYTES)
            except OSError:
                continue
            out.append({
                "path": rel,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "bytes": len(raw),
                "text": raw.decode("utf-8", "replace"),
            })
    return out


# ------------------------------------------------------------ normalising

# THE SPDX LICENSE MATCHING GUIDELINES, as normalisation passes. These are a
# published spec (Annex B), not house style: they define which textual
# differences are legally insubstantial. Skipping them is why prose regexes
# fail on the same licence formatted two ways.
COPYRIGHT_LINE = re.compile(
    r"^\s*(?:[#*/;%!-]*\s*)?(?:copyright|\(c\)|\u00a9)\b.*$",
    re.I | re.M)
COMMENT_PREFIX = re.compile(r"^[ \t]*(?:[#*;%!]|//|/\*|\*/|--|dnl)[ \t]?", re.M)
BULLET = re.compile(r"^[ \t]*(?:\(?[0-9a-z]{1,3}[.)]|[-*\u2022])[ \t]+", re.M)
WS = re.compile(r"\s+")

VARIETAL = {
    "licence": "license", "licences": "licenses", "licenced": "licensed",
    "acknowledgement": "acknowledgment", "analogue": "analog",
    "authorisation": "authorization", "authorised": "authorized",
    "organisation": "organization", "organisations": "organizations",
    "sublicence": "sublicense", "noninfringement": "non-infringement",
    "labour": "labor", "modelled": "modeled", "offence": "offense",
    "programme": "program", "recognise": "recognize", "signalling": "signaling",
}


def normalise(text):
    """Reduce a licence text to what actually distinguishes it."""
    t = text
    # B.11: the copyright notice is ignored for matching. This is the single
    # largest source of spurious mismatches -- every project's notice differs.
    t = COPYRIGHT_LINE.sub(" ", t)
    # B.7: a licence embedded in a source header is the same licence.
    t = COMMENT_PREFIX.sub("", t)
    # B.8: bullets and numbering vary between renderings of one licence.
    t = BULLET.sub(" ", t)
    # B.5, B.6: case, dashes and quotes are equivalent.
    t = t.lower()
    t = re.sub(r"[\u2010-\u2015\u2212]", "-", t)
    t = re.sub(r"[\u2018\u2019\u201c\u201d`]", "'", t)
    # B.14: http and https are equivalent.
    t = t.replace("https://", "http://")
    # B.9: varietal spellings are equivalent.
    words = re.split(r"([a-z]+)", t)
    t = "".join(VARIETAL.get(w, w) for w in words)
    # B.6 again: punctuation carries little signal once the rest is gone, and
    # keeping it makes bigrams brittle across renderings.
    t = re.sub(r"[^a-z0-9 ]+", " ", t)
    # B.4: all whitespace is one space.
    return WS.sub(" ", t).strip()


def bigrams(norm):
    w = norm.split()
    return set(zip(w, w[1:])) if len(w) > 1 else set(w)


def dice(a, b):
    """Sorensen-Dice over token bigrams -- the metric askalono, licensee and
    the SPDX reference matcher all use. Comparing WHOLE normalised texts is
    what separates bzip2 from zlib: they share one clause, so a clause-hunting
    regex confuses them, while their full bigram sets do not overlap much."""
    if not a or not b:
        return 0.0
    return 2 * len(a & b) / (len(a) + len(b))


# ----------------------------------------------------- required phrases

# A SIMILARITY SCORE ALONE IS NOT ENOUGH FOR NEAR-TWINS. ScanCode calls these
# key phrases: text that MUST be present for a licence to be considered at
# all. bzip2 and zlib share the "altered source versions must be plainly
# marked" clause and differ in their authors' names, so the name is the
# discriminator that makes the answer certain rather than merely probable.
REQUIRED_PHRASES = {
    "bzip2-1.0.6": ["julian seward"],
    "Zlib":        ["jean loup gailly", "mark adler"],
    "libpng-2.0":  ["libpng"],
    "curl":        ["curl"],
    "OpenSSL":     ["openssl"],
    "PostgreSQL":  ["postgresql"],
}


def phrase_ok(spdx_id, norm):
    need = REQUIRED_PHRASES.get(spdx_id)
    if not need:
        return True
    return any(p in norm for p in need)


# ------------------------------------------------------------- SPDX corpus

def load_corpus(path):
    """The SPDX license list, normalised once.

    Vendored and pinned like any other source. A few MB of plain text, no
    dependencies, and the same corpus askalono and the SPDX reference matcher
    use. ScanCode's ~35,000 rules exist for the long tail; a curated set of a
    hundred well-known packages does not need them.
    """
    corpus = {}
    if not os.path.isdir(path):
        return corpus
    for fn in sorted(os.listdir(path)):
        if not fn.endswith(".txt"):
            continue
        # SKIP DEPRECATED IDENTIFIERS. license-list-data ships the retired
        # ones as deprecated_GPL-2.0+.txt alongside the current
        # GPL-2.0-or-later.txt, and their texts are near-identical -- so the
        # matcher kept proposing `deprecated_GPL-2.0+`, which is a real SPDX
        # id and the wrong one to write into a manifest.
        if fn.startswith("deprecated_"):
            continue
        spdx = fn[:-4]
        try:
            raw = open(os.path.join(path, fn), encoding="utf-8",
                       errors="replace").read()
        except OSError:
            continue
        n = normalise(raw)
        corpus[spdx] = (n, bigrams(n))
    return corpus


# ------------------------------------------------------------- SPDX headers

HEADER = re.compile(rb"SPDX-License-Identifier:\s*([^\r\n*/]+)")
CODE_EXT = (".c", ".h", ".cc", ".cpp", ".hpp", ".py", ".sh", ".rs", ".go",
            ".am", ".ac", ".m4", ".build", ".pl", ".rb", ".java")


def scan_headers(root, limit=6000):
    """Per-file SPDX-License-Identifier tags.

    THE MOST AUTHORITATIVE PER-FILE SIGNAL, because the copyright holder wrote
    it deliberately. It is also the only way to tell GPL-2.0-only from
    GPL-2.0-or-later: their COPYING files are BYTE-IDENTICAL, and the
    distinction lives entirely in the per-file notice. Roughly half this
    package set is GPL, so without this the matcher would mislabel version
    flexibility across the board.
    """
    seen, n = {}, 0
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "tests")]
        for fn in files:
            if n >= limit:
                break
            if not fn.endswith(CODE_EXT):
                continue
            n += 1
            try:
                head = open(os.path.join(dirpath, fn), "rb").read(4096)
            except OSError:
                continue
            m = HEADER.search(head)
            if m:
                tag = m.group(1).decode("utf-8", "replace").strip()
                seen[tag] = seen.get(tag, 0) + 1
    return seen


# -------------------------------------------------------------- manifests

MANIFEST_PATTERNS = [
    ("meson.build", re.compile(r"license\s*:\s*'([^']+)'")),
    ("meson.build", re.compile(r'license\s*:\s*"([^"]+)"')),
    ("Cargo.toml", re.compile(r'^license\s*=\s*"([^"]+)"', re.M)),
    ("pyproject.toml", re.compile(r'^license\s*=\s*"([^"]+)"', re.M)),
    ("package.json", re.compile(r'"license"\s*:\s*"([^"]+)"')),
]


def scan_manifest(root):
    """What the project DECLARES, as distinct from what it ships.

    A declaration states intent and a licence file states terms. When they
    disagree that is a review flag, not something to resolve automatically --
    which is why this is reported separately rather than folded into the
    conclusion.
    """
    out = {}
    for fname, pat in MANIFEST_PATTERNS:
        p = os.path.join(root, fname)
        if not os.path.exists(p):
            continue
        try:
            t = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        m = pat.search(t)
        if m:
            out[fname] = m.group(1)
    return out


# ------------------------------------------------------------------ detect

def detect(root, corpus, threshold, probable=0.85, top_n=3):
    files = find_license_files(root)
    results = []
    for f in files:
        norm = normalise(f["text"])
        bg = bigrams(norm)
        scored = []
        for spdx, (cn, cb) in corpus.items():
            s = dice(bg, cb)
            if s > 0.30 and phrase_ok(spdx, norm):
                scored.append((s, spdx))
        scored.sort(reverse=True)
        best = scored[0] if scored else (0.0, None)
        # TWO THRESHOLDS, BECAUSE ONE WAS ANSWERING THE WRONG QUESTION.
        #
        # At a single 0.98 cutoff the run reported NEEDS REVIEW for bzip2
        # (0.9631 against bzip2-1.0.6), libpng (0.9080 against libpng-1.6.35)
        # and harfbuzz (0.8592 against MIT-Modern-Variant) -- every one of
        # them the CORRECT licence, missed because the shipped file differs
        # from SPDX's canonical text by a version number or a contact line.
        # That is why GitHub shows "unknown" so often: licensee uses the same
        # cutoff and gets the same result.
        #
        # So: `matched` still means near-certain, and `probable` names the
        # licence with its score for a human to confirm. Telling a curator
        # "this is almost certainly bzip2-1.0.6" is useful; telling them
        # "NEEDS REVIEW" with no candidate is not.
        if best[0] >= threshold:
            verdict, spdx = "matched", best[1]
        elif best[0] >= probable:
            verdict, spdx = "probable", best[1]
        elif scored:
            verdict, spdx = "NEEDS REVIEW", None
        else:
            verdict, spdx = "NO MATCH", None
        results.append({
            "path": f["path"],
            "sha256": f["sha256"],
            "bytes": f["bytes"],
            "spdx": spdx,
            "score": round(best[0], 4),
            "candidates": [{"spdx": s, "score": round(v, 4)}
                           for v, s in scored[:top_n]],
            "verdict": verdict,
        })

    headers = scan_headers(root)
    manifest = scan_manifest(root)
    ids = sorted({r["spdx"] for r in results
                  if r["spdx"] and r["verdict"] == "matched"})
    probables = sorted({r["spdx"] for r in results
                        if r["spdx"] and r["verdict"] == "probable"})
    # AND, NOT A SINGLE STRING. Several licence files in one tarball means
    # several sets of terms apply -- which is the honest reading for xz and
    # ffmpeg. A genuine OR (cairo) cannot be inferred from file presence and
    # has to be curated, so this proposes AND and says so.
    expr = " AND ".join(ids) if ids else None

    # WHERE THE EVIDENCE DISAGREES, SAY SO RATHER THAN PICK ONE.
    #
    # The GPL case makes this unavoidable: GPL-2.0-only and GPL-2.0-or-later
    # ship BYTE-IDENTICAL COPYING files, and the distinction exists only in
    # per-file notices. So a file-derived expression will say -only for a
    # package that is really -or-later, every time, and the header scan is the
    # only thing that can contradict it. Roughly half this package set is GPL.
    flags = []
    # SEVERAL LICENCE FILES DOES NOT MEAN "AND". cairo ships MPL-1.1 and
    # LGPL-2.1 and is licensed under EITHER -- a genuine SPDX `OR`. ffmpeg
    # ships GPL and LGPL texts and which one applies depends on ./configure.
    # File presence cannot distinguish those from xz, where several licences
    # really do apply at once. So AND is proposed as the conservative reading
    # and the ambiguity is stated rather than hidden.
    if len(ids) > 1:
        flags.append(f"{len(ids)} licence files matched -- AND is a GUESS. "
                     f"Dual-licensed projects (cairo: MPL OR LGPL) and "
                     f"configure-dependent ones (ffmpeg) need a human to say "
                     f"which operator applies")
    if probables:
        flags.append(f"probable but unconfirmed: {', '.join(probables)}")
    hdr_ids = set()
    for tag in headers:
        hdr_ids.update(re.split(r"\s+(?:AND|OR|WITH)\s+", tag))
    file_ids = set(ids)
    if hdr_ids and file_ids and not (hdr_ids & file_ids):
        flags.append(f"source headers say {sorted(hdr_ids)} but the licence "
                     f"files match {sorted(file_ids)}")
    for tag in sorted(hdr_ids):
        # STRIP THE SUFFIX, NOT A SUBSTRING. `.replace("-only", "")` turned
        # Apache-2.0 into "Apache-2." and printed a flag naming a licence that
        # does not exist.
        base = re.sub(r"-(?:or-later|only)$", "", tag)
        for fid in file_ids:
            if fid != tag and re.sub(r"-(?:or-later|only)$", "", fid) == base:
                flags.append(f"headers say {tag}, licence file matched {fid} "
                             f"-- the texts are identical, trust the header")
    if manifest and expr:
        for src, decl in manifest.items():
            if decl not in (expr, *ids):
                flags.append(f"{src} declares {decl!r}, files match {expr!r}")

    return {
        "license_files": results,
        "spdx_headers": headers,
        "declared_in_manifest": manifest,
        "proposed_expression": expr,
        "review_flags": flags or None,
        "needs_review": [r["path"] for r in results
                         if r["verdict"] != "matched"] or None,
    }


def main():
    ap = argparse.ArgumentParser(prog="license")
    ap.add_argument("root", help="unpacked source tree")
    ap.add_argument("--corpus", required=True,
                    help="directory of SPDX licence texts, one <id>.txt each")
    # 0.98, THE SAME CUTOFF GITHUB'S licensee USES. A fixture with the
    # project name substituted AND an extra clause appended scored 0.9326 and
    # was reported as a clean match at 0.90 -- but SPDX B.3.3 says added text
    # means it is NOT the same licence. A high threshold turns that into
    # NEEDS REVIEW, which is the honest answer and the whole point.
    ap.add_argument("--probable", type=float, default=0.85,
                    help="above this, name the licence as probable")
    ap.add_argument("--threshold", type=float, default=0.98,
                    help="below this, report NEEDS REVIEW rather than guess")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    corpus = load_corpus(a.corpus)
    if not corpus:
        print(f"  no corpus at {a.corpus} -- nothing to match against",
              file=sys.stderr)
        return 2
    r = detect(a.root, corpus, a.threshold, a.probable)

    if a.json:
        print(json.dumps(r, indent=2))
        return 0

    print(f"  corpus: {len(corpus)} licences")
    if not r["license_files"]:
        print("  NO LICENCE FILE FOUND anywhere in the conventional places.")
        print("  That is a real state, not always an error -- sqlite is public")
        print("  domain and says so only in its source headers -- but it must")
        print("  be curated rather than assumed.")
    for f in r["license_files"]:
        print(f"\n  {f['path']}  ({f['bytes']} bytes)")
        print(f"    sha256 {f['sha256']}")
        print(f"    {f['verdict']:<12} {f['spdx'] or ''}"
              + (f"   ({f['score']:.4f})" if f['spdx'] else ""))
        for c in f["candidates"]:
            print(f"      {c['score']:.4f}  {c['spdx']}")
    if r["spdx_headers"]:
        print("\n  SPDX headers in source:")
        for k, v in sorted(r["spdx_headers"].items(),
                           key=lambda x: -x[1])[:8]:
            print(f"    {v:>5}  {k}")
    if r["declared_in_manifest"]:
        print("\n  declared in a manifest:")
        for k, v in r["declared_in_manifest"].items():
            print(f"    {k}: {v}")
    if r.get("review_flags"):
        print("\n  DISAGREEMENT -- curate this one:")
        for f in r["review_flags"]:
            print(f"    {f}")
    print(f"\n  proposed: {r['proposed_expression'] or 'UNRESOLVED'}")
    if r["needs_review"]:
        print(f"  needs review: {', '.join(r['needs_review'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
