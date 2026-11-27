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

## Open

- [ ] Create secret `NFLVERSE_WORKFLOWS_TOKEN` in this repo (fine-grained,
      nflverse org, all repos, only "Actions: Read and write"). Then run
      "Enable workflows" manually with `dry-run`, then without.
- [ ] Create `NFLVERSE_READ_TOKEN` (fine-grained, read-only "Contents" on
      nflapi, ngsscrapR, nflverse-espn, nfldx), ideally as an org secret.
- [ ] `upload-timestamps` is untested (writes to real releases). First real
      test: when nflverse-pbp switches its `upload_timestamps` job to it.
- [ ] `enable-workflows` has never run.
- [ ] Migrate repos (below). After each repo uses the central jobs, delete
      its heartbeat workflow (only once `enable-workflows` runs).
- [ ] Afterwards: retire the `nflverse.workflows` R package (nflverse-workflows
      repo) once nothing calls it.

## Repo migration order

Setup / total seconds from the latest successful run before migration.

| # | Repo / workflow | Setup / total | Packages for `setup` | Notes |
|---|---|---|---|---|
| 1 | nflverse-pbp `update_data`, `update_teams_color_logos` | 26–31 / 61–72 (own image already) | `nflverse/nflfastR nflverse/nflreadr nflverse/nflverse-data` | Switch from its own image + `exec/refresh_nflverse.R` to r-runner + `setup`; `upload_timestamps` job → action; then delete `docker/` and `build_image.yaml` there |
| 2 | nflverse-pbp-internal `release_raw_pbp` (every 15 min), `refresh_raw_pbp` | 62 / 70 | `nflverse/nflapi nflverse/nflverse-data nflverse/nflreadr`, `install-local: true` | Biggest gain. First private package (needs `NFLVERSE_READ_TOKEN`). Commit step → `commit-and-push` |
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
