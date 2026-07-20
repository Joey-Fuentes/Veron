# spikes/livebootstrap — run the real no-host bootstrap, staged (tracer)

**Invariants SUSPENDED.** This runs the established **live-bootstrap** on our
runner — the actual, pinned, no-host climb from a tiny seed up toward gcc — and
does it in **stages**, mirroring live-bootstrap's own CI (`pass1 → pass2 →
pass3`), where each pass tars its `target/` tree and the next pass extends it.

## Why pass1 first

`pass1` = "up to the Linux build": stage0-posix → M2-Planet → mescc-tools →
**Mes → tcc → early gcc** → … → Linux kernel. So the milestone you asked for —
the **borrowed tcc building gcc** — happens *inside pass1's log*. Landing pass1
is the meaningful result; pass2/pass3 (Python, then the rest) come after.

## This is heavy and experimental

Unlike the earlier tracers, this is not a quick green check:

- **Long.** pass1 builds the whole lower half; expect a multi-hour job.
- **Big.** `target/` can reach several GB; disk (14 GB) and artifact upload are
  the most likely failure points. We free space first and archive what exists.
- **Sandbox-sensitive.** Needs bubblewrap + an AppArmor workaround on Ubuntu
  24.04 (copied from live-bootstrap's own CI).

It is a **bounded probe**: the bootstrap step is `continue-on-error`, and the
job always archives whatever `target/` it produced plus a package listing, so
even a partial climb tells us exactly how far it got.

## Staged hand-off

If pass1 finishes and uploads `pass1_image`, a follow-on `pass2` workflow can
download that artifact, extract it, and continue — same structure upstream uses.
We build pass1 alone first and read its log before wiring pass2/pass3.

## Honesty note

Everything here is the borrowed bootstrap; Veron's own seed is not in this loop.
This shows the known ladder running on our setup and locates where tcc/gcc land.
`live-bootstrap` is fetched as an upstream build dependency (like gcc/musl),
not vendored; invocation mirrors its own `bwrap.yml` pass1.
