#!/bin/bash
# Check the shape of download/checksums.json: build.sh and the Check
# Upstream Versions workflow read these fields. Each pin needs a numeric
# version, a lowercase sha256 and a GitHub release URL for that version, and
# bootc and bootc-vendor must name the same version. Exit 1 on a bad file.
#   bash download/check-checksums.sh [FILE]
set -euo pipefail

file="${1:-$(dirname "${BASH_SOURCE[0]}")/checksums.json}"

# -s reads every JSON document into 1 array, so a file with 2 documents or
# none fails: jq -e alone exits on the last document only.
if ! jq -s -e '
  def pin($k): .[$k] as $p
    | ($p | type == "object")
    and ($p.version | type == "string" and test("^[0-9]+(\\.[0-9]+)*$"))
    and ($p.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and ($p.url | type == "string" and startswith("https://github.com/")
         and contains("/download/v" + $p.version + "/"));
  length == 1 and (.[0]
    | type == "object"
    and (keys == ["bootc", "bootc-vendor", "ostree"])
    and pin("ostree") and pin("bootc") and pin("bootc-vendor")
    and .bootc.version == .["bootc-vendor"].version)
' "$file" >/dev/null; then
    echo "Error: $file is not 1 JSON object with the expected pins (ostree, bootc, bootc-vendor)" >&2
    exit 1
fi
echo "$file: OK (3 pins: ostree, bootc, bootc-vendor)"
