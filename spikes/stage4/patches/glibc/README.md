# Vendored glibc patches

LFS's patch directories are **not archives**. `/patches/lfs/development/` tracks
whatever the development book currently is, and its contents are revised and
removed in place. Two consecutive runs of `stage3-to-stage4-reference` died on

```
FETCH FAILED: .../patches/lfs/development/glibc-2.43-upstream_fixes-1.patch
```

while sixteen tarballs and `glibc-fhs-1.patch` came down from the same host in
the same run, and with `stage4-complete`'s own curl flags. The file had been
removed, not merely moved.

**`stage4-complete` fetches the same file from the same directory with no
cache, so it will fail the same way.** Vendoring fixes both jobs.

## What belongs here

| file | why |
|---|---|
| `glibc-2.43-upstream_fixes-1.patch` | *"Now fix glibc to build against Linux 7"* -- the book's own words. This box pairs glibc 2.43 with linux 7.1.3 headers, which is exactly the pairing the patch exists for. Without it, rung 13 stops on a `-Werror` redefinition between the libc and the kernel headers. |
| `glibc-fhs-1.patch` | LFS 13.0's own, and stable -- `/patches/lfs/13.0/` is a released directory rather than a moving one. Vendored anyway, because "this one happens to be stable" is a property of the server, not of this repository. |

## Digests, from the vendored book

```
glibc-fhs-1.patch                   9a5997c3452909b1769918c759eff8a2
glibc-2.43-upstream_fixes-1.patch   1f5074a1dce85a72d2ea465ca76e420b
```

Recorded from `spikes/stage4/books/LFS-BOOK-r13_0-156-systemd`. The workflows
compare against these and say plainly when they differ; they do **not** gate on
them, because the real gate is `patch` itself -- a truncated or substituted
patch does not apply cleanly to glibc 2.43, and rung 13 refuses to continue
when it does not.

## How to add one

```sh
curl -O https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.43-upstream_fixes-1.patch
md5sum glibc-2.43-upstream_fixes-1.patch    # expect 1f5074a1dce85a72d2ea465ca76e420b
cp glibc-2.43-upstream_fixes-1.patch spikes/stage4/patches/glibc/
```

If the md5 differs, the development book has moved on. That is not necessarily
wrong -- but record the new digest here and say which revision it came from,
rather than replacing the number silently.

## The general rule this is an instance of

Anything the build **needs** should be a pinned input this repository holds or
can name a stable URL for. A file fetched from a directory that mutates is
neither, and it fails at the least convenient moment -- in this case after
sixteen successful downloads, on the seventeenth, in a job that had already run
for a minute.
