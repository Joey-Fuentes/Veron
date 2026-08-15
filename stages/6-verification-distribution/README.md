# stages/6-verification-distribution — the last stage

New work, not adopted from a spike (there is none): the kernel matrix
(minimal-qemu / reference-laptop / generic), EFI stub + baked reproducible
initramfs, `e2fsprogs` + the installer, the image formats, distribution, and
the signed ledger — gated by `veron trace --verify` walking every edge.
`kernels/` and `installer/` land here; the C tracer ships from
`tools/trace/`. See design doc §6 and docs/stages/STAGE6.md.

**Status: SCAFFOLD ONLY — gated on steps 1–5 of the order of work.**
