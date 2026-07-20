# spikes/ — rapid cross-arch proof-of-concepts

A spike is a tiny program you assemble and run under QEMU user-mode to answer
one question fast. Spikes are throwaway/experimental — they may use full
assembler conveniences (macros, pseudo-instructions). Only the real stage-0
seed obeys the no-pseudo-ops, bijective-encoding rule.

## Naming convention

One source per architecture, tagged in the filename:

```
spikes/<name>/<name>.x86_64.s
spikes/<name>/<name>.aarch64.s
spikes/<name>/<name>.riscv64.s
```

The workflow picks up `spikes/**/*.<arch>.s` automatically for each arch in the
matrix. A spike need not cover all three arches — add only the ones you're
testing.

## Run one locally (same script CI uses)

```bash
tools/spike.sh aarch64 spikes/hello/hello.aarch64.s          # run + show output
tools/spike.sh riscv64 spikes/hello/hello.riscv64.s --dump   # also disassemble
```

Prereqs locally: `qemu-user` and the cross-binutils packages (see `ci/Dockerfile`
for the exact list).

## Run in CI

- **Push** anything under `spikes/**` or `tools/spike.sh` → all three arches run
  in parallel; results appear in the job summary.
- **Manually** via the Actions tab → *spike* → *Run workflow*, optionally
  pointing at a single `.s` file.

The loop is deliberately fast: logic lives in `tools/spike.sh` so your local run
and the CI run are identical, and `fail-fast: false` means you always see all
three arch results even if one fails.
