# 0001 — Release the trixie and forky builds together

- **Status:** Accepted
- **Date:** 2026-11-13

## Context

Debian 14 (forky) is the next release after Debian 13 (trixie), and Frostyard
images must install `bootc` and `libostree-1-1` on both (core Plan 0009,
phase 6). The 2 packages link the libraries of the Debian release they are
built against, and those libraries differ: forky ships gpgme 2
(`libgpgme.so.45`, package `libgpgme45`) where trixie has gpgme 1
(`libgpgme.so.11`, package `libgpgme11t64`). A package whose `Depends` names
the other Debian release's library package is published but not installable.

The version marker that routes a package to a codename is the `~debNN` suffix
(core ADR-0055), so a forky build carries `~deb14` and sorts above the
`~deb13` build of the same upstream version. Until now `build.sh` accepted
only trixie, and the `Release` job accepted only `~deb13` packages, so a
forky package had no path to the APT repository.

## Decision

1 run of the **Build** workflow builds both codenames, and 1 release holds
both:

- A `stamp` job computes 1 UTC minute stamp, and both build legs take it as
  `BUILD_STAMP`. Every version and the release tag end in that stamp, so 1
  release is 1 build.
- The `build` job is a matrix with 1 leg for each codename, in parallel, each
  in a `debian:<codename>` container: `Build (Debian Trixie)` and
  `Build (Debian Forky)`.
- `build.sh` holds 1 `Depends` list for each codename, chosen by the
  container's codename. A check at the end of the build reads the `NEEDED`
  sonames of every ELF file in each package, maps each soname to its Debian
  package with `dpkg -S`, and fails unless the result equals that package's
  `Depends` list.
- The `Release` job requires exactly 4 packages: `bootc` and `libostree-1-1`,
  each once for `~deb13` and once for `~deb14`, from 1 stamp, with the same
  upstream version on both codenames.
- The `publish-deb` request names both codenames, `["trixie", "forky"]`.

## Consequences

- The trixie packages stay exactly as they are: the same `Depends` text, the
  same version shape and the same tag shape. A consumer of `trixie` sees no
  change.
- A forky build failure blocks the release of trixie too, because the
  `Release` job needs every build leg. Recovery is to fix the forky
  `Depends` list or the forky build and run again. The risk is small: a
  release is a manual run, and every pull request builds both legs, so `main`
  is known green before a release.
- apt-publisher must register this repository for `forky` before the first
  release that carries `~deb14`; until then it refuses the request
  (frostyard/apt-publisher#50).
- The ostree pin must stay at or above forky's own `libostree-1-1`
  (`2026.6-1` today). With a lower pin, the `~deb14` build sorts below
  Debian's package, and apt on forky installs Debian's `libostree-1-1` in
  place of this build.
- Each new Debian release adds 1 leg to the matrix, 1 `Depends` list pair in
  `build.sh`, and 1 codename in the request; the release check and this ADR
  change with it.

## Alternatives considered

- **A separate release for each codename:** rejected. It means 2 tags and 2
  `publish-deb` requests for 1 run of the boot chain, and 2 build stamps,
  which no longer says that both codenames came from 1 source revision.
- **A separate workflow for forky:** rejected. It duplicates the release
  logic: the version checks, the tag, the attestation and the publication
  request.

## References

- Plan: [frostyard/core Plan 0009](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md),
  phase 6
- Builds on: [core ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)
  (a `~debNN` version is published only to the codename for Debian NN),
  [core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)
  (the `image` component)
- Shapes: [design/overview.md](../design/overview.md),
  [runbooks/release.md](../runbooks/release.md)
