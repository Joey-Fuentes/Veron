#!/bin/sh
# CLONE A PINNED COMMIT FROM WHICHEVER MIRROR IS UP, AND VERIFY IT.
#
# Sourced, not run:
#
#     . "$GITHUB_WORKSPACE/tools/clone-pinned.sh"
#     clone_pinned tcc-src "$TCC_SHA" \
#         "https://github.com/TinyCC/tinycc.git https://repo.or.cz/tinycc.git"
#
# ---------------------------------------------------------------------------
# WHY MIRROR ORDER IS A PERFORMANCE DECISION AND NOT A TRUST ONE
#
# Git object names are content-addressed. Commit 5ec0e6f8 fetched from GitHub
# is the same tree as commit 5ec0e6f8 fetched from repo.or.cz, or it is not
# that commit. A mirror is transport. That is the same argument
# spikes/toolbox/README.md makes for committing an opaque emulator: the thing
# cannot influence an output as long as something checks what arrived.
#
# THE CATCH IS THAT NOTHING WAS CHECKING. The clone loops this replaces ended
# at `git clone && checkout $SHA`, which is a correct pin and an unverified
# one: if a mirror served a tree in which that SHA does not exist, the checkout
# fails loudly -- fine -- but nothing ever asserted that what landed in the
# working tree IS the pin. tools/fetch-pinned.sh was more honest and more
# wrong, printing "no hash check possible on a clone". A clone is the EASIEST
# thing here to verify; it is one rev-parse.
#
# So this function ends with that rev-parse, and a mismatch is a hard failure
# rather than a warning. With it, putting GitHub first costs nothing but time
# saved. Without it, mirror order really would be a trust decision, which is
# why the order and the check are landing in the same commit.
#
# SHA-1, honestly. Git names are SHA-1 and its collision resistance is broken
# in general. Git ships the hardened SHA-1DC implementation, which detects the
# known attack, and the pin predates any mirror we might be worried about. Read
# this as protection against a stale, truncated or corrupt mirror -- which is
# what actually happens -- rather than against a motivated attacker. The tcc
# arm64 series is a second, independent tripwire: sources/tcc.toml records that
# it was located by matching PRE-IMAGE BLOB HASHES, so a wrong tree fails to
# apply instead of building something else quietly.
#
# WHY IT IS NOT ONE `git clone`. A full clone of tinycc from repo.or.cz was
# taking minutes and resetting mid-transfer often enough to need two attempts
# per run. Nothing here wants the history: one commit is the whole requirement.
# The shallow fetch is attempted first and a full clone is the fallback,
# because not every server allows a client to ask for a bare SHA
# (uploadpack.allowReachableSHA1InWant). Both routes end at the same check, so
# the fallback is a slower way to the same guarantee, not a weaker one.
# ---------------------------------------------------------------------------

# clone_pinned DEST SHA "URL [URL ...]"
clone_pinned() {
    _cp_dest="$1"
    _cp_sha="$2"
    _cp_urls="$3"
    # Not a hardcoded /tmp: Termux (Android) has no writable /tmp, and a
    # failed redirect stops the command it feeds from ever running -- so the
    # hardcoded path made every clone attempt fail before git started.
    _cp_err="${TMPDIR:-/tmp}/clone-pinned-err.txt"

    if [ -z "$_cp_dest" ] || [ -z "$_cp_sha" ] || [ -z "$_cp_urls" ]; then
        echo "clone_pinned: usage: clone_pinned DEST SHA \"URL [URL ...]\""
        return 2
    fi

    # A 404 on a private-looking path otherwise stops to ask for a username and
    # hangs the runner until the job timeout.
    GIT_TERMINAL_PROMPT=0
    export GIT_TERMINAL_PROMPT

    for _cp_url in $_cp_urls; do
        for _cp_try in 1 2; do
            rm -rf "$_cp_dest"

            # --- shallow, by SHA ------------------------------------------
            if git init -q "$_cp_dest" 2>"$_cp_err" \
               && git -C "$_cp_dest" remote add origin "$_cp_url" \
                    2>>"$_cp_err" \
               && timeout 180 git -C "$_cp_dest" fetch -q --depth 1 origin \
                    "$_cp_sha" 2>>"$_cp_err" \
               && git -C "$_cp_dest" checkout -q FETCH_HEAD \
                    2>>"$_cp_err"; then
                if _clone_pinned_verify "$_cp_dest" "$_cp_sha"; then
                    echo "  $_cp_url: shallow fetch of $_cp_sha, commit verified"
                    return 0
                fi
                echo "  $_cp_url: fetched, but HEAD is not the pin -- refusing"
                rm -rf "$_cp_dest"
                continue
            fi

            # --- full clone, for servers that refuse a bare SHA ------------
            rm -rf "$_cp_dest"
            if timeout 300 git clone -q "$_cp_url" "$_cp_dest" \
                    2>>"$_cp_err" \
               && git -C "$_cp_dest" checkout -q "$_cp_sha" \
                    2>>"$_cp_err"; then
                if _clone_pinned_verify "$_cp_dest" "$_cp_sha"; then
                    echo "  $_cp_url: full clone (server refused a bare SHA), commit verified"
                    return 0
                fi
                echo "  $_cp_url: cloned, but HEAD is not the pin -- refusing"
                rm -rf "$_cp_dest"
                continue
            fi

            rm -rf "$_cp_dest"
            echo "  $_cp_url attempt $_cp_try failed, retrying"
        done
    done

    echo "FAIL: no mirror produced $_cp_sha for $_cp_dest"
    echo "      This is a fetch problem, not a build problem. Re-run; if it"
    echo "      persists, a URL has moved and sources/*.toml needs updating."
    [ -s "$_cp_err" ] && cat "$_cp_err"
    return 1
}

# THE WHOLE POINT OF THE FILE. Everything above chooses a route; this decides
# whether the route was allowed to matter.
_clone_pinned_verify() {
    _cpv_got=$(git -C "$1" rev-parse HEAD 2>/dev/null || echo "")
    [ "$_cpv_got" = "$2" ] && return 0
    echo "  COMMIT MISMATCH in $1"
    echo "    got  $_cpv_got"
    echo "    want $2"
    return 1
}

# verify_pinned DIR SHA -- for a checkout this file did not perform itself,
# so a clone that stays hand-rolled can still be held to the same standard.
verify_pinned() {
    if _clone_pinned_verify "$1" "$2"; then
        echo "  $1 at $2, commit verified"
        return 0
    fi
    return 1
}
