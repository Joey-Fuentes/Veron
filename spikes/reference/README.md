# spikes/reference — vendored upstream source (READ-ONLY reference)

Pinned copies of the upstream sources that define our handoff target. These are
here so the source can be **consulted locally** (including by the assistant in a
fresh session, whose sandbox has no network and does not persist) when designing
against the C subset we must reach — see
[`../stage2-pico-c/TARGET-SUBSET.md`](../stage2-pico-c/TARGET-SUBSET.md).

## What's here

| dir          | upstream                                   | pinned commit                              | matches CI? |
|--------------|--------------------------------------------|--------------------------------------------|-------------|
| `m2-planet/` | https://github.com/oriansj/M2-Planet.git   | `bd2fe4b0659fd0ad3f476a5ad0ef801bd134665d` | yes         |
| `m2libc/`    | https://github.com/oriansj/M2libc.git      | `ca023d8dc855171fd0618951add5817e0e568fca` | **no**      |

`bd2fe4b` is the tag `Release_1.13.1` (2025-08-17) exactly, and it is
`M2PLANET_SHA` in `tcc-two-ways.yml` and the other stage-3 workflows. See
[`../UPSTREAM-PINS.md`](../UPSTREAM-PINS.md) for why a tagged release rather
than `master`: the post-release tree carries the unreleased 1.13.2 buffered-I/O
change, which miscompiles on aarch64.

**This directory was `34fbd5c` until now** -- `Release_1.13.1-56-g34fbd5c`, a
`master` checkout from 2026-07-06, fifty-six commits past the pin. The pin
moved to the release tag and `UPSTREAM-PINS.md` was written to explain why, but
the vendored copy was never re-cloned. Nothing failed, because nothing builds
from this directory -- it just quietly stopped being the source CI compiles,
which is the one property the section below promises.

The consequence was concrete: the stage-3 patch series (`patches/m2-planet/` and
`patches/micro-c-experiments/`) would not apply here at all -- 42 hunks of
`EXPERIMENT-cc_core.c.patch` failed -- so micro-c could not be built or run
outside CI, and every stage-3 diagnosis had to go through a full CI round. At
the pin, all fifteen patches apply and the resulting binary is **byte-identical**
to the one CI builds.

**`m2libc/` is still at the old pin and is known-stale.** `UPSTREAM-PINS.md`
records the current M2libc pin as `68a23cfd05d5a355ba7a30c770d684cbe86fcc4e`,
which is also what M2-Planet's own submodule points at from `bd2fe4b`. This
directory is `ca023d8`. It is left alone here rather than half-fixed, because it
is the copy `difftest.sh` and the CI `SUBJECT` steps both pass as `M2LIBC`, so
CI and local agree today -- changing one without the other would break that. It
should be refreshed to `68a23cfd` in its own change, with the workflows checked
in the same pass.

The subset characterization in `TARGET-SUBSET.md` was derived from the *old*
tree. `cc.h`'s data model is unchanged between the two, but that has not been
re-derived and should not be assumed.

The self-host subset is defined by M2-Planet's own compiler source
(`m2-planet/cc.h`, `cc*.c`, `gcc_req.h`) plus the M2libc it links
(`m2libc/bootstrappable.c`, `stdio.c`, `stdlib.c`, `string.c`, `ctype.c`, and the
`m2libc/aarch64/` runtime `.M1`/`.hex2`). Start with `cc.h` — it's the whole data
model in ~180 lines.

## What this is NOT

- **Not part of the build.** Nothing here is compiled or assembled by our CI. The
  `borrow-m2-demo` workflow still *fetches* the pinned upstreams itself; this tree
  is documentation/reference only. (No file here matches the generic spike matrix
  glob, so `as` never touches it.)
- **Not our code.** M2-Planet and M2libc are GPLv3; their `LICENSE` files are kept
  in place. They are upstream build dependencies of the borrowed live-bootstrap
  chain, vendored here purely for reference.
- **Not a fixed snapshot to edit.** Treat it read-only. To refresh, re-clone at a
  new commit, replace these dirs, update the SHAs above (and in
  `borrow-m2-demo.yml` + `TARGET-SUBSET.md`), and re-derive the subset if it moved.

## Refreshing, and the check that would have caught this

    git clone https://github.com/oriansj/M2-Planet.git /tmp/m2
    git -C /tmp/m2 archive <SHA> | (mkdir -p m2-planet && cd m2-planet && tar -xf -)

Use `git archive`, not `checkout` plus a copy: a checkout leaves any local
modifications in place and you will vendor a patched tree without noticing.

The invariant worth testing is one line, and it is the property this directory
exists for:

    the stage-3 patch series applies cleanly to reference/m2-planet

A drifted copy passes every other check -- it compiles, it reads correctly, it
looks like M2-Planet -- and fails only that one. It went unnoticed for weeks.
