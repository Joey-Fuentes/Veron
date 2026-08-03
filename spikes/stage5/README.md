# stage5 spike — two packages, out of the box, booting

A feasibility tracer for the **ecosystem stage**: does the designed shape —
recipes, a generated plan, three gates, a manifest, a ledger record, a
deterministic image — hold at n=2? Invariants are suspended here as everywhere
under `spikes/`; the production shape is laid out in [`scratch/LAYOUT.md`](./scratch/LAYOUT.md).

**Nothing here has run yet.** It is written, syntax-checked, and the driver is
exercised end to end on fixture data — the plan regenerates identically, the
stale-plan gate fails correctly, the rootfs tar survives an mtime change. What
has *not* happened is a real build, a real image, or a boot. Expect the first
several runs to find harness bugs. That is the normal rate here: six of the
first seven bridge runs found harness bugs rather than compiler bugs.

---

## The two packages, and why they are different jobs

| | `pkgconf` 3.0.5 | `hello` 2.12.3 |
|---|---|---|
| role | the real floor of the package set | the instrument |
| group | `build-substrate` | `spike-probe` — **not** a stage 5 package |
| proves | the search path is pinnable, transitive `.pc` resolution works | the harness: configure, `make check`, DESTDIR, a binary that runs in the guest |

`hello` is here because **the harness must not be confusable with the
package**. If a run fails, bisect with `hello` alone — it has no moving parts.

**What n=2 buys over n=1**, and this is most of the argument for two:

- **Ordering determinism.** Two independent nodes create a tie in the
  topological sort. Unless the tie-break is pinned, `PLAN.txt` does not
  regenerate identically and the diff gate produces false failures until
  someone disables it. n=1 cannot catch this.
- **Manifest attribution.** Two DESTDIRs merging into one image is where
  "which derivation produced this file" first has to work. That is what
  `veron why` reads, and the part that is painful to retrofit.
- **Two SPDX ids** — ISC and GPL-3.0-or-later — so the license field is a real
  test rather than a placeholder.

---

## Running it locally

Identical to what the workflow does, because the workflow is a caller:

```sh
cd spikes/stage5
python3 tools/veron plan            # every command, fully expanded
python3 tools/veron plan --check    # regenerate and diff against PLAN.txt
python3 tools/veron fetch           # sha256 against the manifest
python3 tools/veron build --dry-run # print exactly what would run
python3 tools/veron build
python3 tools/veron manifest        # every path -> its package
python3 tools/veron rootfs          # deterministic tar
python3 tools/veron ledger
python3 tools/veron status
```

Python 3.11+ (`tomllib`), standard library only.

---

## Findings already, before a single run

**1. There is no entry contract. This is the blocking one.**

Stage 4 publishes `veron-boot` (Image + initramfs), `veron-toolchain` (five
binaries and a `libexec-gcc` tarball) and `sysroot-manifest`. It does **not**
publish a sysroot. The full tree goes to `actions/cache` under
`sysroot-mc-tcc-<glibc>-<khdr>-v2-${{ github.run_id }}` — unique per run, and
that workflow's own comment says *nothing restores this today*.

So stage 5 has nothing clean to consume. The spike restores by cache prefix,
which silently gets whichever recent run happened to save last — exactly the
ambiguity a content-addressed entry contract removes. **The fix belongs in
stage 4:** publish the sysroot as a named, hashed artifact. Until then the
spike proves the need by being awkward about it, and reports
`VERON-BUDGET-DIRTY` when it falls back to the runner's toolchain.

**2. `hello` has no pinnable sha256 and cannot get one from a search.**

GNU publishes a detached signature, not a checksum file, and there is no digest
inside a `.sig` to extract. The pin is *computed* by a human, once, after
`gpg --verify` succeeds — verify first, hash second, or you pin whatever you
happened to download. The recipe carries `PENDING-HUMAN-VERIFICATION` and
`veron fetch` fails loudly until someone does it. **That failure is the design
working**, and the digest must not be copied off a web page: that is laundered
provenance, a second unverified source wearing the shape of verification.

**3. The tarball-vs-git question has no answer at this rung.**

`pkgconf`'s recipe carries the commit as *metadata* and `correspondence =
"unverified"`. It cannot be better here: a git checkout has no `./configure`,
and generating one needs autoconf, automake, libtool, m4 and perl — all group
1, all **above** pkgconf. So the shipped generated files are irreducibly
trusted at the floor, and the window closes once group 1 exists.

That residue is not a footnote. The 2024 xz backdoor lived in exactly it:
generated build machinery present in the tarball and absent from the
repository, where anyone diffing the *source* saw nothing.

---

## What this spike deliberately does not do

- **No self-rebuild gate.** Booting and running both packages proves the
  packages work. The system *rebuilding* them and matching hashes is a
  different and stronger claim, it needs a toolchain in the guest, and it needs
  a harness already known-good — otherwise a mismatch is ambiguous between the
  two, which is the confusion this repo has already paid for twice.
- **No login prompt.** That needs `agetty`, a shell, `/etc/passwd` and an init
  that spawns a getty rather than running a script — two of which are not
  built. Arrives with group 2. The spike keeps stage 4's marker-and-exit boot.
- **No bootloader**, so the image is not yet standalone-flashable. QEMU boots
  stage 4's kernel with this as the root disk. Declared, not implied.
- **No cache.** Cold every run. A cache is the step most likely to hide a
  reproducibility bug behind a hit, and it lands after G3 works.
- **One flavor, one arch.** glibc, ARM64.

---

## What to look for in the first run

In rough order of what will break:

1. `VERON-FETCH-FAIL` on `hello` — **expected**, see finding 2.
2. `VERON-ENTRY-ABSENT` — expected unless a stage-4 run recently saved a
   sysroot; the run continues as a harness-only test and says so.
3. `pkgconf`'s configure flag spellings, and whether 3.0.5 ships a usable
   `./configure` at all rather than expecting meson. Unverified here.
4. `VERON-IMAGE-REPRO-DIFF` — the container is the hardest part and the knobs
   in the workflow are a first guess. A difference is a finding: add it to
   `policy/expected-differences.toml` with a cause, or fix the knob. Do not
   silence it.
