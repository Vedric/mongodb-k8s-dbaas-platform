#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# grafana-annotate.sh - Post annotations to Grafana for chaos events timeline.
# ---------------------------------------------------------------------------

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"

usage() {
  cat <<HELP
Usage: $(basename "$0") [OPTIONS] TEXT

Post an annotation to Grafana for timeline visualization.

Options:
  --url URL       Grafana URL (env: GRAFANA_URL, default: http://localhost:3000)
  --user USER     Grafana admin user (env: GRAFANA_USER, default: admin)
  --pass PASS     Grafana admin password (env: GRAFANA_PASS, default: admin)
  --tags TAGS     Comma-separated tags (default: chaos)
  --dashboard UID Dashboard UID to annotate (optional, default: global)
  -h, --help      Show this help

Examples:
  $(basename "$0") "Chaos: primary killed"
  $(basename "$0") --tags "chaos,failover" "Primary failover started"
HELP
  exit 0
}

TAGS="chaos"
DASHBOARD_UID=""
TEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) GRAFANA_URL="$2"; shift 2 ;;
    --user) GRAFANA_USER="$2"; shift 2 ;;
    --pass) GRAFANA_PASS="$2"; shift 2 ;;
    --tags) TAGS="$2"; shift 2 ;;
    --dashboard) DASHBOARD_UID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) TEXT="$1"; shift ;;
  esac
done

if [ -z "${TEXT}" ]; then
  echo "Error: annotation text is required" >&2
  usage
fi

# Convert comma-separated tags to JSON array
TAGS_JSON=$(echo "${TAGS}" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | paste -sd ',' -)

PAYLOAD="{\"text\":\"${TEXT}\",\"tags\":[${TAGS_JSON}]"
if [ -n "${DASHBOARD_UID}" ]; then
  PAYLOAD="${PAYLOAD},\"dashboardUID\":\"${DASHBOARD_UID}\""
fi
PAYLOAD="${PAYLOAD}}"

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${GRAFANA_URL}/api/annotations" \
  -H "Content-Type: application/json" \
  -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
  -d "${PAYLOAD}" 2>/dev/null) || true

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [ "${HTTP_CODE}" = "200" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Annotation posted: ${TEXT}"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: Failed to post annotation (HTTP ${HTTP_CODE}): ${BODY}" >&2
fi
