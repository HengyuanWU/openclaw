#!/usr/bin/env bash
set -euo pipefail

IMAGE="ghcr.io/openclaw/openclaw:latest"
LOG_FILE="/tmp/openclaw-deploy.log"
STATE_FILE="/tmp/openclaw-deploy.state"
MAX_RETRIES=10
INITIAL_BACKOFF_SEC=3
MAX_BACKOFF_SEC=90
HEARTBEAT_SEC=20
PULL_TIMEOUT_SEC=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: scripts/docker/pull-openclaw-image.sh [options]

Robust image pull with retry + resume-friendly behavior.
Docker stores partial layers locally, so each retry continues from cached layers.

Options:
  -i, --image <ref>            Image reference (default: ghcr.io/openclaw/openclaw:latest)
  -l, --log-file <path>        Log file path (default: /tmp/openclaw-deploy.log)
  -s, --state-file <path>      State file path (default: /tmp/openclaw-deploy.state)
  -r, --retries <n>            Max attempts (default: 10)
  --initial-backoff <sec>      Initial retry backoff in seconds (default: 3)
  --max-backoff <sec>          Max retry backoff in seconds (default: 90)
  --heartbeat <sec>            Progress heartbeat interval in seconds (default: 20)
  --attempt-timeout <sec>      Timeout per attempt; 0 disables timeout (default: 0)
  --dry-run                    Print effective config and exit
  -h, --help                   Show this help

Monitoring:
  tail -f /tmp/openclaw-deploy.log
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)
      IMAGE="${2:?missing value for $1}"
      shift 2
      ;;
    -l|--log-file)
      LOG_FILE="${2:?missing value for $1}"
      shift 2
      ;;
    -s|--state-file)
      STATE_FILE="${2:?missing value for $1}"
      shift 2
      ;;
    -r|--retries)
      MAX_RETRIES="${2:?missing value for $1}"
      shift 2
      ;;
    --initial-backoff)
      INITIAL_BACKOFF_SEC="${2:?missing value for $1}"
      shift 2
      ;;
    --max-backoff)
      MAX_BACKOFF_SEC="${2:?missing value for $1}"
      shift 2
      ;;
    --heartbeat)
      HEARTBEAT_SEC="${2:?missing value for $1}"
      shift 2
      ;;
    --attempt-timeout)
      PULL_TIMEOUT_SEC="${2:?missing value for $1}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

for pair in \
  "MAX_RETRIES:$MAX_RETRIES" \
  "INITIAL_BACKOFF_SEC:$INITIAL_BACKOFF_SEC" \
  "MAX_BACKOFF_SEC:$MAX_BACKOFF_SEC" \
  "HEARTBEAT_SEC:$HEARTBEAT_SEC" \
  "PULL_TIMEOUT_SEC:$PULL_TIMEOUT_SEC"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if ! is_uint "$value"; then
    echo "$name must be a non-negative integer, got: $value" >&2
    exit 2
  fi
done

if [[ "$MAX_RETRIES" -eq 0 ]]; then
  echo "MAX_RETRIES must be >= 1" >&2
  exit 2
fi
if [[ "$HEARTBEAT_SEC" -eq 0 ]]; then
  echo "HEARTBEAT_SEC must be >= 1" >&2
  exit 2
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF2
IMAGE=$IMAGE
LOG_FILE=$LOG_FILE
STATE_FILE=$STATE_FILE
MAX_RETRIES=$MAX_RETRIES
INITIAL_BACKOFF_SEC=$INITIAL_BACKOFF_SEC
MAX_BACKOFF_SEC=$MAX_BACKOFF_SEC
HEARTBEAT_SEC=$HEARTBEAT_SEC
PULL_TIMEOUT_SEC=$PULL_TIMEOUT_SEC
EOF2
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

now() {
  date '+%Y-%m-%d %H:%M:%S %z'
}

log() {
  echo "[$(now)] $*"
}

write_state() {
  local status="$1"
  local attempt="$2"
  local message="$3"

  cat > "$STATE_FILE" <<EOF2
timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
status=$status
attempt=$attempt
max_retries=$MAX_RETRIES
image=$IMAGE
message=$message
EOF2
}

retry_sleep() {
  local attempt="$1"
  local backoff="$INITIAL_BACKOFF_SEC"
  local i=1

  while [[ "$i" -lt "$attempt" ]]; do
    backoff=$((backoff * 2))
    if [[ "$backoff" -gt "$MAX_BACKOFF_SEC" ]]; then
      backoff="$MAX_BACKOFF_SEC"
      break
    fi
    i=$((i + 1))
  done

  echo "$backoff"
}

run_pull_attempt() {
  local attempt="$1"
  local started_at
  started_at="$(date +%s)"

  local -a pull_cmd
  if [[ "$PULL_TIMEOUT_SEC" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
    pull_cmd=(timeout --foreground "$PULL_TIMEOUT_SEC" docker pull "$IMAGE")
  else
    pull_cmd=(docker pull "$IMAGE")
    if [[ "$PULL_TIMEOUT_SEC" -gt 0 ]]; then
      log "timeout command not found; running without attempt timeout"
    fi
  fi

  log "Attempt $attempt/$MAX_RETRIES: pulling $IMAGE"
  write_state "running" "$attempt" "pulling"

  set +e
  {
    "${pull_cmd[@]}" 2>&1 &
    local pull_pid="$!"

    (
      while kill -0 "$pull_pid" >/dev/null 2>&1; do
        sleep "$HEARTBEAT_SEC"
        local now_ts elapsed_so_far
        now_ts="$(date +%s)"
        elapsed_so_far=$((now_ts - started_at))
        log "Attempt $attempt still running (${elapsed_so_far}s elapsed)"
        write_state "running" "$attempt" "elapsed=${elapsed_so_far}s"
      done
    ) &
    local heartbeat_pid="$!"

    wait "$pull_pid"
    local cmd_exit="$?"
    kill "$heartbeat_pid" >/dev/null 2>&1 || true
    wait "$heartbeat_pid" >/dev/null 2>&1 || true
    return "$cmd_exit"
  } | sed -u 's/\r/\n/g'
  local pull_exit="${PIPESTATUS[0]}"
  set -e

  local ended_at elapsed
  ended_at="$(date +%s)"
  elapsed=$((ended_at - started_at))

  if [[ "$pull_exit" -eq 0 ]]; then
    log "Attempt $attempt succeeded in ${elapsed}s"
    write_state "success" "$attempt" "pull complete"
    return 0
  fi

  log "Attempt $attempt failed in ${elapsed}s (exit=$pull_exit)"
  write_state "failed" "$attempt" "docker pull exit $pull_exit"
  return "$pull_exit"
}

log "Starting resilient pull"
log "Image: $IMAGE"
log "State file: $STATE_FILE"
log "To monitor: tail -f $LOG_FILE"

attempt=1
while [[ "$attempt" -le "$MAX_RETRIES" ]]; do
  if run_pull_attempt "$attempt"; then
    digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)"
    if [[ -n "$digest" ]]; then
      log "Pulled digest: $digest"
      write_state "success" "$attempt" "digest=$digest"
    fi
    log "Pull complete"
    exit 0
  fi

  if [[ "$attempt" -ge "$MAX_RETRIES" ]]; then
    break
  fi

  sleep_sec="$(retry_sleep "$attempt")"
  log "Retrying after ${sleep_sec}s (Docker layer cache preserves already downloaded chunks)"
  write_state "retry_wait" "$attempt" "sleep ${sleep_sec}s"

  remaining="$sleep_sec"
  while [[ "$remaining" -gt 0 ]]; do
    chunk="$HEARTBEAT_SEC"
    if [[ "$remaining" -lt "$chunk" ]]; then
      chunk="$remaining"
    fi
    sleep "$chunk"
    remaining=$((remaining - chunk))
    log "Waiting before retry: ${remaining}s left"
  done

  attempt=$((attempt + 1))
done

log "Pull failed after $MAX_RETRIES attempts"
write_state "exhausted" "$MAX_RETRIES" "all attempts failed"
exit 1
