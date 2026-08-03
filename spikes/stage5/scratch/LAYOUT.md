# scratch — how this should look in production

Everything in `spikes/stage5/` is under suspended invariants and a spike path.
This file is what it should become when it moves into Veron proper. It is a
proposal; nothing here is ratified.

```
packages/<name>/recipe.toml       one file per package — MANY, not one
packages/<name>/patches/*.patch   our delta, and only ours
policy/defaults.toml              global build policy — ONE file
policy/expected-differences.toml  declared divergence
policy/opaque.toml                things that cannot be built, with reasons
policy/keyring.toml               fingerprints Veron vouches for
tools/veron                       the driver — runs anywhere
PLAN.txt                          generated, COMMITTED, shipped
ledger/<output-hash>.json         one record per output
```

## Many recipes, one plan

**Authored: many.** One file per package means branch A adding `foo` and branch
B adding `bar` can never conflict. One big authored file puts every branch in
the same region, and you resolve conflicts weekly for no benefit.

**Generated: one.** `PLAN.txt` is the aggregate — every package, every literal
argv, all three shas, the resolved order. Length stops mattering the moment
nobody authors it, and a CLI or UI reads it better than a human does.

**It is committed, and that was a correction.** The earlier argument against —
that it would conflict — was both overstated and beside the point. Deterministic
generation with one contiguous block per package merges cleanly, and more
importantly the file is a *deliverable*, not a working file. An end user has a
downloaded image and no git, and needs to check that their master list of
packages, shas and commands matches Veron's. If the plan only exists when the
tool generates it, the tool is the only witness to what the tool did.

Kept honest by one gate: `veron plan --check` regenerates and diffs, and CI
fails on a difference. **The gate must run on the merge result, not just on
branch heads** — two branches can each be green, each having regenerated
correctly, and their merge still disagree with the recipes because neither
branch saw the other's package. Nobody hand-edited anything and main is wrong.

**A conflict in a derived file is never resolved, only regenerated.** A
hand-merged `PLAN.txt` corresponds to no possible run of the generator: it
looks authoritative and is fiction, which is worse than stale, because a stale
one fails the gate and a hand-merged one can be made to pass a careless eye.
The same rule covers every derived-but-committed artifact — plan, ledger
records, resolved order, SBOM.

## Verification is one hash, not a 10k-line diff

Hash `PLAN.txt`, carry that hash into the ledger root. `veron verify` checks
one hash and only falls back to a diff when it mismatches.

## What the stage script is

**Policy, not inventory** — which is what keeps it readable at 200 packages:

```sh
#!/bin/sh
set -eu
# Ecosystem stage. Policy only. The dependency graph is DERIVED from
# packages/*/recipe.toml and is never listed here.

veron build  --group build-substrate --gates build,test
veron build  --group system          --gates build,test
veron build  --group networking      --gates build,test

veron verify --tier 1                       # G3: rebuild, byte-compare
veron selfrebuild --subset build-substrate  # boot it, rebuild inside, diff

veron build  --group graphics --arch aarch64   # tier 2: reference arch only
veron build  --group wayland  --arch aarch64

veron status --require-unknown 0
```

Thirty lines, and it tells you the shape of the whole stage: order, gates,
where the arch matrix narrows, what the exit condition is. Group membership
lives in each recipe, so adding a package still touches exactly one file.

## Open, and deliberately not decided here

- **`packages/` as a top-level directory** is not in `ARCHITECTURE.md` §4's
  skeleton. Adding one is a design change under `AGENTS.md` §2a. The
  alternative — `stages/5-ecosystem/` — keys packages to a stage number that
  [`STAGE-NUMBERING.md`](../../../STAGE-NUMBERING.md) has not settled, which
  is an argument for the separate directory rather than against it. Living
  under `spikes/` for now avoids forcing the decision early.
- **`sources/` overlaps this.** Pins currently live in `sources/*.toml`. If
  they also live in recipes, a version bump means editing two files and they
  drift. Folding the pin into the recipe is one edit per bump, with
  `veron roots` generating the aggregate view `sources/` serves by hand — but
  `sources/` is load-bearing for stages 0–4, so that is a migration, not a
  deletion.
- **`tools/lint-workflow`** — ten lines that fail if any `run:` in
  `.github/workflows/` contains build logic rather than a `veron` call.
  Without it this regresses within a month, one quick YAML fix at a time.
