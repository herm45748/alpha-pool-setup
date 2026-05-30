#!/usr/bin/env bash
# AlphaPool Pearl one-click setup.
# Installs alpha-miner and runs a 30s node-switching supervisor under PM2.

set -euo pipefail

SETUP_URL="https://raw.githubusercontent.com/herm45748/alpha-pool-setup/main/alpha-pool-setup.sh"
MINER_URL="https://pearl.alphapool.tech/downloads/alpha-miner"
INSTALL_DIR="${ALPHA_MINER_DIR:-$HOME/alpha-pool}"
MINER_BIN="$INSTALL_DIR/alpha-miner"
SUPERVISOR="$INSTALL_DIR/alpha-pool-supervisor.sh"
STATUS_BIN="$INSTALL_DIR/status.sh"
UPDATE_BIN="$INSTALL_DIR/update.sh"
RESTART_BIN="$INSTALL_DIR/restart.sh"
CONFIG_FILE="$INSTALL_DIR/alpha-pool.env"
MINER_LOG="$INSTALL_DIR/alpha-miner.log"
SUPERVISOR_LOG="$INSTALL_DIR/supervisor.log"
MINER_PID="$INSTALL_DIR/alpha-miner.pid"
CURRENT_POOL="$INSTALL_DIR/current-pool"
PM2_APP="alpha-pool"
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

ensure_pm2() {
  if command -v pm2 >/dev/null 2>&1; then
    return
  fi
  if ! command -v npm >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "npm not found, installing nodejs/npm with apt..."
      export DEBIAN_FRONTEND=noninteractive
      if [[ "$(id -u)" -eq 0 ]]; then
        apt-get update
        apt-get install -y nodejs npm
      elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y nodejs npm
      else
        echo "missing npm and sudo; run as root or install nodejs/npm first" >&2
        exit 1
      fi
    else
      echo "missing npm and apt-get; install nodejs/npm or PM2 first" >&2
      exit 1
    fi
  fi
  if command -v npm >/dev/null 2>&1; then
    echo "pm2 not found, installing with npm..."
    npm install -g pm2
    return
  fi
  echo "failed to install pm2" >&2
  exit 1
}

load_existing_or_prompt() {
  address=""
  worker=""
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    address="${ADDRESS:-}"
    worker="${WORKER:-}"
  fi

  if [[ -z "$address" ]]; then
    if [[ ! -r /dev/tty ]]; then
      echo "interactive terminal required for first install" >&2
      exit 1
    fi
    read -r -p "PRL address (prl1p...): " address </dev/tty
  fi
  if [[ ! "$address" =~ ^prl1p[a-z0-9]+$ ]]; then
    echo "invalid PRL address: must start with prl1p" >&2
    exit 1
  fi

  if [[ -z "$worker" ]]; then
    if [[ ! -r /dev/tty ]]; then
      worker="rig01"
    else
      read -r -p "Worker name [rig01]: " worker </dev/tty
      worker="${worker:-rig01}"
    fi
  fi
}

write_config() {
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
}

write_status() {
  cat >"$STATUS_BIN" <<'STATUS_EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="$HOME/alpha-pool/alpha-pool.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "status: not installed"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

running="stopped"
pid="-"
if [[ -s "$MINER_PID" ]] && kill -0 "$(cat "$MINER_PID")" >/dev/null 2>&1; then
  running="running"
  pid="$(cat "$MINER_PID")"
fi

pool="$(cat "$CURRENT_POOL" 2>/dev/null || echo "-")"

python3 - "$MINER_LOG" "$running" "$pid" "$pool" <<'PY'
import re
import statistics
import sys
from pathlib import Path

log_path, running, pid, pool = sys.argv[1:5]
text = Path(log_path).read_text(errors="replace") if Path(log_path).exists() else ""
samples = [
    (float(m.group(1)), float(m.group(2)))
    for m in re.finditer(r"hashrate_th_s=([0-9.]+).*?share_equiv_th_s=([0-9.]+)", text)
]
shares = len(re.findall(r"component=share submitted|accepted", text, flags=re.I))
errors = re.findall(
    r".*(disconnect|timeout|timed out|connection refused|connection reset|broken pipe|failed|error|stale|rejected|lost|drop|packet).*",
    text,
    flags=re.I,
)
latest = samples[-1] if samples else None
tail = samples[-20:]
avg_hash = statistics.mean(x for x, _ in tail) if tail else None
avg_share = statistics.mean(y for _, y in tail) if tail else None

if running == "running" and latest and not errors[-3:]:
    health = "OK"
elif running == "running" and latest:
    health = "WARN"
else:
    health = "BAD"

print(f"status: {health}")
print(f"miner: {running} pid={pid}")
print(f"pool: {pool}:5566")
print(f"latest_hashrate: {latest[0]:.2f} TH/s" if latest else "latest_hashrate: -")
print(f"latest_share_equiv: {latest[1]:.2f} TH/s" if latest else "latest_share_equiv: -")
print(f"avg20_hashrate: {avg_hash:.2f} TH/s" if avg_hash is not None else "avg20_hashrate: -")
print(f"avg20_share_equiv: {avg_share:.2f} TH/s" if avg_share is not None else "avg20_share_equiv: -")
print(f"shares_submitted: {shares}")
print(f"recent_error: {errors[-1]}" if errors else "recent_error: -")
PY
STATUS_EOF
  chmod +x "$STATUS_BIN"
}

write_supervisor() {
  cat >"$SUPERVISOR" <<'SUPERVISOR_EOF'
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090
source "$HOME/alpha-pool/alpha-pool.env"
STATUS_BIN="$HOME/alpha-pool/status.sh"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
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

print_report() {
  log "report begin"
  "$STATUS_BIN" 2>&1 | sed 's/^/[status] /'
  log "report end"
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

    print_report
    sleep "$CHECK_INTERVAL"
  done
}

main "$@"
SUPERVISOR_EOF
  chmod +x "$SUPERVISOR"
}

write_helpers() {
  cat >"$UPDATE_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL "$SETUP_URL" | bash -s -- --update
EOF
  chmod +x "$UPDATE_BIN"

  cat >"$RESTART_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pm2 restart alpha-pool
pm2 logs alpha-pool --lines 80
EOF
  chmod +x "$RESTART_BIN"
}

download_miner() {
  echo "downloading alpha-miner..."
  curl -fL -o "$MINER_BIN" "$MINER_URL"
  chmod +x "$MINER_BIN"
}

start_pm2() {
  pm2 delete "$PM2_APP" >/dev/null 2>&1 || true
  pm2 start "$SUPERVISOR" --name "$PM2_APP" \
    --output "$SUPERVISOR_LOG" --error "$SUPERVISOR_LOG" --merge-logs
  pm2 save >/dev/null 2>&1 || true
}

main() {
  need_cmd curl
  need_cmd timeout
  need_cmd date
  need_cmd python3
  ensure_pm2

  mkdir -p "$INSTALL_DIR"

  echo "AlphaPool Pearl setup"
  echo "Pool port: $PORT"
  echo "Supervisor check interval: ${CHECK_INTERVAL}s"

  load_existing_or_prompt
  write_config
  write_status
  write_supervisor
  write_helpers
  download_miner

  pkill -x alpha-miner >/dev/null 2>&1 || true
  start_pm2

  echo
  echo "PM2:"
  echo "  pm2 status alpha-pool"
  echo "  pm2 logs alpha-pool"
  echo "  pm2 restart alpha-pool"
  echo
  echo "Commands:"
  echo "  $STATUS_BIN"
  echo "  $UPDATE_BIN"
  echo "  $RESTART_BIN"
}

main "$@"
