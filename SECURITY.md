# Security policy

bootc-debian is a public repository. It builds the Debian trixie and forky
packages `bootc` and `libostree-1-1` and publishes them to the Frostyard APT
repository at `https://repository.frostyard.org/debian/`, which Frostyard
images install bootc from.

## Reporting a vulnerability

Use GitHub private vulnerability reporting:
https://github.com/frostyard/bootc-debian/security

Open the Security tab and click **Report a vulnerability**.

Do not open a public issue with the details of a vulnerability. Do not post
credentials in an issue, a pull request or a discussion.

Tell us what you can: the affected version or commit, what an attacker can do,
and the smallest way to reproduce it. We will answer with what we found and
when a fix lands.

If a credential may be exposed, say so in the first line.

## Supported versions

Only the latest GitHub release, and the packages of that release in the APT
repository, get fixes. A fix lands on `main` and ships in a new release: this
repository makes no backported releases, and the timestamp in each version
makes the new build the newest for apt.

## Scope

In scope:

- [`build.sh`](build.sh): the download, verification and build steps, the
  version it puts on each package, and the `Depends` lists;
- the pins in [`download/checksums.json`](download/checksums.json) and their
  verification in [`download/verified-download.sh`](download/verified-download.sh)
  and [`download/check-checksums.sh`](download/check-checksums.sh);
- the release, the build attestation and the publish request in
  [`.github/workflows/build.yml`](.github/workflows/build.yml);
- the version bot in
  [`.github/workflows/check-dependencies.yml`](.github/workflows/check-dependencies.yml);
- the org secret `APT_PUBLISH_TOKEN`, which the publish request uses.

Out of scope: bugs in bootc or ostree themselves. Report those upstream, to
[bootc-dev/bootc](https://github.com/bootc-dev/bootc/security) and
[ostreedev/ostree](https://github.com/ostreedev/ostree/security).
