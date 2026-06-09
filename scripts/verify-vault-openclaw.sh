#!/usr/bin/env bash
set -euo pipefail

ROLE_NAME="openclaw-resolver"
POLICY_NAME="openclaw-resolver-read"
SECRET_ID_PATH="providers/openai/apiKey"
COMPOSE_DIR="${COMPOSE_DIR:-/data/compose/openclaw}"
ENV_FILE=""
VAULT_ADDR_DEFAULT="https://127.0.0.1:8200"
VAULT_CACERT_DEFAULT="${COMPOSE_DIR}/vault/tls/vault.crt"
ROOT_TOKEN_FILE_DEFAULT="${COMPOSE_DIR}/vault/root.token"
SKIP_RELOAD=0

usage() {
  cat <<'EOF'
Verify local Vault + OpenClaw integration health.

Usage:
  scripts/verify-vault-openclaw.sh [options]

Options:
  --role <name>              AppRole name (default: openclaw-resolver)
  --policy <name>            Policy name (default: openclaw-resolver-read)
  --id <id>                  Resolver id to test (default: providers/openai/apiKey)
  --compose-dir <path>       Compose directory (default: /data/compose/openclaw)
  --env-file <path>          Explicit env file path (default: <compose-dir>/.env)
  --vault-addr <url>         Vault address (default: https://127.0.0.1:8200)
  --vault-cacert <path>      Vault CA cert path (default: <compose-dir>/vault/tls/vault.crt)
  --root-token-file <path>   Root/admin token file (default: <compose-dir>/vault/root.token)
  --skip-reload              Skip `openclaw-cli secrets reload`
  -h, --help                 Show this help
EOF
}

log() {
  printf '[verify-vault-openclaw] %s\n' "$*"
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
    --policy)
      POLICY_NAME="$2"
      shift 2
      ;;
    --id)
      SECRET_ID_PATH="$2"
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
    --skip-reload)
      SKIP_RELOAD=1
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
need_cmd rg

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

log "Checking docker service health"
docker ps --format '{{.Names}} {{.Status}}' \
  | rg -q '^openclaw-vault .*healthy'
docker ps --format '{{.Names}} {{.Status}}' \
  | rg -q '^openclaw-openclaw-gateway-1 .*healthy'

log "Checking Vault status"
STATUS_JSON="$(vault status -format=json)"
printf '%s' "${STATUS_JSON}" | node -e '
let d=""; process.stdin.on("data",c=>d+=c); process.stdin.on("end",()=>{
  const s=JSON.parse(d);
  if (!s.initialized) throw new Error("Vault is not initialized");
  if (s.sealed) throw new Error("Vault is sealed");
  if (s.storage_type !== "raft") throw new Error(`Unexpected storage_type: ${s.storage_type}`);
  console.log(`vault_initialized=${s.initialized} sealed=${s.sealed} storage=${s.storage_type}`);
});'

log "Checking audit device"
vault audit list | rg -q '^file/'

log "Checking resolver policy and role"
vault policy read "${POLICY_NAME}" | rg -q 'capabilities = \["read"\]'
vault read "auth/approle/role/${ROLE_NAME}" >/dev/null

log "Running resolver protocol test"
docker exec openclaw-openclaw-gateway-1 sh -lc \
  "printf '{\"protocolVersion\":1,\"provider\":\"vault_local\",\"ids\":[\"${SECRET_ID_PATH}\"]}\n' | /home/node/.openclaw/bin/openclaw-vault-resolver.mjs" \
  | node -e '
let d="";
process.stdin.on("data",c=>d+=c);
process.stdin.on("end",()=>{
  const j=JSON.parse(d);
  const ids=Object.keys(j.values||{});
  const errs=Object.keys(j.errors||{});
  if (!ids.length || errs.length) {
    throw new Error(`resolver failed: resolved=${ids.join(",")||"none"} errors=${errs.join(",")||"none"}`);
  }
  console.log(`resolver_ok id=${ids[0]}`);
});'

log "Running OpenClaw secrets audit"
(
  cd "${COMPOSE_DIR}"
  docker compose --env-file "${ENV_FILE}" run --rm -T openclaw-cli secrets audit --check >/dev/null
)

if [[ "${SKIP_RELOAD}" -eq 0 ]]; then
  log "Running OpenClaw secrets reload"
  (
    cd "${COMPOSE_DIR}"
    docker compose --env-file "${ENV_FILE}" run --rm -T openclaw-cli secrets reload >/dev/null
  )
fi

log "Verification complete."
