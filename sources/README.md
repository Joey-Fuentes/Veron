# sources/ — pinned upstream manifests

One lockfile per upstream package: `url` + cryptographic `hash` + `signature`
+ SPDX `license`. Provenance (criterion 1) and license/rights provenance
(criterion 7) both originate here. **Nothing enters a build unnamed.**

See `ARCHITECTURE.md` §3.
