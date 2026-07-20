# flavors/ — instantiations, not copies

A flavor is a small parameter file, not a fork of the tree. One trunk
(stages 0–3) feeds both; they diverge only at stage 4 (libc).

- `musl/`  — `libc=musl`, tools=BusyBox. Minimal, maximally auditable, most
  permissive dependency surface (musl is MIT). Browser: Chromium. GPU: CPU/Vulkan.
- `glibc/` — `libc=glibc`, tools=GNU coreutils. Compatibility flavor: official
  Chrome, CUDA, Steam, and other prebuilt glibc-only blobs run natively.

Guardrail: any "hybrid" (musl base + glibc runtime for a specific blob) is
either a first-class third flavor with its own ledger records, or explicitly
out of scope — never a silent third configuration.

See `ARCHITECTURE.md` §6.
