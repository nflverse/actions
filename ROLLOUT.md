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
- Dedicated tokens: upload token (`NFLVERSE_GH_TOKEN`) only on the step that
  uploads; a read-only token for installing private packages; a separate
  Actions-only token for `enable-workflows`.

## Done

- [x] Repo, r-runner image (built, public), `setup`, `season-matrix`,
      `commit-and-push`, `install-rclone`, `upload-timestamps`,
      `enable-workflows`, Dependabot, tests. Tagged `v1` at 1722d56.
- [x] Tests green on the runner and in the image. Setup in the image: 29–38s
      per job including the image pull.
- [x] Tokens created 2026-11-27: `NFLVERSE_WORKFLOWS_TOKEN` (secret in this
      repo, Actions r/w on all org repos, expires after 1 year) and
      `NFLVERSE_READ_TOKEN` (org secret, Contents read on nflapi, ngsscrapR,
      nflverse-espn, nfldx, expires after 1 year). Renew both before they expire.
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
- [x] Private package path tested (`setup-private` job): nflapi installed
      from GitHub at HEAD in 18s.
- [x] `upload-timestamps` tested 2026-11-27 (nflverse-pbp run 46053835741 from
      the PR #108 branch): 4 releases updated, only those with new files.

## Open

- [ ] Add `libcurl4-openssl-dev libssl-dev libicu-dev` to the image: pak
      runs apt-get for them (~4s) on every GitHub source install of a private
      package. Seen in every nflverse-pbp-internal run (every 15 min).
- [ ] Migrate repos (below). After each repo uses the central jobs, delete
      its heartbeat workflow (only once `enable-workflows` runs).
- [ ] Data repos: switch `NFLVERSE_READ_TOKEN` and the upload token
      `NFLVERSE_GH_TOKEN` to `app-token` during each repo's migration
      (done: nflverse-pbp-internal; nflverse-pbp still uses
      `NFLVERSE_GH_TOKEN`). Add the
      repo to the visibility of the org secret `NFLVERSE_APP_PRIVATE_KEY`
      first. Release steps must stay under 1 hour per token (ngs-data and
      nflverse-data jobs run 42–54 min): split them or mint the token right
      before the upload. Revoke both PATs once nothing uses them (#1).
- [ ] Afterwards: retire the `nflverse.workflows` R package (nflverse-workflows
      repo) once nothing calls it.

## Repo migration order

Setup / total seconds from the latest successful run before migration.

| # | Repo / workflow | Setup / total | Packages for `setup` | Notes |
|---|---|---|---|---|
| 1 | nflverse-pbp `update_data`, `update_teams_color_logos` | 26–31 / 61–72 (own image already) | `nflverse/nflfastR nflverse/nflreadr nflverse/nflverse-data` | **Done** (#108, merged 2026-11-27; jobs 53–70s, image pull + setup 27–40s). Open: delete the `ghcr.io/nflverse/nflverse-pbp` package if it's private. Switch from its own image + `exec/refresh_nflverse.R` to r-runner + `setup`; `upload_timestamps` job → action; then delete `docker/` and `build_image.yaml` there |
| 2 | nflverse-pbp-internal `release_raw_pbp` (every 15 min), `refresh_raw_pbp` | 62 / 70 | `nflverse/nflapi nflverse/nflverse-data nflverse/nflreadr`, `install-local: true` | **Done** (nflverse-pbp-internal#2, 2026-11-27): ~40s per run (pull 13–21s, setup 18–21s incl. building nflapi). First repo on app tokens: read for nflapi in setup, write to nflverse-pbp only on the release step (uploads show as `nflverse-actions[bot]`). No PAT left |
| 3 | ngs-data `update_ngs` | 73–109 per job | `nflverse/nflverse-data nflverse/nflreadr` | Setup job → `season-matrix` (first-season 2016) |
| 3 | nflverse-players `update_players` | 64–96 per job, 12+ jobs | `nflverse/nflapi nflverse/nflverse-espn nflverse/nflverse-data nflverse/nflreadr nflverse/undercover`, `install-local: true` | `season-matrix` with `roster: true`, first-season 1999 |
| 3 | nflverse-ftn (4 workflows) | 81 / 91 | `nflverse/nflverse-data nflverse/nflreadr`, `install-local: true` | `update_participation` → `season-matrix` (2023). Job names are leftover "R-CMD-check" |
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
- `GITHUB_PAT` for `setup` must never be the upload token: `setup` installs
  unpinned GitHub code.
- Org is on GitHub Free: 20 concurrent jobs org-wide. Shorter jobs and
  offset crons (not `:00`) reduce schedule delays.
