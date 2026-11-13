# Package build and publication

Living document. Rationale: [ADR-0001](../adr/0001-release-trixie-and-forky-builds-together.md),
[core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md),
[core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md).
Contracts: [frostyard/core specs](https://github.com/frostyard/core/tree/main/docs/specs).

## Overview

This repository turns 3 pinned upstream release tarballs (ostree, bootc and
bootc's vendored crates) into 2 Debian packages, `bootc` and `libostree-1-1`,
for Debian 13 (trixie) and Debian 14 (forky) on amd64. A manual run of the
**Build** workflow on `main` builds both codenames and creates 1 GitHub
release that holds both builds, and frostyard/apt-publisher publishes that
release to the Frostyard APT repository at
`https://repository.frostyard.org/debian/`.

```
upstream tarballs ──► build.sh ──► dist/*.deb for trixie and forky
                                        │
                                        ▼
                                  GitHub release
                                        │
                                        ▼
                                  publish-deb dispatch
                                        │
                                        ▼
                          frostyard/apt-publisher
               (trixie: ~deb13, forky: ~deb14, component image)
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
`bootc-vendor`). [`build.sh`](../../build.sh) takes the codename of the
container it runs in, and refuses any codename but trixie and forky: it holds
1 `Depends` list for each codename, because the lists name that Debian
release's library packages. Forky ships gpgme 2 (`libgpgme.so.45`, package
`libgpgme45`) where trixie has gpgme 1 (`libgpgme.so.11`, package
`libgpgme11t64`); `bootc` needs the same list on both codenames. At the end of
the build, the check in [`lib/check-depends.sh`](../../lib/check-depends.sh)
reads the `NEEDED` sonames of every ELF file in each package, maps each soname
to its Debian package with `dpkg -S` and fails unless the result equals that
package's `Depends` list, so a wrong or stale list fails the build instead of
shipping (see
[ADR-0001](../adr/0001-release-trixie-and-forky-builds-together.md)). Its test,
[`tests/check-depends-test.sh`](../../tests/check-depends-test.sh), builds small
packages and proves that a wrong list fails.

### Versions

Versions are `<upstream>-frostyard<UTC minute>~deb13` for trixie and
`<upstream>-frostyard<UTC minute>~deb14` for forky, for example
`1.16.8-frostyard202610040130~deb13`. The timestamp makes every rebuild sort
newer, and the `stamp` job passes 1 stamp to both codename builds, so 1
release holds 1 build stamp. The `~debNN` marker names the Debian release the
packages were built against: apt-publisher publishes a `~debNN` version only to
the codename for Debian NN
([core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)),
so the forky build sits beside the trixie one (`~deb13` sorts below `~deb14`).

### The `image` component

`libostree-1-1` replaces Debian's package of the same name, and `bootc` links
against it, so both are published in the `image` component, not `main`
([core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)).
Only Frostyard image builds enable `image` (snosi's build sandbox,
`Components: main image`). A plain Debian host that adds `main` keeps
Debian's `libostree-1-1` and its security updates.

The component is set by apt-publisher, not here: its `config/producers.tsv`
registers this repository for `image`, and the `publish-deb` request names
only the repository, the tag and the 2 codenames, `trixie` and `forky`.

Versions published before the move stay installable from `image`:
apt-publisher's move workflow (ADR-0059 step 5) takes every published version
out of `main`'s index and into `image`'s, unchanged. Their files under
`debian/pool/main/` stay in the bucket, because nothing deletes pool files;
removing them would be a later, separately approved change.

### Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| [`build.yml`](../../.github/workflows/build.yml) | push to `main`, every pull request, a manual run | Lint and, in parallel, the build and install of the packages for both codenames. A push or pull request run publishes nothing. |
| [`check-dependencies.yml`](../../.github/workflows/check-dependencies.yml) | weekly schedule, a manual run | Checks for new ostree and bootc releases and opens or updates a pull request that changes `download/checksums.json`. Then starts Build and ci on its branch. |
| [`ci.yml`](../../.github/workflows/ci.yml) | pull request, push to `main`, a dispatch from `check-dependencies.yml` | Runs `make ci`. |
| [`risk-paths.yml`](../../.github/workflows/risk-paths.yml) | `pull_request_target` | Calls core's `pr-triage.yml` reusable workflow, which adds the `level:L1` to `level:L4` label and `risk:high` at L1 and L2. |

**Build.** **Lint** and the builds run in parallel. The **Lint** job runs
actionlint, shellcheck, `download/check-checksums.sh` and its test. The
**Build stamp** job computes the 1 UTC minute stamp that both builds use. The
matrix job then builds the packages in a `debian:trixie` container, as
**Build (Debian Trixie)**, and in a `debian:forky` container, as **Build
(Debian Forky)**, and installs them, so a broken pin or a broken build fails
here. A failing leg does not cancel the other one.

**Release.** A manual run of Build on `main` (`workflow_dispatch`) also:

1. checks that the build is exactly `bootc` and `libostree-1-1`, amd64, once
   `~deb13` and once `~deb14`, from 1 build stamp, with the same upstream
   version on both codenames;
2. attests their build provenance;
3. creates a GitHub release tagged
   `bootc-<version>-ostree-<version>-<UTC minute>` with the 4 `.deb` files
   (GitHub lists the `.deb13` and `.deb14` in place of `~deb13` and `~deb14`
   in the asset names);
4. sends a `publish-deb` request to frostyard/apt-publisher, naming `trixie`
   and `forky`. apt-publisher publishes the `~deb13` packages to `trixie` and
   the `~deb14` packages to `forky`, component `image`, then dispatches a
   frostyard/snosi image build
   ([core ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md)).

**Check Upstream Versions.** The weekly run opens or updates a pull request on
the branch `auto-update-checksums` that changes `download/checksums.json`. A
`GITHUB_TOKEN` pull request starts no workflow, so the run then starts
**Build** and **ci** on that branch with `gh workflow run`; the pull request
shows its "Build (Debian Trixie)", "Build (Debian Forky)" and "ci" checks. `ci`
is the gate check, so it must run on the bot pull request too. Merging that pull request publishes
nothing: releasing needs a manual run of **Build** on `main`.

## Operational notes

- The release job runs only when the repository is `frostyard/bootc-debian`,
  the ref is `refs/heads/main` and the event is `workflow_dispatch`. A push to
  `main` cannot create a release.
- The release needs both build legs, so a forky build failure blocks the
  trixie release of that run too. Fix the forky `Depends` list or the forky
  build and run again: every pull request builds both legs, so `main` is known
  green before a release.
- apt-publisher must register this repository for `forky` before the first
  release that carries `~deb14`, or it refuses the request
  (frostyard/apt-publisher#50).
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

- Decisions: [ADR-0001](../adr/0001-release-trixie-and-forky-builds-together.md),
  [core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md),
  [core ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md),
  [core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)
- Runbook: [release.md](../runbooks/release.md)
- Index: [docs/README.md](../README.md)
