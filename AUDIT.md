# Audit model

The canonical definition of Veron's **seven audit criteria** and the per-node
audit-record format lives in `ARCHITECTURE.md` §3. The concrete schema, the
provenance graph and the query interface are designed in
[`DERIVATIONS.md`](./DERIVATIONS.md); this file will hold the fixed record JSON
once that lands.

Record fields (summary): `output_hash`, `flavor`, `provenance` (source hash +
signature), `reproducibility` (rebuild attestations), `inputs` (full graph),
`reviewed_delta` (patches/flags), `verification` (tests/self-host), `deferral`
(verified vs. deferred), `license` (SPDX id).
