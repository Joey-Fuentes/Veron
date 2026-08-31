# Stage 4: why the sysroot differed, measured on the artifact

Tree A in the diff is the published `sysroot.tar.zst` from the amd64 run; its
hashes match the A column for all nineteen paths (`perlbug` `934eeb67…`,
`libmvec.a` `fc9e568b…`, `config.h` `262f523d…`). Everything below was read
out of that tarball rather than inferred from the scripts.

## 1. Fifteen of the nineteen are static archives, and the cause is one flag

`ar tv` on the shipped tree partitions every archive in the sysroot cleanly:

```
15 archives   rw-r--r--  1001/1001   Jan  1 00:00 1970
12 archives   rw-r--r--     0/0      Jan  1 00:00 1970
 7 archives   empty (glibc stubs -- 8 bytes, no members)
```

The fifteen carrying `1001/1001` are **exactly** the fifteen in the diff:

```
libBrokenLocale.a  libc.a  libc_nonshared.a  libg.a  libm-2.44.a
libmvec.a  libresolv.a                          <- B2, glibc
libbfd.a  libctf.a  libctf-nobfd.a  libopcodes.a  libsframe.a
                                                 <- B3, binutils' own
libfl.a  liby.a                                  <- B1, flex and bison
perl5/5.44.0/x86_64-linux/CORE/libperl.a         <- B1, perl
```

and the twelve at `0/0` are every archive built from B4 upward — `libgcc.a`,
`libgcc_eh.a`, `libgcov.a`, `libstdc++.a`, `libstdc++exp.a`, `libstdc++fs.a`,
`libsupc++.a`, `libatomic.a`, `libitm.a`, `libz.a`, `libelf.a`,
`libpkgconf.a`. The split falls precisely at B3's `make install`.

`1001` is the GitHub runner's uid. On a Veron laptop it is `1000`. mtime is
already `0` — `SOURCE_DATE_EPOCH` does reach the member timestamp — and mode
is a constant `644` under the fixed umask, so **uid and gid are the only live
fields in the whole delta.** That matches the shape stage 5 measured in its
own box on 2026-08-30: 1096 differing bytes in `libmvec.a`, every one `61`
against `60`.

Why the split lands where it does: phase B runs with `/tools/bin` off `PATH`,
so from B0 until B3 finishes installing, `/usr/bin/ar` is the one **rung 16**
installed. Rung 4 passes `--enable-deterministic-archives`. Rung 10 passes it.
B3 passes it and explains at length why. Rung 16 did not. Every archive
created before B3 replaces that `ar` therefore carries the builder's identity;
every archive after it does not.

**Fix:** `--enable-deterministic-archives` on the rung-16 binutils pass 2
configure, in `rungs-amd64.sh` and `rungs-riscv64.sh`. `D` zeroes uid, gid,
mtime and mode together, so it closes the other three fields before they are
ever reached.

**Second fix, defence in depth:** `--uid 0 --gid 0` on stage 4's two bwrap
invocations, the same two flags stages 5 and 6 already pass. `--unshare-all`
creates a user namespace but maps the caller's uid to itself, so `getuid()`
inside is still the build user. The archiver flag fixes the archives; this
fixes the class — anything tarred, cpio'd or ext4'd out of the box, which is
the same fault the stage-5 commits of 2026-08-30 chased through
`normalize-ext4` and the rootfs image.

Either fix alone makes these fifteen match. Both, and the recorded identity
stops depending on who ran the build at all.

## 2. The other four are perl, and there is nothing to port from stage 5

Stage 4's phase-B perl rung already pins a **superset** of what stage 5's
recipe pins:

```
                        stage 5 recipe    stage 4 sysroot-amd64.sh
  -Dcf_by                    yes                yes
  -Dcf_email                 yes                yes
  -Dperladmin                yes                yes
  -Dmyhostname               yes                yes
  -Dcf_time                  yes                yes
  -Dmyuname                  yes                yes
  -Dosvers                   NO                 yes
  -Dmydomain                 NO                 yes
  config.over override       NO                 yes  (cf_time + mydomain)
```

and every one of them held in the shipped artifact:

```
cf_by='veron'          myuname='Linux veron 7.1.5 x86_64'
cf_time='Thu Jan  1 00:00:00 UTC 1970'
myhostname='veron'     mydomain='.veron'     osvers='7.1.5'
* Configured by     : veron
* Target system     : Linux veron 7.1.5 x86_64
```

No `/home`, no `/work`, no uid, no runner name anywhere in the four files.
The `config.over` trick -- overriding the two values Configure recomputes
regardless of `-D` -- is stage 4's own and stage 5 does not even use it.

So the amd64 path needs nothing from stage 5. What it does need is for the
fix to exist in more than one place.

**THREE COPIES OF THAT RUNG EXIST AND ONLY ONE HAD IT.**

```
  sysroot-amd64.sh     pinned      <- build.sh runs this; the official leg
  rungs-sysroot.sh     BARE        <- stage3-to-stage4-reference.yml
  sysroot-riscv64.sh   BARE        <- stage4-arch-spike-riscv64.yml
```

Both bare copies still carried the old comment block explaining the flags
they no longer passed -- `./Configure -des -Dprefix=/usr -Dcc=gcc` and
nothing else. Any sysroot they produce has the runner's hostname and kernel
version baked into four shipped files. Ported to both, with `riscv64` rather
than `x86_64` in the riscv `myuname` so the constant is not a lie about the
box it describes.

## 3. The manifest does not describe the artifact

Asked directly: **five files in the shipped sysroot appear in no manifest
row.**

```
/.chapter5-complete        95 B   phase marker written by rung 16
/.phase-a-complete         74 B   phase marker, read by build.sh as a gate
/etc/ld.so.cache        2,467 B   ldconfig output
/etc/rpc                1,634 B   glibc data file
/var/lib/nss_db/Makefile 5,299 B  glibc's nss_db install
```

Two are build markers, three are glibc and ldconfig side effects. None is
alarming; all five are content nobody declared.

The larger finding is the other direction. `phase_pack` copies B8's
`manifest.tsv` into `rel/` verbatim, but between B8 and that copy it runs
`sysroot-trim.sh`, which deletes trees and runs `strip --strip-debug` over
three dozen executables. Stripping rewrites bytes. Checked entry by entry
against the shipped tree:

```
10,414  B8 entries
 9,569  regular files actually shipped
   850  entries naming files the trim deleted
    46  entries whose hash is the pre-strip one
 9,518  entries that are correct
```

`/usr/bin/gcc` is recorded at 12,570,128 bytes and `838f834b…`; it ships at
2,414,296 bytes and `261439961f…`. All 46 are strip targets — the 33 named in
`trim.txt` plus their hardlink aliases (`g++`/`c++`, `gawk-5.3.2`,
`perl5.44.0`, `ld.bfd`, the `x86_64-veron-linux-gnu-*` set). The nineteen
differing files are all correctly recorded; the manifest is not why they
differ. But a manifest that disagrees with the tarball beside it in 896 of
10,414 rows cannot be used to verify that tarball, which is the only thing it
is for.

**Fix:** `tools/manifest-shipped.py`, called from `phase_pack` after the trim.
It writes two files and keeps them distinct:

- `rel/manifest-b8.tsv` — what the ladder built, pre-trim. The build record.
- `rel/manifest.tsv` — the trimmed tree, hashed as packed. The artifact record.
- `rel/manifest-reconcile.txt` — every path where they disagree, so the trim's
  effect on the manifest is stated rather than inferred from a size drop.

Consumers keep parsing `rel/manifest.tsv`; the label column reads `SHIP`
rather than `B8`, and the rows are now true.

## 4. Two smaller things, noted and not fixed

**`/usr/bin/strip` ships unstripped.** `trim.txt` ends with `FAILED
/usr/bin/strip: Text file busy` — strip cannot rewrite itself while running.
Consistent on Linux, so not a reproducibility risk today, but it is the one
binary in the set whose final bytes depend on a kernel behaviour rather than
on a decision. Stripping it to a temporary and renaming over it would close
that.

**`/etc/ld.so.cache` is unmanifested and generated.** glibc's `ldconfig` sorts
its output, so it should be stable, but it is derived state inside a published
artifact with no recorded provenance. Worth either manifesting it or dropping
it and letting first boot regenerate it.

## 5. On perl in stage 4 and stage 5

Stage 4 keeps perl -- 4.3 MB binary, 1,879 files, 63 MB under
`/usr/lib/perl5` -- because glibc's and the kernel's builds need one. The
trim only strip-debugs the binary; nothing is removed.

Stage 5 then builds perl 5.44.0 again, `build_only = true`. That is not a
perl-specific arrangement: perl is one of eight `build-substrate` packages
the stage-4 sysroot already provides, alongside `bison`, `flex`, `m4`,
`openssl`, `pkgconf`, `bzip2` and `xz`. The sysroot is substrate; packages
in the image set get their own pinned recipe regardless.

The two perls are pinned independently and neither depends on the other, so
this has no bearing on byte-identity either way.
