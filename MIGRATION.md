# The official tree — step 1 delivered, and how to land it

This package is design doc §7 **step 1** ("Establish the official tree"),
built under §7.0: **nothing here touches `spikes/` or any existing workflow.**
Drop the contents at the repo root — no path collides with anything that
exists. Spike workflows keep running exactly as today; the one new workflow
triggers only on `stages/1-self-assembly/**`.

## What is in this package

```
stages/1-self-assembly/
  self-assembler-arm64.s      REDONE from spikes/stage0-as/stage0-as.aarch64.s:
  elf-wrapper-arm64.s         REDONE from spikes/elf/elf.aarch64.s
  rebaseline.sh               derive/verify the committed binaries (self-host ladder)
  README.md  AUDIT.md
stages/2-pico-c/              scaffold + adoption plan (READMEs)
stages/3-micro-c/             scaffold: micro-c/ (adopted source) + tcc/ (pin + 1 patch)
stages/4-toolchain-kernel/    scaffold + extraction plan
stages/5-user-space/          scaffold + adoption plan
stages/6-verification-distribution/  scaffold
policy/arches.toml            per-target origin declarations (§3.4)
docs/DESIGN.md                the design document, canonical
.github/workflows/1-self-assembly-verify.yml   the official trust-root gate
GITIGNORE-ADDITIONS           append to .gitignore (in/ build/ out/)
```

## The Stage 1 sources: exactly what changed

Verified mechanically against the spike sources: **the only byte-affecting
differences are the renamed embedded strings and their three length
immediates** — everything else that differs is comments.

| site | spike | official |
|---|---|---|
| `inover` string | `"stage0-as: input exceeds INBUF_SZ\n"` (34) | `"self-assembler: input exceeds INBUF_SZ\n"` (39) |
| its write length | `mov x2, #0x22` | `mov x2, #0x27` |
| `rejmsg` string | `"stage0-as: rejected: "` (21) | `"self-assembler: rejected: "` (26) |
| its write length | `mov x2, #0x15` | `mov x2, #0x1a` |
| `cbover` string | `"elf: code exceeds CODEBUF_SZ\n"` (29) | `"elf-wrapper: code exceeds CODEBUF_SZ\n"` (37) |
| its write length | `mov x2, #0x1d` | `mov x2, #0x25` |

Symbol names (`inover`, `rejmsg`, `inbuf`, `symtab`, `outword`, `codebuf`,
`header`, `bss_origin`) are unchanged, so the bounded-diff gate's
".bss references only" analysis carries over unmodified. The `.ascii` content
stays within the self-assembler's own input subset (strings are data), so the
mechanical translation and self-hosting are unaffected by the rename.

## The re-baseline: DERIVED, TESTED, AND INCLUDED

The committed candidates are **in this package**, derived end-to-end and
tested (see the report below): `self-assembler-arm64` (3,730 bytes) and
`elf-wrapper-arm64` (549 bytes), with `BASELINE.txt`. Derivation was
bootstrapped from the committed spike pair under the toolbox
`qemu-aarch64-static` — no host toolchain touched the path — and BASELINE.txt
records the emulation, per the design's `emulated` rule. Your step is
**review and commit** (and optionally re-derive yourself; `rebaseline.sh
derive` runs anywhere — natively on aarch64, or on any host via the toolbox
qemu — and must reproduce these exact hashes):

```sh
./stages/1-self-assembly/rebaseline.sh verify   # green against the included binaries
git add stages/1-self-assembly/self-assembler-arm64 \
        stages/1-self-assembly/elf-wrapper-arm64 \
        stages/1-self-assembly/BASELINE.txt
git commit -m "stage 1: re-baseline committed binaries under official names

Only byte-affecting change from the spike pair: renamed embedded strings
+ three length immediates. gen1==gen2==gen3, elfgen1==elfgen2==elfgen3,
bounded .bss-only divergence from the as+ld reference, spike-oracle
regression green. Derived by rebaseline.sh; verified by
1-self-assembly-verify on every push."
```

The script enforces, in order: lint → mechanical translation (no `###`
leftovers) → gen1 bootstrapped from the committed spike pair →
gen1==gen2==gen3 → elfgen1==elfgen2==elfgen3 → the **spike-oracle
regression** (both stage-1 AND stage-2 built byte-identically to the
committed pair's output, spikes read-only) → the as+ld bounded `.bss`-only
diff wherever binutils exists (always in CI) → behavior probes (the renamed
reject prefix prints exactly; an exit-42 program builds and runs). From the
re-baseline commit on, the workflow's `verify` mode guards the binaries on
every push, with CI adding the native run + bounded diff.

## Test report (executed end-to-end before packaging)

| test | result |
|---|---|
| harness baseline: ORIGINAL spike source → xlate → committed pair reproduces the committed binary | byte-for-byte ✓ |
| renamed sources translate completely | 0 untranslatable lines ✓ |
| self-assembler fixpoint | gen1 == gen2 == gen3, 3,730 B (= 3,720 + 10, exactly the string growth) ✓ |
| elf-wrapper fixpoint | elfgen1 == elfgen2 == elfgen3, 549 B ✓ |
| oracle regression, stage 1 | identical bytes from both pairs (1,702 B) ✓ |
| oracle regression, stage 2 (pico-c, full pipeline) | identical bytes (23,719 B) ✓ |
| renamed reject string | `self-assembler: rejected: ` prints exactly, 26 B ✓ |
| program run | exit(42) built by the new pair runs; byte-parity with committed pair ✓ |
| rebaseline.sh derive / verify | green ✓ / green ✓ |
| tamper test (one flipped byte in a committed binary) | verify exits 1 ✓; restored → 0 ✓ |

**One commit, nothing else in it** — so the hash change is attributable to
exactly the rename.

## The pinned two-decoder round-trip: PORTED (no longer deferred)

`stages/1-self-assembly/roundtrip.sh` — one script, both homes, extracted
from the spike gate (never rewritten where the repo already had the tool:
checks A/A2/B/E run through the repo's own `tools/roundtrip.sh` engine, the
LLVM legs / crosscheck / verbatim lifted from the inline gate, the pins the
same: **binutils 2.47 built from source, LLVM 22.1.8 release**, budget 0).
Additions over the spike gate, both in its spirit: (a) the tarballs are now
digest-pinned — first fetch records `PINS.sha256`, every later cold cache
must reproduce it (the spike gate fetched with no digest); (b) it runs on
non-aarch64 hosts too — binutils is cross-configured, nothing executes, no
qemu needed; (c) a **committed-bytes tie**: the committed file minus its
120-byte wrapper header must equal the pinned reference's `.text` modulo
ONLY the data-addressing adr words (the gate-17 bound, applied to the bytes
actually committed). Tested here: syntax, tool paths (canon runs on both
sources: 1003 / 74 lines), the tie arithmetic (3730 = 120+3610,
549 = 120+429), and the cold-cache failure mode; the full run needs one
network fetch and executes in CI or on your machine — GATE 2 of the
workflow.
- **`tools/veron` adoption** (step 2), stage 2/3 adoption, stage 4
  extraction (step 3): scaffolded with plans in each stage README, not begun
  — each lands as its own §7.0-conformant change proven against the live
  spike as oracle.

## Order from here (design doc §7)

1. ✅ this package + your re-baseline commit
2. Redo stage 5 officially (adopt recipes + driver at a pinned commit;
   byte-identical vs the live spike run)
3. Extract stage 1–4 build logic into `stages/<N>/substages/` scripts
   (spike workflows as oracle)
4. The artifact contract at every seam; `in/`/`build/`/`out/` resolver;
   `veron doctor`
5. Substage records + `veron trace`
6. Workflow consolidation (spikes archive only at YOUR per-stage cutover)
7. Stage 6 proper
