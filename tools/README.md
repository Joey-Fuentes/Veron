# tools/

- `diffoscope-wrap`     — localize divergence when two builds of one derivation disagree.
- `check-fork-invariant` — CI gate: fail if any trunk (stage 0–3) derivation
  hash differs between the musl and glibc flavors. The fork line cannot move
  without a human deciding it should.
- `clone-pinned.sh` — **sourced, not run.** `clone_pinned DEST SHA "URL ..."`
  fetches one pinned commit from the first mirror that answers and then
  **verifies `rev-parse HEAD` against the pin**. `verify_pinned DIR SHA` holds a
  hand-rolled checkout to the same standard.

  Mirror order is a speed choice and not a trust one *because* of that check:
  git names are content-addressed, so a mirror is transport. Before it existed,
  three workflows each carried their own `clone_tcc()` copy that ended at
  `clone && checkout $SHA` — a correct pin, never asserted — and
  `fetch-pinned.sh` said outright that "no hash check possible on a clone",
  which is the one claim in that file that was false. A clone is the easiest
  thing here to verify.

  Known limit, recorded rather than discovered later: the full-clone fallback
  for servers that refuse a bare SHA is **unexercised**. It cannot be tested
  over `file://`, which ignores `uploadpack.allowAnySHA1InWant`, and this
  sandbox has no network. Everything else in it is tested against local repos.
