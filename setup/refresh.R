# Run by setup/action.yml inside ghcr.io/nflverse/r-runner.
#
# 1. Keeps the GitHub packages in NFLVERSE_PACKAGES at their latest commit.
#    For each package we compare the commit it was built from (RemoteSha in its
#    DESCRIPTION) with GitHub HEAD:
#      - installed commit == HEAD: nothing to do
#      - otherwise install the r-universe binary if r-universe has the package
#      - still behind HEAD (r-universe hasn't built the push yet, or the
#        package isn't on r-universe, e.g. private packages): install from
#        GitHub with pak. These packages are pure R, so that takes seconds.
# 2. NFLVERSE_INSTALL_DEPS: installs dependencies of the checked out repo's
#    DESCRIPTION that are missing from the image or too old. A no-op (no pak
#    call) if the image has everything.
# 3. NFLVERSE_INSTALL_LOCAL: installs the checked out repo as a package,
#    without dependencies.
#
# This script never fails the job. Problems are reported as GitHub Actions
# warning annotations and the job continues with what's installed. The
# script that runs next will fail loudly if something important is missing.

# base R has %||% since 4.4
if (!exists("%||%", baseenv())) `%||%` <- function(x, y) if (is.null(x)) y else x

env_flag <- function(x) tolower(Sys.getenv(x, "false")) %in% c("true", "1", "yes")

refs <- strsplit(trimws(Sys.getenv("NFLVERSE_PACKAGES")), "[[:space:],]+")[[1]]
refs <- refs[nzchar(refs)]
install_deps <- env_flag("NFLVERSE_INSTALL_DEPS")
install_local <- env_flag("NFLVERSE_INSTALL_LOCAL")

# Workflow commands end at a newline, so %, \r and \n must be escaped
warn <- function(title, ...) {
  msg <- paste0(...)
  msg <- gsub("\033\\[[0-9;]*m", "", msg)
  msg <- gsub("%", "%25", msg, fixed = TRUE)
  msg <- gsub("\r", "%0D", msg, fixed = TRUE)
  msg <- gsub("\n", "%0A", msg, fixed = TRUE)
  cat("::warning title=", title, "::", msg, "\n", sep = "")
}

info <- function(...) cat("ℹ", ..., "\n")

# Reports warnings (install.packages()) and errors (pak) as annotations
# instead of failing the job
annotate_failures <- function(expr, title = "nflverse setup") {
  tryCatch(
    withCallingHandlers(expr, warning = function(w) {
      warn(title, conditionMessage(w))
      invokeRestart("muffleWarning")
    }),
    error = function(e) warn(title, conditionMessage(e))
  )
  invisible()
}

# gh reads GITHUB_PAT
github_api <- function(endpoint) {
  tryCatch(
    gh::gh(endpoint),
    error = function(e) {
      warn("GitHub API", "Request ", endpoint, " failed: ", conditionMessage(e))
      NULL
    }
  )
}

# NA if the package or its RemoteSha field is missing
installed_sha <- function(pkg) {
  as.character(suppressWarnings(utils::packageDescription(pkg, fields = "RemoteSha")))
}

# Unknown HEAD (API error) or unknown installed commit counts as behind
behind <- function(pkgs) {
  pkgs[vapply(pkgs, function(p) {
    head <- remotes$head[remotes$package == p]
    sha <- installed_sha(p)
    is.na(head) || is.na(sha) || head != sha
  }, logical(1))]
}

# Loads pkg in a fresh R process. In this session a failed load leaves its
# outdated dependencies loaded, so a check after a repair would fail again,
# and pak would install over loaded namespaces. NA if pkg loads, otherwise
# the error output.
load_error <- function(pkg) {
  out <- suppressWarnings(system2(
    file.path(R.home("bin"), "Rscript"),
    c("-e", shQuote(sprintf("loadNamespace('%s')", pkg))),
    stdout = TRUE,
    stderr = TRUE
  ))
  if (is.null(attr(out, "status"))) NA_character_ else paste(out, collapse = "\n")
}

load_errors <- function(pkgs) {
  errors <- vapply(pkgs, load_error, character(1))
  errors[!is.na(errors)]
}

# pak ref "pkg=owner/repo", so pak installs under the right name
pak_refs <- function(pkgs) {
  i <- match(pkgs, remotes$package)
  paste0(remotes$package[i], "=", remotes$repo[i])
}

# Parses Depends/Imports/LinkingTo of a DESCRIPTION file into package names
# and version requirements
description_deps <- function(path) {
  d <- read.dcf(path)
  fields <- intersect(c("Depends", "Imports", "LinkingTo"), colnames(d))
  deps <- trimws(unlist(strsplit(d[1, fields], ",")))
  deps <- deps[nzchar(deps)]
  out <- data.frame(
    package = trimws(sub("[(].*", "", deps)),
    op = ifelse(grepl("[(]", deps), trimws(sub(".*[(]\\s*([<>=]+).*", "\\1", deps)), NA),
    version = ifelse(grepl("[(]", deps), trimws(sub(".*[(]\\s*[<>=]+\\s*([^)]+)[)].*", "\\1", deps)), NA),
    stringsAsFactors = FALSE
  )
  base <- rownames(utils::installed.packages(priority = "base"))
  out[!out$package %in% c("R", base), , drop = FALSE]
}

dep_satisfied <- function(package, op, version) {
  if (!nzchar(system.file(package = package))) return(FALSE)
  if (is.na(op)) return(TRUE)
  installed <- utils::packageVersion(package)
  required <- package_version(version)
  switch(op,
    ">=" = installed >= required,
    ">" = installed > required,
    "==" = installed == required,
    "<=" = installed <= required,
    "<" = installed < required,
    TRUE
  )
}

# 1. GitHub packages -----------------------------------------------------------

# "owner/repo" or "pkg=owner/repo"
remotes <- data.frame(
  package = ifelse(grepl("=", refs), sub("=.*", "", refs), NA_character_),
  repo = sub(".*=", "", refs),
  head = NA_character_,
  stringsAsFactors = FALSE
)

for (i in seq_len(nrow(remotes))) {
  repo <- remotes$repo[i]
  remotes$head[i] <- github_api(paste0("/repos/", repo, "/commits/HEAD"))$sha %||% NA_character_
  if (is.na(remotes$package[i])) {
    desc <- github_api(paste0("/repos/", repo, "/contents/DESCRIPTION"))
    if (!is.null(desc)) {
      txt <- rawToChar(jsonlite::base64_dec(gsub("\n", "", desc$content)))
      remotes$package[i] <- read.dcf(textConnection(txt), fields = "Package")[1, 1]
    }
  }
}

unknown <- remotes$repo[is.na(remotes$package)]
if (length(unknown) > 0) {
  warn(
    "nflverse setup", "Skipping ", paste(unknown, collapse = ", "),
    ": can't read the package name from GitHub. If the repo is private, ",
    "pass a token with read access as github-pat, or name the package as pkg=owner/repo."
  )
}
remotes <- remotes[!is.na(remotes$package), , drop = FALSE]
pkgs <- remotes$package

todo <- behind(pkgs)
if (length(todo) > 0) {
  universe <- tryCatch(
    rownames(utils::available.packages(repos = getOption("repos")[["nflverse"]])),
    error = function(e) character()
  )
  from_universe <- intersect(todo, universe)
  if (length(from_universe) > 0) {
    info("Installing r-universe binaries of", paste(from_universe, collapse = ", "))
    annotate_failures(utils::install.packages(from_universe))
  }
}

# Only packages with a known HEAD can be compared after the install
todo <- behind(remotes$package[!is.na(remotes$head)])
if (length(todo) > 0) {
  info("Installing", paste(todo, collapse = ", "), "from GitHub (no r-universe binary of the latest commit)")
  annotate_failures(pak::pkg_install(pak_refs(todo), upgrade = FALSE))
}

# 2. Dependencies of the checked out repo ------------------------------------

has_description <- file.exists("DESCRIPTION")
local_pkg <- if (has_description) read.dcf("DESCRIPTION", fields = "Package")[1, 1] else NA

if (install_deps && has_description) {
  deps <- description_deps("DESCRIPTION")
  ok <- mapply(dep_satisfied, deps$package, deps$op, deps$version)
  missing <- deps$package[!ok]
  if (length(missing) > 0) {
    info("Installing dependencies missing from the image:", paste(missing, collapse = ", "))
    annotate_failures(pak::local_install_deps(".", upgrade = FALSE))
  } else {
    info("The image has all dependencies of", local_pkg)
  }
}

# 3. The checked out repo as a package ---------------------------------------

if (install_local) {
  if (!has_description) {
    warn("nflverse setup", "install-local is true but there is no DESCRIPTION file in ", getwd())
  } else {
    info("Installing", local_pkg, "from the checked out repo")
    annotate_failures(utils::install.packages(".", repos = NULL, type = "source", quiet = TRUE))
  }
}

# Load check -----------------------------------------------------------------

# install.packages() installs missing dependencies but doesn't upgrade
# outdated ones. If a new package version requires a newer dependency than
# the image has, loading fails. pak resolves and upgrades what's needed.
check <- c(pkgs, if (install_local && has_description) local_pkg)
errors <- load_errors(check)
if (length(errors) > 0) {
  for (pkg in names(errors)) {
    warn(
      "Outdated docker image", pkg, " can't be loaded, probably because it ",
      "needs newer dependencies than the image has. Trying to repair. Please ",
      "rebuild the r-runner image in nflverse/actions.\n", errors[[pkg]]
    )
  }
  # GitHub refs, so pak doesn't swap a package installed from GitHub above
  # for an older r-universe binary
  if (length(pkgs) > 0) annotate_failures(pak::pkg_install(pak_refs(pkgs), upgrade = FALSE))
  if (has_description && (install_deps || install_local)) {
    annotate_failures(pak::local_install_deps(".", upgrade = FALSE))
  }
  errors <- load_errors(names(errors))
  for (pkg in names(errors)) {
    warn("nflverse setup", pkg, " still can't be loaded:\n", errors[[pkg]])
  }
}

# Summary --------------------------------------------------------------------

rows <- character()
for (i in seq_len(nrow(remotes))) {
  pkg <- remotes$package[i]
  head <- remotes$head[i]
  sha <- installed_sha(pkg)
  version <- tryCatch(format(utils::packageVersion(pkg)), error = function(e) "not installed")
  status <- if (is.na(head)) {
    "GitHub HEAD unknown"
  } else if (identical(sha, head)) {
    "GitHub HEAD"
  } else {
    warn("nflverse setup", pkg, " is not at GitHub HEAD ", substr(head, 1, 7))
    "NOT GitHub HEAD"
  }
  info(sprintf("%s %s @ %s (%s)", pkg, version, substr(sha, 1, 7), status))
  rows <- c(rows, sprintf("| %s | %s | `%s` | %s |", pkg, version, substr(sha, 1, 7), status))
}

summary_file <- Sys.getenv("GITHUB_STEP_SUMMARY")
if (nzchar(summary_file) && length(rows) > 0) {
  cat(
    "### nflverse packages",
    "",
    "| Package | Version | Commit | Status |",
    "|---|---|---|---|",
    rows,
    "",
    sep = "\n", file = summary_file, append = TRUE
  )
}
