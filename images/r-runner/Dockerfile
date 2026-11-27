# Shared runtime image for nflverse data update workflows.
# R + gh cli + git + the R packages the data repos use, preinstalled as
# binaries, so update jobs don't spend a minute or more installing R and
# packages. Built and pushed to ghcr.io/nflverse/r-runner by
# .github/workflows/build-r-runner.yaml
#
# Only public packages go into this image. Private nflverse packages (nflapi,
# ngsscrapR, nflverse.espn, nfldx, ...) are installed at job time by the setup
# action. Their dependencies are preinstalled here, so that takes seconds.

# rocker/r-ver = R on Ubuntu LTS, with CRAN set to Posit Public Package
# Manager binaries. Pinned to the R minor version: the weekly rebuild picks up
# R patch releases, a new minor version (often with a new Ubuntu base) comes
# as a Dependabot PR and is tested before it becomes latest.
FROM rocker/r-ver:4.6

LABEL org.opencontainers.image.source="https://github.com/nflverse/actions"
LABEL org.opencontainers.image.description="R runtime for nflverse data update workflows"
LABEL org.opencontainers.image.licenses="MIT"

# gh: release uploads (nflversedata) and API calls in workflows
# git: actions/checkout falls back to a tarball download without git, which
#      breaks workflows that commit files
# jq: JSON handling in workflow shell steps (e.g. the season-matrix action)
# unzip: rclone and other release downloads
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl gpg git jq unzip \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
     > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

RUN Rscript -e 'install.packages("pak", repos = sprintf("https://r-lib.github.io/p/pak/stable/%s/%s/%s", .Platform$pkgType, R.Version()$os, R.Version()$arch))'

# nflverse packages come as Linux binaries from r-universe. The plain
# https://nflverse.r-universe.dev repo serves source packages on Linux (pak
# would e.g. compile gsisdecoder), the binaries live under
# /bin/linux/<ubuntu codename>-<arch>/<R minor version>/. rocker sets the CRAN
# repo (Posit Public Package Manager binaries) in Rprofile.site, we put
# r-universe in front of it under the name "nflverse". The setup action relies
# on that name.
RUN . /etc/os-release && export VERSION_CODENAME \
  && RUNIVERSE=$(Rscript -e 'cat(sprintf("https://nflverse.r-universe.dev/bin/linux/%s-%s/%s.%s", Sys.getenv("VERSION_CODENAME"), R.version$arch, R.version$major, sub("[.].*", "", R.version$minor)))') \
  && echo "options(repos = c(nflverse = '$RUNIVERSE', getOption('repos')))" \
     >> "$(R RHOME)/etc/Rprofile.site" \
  && Rscript -e 'print(getOption("repos"))'

# packages.txt lists what goes into the image, one package per line.
# pak (not install.packages) because it also installs the system libraries
# the binaries need.
# pak replaces RemoteSha (the GitHub commit r-universe built a package from)
# with the version number. The setup action compares RemoteSha with GitHub
# HEAD, so we reinstall every package that comes from r-universe with
# install.packages(), which keeps r-universe's DESCRIPTION as is.
# Help pages, HTML docs and vignettes are removed in the same layer to make the
# image smaller to pull. Jobs never read them.
COPY packages.txt /tmp/build/packages.txt
RUN Rscript -e ' \
    pkgs <- readLines("/tmp/build/packages.txt"); \
    pkgs <- trimws(sub("#.*", "", pkgs)); \
    pkgs <- pkgs[nzchar(pkgs)]; \
    pak::pkg_install(pkgs); \
    pak::cache_clean(); \
    universe <- rownames(available.packages(repos = getOption("repos")[["nflverse"]])); \
    reinstall <- intersect(pkgs, universe); \
    cat("Reinstalling from r-universe to keep RemoteSha:", reinstall, "\n"); \
    install.packages(reinstall); \
  ' \
  && find "$(Rscript -e 'cat(.libPaths()[1])')" -mindepth 2 -maxdepth 2 -type d \
       \( -name help -o -name html -o -name doc \) -exec rm -rf {} + \
  && rm -rf /tmp/build /tmp/Rtmp* /var/lib/apt/lists/*

# Smoke test: fail the build if a package is missing or can't be loaded, or if
# an r-universe package lost its commit SHA
COPY packages.txt /tmp/packages.txt
RUN gh --version && git --version && jq --version \
  && Rscript -e ' \
    pkgs <- readLines("/tmp/packages.txt"); \
    pkgs <- trimws(sub("#.*", "", pkgs)); \
    pkgs <- pkgs[nzchar(pkgs)]; \
    universe <- rownames(available.packages(repos = getOption("repos")[["nflverse"]])); \
    for (p in c(pkgs, "pak")) { \
      loadNamespace(p); \
      cat(p, format(packageVersion(p)), packageDescription(p)$RemoteSha, "\n") \
    }; \
    for (p in intersect(pkgs, universe)) { \
      sha <- packageDescription(p, fields = "RemoteSha"); \
      if (!grepl("^[0-9a-f]{40}$", sha)) { \
        stop(p, " has RemoteSha ", sha, " instead of a commit. ", \
             "Did the install.packages() reinstall fail?") \
      } \
    } \
  ' \
  && rm /tmp/packages.txt

CMD ["R"]
