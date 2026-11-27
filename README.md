# nflverse/actions

Shared GitHub Actions building blocks for nflverse data update workflows.
Instead of every data repo installing R and its packages on every run (60–110s
per job), jobs run in a prebuilt image and only refresh what is outdated.

| | |
|---|---|
| [`images/r-runner`](images/r-runner) | `ghcr.io/nflverse/r-runner`: R, gh, git, jq and the R packages the data repos use |
| [`setup`](setup) | Checkout + keep nflverse GitHub packages at HEAD + install missing deps / the repo itself |
| [`season-matrix`](season-matrix) | Current season and a JSON season array for job matrices, no R needed |
| [`commit-and-push`](commit-and-push) | Commit changed files and push, rebasing and retrying on concurrent pushes |
| [`upload-timestamps`](upload-timestamps) | Upload `timestamp.txt`/`.json` once per release, only if the run updated data in it |
| [`install-rclone`](install-rclone) | Pinned, checksum-verified rclone (Ubuntu's apt version fails on R2) |
| [`app-token`](app-token) | Short-lived token of the "nflverse actions" GitHub App, limited to the repos and permissions a step needs. Replaces the org PATs |
| [`enable-workflows`](.github/workflows/enable-workflows.yaml) | Daily job that re-enables scheduled workflows GitHub disabled for inactivity, replacing heartbeat commits |

Rollout status, open tasks and the repo migration plan: [ROLLOUT.md](ROLLOUT.md).

## Usage

```yaml
jobs:
  update:
    runs-on: ubuntu-latest
    container: ghcr.io/nflverse/r-runner:latest
    steps:
      # read-only token for private packages like nflapi. The repo needs
      # access to the org secret NFLVERSE_APP_PRIVATE_KEY.
      - id: token
        uses: nflverse/actions/app-token@v1
        with:
          client-id: ${{ vars.NFLVERSE_APP_CLIENT_ID }}
          private-key: ${{ secrets.NFLVERSE_APP_PRIVATE_KEY }}
          repositories: nflapi

      - uses: nflverse/actions/setup@v1
        with:
          packages: nflverse/nflreadr nflverse/nflverse-data nflverse/nflapi
          install-local: true
          github-pat: ${{ steps.token.outputs.token }}

      - name: Release data
        run: Rscript exec/update_data.R
        env:
          # upload token only on the step that uploads
          GH_TOKEN: ${{ secrets.NFLVERSE_GH_TOKEN }}
```

Commit files a job produced (replaces the git config/add/commit/push steps):

```yaml
      - uses: nflverse/actions/commit-and-push@v1
        with:
          paths: released_games.csv
          message: Update released games
```

Release timestamps once per run, in a final job:

```yaml
  upload_timestamps:
    needs: [setup, update]
    if: ${{ !cancelled() && needs.setup.result == 'success' }}
    runs-on: ubuntu-latest
    steps:
      - uses: nflverse/actions/upload-timestamps@v1
        with:
          started-at: ${{ needs.setup.outputs.started_at }}
          token: ${{ secrets.NFLVERSE_GH_TOKEN }}
          releases: |
            nflverse/nflverse-data pbp
            nflverse/nflverse-data stats_player
```

Season matrix (replaces the R setup job that called `nflverse.workflows`):

```yaml
jobs:
  setup:
    runs-on: ubuntu-latest
    outputs:
      seasons: ${{ steps.seasons.outputs.seasons }}
    steps:
      - id: seasons
        uses: nflverse/actions/season-matrix@v1
        with:
          first-season: 2016
          season-rebuild: ${{ inputs.season_rebuild }}
          full-rebuild: ${{ inputs.full_rebuild }}

  update:
    needs: setup
    strategy:
      matrix:
        season: ${{ fromJson(needs.setup.outputs.seasons) }}
    # ...
```

## `app-token` inputs

| Input | Default | |
|---|---|---|
| `client-id`, `private-key` | | `vars.NFLVERSE_APP_CLIENT_ID`, `secrets.NFLVERSE_APP_PRIVATE_KEY` |
| `repositories` | `""` | nflverse repos the token can access, e.g. `nflapi, nfldx`. Empty: the current repo. `all`: every repo |
| `contents` | `read` | `read`, `write` (releases, pushes) or `""` |
| `actions` | `""` | `read`, `write` or `""` |

The token expires after one hour and is revoked when the job ends. A step
that runs longer, e.g. a release step that scrapes and uploads for over an
hour, needs its own token minted right before it. The action refuses to mint
a token without any permission input, which would get every permission of the
app.

The private key is an org secret visible to selected repos only: add a repo
there (org settings → Secrets → `NFLVERSE_APP_PRIVATE_KEY`) when it starts
using the app.

## `setup` inputs

| Input | Default | |
|---|---|---|
| `packages` | `""` | GitHub packages to keep at their latest commit: `owner/repo` or `pkg=owner/repo`, separated by whitespace or commas |
| `install-deps` | `true` | Install dependencies from the repo's `DESCRIPTION` that are missing from the image or too old |
| `install-local` | `false` | Install the checked out repo as a package (no dependencies) |
| `github-pat` | `github.token` | Token for the GitHub API and GitHub installs. Private packages need read access. **Never the upload token**: this step installs unpinned code |
| `checkout` | `true` | Run `actions/checkout` first |
| `ref`, `fetch-depth`, `checkout-token` | | Passed to `actions/checkout` |

For each package in `packages`, the action compares the installed commit
(`RemoteSha`) with GitHub HEAD. If they differ it installs the r-universe
binary, and if r-universe hasn't built HEAD yet (or doesn't have the package,
like private ones) it installs from GitHub with pak. The step never fails the
job: problems become warning annotations, and the job summary shows each
package's version and commit.

## Rules

- **Set `shell: bash` in container jobs.** `run:` steps in a job with
  `container:` use `sh` by default, not bash. Add `defaults: run: shell: bash`
  to the workflow if a step uses bash syntax.
- **Only public packages in the image.** Private packages (nflapi, ngsscrapR,
  nflverse.espn, nfldx, ...) go into `packages` of the setup action. Put their
  dependencies into [`packages.txt`](images/r-runner/packages.txt) though, so
  installing them takes seconds.
- **Add a dependency the data repos share to `packages.txt`.** Rare,
  repo-specific dependencies don't need to be in the image: `install-deps`
  installs them at job time.
- **Callers only reference `nflverse/actions/...@v1`.** All third-party
  action versions (checkout, docker, ...) live in this repo and Dependabot
  bumps them here.

## Releases

Changes reach `main` only through PRs, and the PR check `all tests` has to
pass (ruleset "main").

`v1` is a moving tag. After merging a non-breaking change, run the
[Release](.github/workflows/release.yaml) workflow on main:

```sh
gh workflow run release.yaml -R nflverse/actions
```

It runs the full tests on main's HEAD and then moves `v1` there, so every
move is tested and logged. Nobody can push `v*` tags directly: the ruleset
"release tags" only lets the "nflverse actions" app change them, and the
workflow moves the tag with an app token. To undo a release, revert on main
and release again. Breaking
changes to inputs or outputs get `v2`: run the workflow with `tag: v2`.

### The image

`ghcr.io/nflverse/r-runner:latest` only ever points at an image that passed
the tests. [`build-r-runner.yaml`](.github/workflows/build-r-runner.yaml)
runs on changes to `images/r-runner`, weekly (Tuesday 06:17 UTC, for R patch
releases and new CRAN packages) and on manual trigger:

1. **build** pushes the new image as `candidate`.
2. **test** runs [`test.yaml`](.github/workflows/test.yaml) against it: all
   actions, plus a `consumers` job that installs and loads the GitHub
   packages and `DESCRIPTION` dependencies of every data repo. **Add a repo
   there when it starts using the image.**
3. **measure** compares pull and create times and size with the current
   `latest` (job summary). It doesn't block promotion.
4. **promote** tags the tested image `latest`, `YYYY-MM-DD` and the commit
   SHA. Nothing is promoted if a test fails: `latest` stays on the last good
   image and the run fails.

5. **cleanup** deletes test tags of closed PRs and deleted branches, and
   promoted images beyond the newest 8 besides `latest` (about two months of
   weekly builds), each with its two child manifests. Untagged leftovers go
   once they're a day old. See the plan without deleting:
   `GH_TOKEN=$(gh auth token) DRY_RUN=true python3 .github/scripts/cleanup_r_runner.py`

**Testing an image change before merging:** a PR from a branch in this repo
pushes `test-pr-<number>` and runs the tests and measure job against it. For
a Dependabot PR (read-only token) or any other branch, run the workflow with
workflow_dispatch on that branch: it pushes `test-<branch>`. Only main ever
promotes.

**Rolling back:** run "Build r-runner image" on main with `rollback-to` set
to an earlier date tag (e.g. `2026-11-24`) or commit SHA. `latest` points at
that image within seconds, no rebuild. The next build promotes a new image
again if its tests pass, so add a test for whatever broke (or disable the
workflow until it's fixed).

**R versions:** the base is pinned to the R minor version
(`rocker/r-ver:4.6`). Dependabot opens a PR for the next minor version,
which is tested like any other image change.
