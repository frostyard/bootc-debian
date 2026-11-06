# Package build and publication

Living document. Rationale: [core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md),
[core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md).
Contracts: [frostyard/core specs](https://github.com/frostyard/core/tree/main/docs/specs).

## Overview

This repository turns 2 pinned upstream release tarballs into 2 Debian
packages, `bootc` and `libostree-1-1`, for Debian 13 (trixie) on amd64. A
manual run of the **Build** workflow on `main` creates a GitHub release that
holds the packages, and frostyard/apt-publisher publishes that release to the
Frostyard APT repository at `https://repository.frostyard.org/debian/`.

```
upstream tarballs ──► build.sh ──► dist/*.deb ──► GitHub release
                                                        │
                                        publish-deb dispatch
                                                        ▼
                                        frostyard/apt-publisher
                                        (trixie, component image)
```

## Design

### The packages

- `libostree-1-1` — the OSTree library and tools.
- `bootc` — boot and upgrade a host via container images.

`build.sh` downloads and verifies the tarballs, builds ostree, then builds
bootc against that ostree offline (upstream's vendored crates and a pinned
Rust toolchain, `RUST_VERSION`), and packages both as `.deb` files. It is the
only build path: frostyard/snosi no longer builds bootc itself. Its OCI bootc
profiles install these `bootc` and `libostree-1-1` packages from the
Frostyard APT repository
([`shared/packages/bootc/mkosi.conf`](https://github.com/frostyard/snosi/blob/main/shared/packages/bootc/mkosi.conf)).

The upstream versions are pinned in [`download/checksums.json`](../../download/checksums.json)
(version, release-tarball URL, sha256 for `ostree`, `bootc` and
`bootc-vendor`). [`build.sh`](../../build.sh) refuses to run on any codename
but trixie: its `Depends` lists name trixie's library packages.

### Versions

Versions are `<upstream>-frostyard<UTC minute>~deb13`, for example
`1.16.8-frostyard202610040130~deb13`. The timestamp makes every rebuild sort
newer. `~deb13` names the Debian release the packages were built against:
apt-publisher publishes a `~debNN` version only to the codename for Debian NN
([core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)),
so a later forky build (`~deb14`) can sit beside it.

### The `image` component

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
apt-publisher's move workflow (ADR-0059 step 5) takes every published version
out of `main`'s index and into `image`'s, unchanged. Their files under
`debian/pool/main/` stay in the bucket, because nothing deletes pool files;
removing them would be a later, separately approved change.

### Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| [`build.yml`](../../.github/workflows/build.yml) | push to `main`, every pull request, a manual run | Lint, then the build and install of the packages. A push or pull request run publishes nothing. |
| [`check-dependencies.yml`](../../.github/workflows/check-dependencies.yml) | weekly schedule, a manual run | Checks for new ostree and bootc releases and opens or updates a pull request that changes `download/checksums.json`. |
| [`ci.yml`](../../.github/workflows/ci.yml) | pull request, push to `main` | Runs `make ci`. |
| [`risk-paths.yml`](../../.github/workflows/risk-paths.yml) | `pull_request_target` | Calls core's reusable workflow, which adds the `risk:high` label. |

**Build.** The **Lint** job runs actionlint, shellcheck,
`download/check-checksums.sh` and its test. The **Build (Debian Trixie)** job
builds the packages in a `debian:trixie` container and installs them, so a
broken pin or a broken build fails here.

**Release.** A manual run of Build on `main` (`workflow_dispatch`) also:

1. checks that the build is exactly `bootc` and `libostree-1-1`, amd64,
   `~deb13`, from one build;
2. attests their build provenance;
3. creates a GitHub release tagged
   `bootc-<version>-ostree-<version>-<UTC minute>` with the two `.deb` files
   (GitHub lists the `.deb13` in place of `~deb13` in the asset names);
4. sends a `publish-deb` request to frostyard/apt-publisher. apt-publisher
   publishes the release to `trixie`, component `image`, then dispatches a
   frostyard/snosi image build
   ([core ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md)).

**Check Upstream Versions.** The weekly run opens or updates a pull request on
the branch `auto-update-checksums` that changes `download/checksums.json`. A
`GITHUB_TOKEN` pull request starts no workflow, so the run then starts
**Build** on that branch with `gh workflow run`; the pull request shows its
"Build (Debian Trixie)" check. Merging that pull request publishes nothing:
releasing needs a manual run of **Build** on `main`.

## Operational notes

- The release job runs only when the repository is `frostyard/bootc-debian`,
  the ref is `refs/heads/main` and the event is `workflow_dispatch`. A push to
  `main` cannot create a release.
- The manual run has its own concurrency group and is never cancelled, so a
  push to `main` cannot stop it between the release and the request for
  publication.
- The request job is not `continue-on-error`: if it fails, nothing was
  published and the run fails. Re-running that job alone requests the same
  release again.
- `gh` uploads the release assets to a draft and publishes it once all are
  attached, so apt-publisher never sees a partial release.
- Release assets must be under 2 GiB. The release check fails otherwise.

## References

- Rationale: [core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md),
  [core ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md),
  [core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)
- Runbook: [release.md](../runbooks/release.md)
- Index: [docs/README.md](../README.md)
