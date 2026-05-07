#!/usr/bin/env bash
# shellcheck shell=bash
#
# helpers.sh — shared logging, masking, retry, and HTTP helpers for the
# FlareOps purge-cache action.
#
# This file is intended to be sourced from purge.sh. It must remain free of
# top-level side effects (no `exit`, no API calls) so it can be sourced from
# tests as well.

# ---------- logging ----------------------------------------------------------
#
# All log output goes to stderr so stdout stays clean for any future use that
# might want to capture structured output (e.g. piping JSON). GitHub Actions
# renders stderr identically to stdout in logs, so this has no UX impact.

flareops::ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

flareops::log() {
  # Args: <level> <message...>
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(flareops::ts)" "${level}" "$*" >&2
}

flareops::info()  { flareops::log "INFO"  "$@"; }
flareops::warn()  { flareops::log "WARN"  "$@"; }
flareops::error() { flareops::log "ERROR" "$@"; }

flareops::debug() {
  # Debug logs are only emitted when FLAREOPS_DEBUG=true. The check is on the
  # raw env var rather than a derived boolean so this works whether or not
  # purge.sh has finished normalizing inputs.
  if [[ "${FLAREOPS_DEBUG:-false}" == "true" ]]; then
    flareops::log "DEBUG" "$@"
  fi
}

# ---------- secret masking ---------------------------------------------------
#
# GitHub Actions auto-masks values that are referenced as `${{ secrets.X }}`
# but values that are derived/transformed (e.g. concatenated into headers) do
# not get masked automatically. We emit `::add-mask::` workflow commands so
# Actions hides them from logs even if a misbehaving curl prints them.

flareops::mask() {
  local value="$1"
  # Empty values can't be masked and emitting `::add-mask::` with empty input
  # would be a no-op that just clutters logs.
  if [[ -n "${value}" ]]; then
    printf '::add-mask::%s\n' "${value}"
  fi
}

# ---------- input parsing ----------------------------------------------------
#
# Cloudflare expects JSON arrays. Action inputs come in as free-form strings
# where users typically separate values with newlines (YAML `|` blocks) but
# may also use commas. We accept both, trim whitespace, drop empty entries,
# and emit one entry per line on stdout so callers can pipe into jq.

flareops::split_list() {
  local raw="$1"
  # Replace commas with newlines, then read line-by-line so we can trim and
  # filter empties without losing entries that legitimately contain spaces
  # (e.g. URLs with %20). We deliberately do not split on whitespace.
  printf '%s\n' "${raw}" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' \
    || true
}

# Newline-only splitter. Used for inputs whose entries can legitimately
# contain commas — currently just `files`, where each entry may be a JSON
# object that has commas inside it. Comma-separation isn't supported for
# such entries; users must use newlines.
flareops::split_lines_only() {
  local raw="$1"
  printf '%s\n' "${raw}" \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' \
    || true
}

# Convert a newline-separated list to a JSON array. Each entry is encoded as a
# JSON string by jq, which handles escaping of quotes, backslashes, and unicode
# correctly — far safer than hand-rolling string concatenation.
flareops::list_to_json_string_array() {
  local raw="$1"
  flareops::split_list "${raw}" \
    | jq -R . \
    | jq -s .
}

# Files input may be either plain URLs OR pre-formed JSON objects (when the
# user wants to attach headers per Cloudflare's files-with-headers schema).
# We detect JSON-shaped entries by their leading `{` and pass them through
# as-is; everything else is treated as a string URL.
flareops::files_to_json_array() {
  local raw="$1"
  # NOTE: we use newline-only splitting here (not split_list) because JSON
  # object entries legitimately contain commas. Users mixing plain URLs and
  # JSON file-with-headers objects must separate them with newlines.
  # The detection inside jq lets us mix string and object entries safely
  # without a second pass in shell.
  flareops::split_lines_only "${raw}" \
    | jq -R 'if startswith("{") then fromjson else . end' \
    | jq -s .
}

# ---------- backoff ----------------------------------------------------------
#
# Exponential backoff with full jitter. Returning 0 unconditionally keeps the
# function safe to use under `set -e` even if `awk`/`shuf` is missing.

flareops::sleep_backoff() {
  # Args: <attempt> <base_delay_seconds>
  local attempt="$1"
  local base="$2"
  local max=$((base * (1 << attempt)))
  # Use awk for a portable random in [0, max). RANDOM is bash-specific but
  # bounded to 32767, which is fine here; we use it as a jitter source.
  local jitter=$((RANDOM % (max + 1)))
  flareops::debug "Backing off ${jitter}s (attempt=${attempt}, base=${base}s, max=${max}s)"
  sleep "${jitter}"
  return 0
}

# ---------- HTTP -------------------------------------------------------------
#
# flareops::http_post performs a single POST with a timeout and writes the
# response body to a tempfile. It echoes the HTTP status code on stdout and
# the response file path on fd 3 (chosen via a global var because bash can't
# return two values cleanly).
#
# We intentionally do NOT pass auth via curl's --user since that would leak
# the api_key into ps(1) output on shared runners. Headers are passed via
# stdin-read variables instead.

# Caller-provided globals:
#   FLAREOPS_RESPONSE_BODY_FILE — set by this function for the caller to read
#   FLAREOPS_RESPONSE_HEADERS_FILE — set by this function for the caller to read

flareops::http_post() {
  # Args: <url> <auth_header_1> [auth_header_2] <body_json>
  # We pass headers explicitly rather than from env so masking is the caller's
  # responsibility and this function stays a thin wrapper.
  local url="$1"
  local auth1="$2"
  local auth2="$3"
  local body="$4"

  local body_file headers_file
  body_file="$(mktemp)"
  headers_file="$(mktemp)"
  FLAREOPS_RESPONSE_BODY_FILE="${body_file}"
  FLAREOPS_RESPONSE_HEADERS_FILE="${headers_file}"

  # `--fail-with-body` (curl 7.76+) keeps the body on non-2xx, which we need
  # for surfacing Cloudflare error messages. We deliberately do NOT use
  # `--fail` (which discards the body on errors).
  local curl_args=(
    --silent
    --show-error
    --location
    --max-time "${FLAREOPS_TIMEOUT:-30}"
    --request POST
    --header "Content-Type: application/json"
    --header "Accept: application/json"
    --header "User-Agent: flareops-purge-cache/1.0 (+https://github.com/amitsdalal/FlareOps)"
    --output "${body_file}"
    --dump-header "${headers_file}"
    --write-out "%{http_code}"
  )

  if [[ -n "${auth1}" ]]; then
    curl_args+=(--header "${auth1}")
  fi
  if [[ -n "${auth2}" ]]; then
    curl_args+=(--header "${auth2}")
  fi

  # Pass the body via stdin to avoid putting it on the command line. URLs and
  # tags don't contain secrets, but bodies can contain them in future modules.
  local http_code
  http_code="$(printf '%s' "${body}" | curl "${curl_args[@]}" --data-binary @- "${url}" || true)"

  # If curl failed before getting a response (e.g. DNS failure), http_code is
  # empty. Normalize to "000" so callers can compare numerically.
  if [[ -z "${http_code}" ]]; then
    http_code="000"
  fi

  printf '%s' "${http_code}"
}

# Extract the cf-ray request ID from a header dump file. Returns empty string
# if not present (e.g. on local DNS failure).
flareops::extract_cf_ray() {
  local headers_file="$1"
  if [[ -f "${headers_file}" ]]; then
    # Header keys are case-insensitive per RFC 7230. Cloudflare uses `cf-ray`
    # but we match case-insensitively to be safe.
    grep -iE '^cf-ray:' "${headers_file}" \
      | head -n1 \
      | sed -E 's/^[Cc][Ff]-[Rr][Aa][Yy]:[[:space:]]*//; s/[[:space:]]+$//' \
      || true
  fi
}

# ---------- retry wrapper ---------------------------------------------------
#
# flareops::with_retry runs a callback that performs a single HTTP attempt,
# inspects the result, and decides whether to retry. The callback must:
#   - print the HTTP code to stdout (last line)
#   - leave the response body in $FLAREOPS_RESPONSE_BODY_FILE
#
# We retry on:
#   - HTTP 000 (network/DNS failures)
#   - HTTP 408, 429, 5xx
# We do NOT retry on:
#   - 4xx other than 408/429 (auth errors, malformed payloads, etc.)
#   - 2xx (obviously)

flareops::should_retry() {
  local code="$1"
  case "${code}" in
    000|408|429|5*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- cleanup ----------------------------------------------------------

flareops::cleanup_tempfiles() {
  # Called from a trap in purge.sh. Best-effort: don't fail the action on
  # cleanup errors.
  if [[ -n "${FLAREOPS_RESPONSE_BODY_FILE:-}" && -f "${FLAREOPS_RESPONSE_BODY_FILE}" ]]; then
    rm -f "${FLAREOPS_RESPONSE_BODY_FILE}" || true
  fi
  if [[ -n "${FLAREOPS_RESPONSE_HEADERS_FILE:-}" && -f "${FLAREOPS_RESPONSE_HEADERS_FILE}" ]]; then
    rm -f "${FLAREOPS_RESPONSE_HEADERS_FILE}" || true
  fi
}
