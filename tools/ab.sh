#!/bin/sh
# ab.sh -- consistent A/B reporting for our tools against upstream's.
#
# Sourced by workflows:  . tools/ab.sh
#
# Every artifact gets size + sha so two runs, or two builds, can actually be
# compared. Every invocation reports rc, wall time, and what it produced.
#
#   ab_art  <label> <path>                  one artifact: size, sha, path
#   ab_inputs <path>...                     several at once
#   ab_run  <label> <timeout> <out> <cmd>   run, report rc/time/output
#   ab_cmp  <label> <a> <b>                 same bytes or not, with both shas
#   ab_rule <text>                          section heading

ab_sha() {
    if [ -f "$1" ]; then sha256sum "$1" 2>/dev/null | cut -c1-16; else echo '-'; fi
}

ab_size() {
    if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo '-'; fi
}

ab_rule() {
    printf '\n  === %s ===\n' "$1"
    printf '  %-26s %12s  %-16s\n' 'ARTIFACT' 'BYTES' 'SHA256[0:16]'
}

ab_art() {
    printf '  %-26s %12s  %-16s\n' "$1" "$(ab_size "$2")" "$(ab_sha "$2")"
}

ab_inputs() {
    for f in "$@"; do ab_art "$(basename "$f")" "$f"; done
}

# ab_run <label> <timeout-seconds> <output-path-or-dash> <command...>
ab_run() {
    _lbl="$1"; _to="$2"; _out="$3"; shift 3
    [ "$_out" = '-' ] || rm -f "$_out"
    set +e
    _s=$(date +%s)
    timeout "$_to" "$@" </dev/null >/tmp/ab.stdout 2>/tmp/ab.stderr
    _rc=$?
    _e=$(date +%s)
    set -e
    _note=''
    [ "$_rc" = 124 ] && _note='HUNG'
    [ "$_rc" = 139 ] && _note='SEGV'
    [ "$_rc" = 132 ] && _note='SIGILL'
    if [ "$_out" = '-' ]; then
        printf '  %-26s rc=%-4s %4ss  %-6s\n' "$_lbl" "$_rc" "$((_e-_s))" "$_note"
    else
        printf '  %-26s rc=%-4s %4ss  %-6s out=%s bytes sha=%s\n' \
            "$_lbl" "$_rc" "$((_e-_s))" "$_note" "$(ab_size "$_out")" "$(ab_sha "$_out")"
    fi
    if [ -s /tmp/ab.stderr ]; then
        head -2 /tmp/ab.stderr | sed 's/^/      ! /'
    fi
    return 0
}

# ab_cmp <label> <fileA> <fileB>
ab_cmp() {
    printf '  %-26s ' "$1"
    if [ ! -f "$2" ] || [ ! -f "$3" ]; then
        printf 'CANNOT COMPARE  a=%s b=%s\n' "$(ab_size "$2")" "$(ab_size "$3")"
        return 0
    fi
    if cmp -s "$2" "$3"; then
        printf 'IDENTICAL  %s bytes  sha=%s\n' "$(ab_size "$2")" "$(ab_sha "$2")"
    else
        printf 'DIFFER\n'
        printf '      ours %10s bytes sha=%s\n' "$(ab_size "$2")" "$(ab_sha "$2")"
        printf '      ref  %10s bytes sha=%s\n' "$(ab_size "$3")" "$(ab_sha "$3")"
        cmp "$2" "$3" 2>&1 | head -1 | sed 's/^/      /'
    fi
    return 0
}
