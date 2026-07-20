# spikes/reference — vendored upstream source (READ-ONLY reference)

Pinned copies of the upstream sources that define our handoff target. These are
here so the source can be **consulted locally** (including by the assistant in a
fresh session, whose sandbox has no network and does not persist) when designing
against the C subset we must reach — see
[`../stage2-mini-c/TARGET-SUBSET.md`](../stage2-mini-c/TARGET-SUBSET.md).

## What's here

| dir          | upstream                                   | pinned commit                              |
|--------------|--------------------------------------------|--------------------------------------------|
| `m2-planet/` | https://github.com/oriansj/M2-Planet.git   | `34fbd5c2a9b6eb634a4f6ad95158dcd1efcf19e0` |
| `m2libc/`    | https://github.com/oriansj/M2libc.git      | `ca023d8dc855171fd0618951add5817e0e568fca` |

These are the exact commits the `borrow-m2-demo` workflow pins, so the vendored
copy and the CI-built copy are the same source. The subset characterization in
`TARGET-SUBSET.md` was derived from *these* files.

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
