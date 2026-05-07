#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
# SC2016 disabled: error messages embed literal backticks for markdown
# rendering, not command substitution.
#
# validate.sh — confirms the runner has the binaries the action needs.
#
# This runs as its own composite step (before purge.sh) so that missing
# dependencies surface as a clear, fast failure instead of a cryptic error
# deep inside the purge logic. It only checks the runtime; input validation
# happens inside purge.sh after env vars are normalized.

set -Eeuo pipefail

require_binary() {
  local bin="$1"
  local hint="$2"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    printf '::error::Required dependency `%s` not found on this runner. %s\n' \
      "${bin}" "${hint}" >&2
    exit 1
  fi
}

# curl and jq are present by default on `ubuntu-latest`, `macos-latest`, and
# `windows-latest` runners. Self-hosted runners may need to install them.
require_binary curl "Install via your package manager (e.g. \`apt-get install -y curl\`)."
require_binary jq   "Install via your package manager (e.g. \`apt-get install -y jq\`)."

# The action targets bash 3.2+ to support macOS's default `/bin/bash`. We
# deliberately avoid bash 4-only features (`${var,,}`, associative arrays,
# `mapfile`, etc.) so users on stock macOS or stripped self-hosted runners
# work without installing Homebrew bash.
if ((BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2))); then
  printf '::error::Bash %s detected; FlareOps requires bash >= 3.2.\n' \
    "${BASH_VERSION}" >&2
  exit 1
fi

printf '::debug::FlareOps runtime validation passed (curl=%s, jq=%s, bash=%s)\n' \
  "$(curl --version | head -n1)" \
  "$(jq --version)" \
  "${BASH_VERSION}"
