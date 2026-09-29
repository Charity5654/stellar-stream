#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# compose-up.sh — start the Docker Compose stack and either reach a verified
# healthy state or stop with a clear rollback.
#
# Phases:
#   1. Preflight   — compose file parses, backend/.env exists.
#   2. Backend     — start redis + backend, poll the container health status.
#   3. Recovery    — on an unhealthy/crashed backend, print diagnostics and
#                    restart it at most MAX_RECOVERY_ATTEMPTS times. Config
#                    errors (env validation failures) are never retried.
#   4. Frontend    — start frontend only once the backend is healthy.
#   5. Rollback    — on any failure, `docker compose down` (volumes are KEPT,
#                    so the SQLite database is never deleted) and exit non-zero.
#
# Exit codes: 0 healthy, 1 unhealthy after recovery (rolled back),
#             2 preflight failed (nothing was started).
#
# Tunables (environment variables):
#   BACKEND_HEALTH_TIMEOUT   seconds to wait for backend healthy   (default 180)
#   FRONTEND_HEALTH_TIMEOUT  seconds to wait for frontend healthy  (default 120)
#   POLL_INTERVAL            seconds between health polls          (default 5)
#   MAX_RECOVERY_ATTEMPTS    backend restarts before rollback      (default 1)
#   MAX_CRASH_RESTARTS       container restarts treated as a crash loop (default 3)
#   ROLLBACK                 "down" (default) or "keep" to leave containers for debugging
#   COMPOSE_BUILD            "1" (default) passes --build to `up`
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOCKER="${DOCKER_CMD:-docker}"
COMPOSE_FILE="${COMPOSE_FILE_PATH:-$ROOT_DIR/docker-compose.yml}"
ENV_FILE="${BACKEND_ENV_FILE:-$ROOT_DIR/backend/.env}"
BACKEND_HEALTH_TIMEOUT="${BACKEND_HEALTH_TIMEOUT:-180}"
FRONTEND_HEALTH_TIMEOUT="${FRONTEND_HEALTH_TIMEOUT:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-1}"
MAX_CRASH_RESTARTS="${MAX_CRASH_RESTARTS:-3}"
ROLLBACK="${ROLLBACK:-down}"
COMPOSE_BUILD="${COMPOSE_BUILD:-1}"

# Pin to the base compose file so the dev override (hot-reload) is not merged in.
compose() { "$DOCKER" compose -f "$COMPOSE_FILE" "$@"; }

log()  { printf '[compose-up] %s\n' "$*"; }
fail() { printf '[compose-up] FAIL: %s\n' "$*" >&2; }

# Log lines emitted by validateEnv()/startServer() that a restart cannot fix.
CONFIG_ERROR_PATTERN='Soroban configuration incomplete|Invalid environment|must be exactly 56 characters|must start with|failed to start server'

rollback() {
  local reason="$1"
  fail "$reason"
  if [[ "$ROLLBACK" == "keep" ]]; then
    log "ROLLBACK=keep — containers left running for inspection."
    log "Roll back manually with: docker compose down   (do NOT add -v; it deletes the SQLite volume)"
  else
    log "Rolling back: docker compose down (named volume backend-data is preserved)"
    compose down --remove-orphans >/dev/null 2>&1 || fail "docker compose down failed; run it manually"
  fi
  log "RESULT: FAIL — stack rolled back. Fix the cause above, then re-run scripts/compose-up.sh"
  exit 1
}

# Prints "<state> <health> <restart_count>", e.g. "running starting 0".
service_state() {
  local id
  id="$(compose ps -a -q "$1" 2>/dev/null | head -n1)"
  if [[ -z "$id" ]]; then
    echo "missing none 0"
    return
  fi
  "$DOCKER" inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$id" 2>/dev/null \
    || echo "missing none 0"
}

diagnose() {
  local service="$1" id
  log "── diagnostics: $service ──"
  compose ps -a "$service" 2>&1 | sed 's/^/  /'
  id="$(compose ps -a -q "$service" 2>/dev/null | head -n1)"
  if [[ -n "$id" ]]; then
    log "last healthcheck probes:"
    "$DOCKER" inspect -f '{{if .State.Health}}{{range .State.Health.Log}}  exit={{.ExitCode}} {{.Output}}{{end}}{{end}}' "$id" 2>/dev/null | tail -n 6
  fi
  log "last 40 log lines:"
  compose logs --no-color --tail 40 "$service" 2>&1 | sed 's/^/  /'
}

is_config_error() {
  compose logs --no-color --tail 200 "$1" 2>/dev/null | grep -Eq "$CONFIG_ERROR_PATTERN"
}

# Returns 0 healthy, 1 timed out, 3 crashed / crash-looping.
wait_healthy() {
  local service="$1" timeout="$2" elapsed=0 state health restarts baseline
  # RestartCount is cumulative across `compose restart`, so count from here.
  read -r _ _ baseline <<<"$(service_state "$service")"
  while (( elapsed <= timeout )); do
    read -r state health restarts <<<"$(service_state "$service")"
    case "$state/$health" in
      running/healthy)
        log "$service is healthy (${elapsed}s)"
        return 0 ;;
      exited/*|dead/*)
        log "$service container is $state"
        return 3 ;;
    esac
    if (( restarts - baseline >= MAX_CRASH_RESTARTS )); then
      log "$service restarted $(( restarts - baseline )) times — crash loop"
      return 3
    fi
    log "waiting for $service: state=$state health=$health restarts=$restarts (${elapsed}/${timeout}s)"
    sleep "$POLL_INTERVAL"
    elapsed=$(( elapsed + POLL_INTERVAL ))
  done
  return 1
}

# ── 1. Preflight ──────────────────────────────────────────────────────────────
for n in BACKEND_HEALTH_TIMEOUT FRONTEND_HEALTH_TIMEOUT POLL_INTERVAL MAX_RECOVERY_ATTEMPTS MAX_CRASH_RESTARTS; do
  if [[ ! "${!n}" =~ ^[0-9]+$ ]]; then fail "$n must be a non-negative integer"; exit 2; fi
done
if (( POLL_INTERVAL < 1 )); then fail "POLL_INTERVAL must be >= 1"; exit 2; fi
if ! "$DOCKER" compose version >/dev/null 2>&1; then
  fail "docker compose is not available (need Docker Compose v2)"
  exit 2
fi
if [[ ! -f "$ENV_FILE" ]]; then
  fail "missing ${ENV_FILE#"$ROOT_DIR"/} — docker-compose.yml requires it via env_file"
  log "Create it with: cp backend/.env.example backend/.env"
  log "For local runs without a deployed contract, set SOROBAN_DISABLED=true in it."
  exit 2
fi
if ! compose config -q >/dev/null 2>&1; then
  fail "docker-compose.yml is invalid:"
  compose config -q 2>&1 | sed 's/^/  /' >&2
  exit 2
fi
log "preflight OK"

# ── 2. Backend ────────────────────────────────────────────────────────────────
up_args=(up -d)
[[ "$COMPOSE_BUILD" == "1" ]] && up_args+=(--build)

log "starting redis + backend"
if ! compose "${up_args[@]}" redis backend; then
  diagnose backend
  rollback "docker compose up failed for redis/backend"
fi

# ── 3. Recovery loop ──────────────────────────────────────────────────────────
attempt=0
while :; do
  wait_healthy backend "$BACKEND_HEALTH_TIMEOUT"
  rc=$?
  (( rc == 0 )) && break

  diagnose backend
  if is_config_error backend; then
    log "hint: backend rejected its configuration — edit backend/.env (see backend/.env.example)."
    log "hint: for local runs without a contract set SOROBAN_DISABLED=true."
    rollback "backend failed configuration validation; restarting will not help"
  fi
  if (( attempt >= MAX_RECOVERY_ATTEMPTS )); then
    rollback "backend did not become healthy after $attempt recovery attempt(s)"
  fi
  attempt=$(( attempt + 1 ))
  log "recovery attempt $attempt/$MAX_RECOVERY_ATTEMPTS: restarting backend"
  compose restart backend >/dev/null 2>&1 || rollback "docker compose restart backend failed"
done

# ── 4. Frontend ───────────────────────────────────────────────────────────────
log "starting frontend"
if ! compose "${up_args[@]}" frontend; then
  diagnose frontend
  rollback "docker compose up failed for frontend"
fi
if ! wait_healthy frontend "$FRONTEND_HEALTH_TIMEOUT"; then
  diagnose frontend
  rollback "frontend did not become healthy"
fi

log "RESULT: PASS — backend http://localhost:3001/api/health, frontend http://localhost:3000"
exit 0
