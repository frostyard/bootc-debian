# shellcheck shell=bash
# The Depends check of build.sh: hold each codename's Depends list to the
# libraries that the built package files really need.
#
# A per-codename Depends list is right only when it names exactly the packages
# that provide the libraries of that Debian release. This file reads the
# NEEDED sonames of every ELF file in a built package (objdump -p), maps each
# soname to its Debian package (dpkg -S) and fails unless the result equals
# the package's Depends list, so a forky package cannot keep a trixie library
# package, and vice versa.
#
# Sourced by build.sh, never run: it defines functions and has no side
# effects. tests/check-depends-test.sh proves that it fails on a wrong list.

dep_package() { # dep_package PACKAGE SONAME: sets dep_package_name
	local package=$1 so=$2
	local -a providers=()
	case "$so" in
	ld-linux-x86-64.so.2)
		# The runtime linker is in libc6. trixie diverts
		# /lib64/ld-linux-x86-64.so.2, so dpkg -S names no package.
		dep_package_name="libc6"
		return 0
		;;
	libostree-1.so.1)
		# Built here and installed from a tarball, so no package owns the
		# file: the ostree package provides this soname, and bootc depends
		# on it.
		dep_package_name="libostree-1-1"
		return 0
		;;
	esac
	# A soname can be provided by more than 1 package, and a -dev package
	# ships the unversioned link; keep the runtime packages only.
	while IFS= read -r provider; do
		[[ -n "$provider" ]] && providers+=("$provider")
	done < <(dpkg -S "*/$so" 2>/dev/null | grep -v '^diversion by' |
		cut -d: -f1 | tr ',' '\n' | sed 's/^ *//' |
		grep -v -- '-dev$' | sort -u || true)
	case ${#providers[@]} in
	0)
		echo "Error: ${package}: no Debian package provides ${so}" >&2
		return 1
		;;
	1) dep_package_name=${providers[0]} ;;
	*)
		echo "Error: ${package}: ${so} comes from several packages: ${providers[*]}" >&2
		return 1
		;;
	esac
}

join_names() { # join_names NAME...: prints the names sorted, separated by ", "
	printf '%s\n' "$@" | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g'
}

depends_packages() { # depends_packages ROOT PACKAGE: appends to the caller's
	# depends_derived[] the Debian packages that provide ROOT's NEEDED sonames
	local root=$1 package=$2 file so out list status=0
	local -A sonames=()
	depends_derived=()
	# find and objdump run in this shell, and their exit status is checked: a
	# listing or a read that failed keeps the sonames of the other files, and
	# the check would then pass on a package it did not fully read. A
	# temporary file holds find's NUL-separated output, which no variable can
	# hold.
	list=$(mktemp) || return 1
	if ! find "$root" -type f -print0 >"$list"; then
		echo "not ok - ${package}: find cannot list the files under ${root}" >&2
		rm -f "$list"
		return 1
	fi
	while IFS= read -r -d '' file; do
		# 7f454c46 is the ELF magic: objdump -p fails on anything else, and
		# reads an archive member by member, so test it first.
		[[ "$(od -An -tx1 -N4 "$file" | tr -d ' \n')" == 7f454c46 ]] || continue
		if ! out=$(objdump -p "$file"); then
			echo "not ok - ${package}: objdump -p ${file} failed" >&2
			status=1
			break
		fi
		while IFS= read -r so; do
			[[ -n "$so" ]] && sonames["$so"]=1
		done < <(awk '/NEEDED/ { print $2 }' <<<"$out")
	done <"$list"
	rm -f "$list"
	((status == 0)) || return 1
	for so in "${!sonames[@]}"; do
		# The library a package ships provides its own soname.
		if [[ "$so" == libostree-1.so.1 && "$package" == libostree-1-1 ]]; then
			continue
		fi
		dep_package "$package" "$so" || return 1
		depends_derived+=("$dep_package_name")
	done
}

check_depends_dir() { # check_depends_dir ROOT PACKAGE DEPENDS: the check on a
	# package whose payload is already extracted into ROOT
	local root=$1 package=$2 depends=$3 name listed needed
	local -a wanted=() depends_derived=() missing=() extra=()
	local -A have=() want=()
	depends_packages "$root" "$package" || return 1
	IFS=', ' read -r -a wanted <<<"$depends"
	for name in "${depends_derived[@]}"; do have[$name]=1; done
	for name in "${wanted[@]}"; do want[$name]=1; done
	for name in "${!have[@]}"; do
		[[ -n "${want[$name]:-}" ]] || missing+=("$name")
	done
	for name in "${!want[@]}"; do
		[[ -n "${have[$name]:-}" ]] || extra+=("$name")
	done
	if ((${#missing[@]} == 0 && ${#extra[@]} == 0)); then
		echo "ok - ${package}: Depends match the packages its binaries need (${#want[@]} packages)"
		return 0
	fi
	listed="$(join_names "${!want[@]}")"
	needed="$(join_names "${!have[@]}")"
	echo "Error: ${package}: the Depends list does not match the packages its binaries need" >&2
	echo "  Depends:      ${listed}" >&2
	echo "  binaries need: ${needed}" >&2
	if ((${#missing[@]})); then
		echo "  missing from Depends: ${missing[*]}" >&2
	fi
	if ((${#extra[@]})); then
		echo "  in Depends but not needed: ${extra[*]}" >&2
	fi
	return 1
}

check_depends() { # check_depends DEB PACKAGE DEPENDS [WORKDIR]: fails unless
	# the packages that provide DEB's NEEDED sonames are exactly DEPENDS.
	# WORKDIR holds the extracted payload and is kept; without it a temporary
	# directory is used and removed again.
	local deb=$1 package=$2 depends=$3 work=${4:-} root status=0
	if [[ -n $work ]]; then
		root="$work/depends/$(basename "$deb" .deb)"
		rm -rf "$root"
		mkdir -p "$root"
	else
		root="$(mktemp -d)" || return 1
	fi
	if ! dpkg-deb --extract "$deb" "$root"; then
		[[ -n $work ]] || rm -rf "$root"
		return 1
	fi
	if check_depends_dir "$root" "$package" "$depends"; then
		status=0
	else
		status=$?
	fi
	[[ -n $work ]] || rm -rf "$root"
	return "$status"
}
