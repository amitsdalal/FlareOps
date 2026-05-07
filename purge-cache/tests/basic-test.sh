#!/usr/bin/env bash
# shellcheck shell=bash
#
# basic-test.sh — smoke test for the purge-cache scripts.
#
# This test does NOT hit the Cloudflare API. It verifies:
#   - helpers.sh sources cleanly under `set -Eeuo pipefail`
#   - input parsing (split_list, list_to_json_string_array, files_to_json_array)
#     produces well-formed JSON arrays for representative inputs
#   - purge.sh fails with a clean error on missing auth and missing zone
#   - purge.sh in dry-run mode emits the expected outputs
#
# Run from the repo root: `bash purge-cache/tests/basic-test.sh`

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/purge-cache/scripts"

# shellcheck source=../scripts/helpers.sh
source "${SCRIPTS_DIR}/helpers.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    printf '  ok   %s\n' "${label}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n    expected: %q\n    actual:   %q\n' \
      "${label}" "${expected}" "${actual}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  ok   %s\n' "${label}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n    needle:   %q\n    haystack: %q\n' \
      "${label}" "${needle}" "${haystack}"
    FAIL=$((FAIL + 1))
  fi
}

# ---------- helpers.sh unit tests --------------------------------------------

printf 'helpers.sh\n'

# split_list trims whitespace, drops blanks, accepts comma + newline separators.
got="$(flareops::split_list $'  foo  ,bar\n\nbaz  \n')"
expected=$'foo\nbar\nbaz'
assert_eq "split_list trims and dedupes blanks" "${expected}" "${got}"

# list_to_json_string_array produces a JSON array of strings.
got="$(flareops::list_to_json_string_array $'tag-1\ntag-2,tag-3' | jq -c .)"
assert_eq "list_to_json_string_array emits JSON array" \
  '["tag-1","tag-2","tag-3"]' "${got}"

# files_to_json_array passes JSON object entries through unchanged.
mixed_input=$'https://example.com/a\n{"url":"https://example.com/b","headers":{"Origin":"https://x"}}'
got="$(flareops::files_to_json_array "${mixed_input}" | jq -c .)"
expected='["https://example.com/a",{"url":"https://example.com/b","headers":{"Origin":"https://x"}}]'
assert_eq "files_to_json_array mixes URLs and objects" "${expected}" "${got}"

# should_retry classifies common codes correctly.
if flareops::should_retry 500; then assert_eq "should_retry 500" "true" "true"; else assert_eq "should_retry 500" "true" "false"; fi
if flareops::should_retry 429; then assert_eq "should_retry 429" "true" "true"; else assert_eq "should_retry 429" "true" "false"; fi
if flareops::should_retry 401; then assert_eq "should_retry 401" "false" "true"; else assert_eq "should_retry 401" "false" "false"; fi
if flareops::should_retry 200; then assert_eq "should_retry 200" "false" "true"; else assert_eq "should_retry 200" "false" "false"; fi

# ---------- purge.sh integration tests ---------------------------------------

printf 'purge.sh — error paths\n'

# Missing auth → exit 1, error message includes "Authentication required".
set +e
out="$(
  FLAREOPS_ZONE_ID="0123456789abcdef0123456789abcdef" \
  FLAREOPS_PURGE_TYPE="everything" \
  FLAREOPS_BEARER_TOKEN="" \
  FLAREOPS_EMAIL="" \
  FLAREOPS_API_KEY="" \
  bash "${SCRIPTS_DIR}/purge.sh" 2>&1
)"
rc=$?
set -e
assert_eq "missing auth exits 1" "1" "${rc}"
assert_contains "missing auth error message" "Authentication required" "${out}"

# Missing zone → exit 1.
set +e
out="$(
  FLAREOPS_PURGE_TYPE="everything" \
  FLAREOPS_BEARER_TOKEN="dummy" \
  bash "${SCRIPTS_DIR}/purge.sh" 2>&1
)"
rc=$?
set -e
assert_eq "missing zone exits 1" "1" "${rc}"
assert_contains "missing zone error message" "zone_id" "${out}"

# Invalid zone ID → exit 1.
set +e
out="$(
  FLAREOPS_ZONE_ID="not-a-real-zone" \
  FLAREOPS_PURGE_TYPE="everything" \
  FLAREOPS_BEARER_TOKEN="dummy" \
  bash "${SCRIPTS_DIR}/purge.sh" 2>&1
)"
rc=$?
set -e
assert_eq "invalid zone id exits 1" "1" "${rc}"
assert_contains "invalid zone id error message" "valid Cloudflare zone ID" "${out}"

# purge_type=files with empty files → exit 1.
set +e
out="$(
  FLAREOPS_ZONE_ID="0123456789abcdef0123456789abcdef" \
  FLAREOPS_PURGE_TYPE="files" \
  FLAREOPS_BEARER_TOKEN="dummy" \
  bash "${SCRIPTS_DIR}/purge.sh" 2>&1
)"
rc=$?
set -e
assert_eq "files purge w/o files exits 1" "1" "${rc}"
assert_contains "files purge error message" "non-empty \`files\`" "${out}"

# Unknown purge_type → exit 1.
set +e
out="$(
  FLAREOPS_ZONE_ID="0123456789abcdef0123456789abcdef" \
  FLAREOPS_PURGE_TYPE="bogus" \
  FLAREOPS_BEARER_TOKEN="dummy" \
  bash "${SCRIPTS_DIR}/purge.sh" 2>&1
)"
rc=$?
set -e
assert_eq "unknown purge_type exits 1" "1" "${rc}"
assert_contains "unknown purge_type message" "Unknown purge_type" "${out}"

# ---------- purge.sh dry-run -------------------------------------------------

printf 'purge.sh — dry-run\n'

tmp_output="$(mktemp)"
tmp_summary="$(mktemp)"
set +e
out="$(
  GITHUB_OUTPUT="${tmp_output}" \
  GITHUB_STEP_SUMMARY="${tmp_summary}" \
  FLAREOPS_ZONE_ID="0123456789abcdef0123456789abcdef" \
  FLAREOPS_PURGE_TYPE="tags" \
  FLAREOPS_CACHE_TAGS=$'product-1\nproduct-2' \
  FLAREOPS_BEARER_TOKEN="dummy-token" \
  FLAREOPS_DRY_RUN="true" \
  bash "${SCRIPTS_DIR}/purge.sh" 2>&1
)"
rc=$?
set -e
assert_eq "dry-run exits 0" "0" "${rc}"
assert_contains "dry-run logs would-POST" "Would POST" "${out}"
assert_contains "dry-run output: success=true" "success<<FLAREOPS_EOF"$'\n'"true" "$(cat "${tmp_output}")"
assert_contains "dry-run output: zones_processed" "zones_processed" "$(cat "${tmp_output}")"
rm -f "${tmp_output}" "${tmp_summary}"

# ---------- summary ----------------------------------------------------------

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
