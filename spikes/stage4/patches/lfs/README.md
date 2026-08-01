# Vendored LFS patches

Every patch section 3.3 of `LFS-BOOK-r13_0-167` lists, with the digest the book
records. All eight verified on arrival.

```
glibc-fhs-1.patch                          9a5997c3452909b1769918c759eff8a2
Python-3.14.6-consolidated_fixes-1.patch   263746d5e08aa2c9f2d9d7060435dec4
bzip2-1.0.8-install_docs-1.patch           6a5ac7e89b791aae556de0f745916f7f
coreutils-9.11-i18n-1.patch                900d64d9936516b68613271c9ebc0059
expect-5.45.4-gcc15-1.patch                0ca4d6bb8d572fbcdb13cb36cd34833e
kbd-2.10.0-backspace-1.patch               f75cca16a38da6caa7d52151f7136895
sysvinit-3.14-consolidated-1.patch         3af8fd8e13cad481eeeaa48be4247445
tar-1.35-acl_fix-1.patch                   dbab49e317105539611866dac5dd54f6
```

## Which of these does the bridge actually use?

**One: `glibc-fhs-1.patch`.** It is the only patch applied in chapter 5, and
chapter 5 is where this chain's ladder ends.

| patch | applied in | do we reach it? |
|---|---|---|
| **glibc-fhs-1** | **5.5 glibc** | **yes -- rung 13** |
| Python-3.14.6-consolidated_fixes-1 | 8.x Python | no. Rung 11.7 builds Python from an unpatched tarball, and it is a BUILD TOOL for glibc rather than part of the final system |
| bzip2, coreutils, expect, kbd, sysvinit, tar | 8.x | no. Chapter 8 is the final system; this chain substitutes BusyBox for chapter 6 and does not reach chapter 8 at all |

So seven of the eight are for a part of LFS the bridge does not build. They are
vendored anyway, because the point of vendoring is that the decision not to
need something is ours rather than the server's.

## Why they are here rather than fetched

`/patches/lfs/development/` is not an archive: it tracks whatever the
development book currently is, and its contents are revised and **removed** in
place. Two runs of `stage3-to-stage4-reference` died on

```
FETCH FAILED: .../lfs/development/glibc-2.43-upstream_fixes-1.patch
```

while every other file came down from the same directory in the same run, with
`stage4-complete`'s own curl flags. The book explains it: r13.0-167 moved to
**glibc 2.44**, which needs no reconciliation with a 7.x kernel, and dropped
that patch from 3.3 entirely.

That is the good version of this failure -- the answer was "stop needing it".
The bad version is a patch we DO need disappearing mid-build, which is what
this directory prevents.

## Refreshing

`.github/workflows/fetch-lfs-patches.yml` reads section 3.3 out of the vendored
book, fetches exactly what it names from every directory LFS uses, verifies
each digest, and uploads the set. Run it, download the artifact, drop the files
here.

If a digest differs, the development book has revised the patch in place. That
is expected and not wrong -- but read the diff and record the new digest here
with the revision it came from, rather than replacing the number silently.
