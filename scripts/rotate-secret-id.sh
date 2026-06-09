#!/usr/bin/env bash
set -euo pipefail

ROLE_NAME="openclaw-resolver"
COMPOSE_DIR="${COMPOSE_DIR:-/data/compose/openclaw}"
ENV_FILE=""
VAULT_ADDR_DEFAULT="https://127.0.0.1:8200"
VAULT_CACERT_DEFAULT="${COMPOSE_DIR}/vault/tls/vault.crt"
ROOT_TOKEN_FILE_DEFAULT="${COMPOSE_DIR}/vault/root.token"
NO_REVOKE_OLD=0

usage() {
  cat <<'EOF'
Rotate Vault AppRole secret_id for OpenClaw and update compose .env.

Usage:
  scripts/rotate-secret-id.sh [options]

Options:
  --role <name>              AppRole name (default: openclaw-resolver)
  --compose-dir <path>       Compose directory (default: /data/compose/openclaw)
  --env-file <path>          Explicit env file path (default: <compose-dir>/.env)
  --vault-addr <url>         Vault address (default: https://127.0.0.1:8200)
  --vault-cacert <path>      Vault CA cert path (default: <compose-dir>/vault/tls/vault.crt)
  --root-token-file <path>   Root/admin token file (default: <compose-dir>/vault/root.token)
  --no-revoke-old            Keep old secret_id active
  -h, --help                 Show this help

Token source:
  If VAULT_TOKEN is set, this script uses it.
  Otherwise it reads token text from --root-token-file.
EOF
}

log() {
  printf '[rotate-secret-id] %s\n' "$*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

while (($# > 0)); do
  case "$1" in
    --role)
      ROLE_NAME="$2"
      shift 2
      ;;
    --compose-dir)
      COMPOSE_DIR="$2"
      shift 2
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --vault-addr)
      VAULT_ADDR_DEFAULT="$2"
      shift 2
      ;;
    --vault-cacert)
      VAULT_CACERT_DEFAULT="$2"
      shift 2
      ;;
    --root-token-file)
      ROOT_TOKEN_FILE_DEFAULT="$2"
      shift 2
      ;;
    --no-revoke-old)
      NO_REVOKE_OLD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${ENV_FILE}" ]]; then
  ENV_FILE="${COMPOSE_DIR}/.env"
fi

need_cmd vault
need_cmd docker
need_cmd node
need_cmd sed
need_cmd rg

if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'Env file not found: %s\n' "${ENV_FILE}" >&2
  exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  if [[ ! -f "${ROOT_TOKEN_FILE_DEFAULT}" ]]; then
    printf 'VAULT_TOKEN is not set and root token file not found: %s\n' "${ROOT_TOKEN_FILE_DEFAULT}" >&2
    exit 1
  fi
  VAULT_TOKEN="$(<"${ROOT_TOKEN_FILE_DEFAULT}")"
fi

export VAULT_ADDR="${VAULT_ADDR_DEFAULT}"
export VAULT_CACERT="${VAULT_CACERT_DEFAULT}"
export VAULT_TOKEN

if [[ ! -f "${VAULT_CACERT}" ]]; then
  printf 'Vault CA cert not found: %s\n' "${VAULT_CACERT}" >&2
  exit 1
fi

log "Checking Vault status"
vault status >/dev/null

OLD_SECRET_ID="$(sed -n 's/^OPENCLAW_VAULT_SECRET_ID=//p' "${ENV_FILE}" | tail -n1)"
OLD_ACCESSOR=""
if [[ -n "${OLD_SECRET_ID}" ]]; then
  LOOKUP_JSON="$(
    vault write -format=json "auth/approle/role/${ROLE_NAME}/secret-id/lookup" \
      "secret_id=${OLD_SECRET_ID}" 2>/dev/null || true
  )"
  if [[ -n "${LOOKUP_JSON}" ]]; then
    OLD_ACCESSOR="$(printf '%s' "${LOOKUP_JSON}" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(d);process.stdout.write(j?.data?.secret_id_accessor||"")}catch{}})')"
  fi
fi

log "Creating new secret_id for AppRole: ${ROLE_NAME}"
NEW_JSON="$(vault write -f -format=json "auth/approle/role/${ROLE_NAME}/secret-id")"
NEW_SECRET_ID="$(printf '%s' "${NEW_JSON}" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{const j=JSON.parse(d);process.stdout.write(j?.data?.secret_id||"")})')"
if [[ -z "${NEW_SECRET_ID}" ]]; then
  printf 'Failed to mint new secret_id for role: %s\n' "${ROLE_NAME}" >&2
  exit 1
fi

ROLE_ID="$(vault read -field=role_id "auth/approle/role/${ROLE_NAME}/role-id")"

if rg -q '^OPENCLAW_VAULT_SECRET_ID=' "${ENV_FILE}"; then
  sed -i "s|^OPENCLAW_VAULT_SECRET_ID=.*|OPENCLAW_VAULT_SECRET_ID=${NEW_SECRET_ID}|" "${ENV_FILE}"
else
  printf '\nOPENCLAW_VAULT_SECRET_ID=%s\n' "${NEW_SECRET_ID}" >> "${ENV_FILE}"
fi

if rg -q '^OPENCLAW_VAULT_ROLE_ID=' "${ENV_FILE}"; then
  sed -i "s|^OPENCLAW_VAULT_ROLE_ID=.*|OPENCLAW_VAULT_ROLE_ID=${ROLE_ID}|" "${ENV_FILE}"
else
  printf 'OPENCLAW_VAULT_ROLE_ID=%s\n' "${ROLE_ID}" >> "${ENV_FILE}"
fi

log "Restarting gateway with new credentials"
(
  cd "${COMPOSE_DIR}"
  docker compose --env-file "${ENV_FILE}" up -d openclaw-gateway >/dev/null
)

for _ in $(seq 1 30); do
  HEALTH="$(
    docker inspect openclaw-openclaw-gateway-1 --format '{{.State.Health.Status}}' 2>/dev/null || true
  )"
  if [[ "${HEALTH}" == "healthy" ]]; then
    break
  fi
  sleep 2
done

log "Running OpenClaw secrets checks"
(
  cd "${COMPOSE_DIR}"
  docker compose --env-file "${ENV_FILE}" run --rm -T openclaw-cli secrets audit --check >/dev/null
  docker compose --env-file "${ENV_FILE}" run --rm -T openclaw-cli secrets reload >/dev/null
)

if [[ "${NO_REVOKE_OLD}" -eq 0 && -n "${OLD_ACCESSOR}" ]]; then
  log "Revoking previous secret_id accessor"
  vault write "auth/approle/role/${ROLE_NAME}/secret-id-accessor/destroy" "secret_id_accessor=${OLD_ACCESSOR}" >/dev/null
fi

log "Rotation complete. Updated ${ENV_FILE} and refreshed gateway credentials."
