#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source=./helpers.sh
# shellcheck disable=SC2016
# SC2016 disabled file-wide: this script emits ::error::/::warning:: workflow
# commands and markdown summary lines that contain literal backticks for
# rendering — they are NOT shell command substitutions.
#
# purge.sh — entry point for the FlareOps Cloudflare cache-purge action.
#
# Reads action inputs from FLAREOPS_* env vars (set by action.yml), validates
# them, builds the appropriate Cloudflare API payload, and performs one or
# more POST requests to /zones/<zone_id>/purge_cache with retries.
#
# This script writes its outputs to GITHUB_OUTPUT and uses ::error::/::warning::
# workflow commands so failures are surfaced cleanly in the Actions UI.

set -Eeuo pipefail

# Resolve the directory this script lives in so we can source siblings without
# relying on the caller's CWD. BASH_SOURCE[0] is the canonical way to do this.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./helpers.sh
source "${SCRIPT_DIR}/helpers.sh"

trap flareops::cleanup_tempfiles EXIT

# ---------- normalize inputs -------------------------------------------------
#
# action.yml passes inputs as env vars with a FLAREOPS_ prefix. We copy them
# to local vars so the rest of the script reads naturally and so we can apply
# defaults / lowercase booleans in one place.

ZONE_ID="${FLAREOPS_ZONE_ID:-}"
ZONE_IDS_RAW="${FLAREOPS_ZONE_IDS:-}"
PURGE_TYPE="${FLAREOPS_PURGE_TYPE:-everything}"
FILES_RAW="${FLAREOPS_FILES:-}"
HOSTNAMES_RAW="${FLAREOPS_HOSTNAMES:-}"
CACHE_TAGS_RAW="${FLAREOPS_CACHE_TAGS:-}"
PREFIXES_RAW="${FLAREOPS_PREFIXES:-}"
BEARER_TOKEN="${FLAREOPS_BEARER_TOKEN:-}"
EMAIL="${FLAREOPS_EMAIL:-}"
API_KEY="${FLAREOPS_API_KEY:-}"
DRY_RUN="${FLAREOPS_DRY_RUN:-false}"
DEBUG="${FLAREOPS_DEBUG:-false}"
TIMEOUT="${FLAREOPS_TIMEOUT:-30}"
RETRIES="${FLAREOPS_RETRIES:-3}"
RETRY_DELAY="${FLAREOPS_RETRY_DELAY:-2}"
API_ENDPOINT="${FLAREOPS_API_ENDPOINT:-https://api.cloudflare.com/client/v4}"

# Booleans: accept any common truthy/falsy variants and normalize to true/false.
# `tr` is used instead of bash 4+ `${var,,}` so the action works on macOS's
# default bash 3.2 without requiring Homebrew bash.
to_bool() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    true|1|yes|y|on)  printf 'true' ;;
    *)                printf 'false' ;;
  esac
}
DRY_RUN="$(to_bool "${DRY_RUN}")"
DEBUG="$(to_bool "${DEBUG}")"
# Re-export DEBUG so helpers.sh's flareops::debug picks up the normalized value.
export FLAREOPS_DEBUG="${DEBUG}"

# Mask credentials immediately so any later accidental log line is hidden.
flareops::mask "${BEARER_TOKEN}"
flareops::mask "${API_KEY}"
# Email is technically not a secret but Cloudflare considers it sensitive in
# combination with the global key. Masking is cheap and avoids leakage in
# verbose logs.
flareops::mask "${EMAIL}"

# Lowercase purge_type so users can pass "Everything", "FILES", etc.
# (`tr`-based for bash 3.2 compatibility — see to_bool above.)
PURGE_TYPE="$(printf '%s' "${PURGE_TYPE}" | tr '[:upper:]' '[:lower:]')"

# Numeric inputs: enforce they look like integers so a malformed input doesn't
# end up in `sleep`/`--max-time` and behave unpredictably.
require_int() {
  local name="$1" value="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '::error::Input `%s` must be a non-negative integer; got %q\n' \
      "${name}" "${value}" >&2
    exit 1
  fi
}
require_int timeout "${TIMEOUT}"
require_int retries "${RETRIES}"
require_int retry_delay "${RETRY_DELAY}"
export FLAREOPS_TIMEOUT="${TIMEOUT}"

# ---------- validate auth ----------------------------------------------------

AUTH_HEADER_1=""
AUTH_HEADER_2=""

if [[ -n "${BEARER_TOKEN}" ]]; then
  AUTH_HEADER_1="Authorization: Bearer ${BEARER_TOKEN}"
  flareops::info "Authentication: API Token (Bearer)"
else
  if [[ -z "${EMAIL}" || -z "${API_KEY}" ]]; then
    printf '::error::Authentication required. Provide either `bearer_token`, or BOTH `email` and `api_key`.\n' >&2
    exit 1
  fi
  AUTH_HEADER_1="X-Auth-Email: ${EMAIL}"
  AUTH_HEADER_2="X-Auth-Key: ${API_KEY}"
  flareops::info "Authentication: Global API Key (X-Auth-Email + X-Auth-Key)"
fi

# ---------- validate zones ---------------------------------------------------

# Build the canonical list of zones. zone_ids takes precedence over zone_id;
# if both are empty we fail.
ZONE_LIST=()
if [[ -n "${ZONE_IDS_RAW}" ]]; then
  while IFS= read -r z; do
    [[ -n "${z}" ]] && ZONE_LIST+=("${z}")
  done < <(flareops::split_list "${ZONE_IDS_RAW}")
elif [[ -n "${ZONE_ID}" ]]; then
  ZONE_LIST+=("${ZONE_ID}")
else
  printf '::error::Either `zone_id` or `zone_ids` is required.\n' >&2
  exit 1
fi

# Cloudflare zone IDs are 32-char lowercase hex strings. We validate to catch
# common mistakes (extra whitespace, accidentally-pasted zone names, etc.)
# before sending the request.
for z in "${ZONE_LIST[@]}"; do
  if ! [[ "${z}" =~ ^[a-f0-9]{32}$ ]]; then
    printf '::error::Zone ID %q does not look like a valid Cloudflare zone ID (expected 32 lowercase hex chars).\n' \
      "${z}" >&2
    exit 1
  fi
done

flareops::info "Zones to purge: ${#ZONE_LIST[@]}"

# ---------- build payload ----------------------------------------------------
#
# Each purge_type maps to a different JSON body. We build the body exactly
# once (it doesn't depend on the zone) and reuse it across multi-zone
# requests.

build_payload() {
  case "${PURGE_TYPE}" in
    everything|all)
      # Cloudflare accepts {"purge_everything": true}.
      jq -n '{purge_everything: true}'
      ;;
    files|urls)
      if [[ -z "${FILES_RAW}" ]]; then
        printf '::error::`purge_type=files` requires non-empty `files` input.\n' >&2
        exit 1
      fi
      flareops::files_to_json_array "${FILES_RAW}" | jq '{files: .}'
      ;;
    hostnames|hosts)
      if [[ -z "${HOSTNAMES_RAW}" ]]; then
        printf '::error::`purge_type=hostnames` requires non-empty `hostnames` input.\n' >&2
        exit 1
      fi
      flareops::list_to_json_string_array "${HOSTNAMES_RAW}" | jq '{hosts: .}'
      ;;
    tags|cache_tags|cache-tags)
      if [[ -z "${CACHE_TAGS_RAW}" ]]; then
        printf '::error::`purge_type=tags` requires non-empty `cache_tags` input.\n' >&2
        exit 1
      fi
      flareops::list_to_json_string_array "${CACHE_TAGS_RAW}" | jq '{tags: .}'
      ;;
    prefixes|prefix)
      if [[ -z "${PREFIXES_RAW}" ]]; then
        printf '::error::`purge_type=prefixes` requires non-empty `prefixes` input.\n' >&2
        exit 1
      fi
      flareops::list_to_json_string_array "${PREFIXES_RAW}" | jq '{prefixes: .}'
      ;;
    *)
      printf '::error::Unknown purge_type %q. Expected one of: everything, files, hostnames, tags, prefixes.\n' \
        "${PURGE_TYPE}" >&2
      exit 1
      ;;
  esac
}

PAYLOAD="$(build_payload)"
# Compact for transport; pretty-print only for debug logs.
PAYLOAD_COMPACT="$(printf '%s' "${PAYLOAD}" | jq -c .)"

if [[ "${DEBUG}" == "true" ]]; then
  flareops::debug "Resolved purge_type: ${PURGE_TYPE}"
  flareops::debug "Request payload: ${PAYLOAD_COMPACT}"
fi

# ---------- execute ---------------------------------------------------------

PROCESSED=()
FAILED=()
LAST_HTTP_CODE=""
LAST_REQUEST_ID=""

purge_zone() {
  local zone="$1"
  local url="${API_ENDPOINT%/}/zones/${zone}/purge_cache"
  flareops::info "Purging zone ${zone} (type=${PURGE_TYPE})"

  if [[ "${DRY_RUN}" == "true" ]]; then
    flareops::info "[dry-run] Would POST ${url}"
    flareops::info "[dry-run] Payload: ${PAYLOAD_COMPACT}"
    PROCESSED+=("${zone}")
    LAST_HTTP_CODE="200"
    return 0
  fi

  local attempt=0
  local max_attempts=$((RETRIES + 1))
  local http_code=""
  while (( attempt < max_attempts )); do
    http_code="$(flareops::http_post "${url}" "${AUTH_HEADER_1}" "${AUTH_HEADER_2}" "${PAYLOAD_COMPACT}")"
    LAST_HTTP_CODE="${http_code}"
    LAST_REQUEST_ID="$(flareops::extract_cf_ray "${FLAREOPS_RESPONSE_HEADERS_FILE}")"

    if [[ "${DEBUG}" == "true" ]]; then
      flareops::debug "HTTP ${http_code} (attempt $((attempt + 1))/${max_attempts}) cf-ray=${LAST_REQUEST_ID:-<none>}"
      # Show the first 1024 bytes of the response body. Cloudflare error
      # responses are small JSON; this is plenty.
      if [[ -s "${FLAREOPS_RESPONSE_BODY_FILE}" ]]; then
        flareops::debug "Response body: $(head -c 1024 "${FLAREOPS_RESPONSE_BODY_FILE}")"
      fi
    fi

    # Cloudflare always returns JSON. On 2xx, parse `success` to confirm.
    if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
      local cf_success
      cf_success="$(jq -r '.success // false' < "${FLAREOPS_RESPONSE_BODY_FILE}" 2>/dev/null || printf 'false')"
      if [[ "${cf_success}" == "true" ]]; then
        flareops::info "Zone ${zone}: purge succeeded (HTTP ${http_code}, cf-ray=${LAST_REQUEST_ID:-<none>})"
        PROCESSED+=("${zone}")
        return 0
      fi
      # 2xx with success=false is unusual but possible; treat as a hard error
      # (no retry — the API has accepted the request and rejected it).
      local cf_errors
      cf_errors="$(jq -c '.errors // []' < "${FLAREOPS_RESPONSE_BODY_FILE}" 2>/dev/null || printf '[]')"
      flareops::error "Zone ${zone}: API returned success=false. errors=${cf_errors}"
      FAILED+=("${zone}")
      return 1
    fi

    # Non-2xx: surface the Cloudflare error message so users can fix things
    # (e.g. invalid zone, insufficient permissions).
    local cf_errors_msg
    cf_errors_msg="$(jq -r '(.errors // []) | map(.message) | join("; ")' \
      < "${FLAREOPS_RESPONSE_BODY_FILE}" 2>/dev/null || printf '')"
    if [[ -n "${cf_errors_msg}" ]]; then
      flareops::warn "Zone ${zone}: HTTP ${http_code} — ${cf_errors_msg}"
    else
      flareops::warn "Zone ${zone}: HTTP ${http_code} (no parseable error body)"
    fi

    if flareops::should_retry "${http_code}"; then
      if (( attempt + 1 < max_attempts )); then
        # 429 responses include a Retry-After header. Honor it when present
        # rather than using our exponential schedule, since the API is telling
        # us exactly how long to wait.
        if [[ "${http_code}" == "429" ]]; then
          local retry_after
          retry_after="$(grep -iE '^retry-after:' "${FLAREOPS_RESPONSE_HEADERS_FILE}" \
            | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/[[:space:]]+$//' || true)"
          if [[ "${retry_after}" =~ ^[0-9]+$ ]]; then
            flareops::warn "Rate limited; sleeping ${retry_after}s per Retry-After header"
            sleep "${retry_after}"
            attempt=$((attempt + 1))
            continue
          fi
        fi
        flareops::sleep_backoff "${attempt}" "${RETRY_DELAY}"
        attempt=$((attempt + 1))
        continue
      fi
    fi

    # Either non-retryable, or out of retries.
    FAILED+=("${zone}")
    return 1
  done

  FAILED+=("${zone}")
  return 1
}

# Run purges sequentially. We deliberately don't parallelize: Cloudflare's
# rate limit is per-account-token, and serial requests give us cleaner
# logs and predictable retry behavior. For users who really need parallelism,
# they can run the action in a matrix.
EXIT_CODE=0
for zone in "${ZONE_LIST[@]}"; do
  if ! purge_zone "${zone}"; then
    EXIT_CODE=1
  fi
done

# ---------- emit outputs -----------------------------------------------------

# GITHUB_OUTPUT is the modern way (since Actions runner 2.297). Older runners
# fall back to the deprecated set-output workflow command.
write_output() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" && -w "${GITHUB_OUTPUT}" ]]; then
    # Use a heredoc-style delimiter so values containing newlines/special
    # chars don't break the file.
    {
      printf '%s<<FLAREOPS_EOF\n' "${key}"
      printf '%s\n' "${value}"
      printf 'FLAREOPS_EOF\n'
    } >> "${GITHUB_OUTPUT}"
  else
    printf '::set-output name=%s::%s\n' "${key}" "${value}"
  fi
}

# Comma-join helper. `IFS=,` with `${arr[*]}` is the canonical bash idiom.
join_csv() {
  local IFS=','
  printf '%s' "$*"
}

if (( ${#FAILED[@]} == 0 )); then
  write_output success "true"
else
  write_output success "false"
fi
write_output response_code "${LAST_HTTP_CODE}"
write_output request_id "${LAST_REQUEST_ID}"
write_output purge_type "${PURGE_TYPE}"
write_output zones_processed "$(join_csv "${PROCESSED[@]:-}")"
write_output failed_zones "$(join_csv "${FAILED[@]:-}")"

# Job summary: a markdown blob shown on the run's summary page. This makes
# multi-zone purges scannable at a glance without digging into raw logs.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -w "${GITHUB_STEP_SUMMARY}" ]]; then
  {
    printf '## FlareOps – Cloudflare Cache Purge\n\n'
    printf '| Field | Value |\n|---|---|\n'
    printf '| Purge type | `%s` |\n' "${PURGE_TYPE}"
    printf '| Zones targeted | %d |\n' "${#ZONE_LIST[@]}"
    printf '| Zones succeeded | %d |\n' "${#PROCESSED[@]}"
    printf '| Zones failed | %d |\n' "${#FAILED[@]}"
    printf '| Dry run | `%s` |\n' "${DRY_RUN}"
    printf '| Last HTTP | `%s` |\n' "${LAST_HTTP_CODE:-n/a}"
    printf '| Last cf-ray | `%s` |\n' "${LAST_REQUEST_ID:-n/a}"
    if (( ${#FAILED[@]} > 0 )); then
      printf '\n**Failed zones:** `%s`\n' "$(join_csv "${FAILED[@]}")"
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if (( EXIT_CODE != 0 )); then
  printf '::error::Purge failed for %d/%d zone(s). See logs above for details.\n' \
    "${#FAILED[@]}" "${#ZONE_LIST[@]}" >&2
fi

exit "${EXIT_CODE}"
