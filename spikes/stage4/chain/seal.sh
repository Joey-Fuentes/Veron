#!/bin/sh
# seal.sh -- the hand-off between rungs, made checkable.
#
#   seal.sh hash   <tree>                        print the tree's content hash
#   seal.sh seal   <tree> <rung> <in-hash> <out> write a chain record
#   seal.sh verify <tree> <expected-hash>        assert a restored tree is THE tree
#   seal.sh chain  <record> [<record> ...]       assert the records form one chain
#
# WHY THIS EXISTS. Three jobs each proved one rung and the chain was never
# proved, because nothing checked that the gcc 10 rung B consumed was the gcc 10
# rung A produced. They shared a version number, not an identity. The original
# stage4-complete answered that by re-running every rung in one process so there
# was no hand-off to distrust -- six hours of compute to establish something a
# content address establishes directly, and it established it for exactly one
# run.
#
# A hand-off is not the weakness. An UNDECLARED hand-off is. So: every rung
# seals its output under a content hash, every rung declares the hash it
# consumed, and the ledger job asserts the edges meet. That is criterion 3's
# input graph as a by-product rather than as extra work, and unlike a single
# monolithic run it gets STRONGER the more times it runs, because a rung whose
# output hash moves without its inputs moving is a reproducibility finding.
set -eu

# DETERMINISTIC BY CONSTRUCTION. mtimes, uid/gid and directory order are all
# build noise and all of them move between runs; none of them are the artifact.
# --sort=name fixes order, --mtime=@0 with SOURCE_DATE_EPOCH=0 in the box fixes
# time, --numeric-owner with 0/0 fixes ownership. What is left is the content.
tree_hash() {
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      --format=gnu -cf - -C "$1" . 2>/dev/null | sha256sum | cut -d' ' -f1
}

case "${1:?seal.sh: subcommand required}" in

  hash)
    tree_hash "${2:?seal.sh hash: tree required}"
    ;;

  verify)
    tree="${2:?}"; want="${3:?}"
    got=$(tree_hash "$tree")
    if [ "$want" != "$got" ]; then
      echo "  CHAIN BROKEN at $tree"
      echo "    the rung before this one sealed : $want"
      echo "    what actually arrived           : $got"
      echo
      echo "  This is the check the whole chain exists for. The tree that got"
      echo "  here is not the tree the previous rung produced, so nothing"
      echo "  downstream can claim to descend from it. Do not retry past this."
      exit 1
    fi
    echo "  chain ok: $tree matches the sealed hash $got"
    ;;

  seal)
    # inhash is ALLOWED to be empty: rung 0 is the root of the chain and has no
    # predecessor to declare. ${4:?} rejected the empty string and made sealing
    # the first rung impossible.
    tree="${2:?}"; rung="${3:?}"; inhash="${4-}"; out="${5:?}"
    outhash=$(tree_hash "$tree")
    # The bind list IS the declaration -- so it goes in the record, not just in
    # a comment. A rung that quietly gains an input should be visible as a diff.
    cat > "$out" <<EOF
{
  "rung": "$rung",
  "output_hash": "$outhash",
  "input_hash": "$inhash",
  "built_by": "${CHAIN_BUILDER:-unknown}",
  "run_id": "${GITHUB_RUN_ID:-local}",
  "commit": "${GITHUB_SHA:-unknown}",
  "borrowed": ${CHAIN_BORROWED:-"[]"},
  "unpinned_inputs": ${CHAIN_UNPINNED:-0},
  "verified": ${CHAIN_VERIFIED:-"[]"},
  "deferred": ${CHAIN_DEFERRED:-"[]"}
}
EOF
    echo "  sealed $rung"
    echo "    in  : $inhash"
    echo "    out : $outhash"
    ;;

  chain)
    shift
    prev=""; prev_rung=""; fail=0
    for r in "$@"; do
      [ -f "$r" ] || { echo "  MISSING RECORD: $r"; fail=1; continue; }
      rung=$(sed -n 's/.*"rung": *"\([^"]*\)".*/\1/p'        "$r")
      inh=$(sed -n  's/.*"input_hash": *"\([^"]*\)".*/\1/p'  "$r")
      outh=$(sed -n 's/.*"output_hash": *"\([^"]*\)".*/\1/p' "$r")
      unp=$(sed -n  's/.*"unpinned_inputs": *\([0-9]*\).*/\1/p' "$r")
      printf '  %-16s in=%.12s out=%.12s\n' "$rung" "${inh:-<none>}" "$outh"
      if [ -n "$prev" ] && [ "$inh" != "$prev" ]; then
        echo "    ^^ BREAK: declares input ${inh:-<none>}"
        echo "              but $prev_rung sealed $prev"
        fail=1
      fi
      if [ "${unp:-0}" -gt 0 ]; then
        echo "    ^^ $unp input(s) unpinned at this rung (invariant #6)"
        fail=1
      fi
      prev="$outh"; prev_rung="$rung"
    done
    [ "$fail" -eq 0 ] || { echo; echo "  THE CHAIN DOES NOT CONNECT."; exit 1; }
    echo
    echo "  every edge connects; no unpinned inputs"
    ;;

  *) echo "seal.sh: unknown subcommand $1" >&2; exit 2 ;;
esac
