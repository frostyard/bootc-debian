#!/bin/bash
# Test download/check-checksums.sh: it must accept the committed
# checksums.json and reject each broken variant below. Exit 1 on a failure.
#   bash download/test-check-checksums.sh
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$dir/check-checksums.sh"
good="$dir/checksums.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
expect() { # expect WANT NAME FILE: WANT is ok or bad
    local want="$1" name="$2" file="$3" got
    if bash "$check" "$file" >/dev/null 2>&1; then got=ok; else got=bad; fi
    if [[ $got == "$want" ]]; then
        pass=$((pass + 1))
    else
        echo "FAIL: $name: want $want, got $got" >&2
        fail=$((fail + 1))
    fi
}
variant() { # variant NAME JQ_FILTER: the committed file, changed by the filter
    jq "$2" "$good" >"$tmp/$1.json"
    expect bad "$1" "$tmp/$1.json"
}

expect ok committed "$good"
jq . "$good" >"$tmp/reformatted.json"
expect ok reformatted "$tmp/reformatted.json"

variant short-sha256 '.bootc.sha256 = "abc"'
variant upper-sha256 '.ostree.sha256 |= ascii_upcase'
variant vendor-drift '.["bootc-vendor"].version = "0.0.1"'
variant foreign-url '.ostree.url = "https://example.com/libostree.tar.xz"'
variant url-other-version '.bootc.url |= sub("/download/v[^/]*/"; "/download/v0.0.1/")'
variant version-null '.ostree.version = "null"'
variant version-number '.ostree.version = 2026'
variant missing-pin 'del(.ostree)'
variant extra-key '.extra = {}'
variant pin-not-object '.bootc = "x"'
variant top-array '[.]'

# Several documents or none: jq -e alone would judge only the last one.
{ echo '{}'; cat "$good"; } >"$tmp/bad-then-good.json"
expect bad bad-then-good "$tmp/bad-then-good.json"
cat "$good" "$good" >"$tmp/two-good.json"
expect bad two-good "$tmp/two-good.json"
: >"$tmp/empty.json"
expect bad empty "$tmp/empty.json"
echo 'not json' >"$tmp/not-json.json"
expect bad not-json "$tmp/not-json.json"
expect bad missing-file "$tmp/does-not-exist.json"

echo "check-checksums.sh: $pass cases passed, $fail failed"
((fail == 0))
