# Release the packages

How to release `bootc` and `libostree-1-1`, how to build them locally, and how
to change the pinned upstream versions. The flow itself is in
[design/overview.md](../design/overview.md).

## Release

A release is 1 manual run of the **Build** workflow on `main`
(`workflow_dispatch`). That run builds the packages, attests them, creates the
GitHub release, and asks frostyard/apt-publisher to publish it.

1. Check that `main` is green: the last **Build** run on `main` passed.
2. Run the workflow from the Actions tab of frostyard/bootc-debian, or with:

   ```sh
   gh workflow run build.yml --ref main
   ```

3. Watch the run. The run has 4 jobs: **Lint**, **Build (Debian Trixie)**,
   **Release** and **Request APT publication**.
4. The **Release** job creates the GitHub release tagged
   `bootc-<version>-ostree-<version>-<UTC minute>`, with exactly 2 `.deb`
   files. It fails, and releases nothing, unless the build holds exactly
   `bootc` and `libostree-1-1`, both amd64, both `~deb13`, from one build.
5. The **Request APT publication** job sends `publish-deb` to
   frostyard/apt-publisher with the repository, the tag and `trixie`. If it
   fails, nothing was published: re-run that job alone and it requests the
   same release again.
6. apt-publisher publishes the release to `trixie`, component `image`, then
   dispatches a frostyard/snosi image build
   ([core ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md)).

Never run this manually from an agent: the run on `main` creates a release and
sends the publication request. A person starts it.

GitHub lists the release assets with `.deb13` in place of `~deb13` in the name.
The packages inside keep their `~deb13` version.

## Verify a release

Each `.deb` asset is bound to the workflow run that built it. To verify 1:

```sh
gh attestation verify FILE --repo frostyard/bootc-debian --source-ref refs/heads/main
```

## Build locally

```sh
docker run --rm -v "$PWD":/src -w /src debian:trixie bash build.sh
```

The packages land in `dist/`. `build.sh` refuses to run on anything but
trixie, and it needs a `debian:trixie` container because it installs the build
dependencies with `apt-get`. Set `DIST=/path` to write the packages elsewhere,
and `DEBUG_BUILD=1` to trace the script.

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

- Flow: [design/overview.md](../design/overview.md)
- Workflows: [`build.yml`](../../.github/workflows/build.yml),
  [`check-dependencies.yml`](../../.github/workflows/check-dependencies.yml)
- Index: [docs/README.md](../README.md)
