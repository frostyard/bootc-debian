#!/bin/bash
# Build ostree and bootc from pinned, sha256-verified release tarballs and
# package them as Debian packages for the frostyard repository.
#
# This mirrors the in-image build snosi uses (shared/bootc/build/bootc.chroot)
# so the two build paths stay identical: same tarballs, same checksums, same
# pinned Rust toolchain, same configure/make invocations. Once these packages
# are published, snosi can install the .debs instead of compiling from source
# on every image build.
#
# Runs as root inside a debian:trixie container (CI or local):
#   docker run --rm -v "$PWD":/src -w /src debian:trixie bash build.sh
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
# Debian NN. ~deb13 sorts below ~deb14, so a later forky build can sit beside
# this one and an upgrade to forky picks it up. Only trixie is supported: the
# Depends lists below name trixie's library packages.
# shellcheck source=/dev/null
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
case "$CODENAME" in
    trixie) DEB_MARKER="~deb13" ;;
    *)
        echo "Error: build in debian:trixie, not '${CODENAME:-unknown}'" >&2
        exit 1
        ;;
esac

# --- Build dependencies (same set as snosi's BuildPackages=) ---------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --no-install-recommends --yes \
    build-essential pkg-config autoconf automake libtool bison \
    curl ca-certificates dpkg-dev jq zstd xz-utils rustup go-md2man dracut \
    libcurl4-openssl-dev libssl-dev libsystemd-dev \
    libgpgme-dev libarchive-dev libfuse3-dev \
    libglib2.0-dev libzstd-dev liblzma-dev \
    libsoup-3.0-dev e2fslibs-dev libext2fs-dev \
    libmount-dev libselinux1-dev \
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
# in apt and roll out to installed systems.
TIMESTAMP="$(date -u +%Y%m%d%H%M)"

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
PKG_VERSION="${OSTREE_VERSION}-frostyard${TIMESTAMP}${DEB_MARKER}"
PKG="$WORK/pkg-libostree"
cp -a "$OSTREE_INSTALL" "$PKG"
# Clean up build artifacts not needed at runtime
find "$PKG" -name '*.la' -delete
find "$PKG" -name '*.a' -delete

# Depends lists below are the COMPLETE runtime link deps, derived from the
# built binaries: objdump -p <bin> | awk '/NEEDED/' over libostree-1.so.1,
# the ostree CLI, the libexec helpers (rofiles-fuse links libfuse3), and the
# bootc binary, with each soname mapped to its trixie package via dpkg -S.
# Re-derive when bumping upstream versions -- a new ostree/bootc may link
# more libraries, and consumers (e.g. snosi images) rely on apt pulling in
# everything the binaries need.
mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<EOF
Package: libostree-1-1
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Maintainer: Frostyard <packages@frostyard.org>
Description: OSTree library and tools (frostyard build)
 Built from ostree v${OSTREE_VERSION} for use with bootc on Debian trixie.
Section: libs
Priority: optional
Depends: libc6, libarchive13t64, libcurl4t64, libfuse3-4, libglib2.0-0t64, libgpg-error0, libgpgme11t64, liblzma5, libselinux1, libsystemd0, zlib1g
Provides: ostree, libostree-dev
Conflicts: libostree-1-1, ostree, libostree-dev
Replaces: libostree-1-1, ostree, libostree-dev
EOF

dpkg-deb --build --root-owner-group "$PKG" "$DIST/libostree-1-1_${PKG_VERSION}_${ARCH}.deb"

# --- Package bootc ----------------------------------------------------------
PKG_VERSION="${BOOTC_VERSION}-frostyard${TIMESTAMP}${DEB_MARKER}"
PKG="$WORK/pkg-bootc"
cp -a "$BOOTC_INSTALL" "$PKG"

mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<EOF
Package: bootc
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Maintainer: Frostyard <packages@frostyard.org>
Description: Boot and upgrade via container images (frostyard build)
 Built from bootc v${BOOTC_VERSION} for Debian trixie.
Section: admin
Priority: optional
Depends: libostree-1-1, libc6, libgcc-s1, libglib2.0-0t64, libpcre2-8-0, libssl3t64, libzstd1, zlib1g
EOF

dpkg-deb --build --root-owner-group "$PKG" "$DIST/bootc_${PKG_VERSION}_${ARCH}.deb"

echo "Packages built:"
ls -l "$DIST"
