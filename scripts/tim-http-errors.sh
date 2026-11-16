#!/usr/bin/env bash
# Compare read-only HTTP error probes on A and B, using example.sh's settings.
# Usage: bash http-errors.sh
# Override A_HOST/B_HOST, A_API/B_API, LOG, PAUSE, CONNECT_TIMEOUT, TIMEOUT.
# A_URL/B_URL can instead specify full base URLs (including https://).
set -euo pipefail

A_HOST=${A_HOST:-127.0.0.1} A_API=${A_API:-${API_PORT:-2375}}
B_HOST=${B_HOST:-127.0.0.1} B_API=${B_API:-${API_PORT:-2375}}
A_URL=${A_URL:-http://$A_HOST:$A_API}
B_URL=${B_URL:-http://$B_HOST:$B_API}
LOG=${LOG:-http-error-evidence.log}
PAUSE=${PAUSE:-3}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-5}
TIMEOUT=${TIMEOUT:-15}
exec 3>&1
printf 'Running checks; detailed results: %s\n' "$LOG" >&3
exec >> "$LOG" 2>&1
command -v curl >/dev/null || { echo 'curl is required' >&2; exit 1; }
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
missing="/__lab_missing_$(date -u +%Y%m%dT%H%M%SZ)_${RANDOM}"

probe() {
  local label=$1 base=$2 name=$3 method=$4 path=$5
  local rc=0 metrics
  : > "$work_dir/headers"
  : > "$work_dir/body"
  : > "$work_dir/errors"
  printf '\n### %s %s [%s]\n%s %s%s\n' \
    "$label" "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$method" "${base%/}" "$path"

  # Do not follow redirects or use --fail: HTTP errors are the evidence.
  # GET and OPTIONS avoid state-changing requests to real API endpoints.
  metrics=$(curl --silent --show-error --globoff \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" \
    --request "$method" --dump-header "$work_dir/headers" \
    --output "$work_dir/body" \
    --write-out 'http_status=%{http_code} remote_ip=%{remote_ip} total_seconds=%{time_total} bytes=%{size_download}' \
    "${base%/}$path" 2> "$work_dir/errors") || rc=$?

  {
    printf 'curl_exit=%s %s\n' "$rc" "$metrics"
    printf '%s\n' '--- headers ---'
    cat "$work_dir/headers"
    printf '\n%s\n' '--- body ---'
    cat "$work_dir/body"
    printf '\n%s\n' '--- curl errors ---'
    cat "$work_dir/errors"
    printf '\n'
  }
}

run_pair() {
  local name=$1 method=$2 path=$3
  probe A "$A_URL" "$name" "$method" "$path"
  sleep "$PAUSE"
  probe B "$B_URL" "$name" "$method" "$path"
  sleep "$PAUSE"
}

printf 'HTTP behavior comparison started %s\nA=%s\nB=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$A_URL" "$B_URL"
if [ "${A_URL%/}" = "${B_URL%/}" ]; then
  printf 'WARNING: A and B use the same URL. This is a baseline run, not a two-target comparison.\n' >&3
fi
run_pair baseline GET /version
run_pair nonexistent-path GET "$missing"
run_pair nested-nonexistent-path GET "$missing/child"
run_pair options-version OPTIONS /version
run_pair invalid-query-value GET '/containers/json?all=definitely-not-a-boolean'
run_pair ping GET /_ping
run_pair system-info GET /info
run_pair all-containers GET '/containers/json?all=1'
run_pair images GET /images/json
run_pair invalid-container-filters GET '/containers/json?filters=%7Bbroken'
run_pair invalid-image-filters GET '/images/json?filters=%7Bbroken'
run_pair missing-container GET "/containers/${missing#/}/json"
run_pair missing-image GET "/images/${missing#/}/json"
run_pair old-api-version GET /v1.0/version
run_pair future-api-version GET /v999.0/version
run_pair baseline-repeat GET /version
printf '\nEvidence saved to %s\nCompare status, headers, body, and repeated behavior.\nTransport errors are not HTTP responses. Differences do not prove honeypot identity.\n' "$LOG"

printf 'Finished. Detailed results saved to %s\n' "$LOG" >&3
