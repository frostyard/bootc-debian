# bootc-debian

Builds Debian (trixie) packages for [ostree](https://github.com/ostreedev/ostree)
and [bootc](https://github.com/bootc-dev/bootc), released here and published
to the Frostyard APT repository (`https://repository.frostyard.org/debian/`,
`trixie`, component `image`) by [frostyard/apt-publisher](https://github.com/frostyard/apt-publisher).
It produces:

- `libostree-1-1` — OSTree library and tools
- `bootc` — boot and upgrade via container images

## The `image` component

`libostree-1-1` replaces Debian's package of the same name, and `bootc` links
against it, so both are published in the `image` component, not `main`
([core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)).
Only Frostyard image builds enable `image` (snosi's build sandbox,
`Components: main image`). A plain Debian host that adds `main` keeps
Debian's `libostree-1-1` and its security updates.

The component is set by apt-publisher, not here: its `config/producers.tsv`
registers this repository for `image`, and the `publish-deb` request names
only the repository, the tag and `trixie`.

Versions published before the move stay installable from `image`:
apt-publisher's move workflow (ADR-0059 step 5) takes every published
version out of `main`'s index and into `image`'s, unchanged. Their files under
`debian/pool/main/` stay in the bucket, because nothing deletes pool files;
removing them would be a later, separately approved change.

## How it works

Upstream versions are pinned in [`download/checksums.json`](download/checksums.json)
(version, release-tarball URL, sha256). [`build.sh`](build.sh) downloads and
verifies the tarballs, builds ostree, then builds bootc against it (offline,
using upstream's vendored crates and a pinned Rust toolchain), and packages
both as `.deb`s. [frostyard/snosi](https://github.com/frostyard/snosi) no
longer builds bootc itself: its OCI bootc profiles install these `bootc` and
`libostree-1-1` packages from the frostyard APT repository
([`shared/packages/bootc/mkosi.conf`](https://github.com/frostyard/snosi/blob/main/shared/packages/bootc/mkosi.conf)).

Versions are `<upstream>-frostyard<UTC minute>~deb13`, for example
`1.16.8-frostyard202610040130~deb13`. The timestamp makes every rebuild sort
newer. `~deb13` names the Debian release the packages were built against:
apt-publisher publishes a `~debNN` version only to the codename for Debian NN
([core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)),
so a later forky build (`~deb14`) can sit beside it.

Workflows:

- **Build** (`build.yml`) — on push to `main` and on PRs: builds the
  packages only.
- **Releasing** — a manual run of **Build** on `main` (`workflow_dispatch`)
  also:
  1. checks that the build is exactly `bootc` and `libostree-1-1`, amd64,
     `~deb13`, from one build;
  2. attests their build provenance;
  3. creates a GitHub release tagged
     `bootc-<version>-ostree-<version>-<UTC minute>` with the two `.deb`
     files (GitHub lists them with `.deb13` in place of `~deb13`);
  4. sends a `publish-deb` request to frostyard/apt-publisher. apt-publisher
     publishes the release to `trixie`, component `image`, then dispatches a
     frostyard/snosi image build.
- **Check Upstream Versions** (`check-dependencies.yml`) — weekly: checks
  for new ostree/bootc releases and opens a PR updating
  `download/checksums.json`. Merging that PR triggers a build; releasing
  needs a manual run.

## Building locally

```sh
docker run --rm -v "$PWD":/src -w /src debian:trixie bash build.sh
```

Packages land in `dist/`. `build.sh` refuses to run on anything but trixie.

## Bumping versions manually

Edit `download/checksums.json` (or run the Check Upstream Versions workflow
via `workflow_dispatch`). On a bootc bump, check whether `RUST_VERSION` in
`build.sh` needs a bump — a new bootc release may require a newer rustc to
build.
