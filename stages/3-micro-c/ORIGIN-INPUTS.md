# ORIGIN — stage 3's remaining adopted inputs (final form, ours)

Adopted per design D2 on 2026-08-15: from here on these are Veron
source; upstream and patch notions end at this commit. Recorded so
attribution and license provenance (criterion 7) hold until any rewrite.

| adopted | derived from | how |
|---|---|---|
| `bootstrap.c` | M2libc `68a23cfd05d5a355ba7a30c770d684cbe86fcc4e` `aarch64/linux/bootstrap.c` | `tools/drop_asm.py` (6 asm syscall bodies removed; the mini-stdio kept) |
| `micro-c/M2libc/bootstrappable.c` | M2libc `68a23cfd05d5a355ba7a30c770d684cbe86fcc4e` | verbatim |
| `linker-tools/` | mescc-tools `5adfbf3364261a77109878a56b100aeeb6ef9ac4` | upstream-makefile-derived source lists; `max_string` 4096→262144; `tools/octal_to_decimal.py`; `tools/defines_to_enums.py` |
| `m2libc/` | `spikes/reference/m2libc` (M2libc `ca023d8…`) + the `spikes/stage3/patches/m2libc` series | patches applied, result adopted |

Licenses: M2libc and mescc-tools are GPL-3.0-or-later; these directories
inherit that until rewritten (same rule as `micro-c/ORIGIN.md`).
The spike copies and patch series stay live and untouched per §7.0.
