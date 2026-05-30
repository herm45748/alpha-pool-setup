#!/usr/bin/env bash
# AlphaPool Pearl one-click setup.
# Installs alpha-miner and starts a supervisor that checks pool latency every 30s.

set -euo pipefail

MINER_URL="https://pearl.alphapool.tech/downloads/alpha-miner"
INSTALL_DIR="${ALPHA_MINER_DIR:-$HOME/alpha-pool}"
MINER_BIN="$INSTALL_DIR/alpha-miner"
SUPERVISOR="$INSTALL_DIR/alpha-pool-supervisor.sh"
CONFIG_FILE="$INSTALL_DIR/alpha-pool.env"
MINER_LOG="$INSTALL_DIR/alpha-miner.log"
SUPERVISOR_LOG="$INSTALL_DIR/supervisor.log"
MINER_PID="$INSTALL_DIR/alpha-miner.pid"
SUPERVISOR_PID="$INSTALL_DIR/supervisor.pid"
CURRENT_POOL="$INSTALL_DIR/current-pool"
PORT="5566"
CHECK_INTERVAL="30"

ENDPOINTS=(
  "us1.alphapool.tech:North America East"
  "us2.alphapool.tech:North America West"
  "eu1.alphapool.tech:Europe 1"
  "eu2.alphapool.tech:Europe 2"
  "ru1.alphapool.tech:Russia / Eurasia"
  "sg1.alphapool.tech:Asia Singapore"
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

shell_quote() {
  printf "%q" "$1"
}

stop_pid_file() {
  local file="$1"
  if [[ -s "$file" ]] && kill -0 "$(cat "$file")" >/dev/null 2>&1; then
    kill "$(cat "$file")" || true
    sleep 2
  fi
}

write_supervisor() {
  cat >"$SUPERVISOR" <<'SUPERVISOR_EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$HOME/alpha-pool/alpha-pool.env"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >>"$SUPERVISOR_LOG"
}

tcp_latency_ms() {
  local host="$1"
  local start end
  start="$(date +%s%3N)"
  if timeout 3 bash -c ":</dev/tcp/$host/$PORT" >/dev/null 2>&1; then
    end="$(date +%s%3N)"
    echo $((end - start))
  else
    echo 999999
  fi
}

best_pool() {
  local best_host="" best_ms=999999 item host label ms
  for item in "${ENDPOINTS[@]}"; do
    host="${item%%:*}"
    label="${item#*:}"
    ms="$(tcp_latency_ms "$host")"
    if [[ "$ms" -lt 999999 ]]; then
      log "latency ${host}:${PORT} ${ms}ms ${label}"
    else
      log "latency ${host}:${PORT} failed ${label}"
    fi
    if [[ "$ms" -lt "$best_ms" ]]; then
      best_ms="$ms"
      best_host="$host"
    fi
  done
  if [[ -z "$best_host" || "$best_ms" -ge 999999 ]]; then
    best_host="us2.alphapool.tech"
    best_ms=999999
  fi
  printf '%s' "$best_host"
}

miner_running() {
  [[ -s "$MINER_PID" ]] && kill -0 "$(cat "$MINER_PID")" >/dev/null 2>&1
}

recent_errors() {
  [[ -f "$MINER_LOG" ]] || return 1
  tail -n 80 "$MINER_LOG" | grep -Eiq 'disconnect|timeout|timed out|connection refused|connection reset|broken pipe|failed|error|stale|rejected|lost|drop|packet'
}

recent_shares() {
  [[ -f "$MINER_LOG" ]] || return 1
  tail -n 160 "$MINER_LOG" | grep -Eiq 'submitted|accepted|found_candidate|hashrate_th_s'
}

stop_miner() {
  if miner_running; then
    log "stopping miner pid $(cat "$MINER_PID")"
    kill "$(cat "$MINER_PID")" || true
    sleep 2
  fi
  pkill -x alpha-miner >/dev/null 2>&1 || true
}

start_miner() {
  local host="$1"
  : >"$MINER_LOG"
  log "starting miner pool=${host}:${PORT} worker=${WORKER}"
  nohup "$MINER_BIN" \
    --pool "stratum+tcp://${host}:${PORT}" \
    --address "$ADDRESS" \
    --worker "$WORKER" \
    >>"$MINER_LOG" 2>&1 &
  echo $! >"$MINER_PID"
  echo "$host" >"$CURRENT_POOL"
}

main() {
  mkdir -p "$INSTALL_DIR"
  log "supervisor started interval=${CHECK_INTERVAL}s port=${PORT}"
  while true; do
    host="$(best_pool)"
    current="$(cat "$CURRENT_POOL" 2>/dev/null || true)"

    restart_reason=""
    if ! miner_running; then
      restart_reason="miner_not_running"
    elif [[ "$host" != "$current" ]]; then
      restart_reason="better_pool ${current:-none}->${host}"
    elif recent_errors; then
      restart_reason="recent_error"
    elif ! recent_shares; then
      restart_reason="no_recent_share"
    fi

    if [[ -n "$restart_reason" ]]; then
      log "restart reason=${restart_reason}"
      stop_miner
      start_miner "$host"
    else
      log "ok pool=${current}"
    fi

    sleep "$CHECK_INTERVAL"
  done
}

main "$@"
SUPERVISOR_EOF
  chmod +x "$SUPERVISOR"
}

main() {
  need_cmd curl
  need_cmd timeout
  need_cmd date

  if [[ ! -r /dev/tty ]]; then
    echo "interactive terminal required" >&2
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"

  echo "AlphaPool Pearl setup"
  echo "Miner: $MINER_URL"
  echo "Pool port: $PORT"
  echo "Supervisor check interval: ${CHECK_INTERVAL}s"
  echo

  read -r -p "PRL address (prl1p...): " address </dev/tty
  if [[ ! "$address" =~ ^prl1p[a-z0-9]+$ ]]; then
    echo "invalid PRL address: must start with prl1p" >&2
    exit 1
  fi

  local worker
  read -r -p "Worker name [rig01]: " worker </dev/tty
  worker="${worker:-rig01}"

  echo "downloading alpha-miner..."
  curl -fL -o "$MINER_BIN" "$MINER_URL"
  chmod +x "$MINER_BIN"

  {
    printf 'INSTALL_DIR=%s\n' "$(shell_quote "$INSTALL_DIR")"
    printf 'MINER_BIN=%s\n' "$(shell_quote "$MINER_BIN")"
    printf 'MINER_LOG=%s\n' "$(shell_quote "$MINER_LOG")"
    printf 'SUPERVISOR_LOG=%s\n' "$(shell_quote "$SUPERVISOR_LOG")"
    printf 'MINER_PID=%s\n' "$(shell_quote "$MINER_PID")"
    printf 'CURRENT_POOL=%s\n' "$(shell_quote "$CURRENT_POOL")"
    printf 'PORT=%s\n' "$(shell_quote "$PORT")"
    printf 'CHECK_INTERVAL=%s\n' "$(shell_quote "$CHECK_INTERVAL")"
    printf 'ADDRESS=%s\n' "$(shell_quote "$address")"
    printf 'WORKER=%s\n' "$(shell_quote "$worker")"
    printf 'ENDPOINTS=(\n'
    for item in "${ENDPOINTS[@]}"; do
      printf '  %s\n' "$(shell_quote "$item")"
    done
    printf ')\n'
  } >"$CONFIG_FILE"

  write_supervisor

  stop_pid_file "$SUPERVISOR_PID"
  stop_pid_file "$MINER_PID"
  pkill -x alpha-miner >/dev/null 2>&1 || true

  : >"$SUPERVISOR_LOG"
  nohup "$SUPERVISOR" >>"$SUPERVISOR_LOG" 2>&1 &
  echo $! >"$SUPERVISOR_PID"

  echo "supervisor pid $(cat "$SUPERVISOR_PID")"
  echo "miner log: tail -f $MINER_LOG"
  echo "supervisor log: tail -f $SUPERVISOR_LOG"
  echo "current pool: cat $CURRENT_POOL"
  echo "stop: kill \$(cat $SUPERVISOR_PID); kill \$(cat $MINER_PID)"
}

main "$@"
