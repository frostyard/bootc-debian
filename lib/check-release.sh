#!/usr/bin/env bash
# The release check of the Release job in .github/workflows/build.yml.
#
# apt-publisher publishes every .deb in the release, and it routes a ~debNN
# version only to the codename for Debian NN (core ADR-0055). The release must
# therefore hold exactly this run's Debian 13 and Debian 14 amd64 builds of
# bootc and libostree-1-1
# (docs/adr/0001-release-trixie-and-forky-builds-together.md): 1 package for
# each name and codename, from 1 build stamp, with the same upstream version on
# both codenames, and nothing else.
#
# Usage: bash lib/check-release.sh DIST_DIR
#
# On a release it appends tag=<tag> to the file that GITHUB_OUTPUT names, and
# on anything else it exits non-zero with a GitHub ::error:: line.
# tests/check-release-test.sh proves both.
set -euo pipefail
shopt -s nullglob

dist=${1:-dist}

if [[ -z ${GITHUB_OUTPUT:-} ]]; then
	echo "::error::GITHUB_OUTPUT is not set, so the release tag has no place to go"
	exit 1
fi

# The 2 names this release publishes, each for Debian 13 and 14.
names=(bootc libostree-1-1)
found=() stamp=""
declare -A file_of=() upstream_of=()
for file in "$dist"/*.deb; do
	name=$(dpkg-deb -f "$file" Package)
	version=$(dpkg-deb -f "$file" Version)
	arch=$(dpkg-deb -f "$file" Architecture)
	size=$(stat -c %s "$file")
	if [[ $arch != amd64 ]]; then
		echo "::error::$file is built for $arch, not amd64"
		exit 1
	fi
	if [[ ! $version =~ ^([0-9]+(\.[0-9]+)*)-frostyard([0-9]{12})~deb(13|14)$ ]]; then
		echo "::error::$file has version $version, which is not a Debian 13 or Debian 14 build of this repository"
		exit 1
	fi
	upstream=${BASH_REMATCH[1]}
	built=${BASH_REMATCH[3]}
	suite=${BASH_REMATCH[4]}
	case " ${names[*]} " in
	*" $name "*) ;;
	*)
		echo "::error::$file is $name, which this release does not publish"
		exit 1
		;;
	esac
	if [[ -n ${file_of[$name/deb$suite]:-} ]]; then
		echo "::error::$file is a second $name build for Debian $suite"
		exit 1
	fi
	if [[ -n $stamp && $built != "$stamp" ]]; then
		echo "::error::$file was built at $built, but another package at $stamp"
		exit 1
	fi
	if [[ $(basename "$file") != "${name}_${version}_${arch}.deb" ]]; then
		echo "::error::$file is not named ${name}_${version}_${arch}.deb"
		exit 1
	fi
	if ((size >= 2147483648)); then
		echo "::error::$file is $size bytes; GitHub release assets must be under 2 GiB"
		exit 1
	fi
	stamp=$built
	file_of[$name/deb$suite]=$file
	upstream_of[$name/deb$suite]=$upstream
	found+=("$name/deb$suite")
done
for name in "${names[@]}"; do
	for suite in 13 14; do
		if [[ -z ${file_of[$name/deb$suite]:-} ]]; then
			echo "::error::no $name build for Debian $suite; found: ${found[*]:-none}"
			exit 1
		fi
	done
	if [[ ${upstream_of[$name/deb13]} != "${upstream_of[$name/deb14]}" ]]; then
		echo "::error::$name is ${upstream_of[$name/deb13]} for Debian 13 but ${upstream_of[$name/deb14]} for Debian 14"
		exit 1
	fi
done
echo "tag=bootc-${upstream_of[bootc/deb13]}-ostree-${upstream_of[libostree-1-1/deb13]}-$stamp" >>"$GITHUB_OUTPUT"
