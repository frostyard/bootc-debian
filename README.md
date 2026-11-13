<!-- readme-kind: packaging -->
# bootc-debian

Debian trixie and forky packages of [bootc](https://github.com/bootc-dev/bootc)
and [ostree](https://github.com/ostreedev/ostree), built from pinned upstream
releases and published to the Frostyard APT repository. They are for Frostyard
images: an image installs `bootc` and `libostree-1-1` from here instead of
building them itself.

**Status:** in production. It releases from `main` by a manual run.

**Documentation:** [docs/README.md](docs/README.md)

## What it publishes

| Package | What it is | Where |
| --- | --- | --- |
| `bootc` | Boot and upgrade a host via container images | `trixie` and `forky`, component `image`, [repository.frostyard.org/debian](https://repository.frostyard.org/debian/) |
| `libostree-1-1` | The OSTree library and tools that `bootc` links against | `trixie` and `forky`, component `image`, [repository.frostyard.org/debian](https://repository.frostyard.org/debian/) |

Each Debian release has its own build, with its own `Depends` list: the 2
packages link the libraries of the release they are built for.

Both packages are published in the `image` component, not `main`:
`libostree-1-1` replaces Debian's package of the same name, and only Frostyard
image builds enable that component
([core ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)).

## Install

Add the repository once, then install both packages:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/frostyard.gpg https://repository.frostyard.org/debian/frostyard.gpg
printf 'Types: deb\nURIs: https://repository.frostyard.org/debian/\nSuites: trixie\nComponents: main image\nSigned-By: /etc/apt/keyrings/frostyard.gpg\n' | sudo tee /etc/apt/sources.list.d/frostyard.sources
sudo apt update
sudo apt install bootc
```

This is what a Frostyard image build does: snosi's build sandbox uses
`Components: main image`. On any other host, `image` replaces Debian's
`libostree-1-1` with this build; a plain Debian host that adds only `main`
keeps Debian's package and its security updates.

## How it works

Upstream versions are pinned in [`download/checksums.json`](download/checksums.json).
[`build.sh`](build.sh) downloads and verifies the tarballs, builds ostree, then
builds bootc against it offline, and packages both as `.deb` files. A manual
run of the Build workflow on `main` creates the GitHub release and sends a
`publish-deb` request to [frostyard/apt-publisher](https://github.com/frostyard/apt-publisher),
the single writer of the APT repository. 1 run builds the Debian 13 packages
and the Debian 14 packages into 1 release
([ADR-0001](docs/adr/0001-release-trixie-and-forky-builds-together.md)).
[docs/design/overview.md](docs/design/overview.md) has the flow, the component
rules, the version scheme and the workflows.

## Develop

```sh
mise install    # shellcheck, actionlint and jq, from mise.toml and mise.lock
make ci         # what CI runs: make verify
make build      # the packages into dist/; CODENAME=forky for Debian 14
docker run --rm -v "$PWD":/src -w /src debian:trixie bash build.sh
docker run --rm -v "$PWD":/src -w /src debian:forky bash build.sh
```

[docs/runbooks/release.md](docs/runbooks/release.md) has the release steps, the
attestation check, building locally and bumping a pin by hand.

## Where to go next

- [AGENTS.md](AGENTS.md): the rules that agents and contributors must keep.
- [docs/README.md](docs/README.md): the design, the runbooks and the org ADRs.
- [SECURITY.md](SECURITY.md): report a vulnerability privately, and what gets
  fixes.
- [LICENSE](LICENSE): MIT.
