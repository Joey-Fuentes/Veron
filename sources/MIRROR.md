# The source mirror

Every pinned upstream tarball, reachable from more than one place, verified by
hash on every fetch.

## Why it exists, and why it got more important

It started as a stage 6 obligation: *"reproducible from pinned sources"* is
false the day an upstream tarball moves, and upstream URLs rot on a scale of a
few years. Shipping a manifest of URLs satisfies nobody in five years.

Then it became load-bearing for something else. A shipped Veron does **not**
need to carry every build-only package, because a user with a network can
rebuild any package from its recipe — same pins, same commands, same hashes CI
used. That turns "package Y was only needed to build X" from a keep/drop
dilemma into a fetch. But it only works if the bytes are still there, which
makes the mirror a **runtime dependency of the shipped system** rather than a
release chore.

A user runs `veron build qtbase`, the tarball 404s, and the self-hosting claim
fails on their machine. That is the failure mode this is designed against.

## The design, in one rule

**The hash is the identity; a host is only a route to it.**

Recipes name a `sha256` and their upstream URL as provenance. No recipe ever
names a mirror. Adding, dropping or replacing a host touches
[`HOSTS.toml`](./HOSTS.toml) and [`MIRRORS.tsv`](./MIRRORS.tsv) — never the
150 recipes, never the ledger.

## Two kinds of host, and both are needed

| kind | locator | examples |
|---|---|---|
| **derivable** | a function of hash + filename, computed, never stored | GitHub releases, R2, Codeberg, SourceForge |
| **opaque** | assigned by the host, cannot be computed, must be recorded | Zenodo DOI, IPFS CID, Software Heritage SWHID |

A template-only design cannot express the second kind, and retrofitting it
means rewriting the resolver. So **the table is canonical** and templates are
only a generator for the rows they can produce. `MIRRORS.tsv` is four columns:

```
sha256    name                    host        locator
3acd3a…   pkgconf-3.0.5.tar.xz    upstream    https://github.com/pkgconf/…
3acd3a…   pkgconf-3.0.5.tar.xz    github      https://github.com/…/3acd3a8a-pkgconf-…
3acd3a…   pkgconf-3.0.5.tar.xz    zenodo      https://zenodo.org/records/…
```

## No host is trusted

Every fetch hashes what it received and discards a mismatch, so a hostile or
broken mirror can waste time and nothing else. That is what makes "add any
host you like" an **availability** decision rather than a security one — and
it is why the mirror needs no vetting, only reachability.

A `BAD` result is not a failed download. It means that host served *different
bytes under the right name*, which is precisely what the pin is for.

## Upstream is tried first

Deliberately. A normal fetch should never touch our mirror, so the mirror stays
a fallback rather than a bandwidth bill, and upstream going dark is something
we notice rather than mask.

## Usage

```sh
python3 tools/mirror.py list                      # every artifact, every route
python3 tools/mirror.py fetch <sha256> <name>     # first route that answers
python3 tools/mirror.py add github <file>         # upload + record
python3 tools/mirror.py add zenodo <file> --locator <doi-url>
python3 tools/mirror.py check                     # re-download, re-verify
python3 tools/mirror.py check --offline           # mirror counts only
```

Adding a host is writing one `put` command in `HOSTS.toml`. There is no
host-specific code in `mirror.py`.

## Durability is N heterogeneous hosts

Two repos on one account are not two hosts. What survives a terms change, an
account suspension or a company decision is **different operators, funding
models and jurisdictions**. The suggested set:

- **GitHub releases** — primary. Release assets are not in the clone, so they
  cost nothing at checkout, and there is no per-asset size problem the way
  there is with the 100 MB limit on committed files.
- **Zenodo** — CERN-operated, EU-funded, built for long-term archival.
- **Software Heritage** — nonprofit whose whole mission is permanent source
  preservation. A backstop, not a fetch path: its API is not built for
  build-time retrieval.
- **Cloudflare R2** — zero egress fees, which is the cost that usually kills a
  self-hosted mirror.

Nothing lasts forever and free tiers change. Durability comes from the count
and the diversity, plus `mirror-verify` turning rot into something found on a
schedule.

## Why tarballs are not committed

`AGENTS.md` invariant 6: *never vendor/copy upstream source into the tree —
fetch it by pinned hash via a `sources/` manifest.* Committing them would be
exactly that. Also: git keeps everything forever, so a deleted tarball still
costs every clone; files over 100 MB are rejected outright and gcc is close to
that; and tarballs are already compressed, so delta compression buys nothing.

Release assets give the storage without any of it.

## Where it stands

**134 routes across 107 artifacts, and nothing is THIN.** Every artifact has
its upstream recorded as provenance plus at least one route that does not
depend on anyone else's uptime.

It stopped being an obligation and became load-bearing the week three
consecutive runs died on a single slow host — `git` at kernel.org, then
`freetype` at SourceForge, then `bash` at ftp.gnu.org. Each was reachable
elsewhere the whole time.

**Two kinds of route, and the cheap one comes first.** A *rewrite* costs
nothing — `ftp.gnu.org`, `ftpmirror.gnu.org` and `mirrors.kernel.org/gnu` serve
the same bytes at computable paths, as do kernel.org's three names and
SourceForge's named mirrors. `probe mirrors` finds those and **verifies each
one serves the right length before recording it**, which is what keeps adding
hosts an availability decision rather than a trust one. Everything else — the
GitHub, GitLab and Codeberg tail, which has no mirror network at all — gets its
second route from our own release namespace.

## Open

- **Three artifacts have one route**, and by design: `libsfdo`, `dinit` and
  `libxkbcommon` publish no tarball at all, only git tags, so they are pinned
  by **commit** and their tarball is generated deterministically by
  `tools/fetch-git.sh`. A commit is a stronger pin than a tarball digest — but
  if the forge is down they cannot be fetched. Uploading the generated tarball
  as a derived artifact would close that.
- **Some assets are keyed by a bare version.** Codeberg and GitHub archive URLs
  end in the tag rather than the project, so labwc's mirror is
  `src/0.9.1.tar.gz`. Unnavigable, and two projects tagging the same version
  would collide.
- **Which host is second** is undecided. It must be a different operator, not
  a second repo.
