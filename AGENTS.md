# bootc-debian contributor context

This repository builds the Debian trixie packages `bootc` and `libostree-1-1`
from pinned upstream release tarballs, releases them on GitHub, and asks
[frostyard/apt-publisher](https://github.com/frostyard/apt-publisher) to
publish them to the Frostyard APT repository. Frostyard images install those
packages instead of building bootc themselves. Start at
[docs/README.md](docs/README.md).

`AGENTS.md` is the canonical instruction file. `CLAUDE.md`, `GEMINI.md`,
`.cursorrules` and [`.github/copilot-instructions.md`](.github/copilot-instructions.md)
are relative symlinks to it (core ADR-0018, core ADR-0029). Edit only this
file.

## Layout

| Path | What it is |
| --- | --- |
| [`build.sh`](build.sh) | Downloads and verifies the pinned tarballs, builds ostree, builds bootc against it offline, and packages both as `.deb` files into `dist/`. Refuses any codename but trixie. |
| [`download/checksums.json`](download/checksums.json) | The upstream pins: version, release-tarball URL and sha256 for `ostree`, `bootc` and `bootc-vendor`. |
| [`download/verified-download.sh`](download/verified-download.sh) | `verified_download KEY PATH`: fetches 1 pin and fails on a sha256 mismatch. `build.sh` sources it. |
| [`download/check-checksums.sh`](download/check-checksums.sh) | Checks the shape of `download/checksums.json`: 3 pins, numeric versions, lowercase sha256 sums, GitHub release URLs, and one bootc version for `bootc` and `bootc-vendor`. |
| [`download/test-check-checksums.sh`](download/test-check-checksums.sh) | The negative test of the checksum check: the committed file passes and each broken variant fails. |
| [`.github/workflows/build.yml`](.github/workflows/build.yml) | Lint and, in parallel, the build and install of the packages. A manual run on `main` also releases and requests publication. |
| [`.github/workflows/check-dependencies.yml`](.github/workflows/check-dependencies.yml) | Weekly: checks for new ostree and bootc releases, updates `download/checksums.json` in a bot PR, and starts Build on that branch. |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | Runs `make ci` on pull requests and on a push to `main`. |
| [`.github/workflows/risk-paths.yml`](.github/workflows/risk-paths.yml) | Calls core's `pr-triage.yml` reusable workflow, which adds the `level:L1` to `level:L4` label and `risk:high` at L1 and L2. |
| [`tests/`](tests/) | The baseline check and its negative tests. |
| [`docs/`](docs/README.md) | The design, the runbooks, the ADRs, the specs and the plans. |

## Gates

`make ci` is the gate; it runs `make verify`, which runs `make lint` and
`make test`:

- `make lint` runs `shellcheck build.sh download/*.sh tests/*.sh` and
  `actionlint`.
- `make test` runs `bash download/test-check-checksums.sh`,
  `bash download/check-checksums.sh`, `tests/check-baseline.sh` and
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
- **A release holds exactly `bootc` and `libostree-1-1`, amd64, `~deb13`, from
  1 build.** The `Release` job in `build.yml` fails otherwise, and
  apt-publisher publishes every `.deb` in the release. Never add a package, an
  architecture or a codename to that job without an ADR.
- **A version is `<upstream>-frostyard<UTC minute>~deb13`**, for example
  `1.16.8-frostyard202610040130~deb13`. The timestamp makes every rebuild sort
  newer; apt-publisher publishes a `~debNN` version only to the codename for
  Debian NN (core ADR-0055), so a forky build (`~deb14`) can sit beside it.
- **`build.sh` refuses any codename but trixie.** Its `Depends` lists name
  trixie's library packages, so a new codename needs new lists, not a rename.
- **The upstream pins change only in [`download/checksums.json`](download/checksums.json)**,
  and [`download/check-checksums.sh`](download/check-checksums.sh) checks the
  shape of that file. Never edit a version, a URL or a sha256 in `build.sh` or
  in a workflow.
- **On a bootc bump, check `RUST_VERSION` in [`build.sh`](build.sh).** A new
  bootc release can need a newer rustc to build, even when its own minimum
  supported Rust version does not change.
- **Keep the file name `build.yml`, its `workflow_dispatch` trigger and the
  job name `Build (Debian Trixie)`.** That job is a required status check, and
  the bot workflow dispatches `build.yml` on the branch `auto-update-checksums`
  with `gh workflow run`, because a `GITHUB_TOKEN` pull request starts no
  workflow.
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
