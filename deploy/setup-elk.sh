set -euo pipefail

ES_URL="${ES_URL:-http://localhost:9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASS="${ES_PASS:-${ELASTIC_PASSWORD:-}}"
ENV_NAME="${ENV_NAME:-prod}"  # prod / dev
FILEBEAT_WRITER_USER="${FILEBEAT_WRITER_USER:-filebeat_writer}"
FILEBEAT_WRITER_PASSWORD="${FILEBEAT_WRITER_PASSWORD:-}"

ALIAS="b2b-logs-${ENV_NAME}"
POLICY="b2b-logs-policy"
TEMPLATE="b2b-logs-${ENV_NAME}-template"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! "${ENV_NAME}" =~ ^[a-z0-9_-]+$ ]]; then
  echo "ERROR: ENV_NAME may only contain lowercase letters, numbers, underscore and hyphen." >&2
  exit 1
fi

if [[ ! "${FILEBEAT_WRITER_USER}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: FILEBEAT_WRITER_USER contains unsupported characters." >&2
  exit 1
fi

for command_name in curl jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${command_name}" >&2
    exit 1
  fi
done

if [[ -z "${ES_PASS}" ]]; then
  echo "ERROR: missing ES password. Set ES_PASS or ELASTIC_PASSWORD." >&2
  exit 1
fi

umask 077
TASK_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TASK_TMP_DIR}"' EXIT

TEMPLATE_FILE="${TASK_TMP_DIR}/template.json"
BOOTSTRAP_FILE="${TASK_TMP_DIR}/bootstrap.json"
WRITER_ROLE_FILE="${TASK_TMP_DIR}/writer-role.json"
WRITER_USER_FILE="${TASK_TMP_DIR}/writer-user.json"

# 使用 jq 產生 JSON，可正確處理 variable escaping
jq -n \
  --arg policy "${POLICY}" \
  --arg alias "${ALIAS}" \
  --arg pattern "${ALIAS}-*" \
  '{
    index_patterns: [$pattern],
    template: {
      settings: {
        "index.number_of_shards": 1,
        "index.number_of_replicas": 0,
        "index.lifecycle.name": $policy,
        "index.lifecycle.rollover_alias": $alias
      }
    },
    priority: 200
  }' > "${TEMPLATE_FILE}"

jq -n \
  --arg alias "${ALIAS}" \
  '{
    aliases: {
      ($alias): {
        is_write_index: true
      }
    }
  }' > "${BOOTSTRAP_FILE}"

jq -n '{
  cluster: ["monitor"],
  indices: [{
    names: ["b2b-logs-*"],
    privileges: ["auto_configure", "create_doc", "view_index_metadata"]
  }]
}' > "${WRITER_ROLE_FILE}"

if [[ -n "${FILEBEAT_WRITER_PASSWORD}" ]]; then
  jq -n \
    --arg password "${FILEBEAT_WRITER_PASSWORD}" \
    '{password: $password, roles: ["b2b_logs_writer"], enabled: true}' > "${WRITER_USER_FILE}"
fi

echo "[1/3] Apply ILM policy"

curl \
  --fail-with-body \
  --silent \
  --show-error \
  --user "${ES_USER}:${ES_PASS}" \
  --request PUT \
  --header "Content-Type: application/json" \
  --data-binary "@${SCRIPT_DIR}/ilm-b2b-logs-policy.json" \
  "${ES_URL}/_ilm/policy/${POLICY}" |
  jq -e .

echo "[2/3] Apply index template"

curl \
  --fail-with-body \
  --silent \
  --show-error \
  --user "${ES_USER}:${ES_PASS}" \
  --request PUT \
  --header "Content-Type: application/json" \
  --data-binary "@${TEMPLATE_FILE}" \
  "${ES_URL}/_index_template/${TEMPLATE}" |
  jq -e .

echo "[3/3] Bootstrap write index"
# 讓 script 可以安全重跑；index 已存在就不要再次建立
if curl \
  --fail \
  --silent \
  --head \
  --user "${ES_USER}:${ES_PASS}" \
  "${ES_URL}/${ALIAS}-000001" >/dev/null; then

  echo "Bootstrap index already exists"
else
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --user "${ES_USER}:${ES_PASS}" \
    --request PUT \
    --header "Content-Type: application/json" \
    --data-binary "@${BOOTSTRAP_FILE}" \
    "${ES_URL}/${ALIAS}-000001" |
    jq -e .
fi


if [[ -n "${FILEBEAT_WRITER_PASSWORD}" ]]; then
  echo "[optional] Apply least-privilege Filebeat writer role and user"
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --user "${ES_USER}:${ES_PASS}" \
    --request PUT \
    --header "Content-Type: application/json" \
    --data-binary "@${WRITER_ROLE_FILE}" \
    "${ES_URL}/_security/role/b2b_logs_writer" |
    jq -e .

  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --user "${ES_USER}:${ES_PASS}" \
    --request PUT \
    --header "Content-Type: application/json" \
    --data-binary "@${WRITER_USER_FILE}" \
    "${ES_URL}/_security/user/${FILEBEAT_WRITER_USER}" |
    jq -e .

  echo "Filebeat writer configured: user=${FILEBEAT_WRITER_USER}"
else
  echo "Filebeat writer provisioning skipped; set FILEBEAT_WRITER_PASSWORD to create/update it."
fi

echo "ELK setup completed: alias=${ALIAS}"
