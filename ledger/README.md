# ledger/ — the audit deliverable

One audit record per derivation output (`<output-hash>.json`), flavor-tagged.
Each record carries the seven criteria:

1. provenance (source hash + signature)
2. reproducibility (output hash + N byte-identical rebuild attestations)
3. hermeticity (full input graph)
4. reviewed delta (our patches / flags / recipe)
5. behavioral verification (tests + self-host / fixpoint + GCC 3-stage)
6. recorded deferral (verified vs. deferred, stated)
7. license & rights (SPDX id per source)

This ledger — not the package internals — is what makes Veron end-to-end
auditable, and doubles as an always-current SBOM + GPL corresponding-source
manifest.

See `ARCHITECTURE.md` §3.
