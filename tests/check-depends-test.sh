#!/usr/bin/env bash
# Tests for lib/check-depends.sh: the Depends check must pass on a matching
# list and must fail, with a known message, on a wrong one. Each case builds a
# tiny .deb whose payload holds an ELF-looking file that needs the sonames of
# the case plus a file that is not ELF, then calls check_depends. objdump and
# the soname-to-package lookup are stubs first on PATH, so the cases do not
# depend on the packages installed on the runner; 1 case uses the real objdump
# on /bin/true when the runner has both. The runner's real dpkg-deb builds and
# extracts the packages, so the check must not call dpkg for that.
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
# shellcheck source=../lib/check-depends.sh
source "$ROOT/lib/check-depends.sh"

stubs=$work/stubs
mkdir -p "$stubs/objdump" "$stubs/dpkg"

# The stub of objdump: it prints the NEEDED lines of FILE from FILE.needed, so a
# case can give a package any sonames without a compiler and a linker.
cat >"$stubs/objdump/objdump" <<'STUB'
#!/usr/bin/env bash
# Stub objdump for tests/check-depends-test.sh: 1 NEEDED line for each line of
# FILE.needed. Any other call is a test defect and lands in the log.
set -uo pipefail
if [[ $# -ne 2 || $1 != -p ]]; then
	printf 'objdump %s\n' "$*" >>"$OBJDUMP_STUB_LOG"
	exit 99
fi
[[ -f $2.needed ]] || exit 0
while IFS= read -r so; do
	printf '  NEEDED               %s\n' "$so"
done <"$2.needed"
STUB

# The stub of dpkg: it answers "dpkg -S */SONAME" from the table, as dpkg does,
# and it logs every other call, so a check that used dpkg instead of dpkg-deb
# to extract a package fails the run.
cat >"$stubs/dpkg/dpkg" <<'STUB'
#!/usr/bin/env bash
# Stub dpkg for tests/check-depends-test.sh: "dpkg -S */SONAME" prints the
# output lines of the table entry for SONAME, and exits 1 when it has none.
# Any other call is a test defect and lands in the log.
set -uo pipefail
if [[ $# -ne 2 || $1 != -S ]]; then
	printf 'dpkg %s\n' "$*" >>"$DPKG_STUB_LOG"
	exit 99
fi
so=${2#\*/}
found=0
while IFS=$'\t' read -r name line; do
	[[ $name == "$so" ]] || continue
	printf '%s\n' "$line"
	found=1
done <"$DPKG_STUB_TABLE"
if ((found == 0)); then
	exit 1
fi
STUB
chmod +x "$stubs/objdump/objdump" "$stubs/dpkg/dpkg"

export DPKG_STUB_TABLE="$work/dpkg-S.table"
export DPKG_STUB_LOG="$work/dpkg-stub.log"
export OBJDUMP_STUB_LOG="$work/objdump-stub.log"
: >"$DPKG_STUB_TABLE"
: >"$DPKG_STUB_LOG"
: >"$OBJDUMP_STUB_LOG"
stub_path="$stubs/objdump:$stubs/dpkg:$real_path"

reset_table() { # reset_table: forgets the sonames and their providers
	: >"$DPKG_STUB_TABLE"
}

provides() { # provides SONAME LINE: dpkg -S prints LINE for SONAME
	printf '%s\t%s\n' "$1" "$2" >>"$DPKG_STUB_TABLE"
}

build_deb() { # build_deb DEB PACKAGE SO...: a .deb whose payload holds 1 ELF
	# file (the 4 magic bytes and a name, which is all the check reads) that
	# needs SO..., and 1 file that is not ELF
	local deb=$1 package=$2 root
	shift 2
	root="$work/pkg/$(basename "$deb" .deb)"
	mkdir -p "$root/DEBIAN" "$root/usr/bin" "$root/usr/share/doc/$package"
	chmod 0755 "$root" "$root/DEBIAN"
	printf 'Package: %s\nVersion: 1.0-1\nArchitecture: amd64\nMaintainer: Test <t@example.org>\nDescription: test package\n A test package.\n' \
		"$package" >"$root/DEBIAN/control"
	printf '\177ELF\002\001\001\000not a real binary: the check reads the magic bytes only\n' \
		>"$root/usr/bin/$package"
	(($# == 0)) || printf '%s\n' "$@" >"$root/usr/bin/$package.needed"
	printf 'This file is not ELF, so the check must ignore it.\n' \
		>"$root/usr/share/doc/$package/README"
	dpkg-deb --build --root-owner-group "$root" "$deb" >/dev/null
}

cases=0
failures=0

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

run_case() { # run_case NAME pass|fail MESSAGE DEB PACKAGE DEPENDS [WORKDIR]
	local name=$1 want=$2 message=$3 deb=$4 package=$5 depends=$6 workdir=${7:-}
	local out status ok=0
	if [[ -n $workdir ]]; then
		out=$(check_depends "$deb" "$package" "$depends" "$workdir" 2>&1) || status=$?
	else
		out=$(check_depends "$deb" "$package" "$depends" 2>&1) || status=$?
	fi
	status=${status:-0}
	if [[ $want == pass ]]; then
		if ((status == 0)) && [[ $out == *"$message"* ]]; then ok=1; fi
	else
		if ((status != 0)) && [[ $out == *"$message"* ]]; then ok=1; fi
	fi
	report "$name: $want, message '$message'" "$ok" "exit $status, output: ${out//$'\n'/ | }"
}

PATH=$stub_path

reset_table
provides libc.so.6 'libc6:amd64: /usr/lib/x86_64-linux-gnu/libc.so.6'
build_deb "$work/matching.deb" bootc libc.so.6
run_case "a matching Depends list passes" pass \
	"Depends match the packages its binaries need (1 packages)" \
	"$work/matching.deb" bootc "libc6"

build_deb "$work/missing.deb" bootc libc.so.6 libzstd.so.1
provides libzstd.so.1 'libzstd1:amd64: /usr/lib/x86_64-linux-gnu/libzstd.so.1'
run_case "a package the binaries need and Depends omits fails" fail \
	"missing from Depends: libzstd1" \
	"$work/missing.deb" bootc "libc6"

run_case "a package in Depends that the binaries do not need fails" fail \
	"in Depends but not needed: libzstd1" \
	"$work/matching.deb" bootc "libc6, libzstd1"

build_deb "$work/noprovider.deb" bootc libc.so.6 libnope.so.9
run_case "a soname with no package fails" fail \
	"no Debian package provides libnope.so.9" \
	"$work/noprovider.deb" bootc "libc6"

build_deb "$work/twoproviders.deb" bootc libc.so.6 libboth.so.1
# dpkg -S prints 1 line for each path that matches, so a multiarch library
# can name 2 packages.
provides libboth.so.1 'shared1:amd64: /usr/lib/x86_64-linux-gnu/libboth.so.1'
provides libboth.so.1 'shared2:amd64: /usr/lib/i386-linux-gnu/libboth.so.1'
run_case "a soname from 2 packages fails" fail \
	"comes from several packages: shared1 shared2" \
	"$work/twoproviders.deb" bootc "libc6"

build_deb "$work/ostree-link.deb" bootc libc.so.6 libostree-1.so.1
run_case "libostree-1.so.1 is libostree-1-1 for bootc" pass \
	"Depends match the packages its binaries need (2 packages)" \
	"$work/ostree-link.deb" bootc "libc6, libostree-1-1"

run_case "libostree-1.so.1 is skipped inside libostree-1-1" pass \
	"Depends match the packages its binaries need (1 packages)" \
	"$work/ostree-link.deb" libostree-1-1 "libc6"

run_case "libostree-1-1 does not depend on itself" fail \
	"in Depends but not needed: libostree-1-1" \
	"$work/ostree-link.deb" libostree-1-1 "libc6, libostree-1-1"

build_deb "$work/ldlinux.deb" bootc ld-linux-x86-64.so.2
run_case "ld-linux-x86-64.so.2 is libc6" pass \
	"Depends match the packages its binaries need (1 packages)" \
	"$work/ldlinux.deb" bootc "libc6"

build_deb "$work/diversion.deb" bootc libre.so.1
provides libre.so.1 'diversion by libc6 from: /lib64/libre.so.1'
provides libre.so.1 'diversion by libc6 to: /lib/x86_64-linux-gnu/libre.so.1'
run_case "a diversion line names no package" fail \
	"no Debian package provides libre.so.1" \
	"$work/diversion.deb" bootc "libc6"

reset_table
provides libc.so.6 'libc6:amd64: /usr/lib/x86_64-linux-gnu/libc.so.6'
run_case "a work directory keeps the extracted payload" pass \
	"Depends match the packages its binaries need (1 packages)" \
	"$work/matching.deb" bootc "libc6" "$work/keep"
if [[ -d $work/keep/depends/matching/usr/bin ]]; then
	report "the work directory holds the payload" 1 ""
else
	report "the work directory holds the payload" 0 "$work/keep holds no extracted payload"
fi

# The real objdump, on a real ELF file: the NEEDED lines come from the runner's
# own binary, and only the soname-to-package lookup is a stub.
if command -v objdump >/dev/null 2>&1 && [[ -f /bin/true ]]; then
	PATH=$stubs/dpkg:$real_path
	reset_table
	real_root="$work/pkg-real"
	mkdir -p "$real_root/DEBIAN" "$real_root/usr/bin"
	chmod 0755 "$real_root" "$real_root/DEBIAN"
	printf 'Package: realelf\nVersion: 1.0-1\nArchitecture: amd64\nMaintainer: Test <t@example.org>\nDescription: test package\n A test package.\n' \
		>"$real_root/DEBIAN/control"
	cp /bin/true "$real_root/usr/bin/realelf"
	dpkg-deb --build --root-owner-group "$real_root" "$work/realelf.deb" >/dev/null
	real_depends=''
	real_index=0
	while IFS= read -r so; do
		real_index=$((real_index + 1))
		provides "$so" "provider${real_index}:amd64: /usr/lib/x86_64-linux-gnu/${so}"
		real_depends+="${real_depends:+, }provider${real_index}"
	done < <(objdump -p /bin/true | awk '/NEEDED/ { print $2 }')
	if [[ -z $real_depends ]]; then
		report "the real objdump gives the sonames of /bin/true" 0 "objdump printed no NEEDED line"
	else
		run_case "the real objdump reads a real ELF file" pass \
			"Depends match the packages its binaries need (${real_index} packages)" \
			"$work/realelf.deb" realelf "$real_depends"
	fi
	PATH=$stub_path
else
	printf 'skip - the real objdump case: no objdump or /bin/true on this runner\n'
fi

# The check must never call dpkg for anything but -S: the payload comes out of
# the package with dpkg-deb, so neither stub logged a call it did not expect.
if [[ -s $DPKG_STUB_LOG || -s $OBJDUMP_STUB_LOG ]]; then
	report "the check calls dpkg only with -S and objdump only with -p" 0 \
		"$(cat "$DPKG_STUB_LOG" "$OBJDUMP_STUB_LOG" | paste -sd ';' -)"
else
	report "the check calls dpkg only with -S and objdump only with -p" 1 ""
fi

printf '1..%d\n' "$cases"
if ((failures > 0)); then
	printf '%d case(s) failed\n' "$failures" >&2
	exit 1
fi
