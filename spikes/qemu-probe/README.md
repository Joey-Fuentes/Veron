# spikes/qemu-probe — isolate qemu-user behaviors (diagnostic tracer)

**Invariants SUSPENDED.** A diagnostic, not a feature. Stage 1's first build
produced wrong output under qemu-user while a Python model of the same logic was
correct — so some qemu-user behavior diverges from expectation. This spike pins
down which one, by running each behavior in isolation as a tiny `stage0-as`
program with a **known-correct exit code**, then comparing under qemu.

## Probes

| # | probe | tests | expect |
|---|-------|-------|--------|
| P1 | `brk_zero` | `brk(0)` returns nonzero | exit 1 |
| P2 | `brk_near` | write/read a byte in brk memory at +0 | 42 |
| P3 | `brk_far`  | write/read in brk memory at +3000 (stage1's nametable offset) | 55 |
| P4 | `brk_read` | `read` stdin into brk memory | 65 (`'A'`) |
| P5 | `img_write`| write/read a byte in image (`.ascii`) memory — **control** | 33 |
| P6 | `img_read` | `read` stdin into image memory | 65 (`'A'`) |
| P7 | `adr_far`  | `adr` to a far-forward label + `ldrb` | 68 (`'D'`) |

## Reading the result

- If **P5/P6/P7 pass** (image memory + read + adr all fine) but **P2/P3/P4 differ**,
  then **brk() heap is the problem under qemu-user** — and stage 1 should get its
  buffers from the image (`.ascii`) region (the proven-writable path the `elf`
  R+W+X segment provides), not `brk`.
- If P2/P3 pass but P4 differs, the issue is `read` into that region, not the
  memory itself.
- If everything passes, the divergence is elsewhere and we look again.

Diagnostic only — reports to the run summary and does not fail the run.
