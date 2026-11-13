# bootc-debian contributor context

This repository builds the Debian trixie and forky packages `bootc` and
`libostree-1-1` from pinned upstream release tarballs, releases them on GitHub,
and asks [frostyard/apt-publisher](https://github.com/frostyard/apt-publisher)
to publish them to the Frostyard APT repository. Frostyard images install
those packages instead of building bootc themselves. Start at
[docs/README.md](docs/README.md).

`AGENTS.md` is the canonical instruction file. `CLAUDE.md`, `GEMINI.md`,
`.cursorrules` and [`.github/copilot-instructions.md`](.github/copilot-instructions.md)
are relative symlinks to it (core ADR-0018, core ADR-0029). Edit only this
file.

## Layout

| Path | What it is |
| --- | --- |
| [`build.sh`](build.sh) | Downloads and verifies the pinned tarballs, builds ostree, builds bootc against it offline, and packages both as `.deb` files into `dist/`. Takes 1 `Depends` list for each codename it supports, and refuses any codename but trixie and forky. |
| [`lib/check-depends.sh`](lib/check-depends.sh) | `check_depends DEB PACKAGE DEPENDS [WORKDIR]`: reads the `NEEDED` sonames of the ELF files in a built package, maps each to its Debian package with `dpkg -S`, and fails unless that set equals the `Depends` list. `build.sh` sources it; [`tests/check-depends-test.sh`](tests/check-depends-test.sh) is its test. |
| [`lib/check-release.sh`](lib/check-release.sh) | `bash lib/check-release.sh DIST_DIR`: the release check of the `Release` job. Fails, with a `::error::` line, unless `DIST_DIR` holds exactly 4 packages: `bootc` and `libostree-1-1`, amd64, each once `~deb13` and once `~deb14`, from 1 build stamp, with the same upstream version on both codenames. Writes `tag=...` to `$GITHUB_OUTPUT`; [`tests/check-release-test.sh`](tests/check-release-test.sh) is its test. |
| [`download/checksums.json`](download/checksums.json) | The upstream pins: version, release-tarball URL and sha256 for `ostree`, `bootc` and `bootc-vendor`. |
| [`download/verified-download.sh`](download/verified-download.sh) | `verified_download KEY PATH`: fetches 1 pin and fails on a sha256 mismatch. `build.sh` sources it. |
| [`download/check-checksums.sh`](download/check-checksums.sh) | Checks the shape of `download/checksums.json`: 3 pins, numeric versions, lowercase sha256 sums, GitHub release URLs, and one bootc version for `bootc` and `bootc-vendor`. |
| [`download/test-check-checksums.sh`](download/test-check-checksums.sh) | The negative test of the checksum check: the committed file passes and each broken variant fails. |
| [`.github/workflows/build.yml`](.github/workflows/build.yml) | Lint and, in parallel, the build and install of the packages. A manual run on `main` also releases and requests publication. |
| [`.github/workflows/check-dependencies.yml`](.github/workflows/check-dependencies.yml) | Weekly: checks for new ostree and bootc releases, updates `download/checksums.json` in a bot PR, and starts Build and ci on that branch. |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | Runs `make ci` on pull requests, on a push to `main`, and on the dispatch that `check-dependencies.yml` sends to the bot branch. |
| [`.github/workflows/risk-paths.yml`](.github/workflows/risk-paths.yml) | Calls core's `pr-triage.yml` reusable workflow, which adds the `level:L1` to `level:L4` label and `risk:high` at L1 and L2. |
| [`tests/check-depends-test.sh`](tests/check-depends-test.sh) | The test of the `Depends` check: a matching list passes and each wrong one fails, with small `.deb` files and stubbed `dpkg` and `objdump`. |
| [`tests/check-release-test.sh`](tests/check-release-test.sh) | The test of the release check: the 4 packages of 1 release pass and write the tag, and each wrong set fails with its message, with fake `.deb` files and a stubbed `dpkg-deb`. |
| [`tests/`](tests/) | The baseline check and its negative tests. |
| [`docs/`](docs/README.md) | The design, the runbooks, the ADRs, the specs and the plans. |

## Gates

`make ci` is the gate; it runs `make verify`, which runs `make lint` and
`make test`:

- `make lint` runs `shellcheck build.sh download/*.sh lib/*.sh
  tests/*.sh` and `actionlint`.
- `make test` runs `bash download/test-check-checksums.sh`,
  `bash download/check-checksums.sh`, `bash tests/check-depends-test.sh`,
  `bash tests/check-release-test.sh`, `tests/check-baseline.sh` and
  `tests/check-baseline-test.sh`.

Run `mise install` first: `mise.toml` and `mise.lock` pin shellcheck,
actionlint and jq (core ADR-0043). The baseline check reads
`.memory/corrections.jsonl` with a small Python program, so `python3` must be
on `PATH` (row B2 of core's baseline spec). CI runs `make ci` in
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Rules

- **Never run the Build workflow by `workflow_dispatch` on `main` from an
  agent.** That run creates a GitHub release and sends the `publish-deb`
  request to frostyard/apt-publisher, which publishes it. A person starts it;
  every other Build run publishes nothing.
- **A release holds exactly 4 packages: `bootc` and `libostree-1-1`, amd64,
  once `~deb13` and once `~deb14`, from 1 run with 1 build stamp.** The
  `Release` job in `build.yml` fails otherwise
  ([`lib/check-release.sh`](lib/check-release.sh)), and apt-publisher publishes
  every `.deb` in the release. Never add a package, an architecture or a
  codename to that job without an ADR ([ADR-0001](docs/adr/0001-release-trixie-and-forky-builds-together.md)).
- **A version is `<upstream>-frostyard<UTC minute>~deb13` for trixie and
  `<upstream>-frostyard<UTC minute>~deb14` for forky**, for example
  `1.16.8-frostyard202610040130~deb13`. The timestamp makes every rebuild sort
  newer; the `Build` workflow passes 1 `BUILD_STAMP` to both codename builds,
  so 1 release holds 1 stamp. apt-publisher publishes a `~debNN` version only
  to the codename for Debian NN (core ADR-0055).
- **`build.sh` builds for trixie and forky, and refuses any other codename.**
  Its `case` block holds 1 `Depends` list for each codename, because they name
  that Debian release's library packages: forky ships `libgpgme45` where
  trixie has `libgpgme11t64`. Its `Depends` check at the end of the script
  fails the build unless each list equals the packages that the package's
  `NEEDED` sonames map to, so a new codename or a library change needs the
  list, not only a rename.
- **The upstream pins change only in [`download/checksums.json`](download/checksums.json)**,
  and [`download/check-checksums.sh`](download/check-checksums.sh) checks the
  shape of that file. Never edit a version, a URL or a sha256 in `build.sh` or
  in a workflow.
- **The bot PR sets its own level labels.** A PR that `GITHUB_TOKEN` opens
  starts no `pull_request_target` run, so the triage caller never labels the
  version PR (frostyard/core#233); [`check-dependencies.yml`](.github/workflows/check-dependencies.yml)
  sets them in the `create-pull-request` step instead: `add-paths` limits the
  commit to `download/checksums.json`, and `labels` names the level of that
  file plus `risk:high` at L1 and L2. [`tests/check-baseline.sh`](tests/check-baseline.sh)
  checks the labels against the level that `.github/risk-paths.json` gives the
  add-paths, so a list change that moves that level must change them too.
- **On a bootc bump, check `RUST_VERSION` in [`build.sh`](build.sh).** A new
  bootc release can need a newer rustc to build, even when its own minimum
  supported Rust version does not change.
- **Keep the file name `build.yml`, its `workflow_dispatch` trigger and the
  job name `Build (Debian Trixie)`.** That job name is a required status
  check, and it comes from the matrix leg whose `title` is `Trixie`; the forky
  leg is `Build (Debian Forky)`. The bot workflow dispatches `build.yml` and
  `ci.yml` on the branch `auto-update-checksums` with `gh workflow run`,
  because a `GITHUB_TOKEN` pull request starts no workflow. `ci` is the gate
  check, so it needs its own `workflow_dispatch` trigger.
- **Every action is pinned to a full commit SHA with a `# vX.Y.Z` comment**
  (a frostyard/core reusable workflow: `# frostyard/core main, YYYY-MM-DD`,
  because core has no release tags), **every checkout sets
  `persist-credentials: false`, and every workflow has top-level
  `permissions: {}` or read-only permissions** (core ADR-0021).
  [`tests/check-baseline.sh`](tests/check-baseline.sh) checks all 3.
- **A PR that touches a path in [`.github/risk-paths.json`](.github/risk-paths.json)
  gets the label of its strictest matched level** (core ADR-0068, ADR-0078):
  `level:L1` (read every line), `level:L2` (read the diff), `level:L3` (skim)
  or `level:L4` (title and CI). A core org floor can raise the computed level
  above the entry's level, and a stricter level label that the PR already has
  stays (the ratchet); only the author lowers it, by hand, with the reason in
  the PR. L1 and L2 also get `risk:high`, and the workflow removes
  `ready-for-human` when the head moves after the label (core ADR-0077). The PR
  body names each matched path and why the change is safe.
- **A blocking review point adds a guard:** a test that fails without the fix,
  or a rule here when no test can catch it, plus 1 line in
  [`.memory/corrections.jsonl`](.memory/corrections.jsonl)
  ([`.memory/README.md`](.memory/README.md)).
- **PR text speaks for the repository.** A title, a body, a comment and a
  commit message give the reason in this repository's terms and link the ADR,
  the spec or the issue that applies. Who decided and when stays off the PR.

## Documentation

`docs/README.md` is the index. A decision about this repository gets an ADR in
`docs/adr/`; an org-wide one goes to frostyard/core and is listed in
`docs/org-adrs.md`. The root `README.md` follows core's README spec (kind
`packaging`, at most 1000 words); the flow, the rules and the runbooks go in
`docs/`.
