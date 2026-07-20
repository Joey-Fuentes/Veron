# CI / orchestration

GitHub Actions is the **orchestrator and one independent rebuilder** — not the
build system itself (the derivations are). It walks the graph, fans builds out
to stay under the **6-hour hosted-runner job cap**, populates the binary cache,
and contributes byte-identical rebuild attestations toward criterion 2.

Workflows to add once `lib/` exists:
- `trunk.yml`        — build + attest stages 0–3 (shared, audited once)
- `flavor-musl.yml`  — instantiate stages 4+ with `libc=musl`
- `flavor-glibc.yml` — instantiate stages 4+ with `libc=glibc`

See `ARCHITECTURE.md` §8.
