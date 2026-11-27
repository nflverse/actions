# Rollout status

Moving nflverse data update workflows from `setup-r` + `setup-r-dependencies`
(60–110s setup per job) to `ghcr.io/nflverse/r-runner` + the actions in this
repo. Pattern first proven in nflverse-pbp #106/#107.

Last updated: 2026-11-27

## Decisions

- One central repo (this one). Callers only reference `nflverse/actions/<action>@v1`;
  third-party action versions live here, bumped by Dependabot.
- One **public** image. **No private packages in images** (GitHub Free plan:
  500 MB private package storage, the image is ~600 MB compressed). Private
  packages are installed at job time via `setup`'s `packages` input.
- Tokens come from the org-owned GitHub App "nflverse actions" via the
  `app-token` action (#1): short-lived, scoped per step to the repos and
  permissions it needs. Read-only for `setup` (private packages), write only
  on the step that uploads, minted after `setup`. The PATs
  `NFLVERSE_READ_TOKEN` and `NFLVERSE_GH_TOKEN` stay only until the
  remaining repos are migrated.

## Done

- [x] Repo, r-runner image (built, public), `setup`, `season-matrix`,
      `commit-and-push`, `install-rclone`, `upload-timestamps`,
      `enable-workflows`, Dependabot, tests. Tagged `v1` at 1722d56.
- [x] Tests green on the runner and in the image. Setup in the image: 29–38s
      per job including the image pull.
- [x] PATs created 2026-11-27 (superseded by the app): `NFLVERSE_WORKFLOWS_TOKEN`
      (deleted, PAT revoked) and `NFLVERSE_READ_TOKEN` (org secret, Contents
      read on nflapi, ngsscrapR, nflverse-espn, nfldx, expires 2027-11). Still
      used by the step 4 repos until their migration.
- [x] `enable-workflows` dry run: token reads all 40 non-archived repos.
      nflverse-pff (stale since 2024) and NFLData.jl CompatHelper are disabled
      for inactivity and kept that way via `EXCLUDE`. Remove them there to
      revive them. The daily schedule is live.
- [x] Image safety (2026-11-27): only tested images become `latest`
      (candidate → tests incl. all consumer repos → promote), rollback via
      `rollback-to`, base pinned to R 4.6 with Dependabot. zstd layers.
- [x] Repo rules (2026-11-27): ruleset `main` (PR + required `all tests`, no
      force push, no bypass). `v1` moves only via the Release workflow.
- [x] GitHub App (2026-11-27, #1): org-owned "nflverse actions"
      (`nflverse-actions`, Contents r/w, Actions r/w, Metadata read, installed
      on all repos). `vars.NFLVERSE_APP_CLIENT_ID`, org secret
      `NFLVERSE_APP_PRIVATE_KEY` (visible to selected repos: actions). The
      `app-token` action mints scoped 1-hour tokens. `enable-workflows`,
      the tests and the Release workflow use it; `NFLVERSE_WORKFLOWS_TOKEN`
      deleted and its PAT revoked. tanho63's older "nflverse service app"
      (personal account, unused) is still installed: decide whether to
      uninstall it.
- [x] Ruleset `release tags`: only the app can create, move or delete `v*`
      tags, i.e. only the Release workflow. Direct pushes are rejected
      (tested).
- [x] System libs (2026-11-27, #11): `libcurl4-openssl-dev libssl-dev
      libicu-dev` in the image plus `PKG_SYSREQS_UPDATE=false`. No more
      apt-get in jobs that build private packages from source. Setup in the
      consumer tests: pbp-internal 18 → 14s, players 18 → 15s, rosters
      33 → 24s.
- [x] Private package path tested (`setup-private` job): nflapi installed
      from GitHub at HEAD in 18s.
- [x] `upload-timestamps` tested 2026-11-27 (nflverse-pbp run 46053835741 from
      the PR #108 branch): 4 releases updated, only those with new files.

## Open

- [ ] Migrate repos (below). After each repo uses the central jobs, delete
      its heartbeat workflow (only once `enable-workflows` runs).
- [ ] Data repos: switch `NFLVERSE_READ_TOKEN` and the upload token
      `NFLVERSE_GH_TOKEN` to `app-token` during each repo's migration
      (done: nflverse-pbp-internal, nflverse-pbp, ngs-data, nflverse-players,
      nflverse-ftn). Add the
      repo to the visibility of the org secret `NFLVERSE_APP_PRIVATE_KEY`
      first. Release steps must stay under 1 hour per token. Check where long
      jobs spend their time first: in ngs-data it was setup, not the release
      step (nflverse-data's archive jobs, 42 min, still to check). Revoke both PATs once nothing uses them (#1).
- [ ] Afterwards: retire the `nflverse.workflows` R package (nflverse-workflows
      repo) once nothing calls it.

## How to migrate a repo

What every migration so far did, in this order. Each one is a PR in the data
repo plus a ROLLOUT.md update here (`main` is protected: PR + `all tests`).

1. **Local clone.** `git status`, stashes, unfinished merges. Don't touch
   work in progress: work in a fresh clone in the scratchpad instead and tell
   the user (ngs-data had an unfinished merge from August).
2. **Repo rules.** Default branch, allowed merge methods (some repos only
   allow squash), classic protection *and* rulesets
   (`gh api repos/nflverse/<repo>/rules/branches/<branch>`). A required
   review means the merge needs `--admin`.
3. **Read the workflows and scripts.** For each workflow: what it uploads
   where (`repo =` / `release_tag =` in `nflverse_save()` /
   `nflverse_upload()`; the default repo is nflverse-data), which secrets it
   needs, whether it commits files, whether anything reads private repos at
   runtime, and whether scripts use `pkgload::load_all()` or the installed
   package (`pkg::` → `install-local: true`).
4. **Job durations.** The longest jobs of the last runs, per step. So far
   every 20–50 min job was `setup-r` / `setup-r-dependencies` hanging, not
   the release step. Release steps over ~50 min need splitting (1-hour app
   tokens).
5. **Rewrite**, keeping workflow file names and dispatch inputs (guga's cron
   jobs dispatch them):
   - `container: ghcr.io/nflverse/r-runner:latest`, `nflverse/actions/setup@v1`
     with the GitHub packages (table below), `install-local` if needed.
   - Private packages: `app-token` with `repositories: <the private repos>`
     (contents read) → `setup`'s `github-pat`.
   - Upload: `app-token` with `contents: write` and exactly the repos it
     writes to, **after** `setup`, set as `GH_TOKEN` (plus `GITHUB_PAT` if
     piggyback or `gh::gh_token()` is used) **only on the release step**.
   - Other secrets only on the step that needs them. `permissions: contents:
     read` unless the job commits (then `contents: write` + `commit-and-push`).
   - Season matrices: `nflverse/actions/season-matrix` with the old
     first season (and `roster: true` where `get_current_season(roster = TRUE)`).
   - Crons off `:00`. Delete the heartbeat workflow and `.heartbeat`.
6. **Org secret visibility.** Add the repo to `NFLVERSE_APP_PRIVATE_KEY`:
   `gh api -X PUT orgs/nflverse/actions/secrets/NFLVERSE_APP_PRIVATE_KEY/repositories/<repo id>`.
7. **Commit and verify.** Stage everything (`git status`: first column), push,
   then check the PR's files on GitHub (`gh api repos/.../pulls/<n>/files`).
8. **Test run from the branch** (`gh workflow run <file> --ref <branch>`).
   Writes to real releases, so only with the user's go-ahead. Check: all jobs
   green, no annotations, uploads show `nflverse-actions[bot]` as uploader.
9. **Merge** (`--admin` only with the user's go-ahead). Then delete the
   heartbeat branch after checking it only has heartbeat commits
   (`gh api repos/<repo>/compare/<branch>...heartbeat`), and update the table
   below.

Template for an update job (see ngs-data `update_ngs.yaml` or
nflverse-players `update_players.yaml` for complete examples):

```yaml
    runs-on: ubuntu-latest
    container: ghcr.io/nflverse/r-runner:latest
    steps:
      - id: read-token            # only with private packages
        uses: nflverse/actions/app-token@v1
        with:
          client-id: ${{ vars.NFLVERSE_APP_CLIENT_ID }}
          private-key: ${{ secrets.NFLVERSE_APP_PRIVATE_KEY }}
          repositories: nflapi
      - uses: nflverse/actions/setup@v1
        with:
          packages: nflverse/nflapi nflverse/nflverse-data nflverse/nflreadr
          install-local: true
          github-pat: ${{ steps.read-token.outputs.token }}
      - id: upload-token
        uses: nflverse/actions/app-token@v1
        with:
          client-id: ${{ vars.NFLVERSE_APP_CLIENT_ID }}
          private-key: ${{ secrets.NFLVERSE_APP_PRIVATE_KEY }}
          repositories: nflverse-data   # exactly the repos it writes to
          contents: write
      - name: Release
        run: Rscript exec/update.R
        env:
          GH_TOKEN: ${{ steps.upload-token.outputs.token }}
```

## Repo migration order

Setup / total seconds from the latest successful run before migration.

| # | Repo / workflow | Setup / total | Packages for `setup` | Notes |
|---|---|---|---|---|
| 1 | nflverse-pbp `update_data`, `update_teams_color_logos` | 26–31 / 61–72 (own image already) | `nflverse/nflfastR nflverse/nflreadr nflverse/nflverse-data` | **Done** (#108, #109, 2026-11-27; jobs 53–70s, image pull + setup 27–40s). App tokens for all uploads (nflverse-data, nflverse-pbp), no PAT left. Old `nflverse-pbp` image package deleted |
| 2 | nflverse-pbp-internal `release_raw_pbp` (every 15 min), `refresh_raw_pbp` | 62 / 70 | `nflverse/nflapi nflverse/nflverse-data nflverse/nflreadr`, `install-local: true` | **Done** (nflverse-pbp-internal#2, 2026-11-27): ~40s per run (pull 13–21s, setup 18–21s incl. building nflapi). First repo on app tokens: read for nflapi in setup, write to nflverse-pbp only on the release step (uploads show as `nflverse-actions[bot]`). No PAT left |
| 3 | ngs-data `update_ngs` | 73–109 per job | `nflverse/nflverse-data nflverse/nflreadr` | **Done** (ngs-data#7, 2026-11-27): jobs 27–39s. The 25–54 min jobs were `setup-r` / `setup-r-dependencies` hanging, not the release step. App tokens: this repo (`ngs-season`) for the season jobs, nflverse-data (`nextgen_stats`) for combine |
| 3 | nflverse-players `update_players` | 64–96 per job, 12+ jobs | `nflverse/nflapi nflverse/nflverse-espn nflverse/nflverse-data nflverse/nflreadr nflverse/undercover`, `install-local: true` | **Done** (nflverse-players#33, 2026-11-27): 14 jobs at 44–65s, setup 15–22s. Long jobs (up to 33 min) were setup hangs. App tokens: read for nflapi/nflverse-espn, write to this repo (+ nflverse-data for `build_dataset`). R-CMD-check / test-package use a read app token. Open: the test "manual overwrite is clean" fails on master (`inst/players_manual_overwrite.json` needs cleaning) |
| 3 | nflverse-ftn (4 workflows) | 81 / 91 | `nflverse/nflverse-data nflverse/nflreadr`, `install-local: true` | **Done** (nflverse-ftn#10, 2026-11-27): ~25s per run (was 80–94s, outliers up to 23 min). App tokens per workflow for nflverse-ftn (`raw`) and/or nflverse-data (`ftn_charting`, `pbp_participation`). Real job names. `rebuild` has never run: its token lasts 1 hour |
| 4 | nflverse-rosters (rosters, injuries, depth_charts, officials) | 65–103 | nflapi, ngsscrapR, nflverse-espn, nflverse-players, nflverse-data, nflreadr (depth charts: nfldx secrets) | Consider merging the three 07:07 workflows into one |
| 4 | nflverse-pfr (snap_counts, adv_stats) | 63–86 | `nflverse/nflverse-data nflverse/undercover`, `install-local: true` | Crons on `:00`: offset them |
| 4 | rotc (otc, player_ids, player_details) | 74 / 180 | `nflverse/nflverse-data nflverse/nflreadr`, `install-local: true` | |
| 4 | espnscrapeR-data `update_qbr` | 73 / 138 | `jthomasmock/espnscrapeR nflverse/nflverse-data nflverse/nflreadr` | fpi/winrate workflow runs on macOS for no reason |
| 4 | nfldata `release_games`, `release_trades` | | `nflverse/nflverse-data` | |
| 4 | nflverse-data `run_archive`, `run_s3_archive` | | `nflverse/nflverse-data nflverse/nflreadr`, `install-local: true` | rclone step → `install-rclone` |

## Gotchas learned

- `run:` steps in container jobs use `sh`, not bash: set
  `defaults: run: shell: bash` when using bash syntax.
- The image is public: no `credentials:` block needed on `container:`.
- pak drops `RemoteSha` for repo installs; the Dockerfile reinstalls
  r-universe packages with `install.packages()` to keep the commit, which
  `setup` compares with GitHub HEAD. The image build fails if that breaks.
- `setup` never fails the job; problems are warning annotations plus a job
  summary table. A failing update script after it is the real signal.
- pak updates already installed system requirements on CI (`CI=true`):
  apt-get update + install in every source build, even with nothing
  missing. The image sets `PKG_SYSREQS_UPDATE=false`; missing ones are
  still installed.
- Many data repos have a repository ruleset "protecc" (1 approval
  required, admins may bypass) besides or instead of classic branch
  protection. Check `gh api repos/nflverse/<repo>/rules/branches/<branch>`,
  not only `.../branches/<branch>/protection`, before planning a merge.
- Most data workflows are started by guga31bb's cron jobs via
  `gh workflow run` (GitHub's schedules are unreliable), so runs show up as
  `workflow_dispatch`. When a migration renames a workflow or changes its
  inputs, tell guga.
- `GITHUB_PAT` for `setup` must never be the upload token: `setup` installs
  unpinned GitHub code.
- Org is on GitHub Free: 20 concurrent jobs org-wide. Shorter jobs and
  offset crons (not `:00`) reduce schedule delays.
