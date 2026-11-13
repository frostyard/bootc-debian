#!/usr/bin/env bash
# Tests for lib/check-release.sh: the release check must pass on exactly the 4
# packages of 1 release, and must fail, with a known ::error:: message and no
# tag, on anything else. Each case fills a dist directory with fake .deb files
# and a sidecar that holds their control fields, then runs the check with a
# temporary GITHUB_OUTPUT. dpkg-deb is a stub first on PATH, so the cases need
# no real package; the stamp, the regex, the name and the size rules come from
# the check itself.
set -euo pipefail
umask 022

ROOT=$(realpath "$(cd "$(dirname "$0")/.." && pwd)")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
real_path=$PATH
work=$(realpath "$work")
if [[ $work == "$ROOT" || $work == "$ROOT"/* ]]; then
	printf 'not ok - the work directory %s is inside the repository %s\n' "$work" "$ROOT" >&2
	rm -rf "$work"
	exit 1
fi

stubs=$work/stubs
mkdir -p "$stubs"

# The stub of dpkg-deb: "dpkg-deb -f FILE FIELD" prints the FIELD line of
# FILE.meta, as dpkg-deb reads the control file of the package. Any other call
# is a test defect and lands in the log.
cat >"$stubs/dpkg-deb" <<'STUB'
#!/usr/bin/env bash
# Stub dpkg-deb for tests/check-release-test.sh: the FIELD line of FILE.meta.
set -uo pipefail
if [[ $# -ne 3 || $1 != -f ]]; then
	printf 'dpkg-deb %s\n' "$*" >>"$DPKG_DEB_STUB_LOG"
	exit 99
fi
sed -n "s/^$3: //p" "$2.meta"
STUB
chmod +x "$stubs/dpkg-deb"
export DPKG_DEB_STUB_LOG="$work/dpkg-deb-stub.log"
: >"$DPKG_DEB_STUB_LOG"
PATH=$stubs:$real_path

# The 1 release the passing cases hold: bootc 1.17.4 and ostree 2026.6, built
# at 1 UTC minute, once for Debian 13 and once for Debian 14.
bootc=1.17.4
ostree=2026.6
stamp=202611131200

cases=0
failures=0
case_no=0

report() { # report NAME OK TEXT: 1 result line, and the count
	local name=$1 ok=$2 text=$3
	cases=$((cases + 1))
	if ((ok)); then
		printf 'ok %d - %s\n' "$cases" "$name"
	else
		printf 'not ok %d - %s\n' "$cases" "$name"
		[[ -z $text ]] || printf '  %s\n' "$text"
		failures=$((failures + 1))
	fi
}

new_dist() { # new_dist: a fresh dist directory and a fresh GITHUB_OUTPUT
	case_no=$((case_no + 1))
	dist="$work/dist-$case_no"
	out_file="$work/github-output-$case_no"
	mkdir -p "$dist"
	: >"$out_file"
}

mkdeb() { # mkdeb FILE PACKAGE VERSION [ARCH]: a fake .deb of that name, and the
	# sidecar that the stub dpkg-deb reads its control fields from
	local file=$1 package=$2 version=$3 arch=${4:-amd64}
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' \
		"$package" "$version" "$arch" >"$dist/$file.meta"
	: >"$dist/$file"
}

mkbuild() { # mkbuild PACKAGE VERSION [ARCH]: the .deb of 1 release build, named
	# as the release job names it
	local package=$1 version=$2 arch=${3:-amd64}
	mkdeb "${package}_${version}_${arch}.deb" "$package" "$version" "$arch"
}

valid_set() { # valid_set [STAMP]: the 4 packages of 1 release
	local s=${1:-$stamp}
	mkbuild bootc "${bootc}-frostyard${s}~deb13"
	mkbuild bootc "${bootc}-frostyard${s}~deb14"
	mkbuild libostree-1-1 "${ostree}-frostyard${s}~deb13"
	mkbuild libostree-1-1 "${ostree}-frostyard${s}~deb14"
}

check_case() { # check_case NAME pass|fail MESSAGE: runs the check on $dist, and
	# holds the exit status, MESSAGE and the tag line to the expectation
	local name=$1 want=$2 message=$3 out status=0 ok=0 tags
	out=$(GITHUB_OUTPUT="$out_file" bash "$ROOT/lib/check-release.sh" "$dist" 2>&1) || status=$?
	tags=$(grep -c '^tag=' "$out_file" || true)
	if [[ $want == pass ]]; then
		if ((status == 0)) && [[ $out == *"$message"* ]] && ((tags == 1)); then ok=1; fi
	else
		if ((status != 0)) && [[ $out == *"$message"* ]] && ((tags == 0)); then ok=1; fi
	fi
	report "$name: $want, message '$message'" "$ok" \
		"exit $status, $tags tag line(s), output: ${out//$'\n'/ | }"
}

new_dist
valid_set
check_case "the 4 packages of 1 release pass" pass ""
if [[ $(<"$out_file") == "tag=bootc-1.17.4-ostree-2026.6-202611131200" ]]; then
	report "the check writes the tag of this release to GITHUB_OUTPUT" 1 ""
else
	report "the check writes the tag of this release to GITHUB_OUTPUT" 0 \
		"GITHUB_OUTPUT holds '$(<"$out_file")'"
fi

new_dist
check_case "an empty dist directory fails" fail \
	"::error::no bootc build for Debian 13; found: none"

new_dist
mkbuild bootc "${bootc}-frostyard${stamp}~deb13"
mkbuild bootc "${bootc}-frostyard${stamp}~deb14"
mkbuild libostree-1-1 "${ostree}-frostyard${stamp}~deb13"
check_case "a release without 1 of the 4 packages fails" fail \
	"::error::no libostree-1-1 build for Debian 14"

new_dist
valid_set
mkbuild zstd "1.5.7-frostyard${stamp}~deb13"
check_case "a package this release does not publish fails" fail \
	"is zstd, which this release does not publish"

new_dist
valid_set
mkbuild bootc "1.17.3-frostyard${stamp}~deb13"
check_case "a second build of 1 package for 1 codename fails" fail \
	"is a second bootc build for Debian 13"

new_dist
mkbuild bootc "${bootc}-frostyard${stamp}~deb13"
mkbuild libostree-1-1 "${ostree}-frostyard${stamp}~deb13"
mkbuild bootc "${bootc}-frostyard202611131201~deb14"
mkbuild libostree-1-1 "${ostree}-frostyard202611131201~deb14"
check_case "2 build stamps in 1 release fail" fail \
	"was built at 202611131201, but another package at 202611131200"

new_dist
mkbuild bootc "${bootc}-frostyard${stamp}~deb13"
mkbuild bootc "1.17.5-frostyard${stamp}~deb14"
mkbuild libostree-1-1 "${ostree}-frostyard${stamp}~deb13"
mkbuild libostree-1-1 "${ostree}-frostyard${stamp}~deb14"
check_case "1 upstream version on Debian 13 and another on Debian 14 fails" fail \
	"::error::bootc is 1.17.4 for Debian 13 but 1.17.5 for Debian 14"

new_dist
valid_set
mkbuild bootc "${bootc}-frostyard${stamp}~deb12"
check_case "a Debian 12 marker fails" fail \
	"has version 1.17.4-frostyard202611131200~deb12, which is not a Debian 13 or Debian 14 build of this repository"

new_dist
valid_set
mkbuild bootc "${bootc}-frostyard${stamp}"
check_case "a version with no ~debNN marker fails" fail \
	"has version 1.17.4-frostyard202611131200, which is not a Debian 13 or Debian 14 build of this repository"

new_dist
valid_set
mkbuild bootc "${bootc}-frostyard${stamp}~deb13" arm64
check_case "a package built for another architecture fails" fail \
	"is built for arm64, not amd64"

new_dist
mkdeb "bootc-${bootc}-frostyard${stamp}~deb13_amd64.deb" bootc "${bootc}-frostyard${stamp}~deb13"
check_case "a package with the wrong file name fails" fail \
	"is not named bootc_1.17.4-frostyard202611131200~deb13_amd64.deb"

new_dist
valid_set
# A sparse file: it costs no disk, and stat reports the size that GitHub
# refuses as a release asset.
truncate -s 2147483648 "$dist/bootc_${bootc}-frostyard${stamp}~deb13_amd64.deb"
check_case "a package of 2 GiB or more fails" fail \
	"is 2147483648 bytes; GitHub release assets must be under 2 GiB"

new_dist
valid_set
out=$(env -u GITHUB_OUTPUT bash "$ROOT/lib/check-release.sh" "$dist" 2>&1) || status=$?
if [[ ${status:-0} -ne 0 && $out == *"GITHUB_OUTPUT is not set"* ]]; then
	report "a run with no GITHUB_OUTPUT fails" 1 ""
else
	report "a run with no GITHUB_OUTPUT fails" 0 \
		"exit ${status:-0}, output: ${out//$'\n'/ | }"
fi

# The check must call dpkg-deb only with -f: neither stub logged a call it did
# not expect.
if [[ -s $DPKG_DEB_STUB_LOG ]]; then
	report "the check calls dpkg-deb only with -f" 0 "$(paste -sd ';' - <"$DPKG_DEB_STUB_LOG")"
else
	report "the check calls dpkg-deb only with -f" 1 ""
fi

printf '1..%d\n' "$cases"
if ((failures > 0)); then
	printf '%d case(s) failed\n' "$failures" >&2
	exit 1
fi
