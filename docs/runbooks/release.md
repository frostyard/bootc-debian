# Release the packages

How to release `bootc` and `libostree-1-1`, how to build them locally, and how
to change the pinned upstream versions. The flow itself is in
[design/overview.md](../design/overview.md).

## Release

A release is 1 manual run of the **Build** workflow on `main`
(`workflow_dispatch`). That run builds the Debian 13 (trixie) packages and the
Debian 14 (forky) packages, attests them, creates the GitHub release with all
4, and asks frostyard/apt-publisher to publish it
([ADR-0001](../adr/0001-release-trixie-and-forky-builds-together.md)).

1. Check that `main` is green: the last **Build** run on `main` passed. That
   run built both codenames, so both `Depends` lists are known to match their
   binaries.
2. Run the workflow from the Actions tab of frostyard/bootc-debian, or with:

   ```sh
   gh workflow run build.yml --ref main
   ```

3. Watch the run. The run has 6 jobs: **Lint**, **Build stamp**, **Build
   (Debian Trixie)**, **Build (Debian Forky)**, **Release** and **Request APT
   publication**. **Build stamp** computes the 1 UTC minute stamp that both
   builds use, so 1 release holds 1 build stamp.
4. The **Release** job creates the GitHub release tagged
   `bootc-<version>-ostree-<version>-<UTC minute>`, with exactly 4 `.deb`
   files. It fails, and releases nothing, unless the build holds `bootc` and
   `libostree-1-1`, amd64, each once `~deb13` and once `~deb14`, from 1 build
   stamp, with the same upstream version on both codenames. A failing build
   leg fails the release too: fix the forky build or its `Depends` list and
   run again.
5. The **Request APT publication** job sends `publish-deb` to
   frostyard/apt-publisher with the repository, the tag and the codenames
   `trixie` and `forky`. If it fails, nothing was published: re-run that job
   alone and it requests the same release again.
6. apt-publisher publishes the `~deb13` packages to `trixie` and the `~deb14`
   packages to `forky`, component `image`, then dispatches a frostyard/snosi
   image build
   ([core ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md)).
   It refuses the request until it registers this repository for `forky`
   (frostyard/apt-publisher#50).

Never run this manually from an agent: the run on `main` creates a release and
sends the publication request. A person starts it.

GitHub lists the release assets with `.deb13` and `.deb14` in place of
`~deb13` and `~deb14` in the name. The packages inside keep their `~debNN`
version.

## Verify a release

Each `.deb` asset is bound to the workflow run that built it. To verify 1:

```sh
gh attestation verify FILE --repo frostyard/bootc-debian --source-ref refs/heads/main
```

## Build locally

```sh
make build                     # trixie, the default
make build CODENAME=forky     # forky
docker run --rm -v "$PWD":/src -w /src debian:trixie bash build.sh
docker run --rm -v "$PWD":/src -w /src debian:forky bash build.sh
```

The packages land in `dist/`. `build.sh` refuses to run on anything but
trixie and forky, and it needs a `debian:trixie` or `debian:forky` container
because it installs the build dependencies with `apt-get` and takes the
`Depends` lists of that codename. Set `DIST=/path` to write the packages
elsewhere, `BUILD_STAMP=<YYYYmmddHHmm>` to pin the version stamp (CI passes 1
stamp to both codenames), and `DEBUG_BUILD=1` to trace the script.

## Bump the upstream versions manually

Edit [`download/checksums.json`](../../download/checksums.json), or run the
**Check Upstream Versions** workflow by `workflow_dispatch`. The file holds 3
pins: `ostree`, `bootc` and `bootc-vendor` (the vendored crates of the same
bootc release). After the edit, run:

```sh
bash download/check-checksums.sh
```

It checks the shape of the file: a numeric version, a lowercase sha256 and a
GitHub release URL for that version for each pin, and the same bootc version
for `bootc` and `bootc-vendor`.

On a bootc bump, check whether `RUST_VERSION` in [`build.sh`](../../build.sh)
needs a bump: a new bootc release may raise the rustc version needed to build
it, even when its own minimum supported Rust version does not change.

## References

- Decision: [ADR-0001](../adr/0001-release-trixie-and-forky-builds-together.md)
- Flow: [design/overview.md](../design/overview.md)
- Workflows: [`build.yml`](../../.github/workflows/build.yml),
  [`check-dependencies.yml`](../../.github/workflows/check-dependencies.yml)
- Index: [docs/README.md](../README.md)
