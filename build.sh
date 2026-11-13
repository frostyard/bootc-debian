#!/bin/bash
# Build ostree and bootc from pinned, sha256-verified release tarballs and
# package them as Debian packages for the frostyard repository.
#
# snosi no longer builds bootc in its images. Its OCI bootc profiles install
# these .debs from the frostyard repository (snosi
# shared/packages/bootc/mkosi.conf), so this script is the only build path.
#
# Runs as root inside a debian:trixie or a debian:forky container (CI or
# local). The codename of that container picks the version marker and the
# Depends lists:
#   docker run --rm -v "$PWD":/src -w /src debian:trixie bash build.sh
#   docker run --rm -v "$PWD":/src -w /src debian:forky bash build.sh
#
# Output: dist/*.deb (override location with DIST=/path).
set -euo pipefail
if [[ "${DEBUG_BUILD:-0}" == "1" ]]; then
    set -x
fi

# Pinned Rust toolchain. Debian Trixie's rustc (1.85) is too OLD to *build*
# bootc 1.16.x: its xtask/build dependencies (cargo_metadata, cargo-platform)
# require rustc >= 1.91, even though bootc's library crate declares MSRV 1.85.
# Installed via rustup, which verifies the toolchain's signatures on download.
# Bump this when bumping bootc if a newer toolchain is needed.
RUST_VERSION="1.96.0"

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${DIST:-$SRCDIR/dist}"

# Both packages link the build distribution's libraries, so each version
# names the Debian release it was built for (frostyard/core ADR-0055):
# frostyard/apt-publisher publishes a ~debNN version only to the codename for
# Debian NN. ~deb13 sorts below ~deb14, so the trixie and the forky build sit
# side by side and an upgrade to forky picks its packages up
# (docs/adr/0001-release-trixie-and-forky-builds-together.md).
#
# trixie and forky are supported, and each has its own Depends lists. The
# lists name the library packages of that codename, and those differ: forky
# ships gpgme 2 (soname libgpgme.so.45, package libgpgme45) where trixie has
# gpgme 1 (libgpgme.so.11, package libgpgme11t64). A package whose Depends
# names the other codename's library package is published but not installable,
# so the check at the end of this script holds each list to the built
# binaries. DEBIAN_RELEASE is the codename text of the Description.
# shellcheck source=/dev/null
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
case "$CODENAME" in
    trixie)
        DEB_MARKER="~deb13"
        DEBIAN_RELEASE="Debian trixie"
        OSTREE_DEPENDS="libc6, libarchive13t64, libcurl4t64, libfuse3-4, libglib2.0-0t64, libgpg-error0, libgpgme11t64, liblzma5, libselinux1, libsystemd0, zlib1g"
        BOOTC_DEPENDS="libostree-1-1, libc6, libgcc-s1, libglib2.0-0t64, libpcre2-8-0, libselinux1, libssl3t64, libzstd1, zlib1g"
        ;;
    forky)
        DEB_MARKER="~deb14"
        DEBIAN_RELEASE="Debian forky"
        # Same libraries as trixie, except gpgme: forky's soname is
        # libgpgme.so.45, which libgpgme45 provides.
        OSTREE_DEPENDS="libc6, libarchive13t64, libcurl4t64, libfuse3-4, libglib2.0-0t64, libgpg-error0, libgpgme45, liblzma5, libselinux1, libsystemd0, zlib1g"
        # bootc needs the same libraries on forky as on trixie.
        BOOTC_DEPENDS="libostree-1-1, libc6, libgcc-s1, libglib2.0-0t64, libpcre2-8-0, libselinux1, libssl3t64, libzstd1, zlib1g"
        ;;
    *)
        echo "Error: build in debian:trixie or debian:forky, not '${CODENAME:-unknown}'" >&2
        exit 1
        ;;
esac

# --- Build dependencies (same set as snosi's BuildPackages=) ---------------
# libclang-dev: bootc >= 1.17 enables its `selinux` feature by default. The
# selinux-sys crate runs bindgen at build time, which needs libclang.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --no-install-recommends --yes \
    build-essential pkg-config autoconf automake libtool bison \
    curl ca-certificates dpkg-dev jq zstd xz-utils rustup go-md2man dracut \
    libcurl4-openssl-dev libssl-dev libsystemd-dev \
    libgpgme-dev libarchive-dev libfuse3-dev \
    libglib2.0-dev libzstd-dev liblzma-dev \
    libsoup-3.0-dev e2fslibs-dev libext2fs-dev \
    libmount-dev libselinux1-dev libclang-dev \
    gobject-introspection libgirepository1.0-dev

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=download/verified-download.sh
source "$SRCDIR/download/verified-download.sh"

MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
ARCH="$(dpkg --print-architecture)"
OSTREE_VERSION="$(jq -r '.ostree.version' "$SRCDIR/download/checksums.json")"
BOOTC_VERSION="$(jq -r '.bootc.version' "$SRCDIR/download/checksums.json")"
# Timestamp suffix so rebuilds of the same upstream version still sort newer
# in apt and roll out to installed systems. The Build workflow passes 1
# BUILD_STAMP to the trixie build and to the forky build, so 1 release holds
# 1 build stamp; a local build derives the stamp from the clock.
if [[ -n "${BUILD_STAMP:-}" ]]; then
    if [[ ! "$BUILD_STAMP" =~ ^[0-9]{12}$ ]]; then
        echo "Error: BUILD_STAMP must be 12 digits (YYYYmmddHHMM), not '${BUILD_STAMP}'" >&2
        exit 1
    fi
    TIMESTAMP="$BUILD_STAMP"
else
    TIMESTAMP="$(date -u +%Y%m%d%H%M)"
fi

# --- Install the pinned Rust toolchain -------------------------------------
export RUSTUP_HOME="${RUSTUP_HOME:-$WORK/rustup}"
export CARGO_HOME="${CARGO_HOME:-$WORK/cargo}"
rustup toolchain install "$RUST_VERSION" --profile minimal

# --- Build ostree. Install into the package root AND into the live /usr
#     (so the bootc build below can link against it). -----------------------
verified_download "ostree" "$WORK/ostree.tar.xz"
tar -xJf "$WORK/ostree.tar.xz" -C "$WORK"
OSTREE_SRC="$(find "$WORK" -maxdepth 1 -type d -name 'libostree-*' | head -n1)"
[[ -n "$OSTREE_SRC" ]] || { echo "Error: ostree source dir not found" >&2; exit 1; }
OSTREE_INSTALL="$WORK/ostree-install"
(
    cd "$OSTREE_SRC"
    ./configure \
        --prefix=/usr \
        --libdir="/usr/lib/${MULTIARCH}" \
        --sysconfdir=/etc \
        --with-curl \
        --with-dracut
    make -j"$(nproc)"
    make install DESTDIR="$OSTREE_INSTALL"
    # Second install into the real /usr so the bootc build can find
    # ostree-1.pc (pkg-config) and load libostree at runtime (the docgen step
    # runs the bootc binary).
    make install DESTDIR=
)
ldconfig

# --- Build bootc (offline, vendored crates) --------------------------------
verified_download "bootc" "$WORK/bootc.tar.zstd"
verified_download "bootc-vendor" "$WORK/bootc-vendor.tar.zstd"
tar --use-compress-program=unzstd -xf "$WORK/bootc.tar.zstd" -C "$WORK"
BOOTC_SRC="$(find "$WORK" -maxdepth 1 -type d -name 'bootc-*' | head -n1)"
[[ -n "$BOOTC_SRC" ]] || { echo "Error: bootc source dir not found" >&2; exit 1; }
# Vendor tarball extracts a top-level vendor/ dir; place it inside the source
# tree and activate the shipped offline cargo config.
tar --use-compress-program=unzstd -xf "$WORK/bootc-vendor.tar.zstd" -C "$BOOTC_SRC"
cp "$BOOTC_SRC/.cargo/vendor-config.toml" "$BOOTC_SRC/.cargo/config.toml"
BOOTC_INSTALL="$WORK/bootc-install"
(
    cd "$BOOTC_SRC"
    export PKG_CONFIG_PATH="/usr/lib/${MULTIARCH}/pkgconfig:/usr/share/pkgconfig"
    export CARGO_NET_OFFLINE=true
    # Run make under the pinned toolchain so the Makefile's nested `cargo`
    # invocations (e.g. the xtask manpage generator) use $RUST_VERSION.
    rustup run "$RUST_VERSION" make bin
    rustup run "$RUST_VERSION" make install-all DESTDIR="$BOOTC_INSTALL"
)

# --- Package libostree-1-1 --------------------------------------------------
mkdir -p "$DIST"
OSTREE_PKG_VERSION="${OSTREE_VERSION}-frostyard${TIMESTAMP}${DEB_MARKER}"
OSTREE_DEB="$DIST/libostree-1-1_${OSTREE_PKG_VERSION}_${ARCH}.deb"
PKG="$WORK/pkg-libostree"
cp -a "$OSTREE_INSTALL" "$PKG"
# Clean up build artifacts not needed at runtime
find "$PKG" -name '*.la' -delete
find "$PKG" -name '*.a' -delete

# The Depends lists in the case block above are the COMPLETE runtime link
# deps, derived from the built binaries: objdump -p <bin> | awk '/NEEDED/'
# over libostree-1.so.1, the ostree CLI, the libexec helpers (rofiles-fuse
# links libfuse3) and the bootc binary, with each soname mapped to its
# package of this codename via dpkg -S. Re-derive when bumping an upstream
# version or adding a codename -- a new ostree/bootc may link more libraries,
# and consumers (e.g. snosi images) rely on apt pulling in everything the
# binaries need. check_depends below fails the build when a list and the
# binaries disagree.
mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<EOF
Package: libostree-1-1
Version: ${OSTREE_PKG_VERSION}
Architecture: ${ARCH}
Maintainer: Frostyard <packages@frostyard.org>
Description: OSTree library and tools (frostyard build)
 Built from ostree v${OSTREE_VERSION} for use with bootc on ${DEBIAN_RELEASE}.
Section: libs
Priority: optional
Depends: ${OSTREE_DEPENDS}
Provides: ostree, libostree-dev
Conflicts: libostree-1-1, ostree, libostree-dev
Replaces: libostree-1-1, ostree, libostree-dev
EOF

dpkg-deb --build --root-owner-group "$PKG" "$OSTREE_DEB"

# --- Package bootc ----------------------------------------------------------
BOOTC_PKG_VERSION="${BOOTC_VERSION}-frostyard${TIMESTAMP}${DEB_MARKER}"
BOOTC_DEB="$DIST/bootc_${BOOTC_PKG_VERSION}_${ARCH}.deb"
PKG="$WORK/pkg-bootc"
cp -a "$BOOTC_INSTALL" "$PKG"

mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<EOF
Package: bootc
Version: ${BOOTC_PKG_VERSION}
Architecture: ${ARCH}
Maintainer: Frostyard <packages@frostyard.org>
Description: Boot and upgrade via container images (frostyard build)
 Built from bootc v${BOOTC_VERSION} for ${DEBIAN_RELEASE}.
Section: admin
Priority: optional
Depends: ${BOOTC_DEPENDS}
EOF

dpkg-deb --build --root-owner-group "$PKG" "$BOOTC_DEB"

# --- Check each Depends list against the built package ----------------------
# A per-codename Depends list is right only when it names exactly the packages
# that provide the libraries of this codename. od tells an ELF file from the
# rest (objdump fails on anything else), objdump -p lists the NEEDED sonames
# of each ELF file, and dpkg -S names the package that holds a soname. The
# derived set must equal the Depends list, so a forky package cannot keep a
# trixie library package, and vice versa.
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
    done < <(dpkg -S "*/$so" 2>/dev/null | grep -v '^diversion by' \
        | cut -d: -f1 | tr ',' '\n' | sed 's/^ *//' \
        | grep -v -- '-dev$' | sort -u || true)
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

check_depends() { # check_depends DEB PACKAGE DEPENDS: fails unless the
    # packages that provide DEB's NEEDED sonames are exactly DEPENDS
    local deb=$1 package=$2 depends=$3 file so name listed needed root
    local -a wanted=() derived=() missing=() extra=()
    local -A sonames=() have=() want=()
    root="$WORK/depends/$(basename "$deb" .deb)"
    rm -rf "$root"
    mkdir -p "$root"
    dpkg-deb --extract "$deb" "$root"
    while IFS= read -r -d '' file; do
        # 7f454c46 is the ELF magic: objdump -p fails on anything else, and
        # reads an archive member by member, so test it first.
        [[ "$(od -An -tx1 -N4 "$file" | tr -d ' \n')" == 7f454c46 ]] || continue
        while IFS= read -r so; do
            [[ -n "$so" ]] && sonames["$so"]=1
        done < <(objdump -p "$file" | awk '/NEEDED/ { print $2 }')
    done < <(find "$root" -type f -print0)
    for so in "${!sonames[@]}"; do
        # The library a package ships provides its own soname.
        if [[ "$so" == libostree-1.so.1 && "$package" == libostree-1-1 ]]; then
            continue
        fi
        dep_package "$package" "$so" || return 1
        derived+=("$dep_package_name")
    done
    IFS=', ' read -r -a wanted <<<"$depends"
    for name in "${derived[@]}"; do have[$name]=1; done
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

check_depends "$OSTREE_DEB" libostree-1-1 "$OSTREE_DEPENDS"
check_depends "$BOOTC_DEB" bootc "$BOOTC_DEPENDS"

echo "Packages built:"
ls -l "$DIST"
