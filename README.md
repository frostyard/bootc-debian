# bootc-debian

Builds Debian (trixie) packages for [ostree](https://github.com/ostreedev/ostree)
and [bootc](https://github.com/bootc-dev/bootc) and publishes them to the
frostyard apt repository (`https://repository.frostyard.org`), producing:

- `libostree-1-1` — OSTree library and tools
- `bootc` — boot and upgrade via container images

## How it works

Upstream versions are pinned in [`download/checksums.json`](download/checksums.json)
(version, release-tarball URL, sha256). [`build.sh`](build.sh) downloads and
verifies the tarballs, builds ostree, then builds bootc against it (offline,
using upstream's vendored crates and a pinned Rust toolchain), and packages
both as `.deb`s. This mirrors the in-image build in
[frostyard/snosi](https://github.com/frostyard/snosi)
(`shared/bootc/build/bootc.chroot`) so both build paths stay identical.

Workflows:

- **Build** (`build.yml`) — on push to `main` and on PRs: builds the
  packages only. Publishing to the frostyard repo and dispatching a snosi
  image build run only on a manual `workflow_dispatch` on `main`, until
  bootc-debian moves to trixie.
- **Check Upstream Versions** (`check-dependencies.yml`) — weekly: checks
  for new ostree/bootc releases and opens a PR updating
  `download/checksums.json`. Merging that PR triggers a build; publishing
  needs a manual dispatch.

## Building locally

```sh
docker run --rm -v "$PWD":/src -w /src debian:trixie bash build.sh
```

Packages land in `dist/`.

## Bumping versions manually

Edit `download/checksums.json` (or run the Check Upstream Versions workflow
via `workflow_dispatch`). On a bootc bump, check whether `RUST_VERSION` in
`build.sh` needs a bump — a new bootc release may require a newer rustc to
build.
