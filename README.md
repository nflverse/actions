# nflverse/actions

Shared GitHub Actions building blocks for nflverse data update workflows.
Instead of every data repo installing R and its packages on every run (60–110s
per job), jobs run in a prebuilt image and only refresh what is outdated.

| | |
|---|---|
| [`images/r-runner`](images/r-runner) | `ghcr.io/nflverse/r-runner`: R, gh, git, jq and the R packages the data repos use |
| [`setup`](setup) | Checkout + keep nflverse GitHub packages at HEAD + install missing deps / the repo itself |
| [`season-matrix`](season-matrix) | Current season and a JSON season array for job matrices, no R needed |

## Usage

```yaml
jobs:
  update:
    runs-on: ubuntu-latest
    container: ghcr.io/nflverse/r-runner:latest
    steps:
      - uses: nflverse/actions/setup@v1
        with:
          packages: nflverse/nflreadr nflverse/nflverse-data nflverse/nflapi
          install-local: true
          # read-only token, needed for private packages like nflapi
          github-pat: ${{ secrets.NFLVERSE_READ_TOKEN }}

      - name: Release data
        run: Rscript exec/update_data.R
        env:
          # upload token only on the step that uploads
          GH_TOKEN: ${{ secrets.NFLVERSE_GH_TOKEN }}
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

`v1` is a moving tag. After merging a non-breaking change:

```sh
git tag -f v1 && git push -f origin v1
```

Breaking changes to inputs or outputs get `v2`.

The image is rebuilt on changes to `images/r-runner`, weekly (Tuesday 06:17
UTC) and on manual trigger. It is tagged `latest`, `YYYY-MM-DD` and the commit
SHA. The "Test actions" workflow runs against each newly pushed image.
