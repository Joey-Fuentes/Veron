# Audit model

The canonical definition of Veron's **seven audit criteria** and the per-node
audit-record format lives in `ARCHITECTURE.md` §3. This file will hold the
concrete record JSON schema once the ledger format is fixed.

Record fields (summary): `output_hash`, `flavor`, `provenance` (source hash +
signature), `reproducibility` (rebuild attestations), `inputs` (full graph),
`reviewed_delta` (patches/flags), `verification` (tests/self-host), `deferral`
(verified vs. deferred), `license` (SPDX id).
