set -euo pipefail

FILEBEAT_URL="${FILEBEAT_URL:-http://127.0.0.1:5066}"
ES_URL="${ES_URL:-http://127.0.0.1:9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASS="${ES_PASS:-${ELASTIC_PASSWORD:-}}"

QUEUE_WARN_PERCENT="${QUEUE_WARN_PERCENT:-70}"
QUEUE_CRITICAL_PERCENT="${QUEUE_CRITICAL_PERCENT:-90}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-75}"
DISK_CRITICAL_PERCENT="${DISK_CRITICAL_PERCENT:-90}"

for command_name in curl jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "CRITICAL: required command not found: ${command_name}" >&2
    exit 2
  fi
done

if [[ -z "${ES_PASS}" ]]; then
  echo "CRITICAL: missing ES_PASS or ELASTIC_PASSWORD" >&2
  exit 2
fi

filebeat_stats="$(curl --fail --silent --show-error "${FILEBEAT_URL}/stats")" || {
  echo "CRITICAL: Filebeat HTTP endpoint is unavailable" >&2
  exit 2
}

cluster_health="$(curl --fail --silent --show-error --user "${ES_USER}:${ES_PASS}" "${ES_URL}/_cluster/health")" || {
  echo "CRITICAL: Elasticsearch cluster health endpoint is unavailable" >&2
  exit 2
}

allocation="$(curl --fail --silent --show-error --user "${ES_USER}:${ES_PASS}" "${ES_URL}/_cat/allocation?format=json&h=node,disk.percent")" || {
  echo "CRITICAL: Elasticsearch disk allocation endpoint is unavailable" >&2
  exit 2
}

queue_percent="$(jq -r '((.libbeat.pipeline.queue.filled.pct // 0) * 100) | floor' <<<"${filebeat_stats}")"
cluster_status="$(jq -r '.status // "unknown"' <<<"${cluster_health}")"
disk_percent="$(jq -r '[.[]."disk.percent" | tonumber? // 0] | max // 0 | floor' <<<"${allocation}")"

severity=0
messages=()

if (( queue_percent >= QUEUE_CRITICAL_PERCENT )); then
  severity=2
  messages+=("Filebeat queue ${queue_percent}%")
elif (( queue_percent >= QUEUE_WARN_PERCENT )); then
  severity=1
  messages+=("Filebeat queue ${queue_percent}%")
fi

if (( disk_percent >= DISK_CRITICAL_PERCENT )); then
  severity=2
  messages+=("Elasticsearch disk ${disk_percent}%")
elif (( disk_percent >= DISK_WARN_PERCENT )); then
  (( severity < 1 )) && severity=1
  messages+=("Elasticsearch disk ${disk_percent}%")
fi

if [[ "${cluster_status}" == "red" || "${cluster_status}" == "unknown" ]]; then
  severity=2
  messages+=("Elasticsearch cluster ${cluster_status}")
elif [[ "${cluster_status}" == "yellow" ]]; then
  (( severity < 1 )) && severity=1
  messages+=("Elasticsearch cluster ${cluster_status}")
fi

if (( ${#messages[@]} == 0 )); then
  echo "OK: Filebeat queue ${queue_percent}%, Elasticsearch disk ${disk_percent}%, cluster ${cluster_status}"
else
  case "${severity}" in
    2) prefix="CRITICAL" ;;
    *) prefix="WARNING" ;;
  esac
  printf '%s: %s\n' "${prefix}" "$(IFS=', '; echo "${messages[*]}")"
fi

exit "${severity}"
