#!/usr/bin/env bash
# AlphaPool Pearl one-click setup.
# Downloads alpha-miner, selects the lowest-latency AlphaPool endpoint,
# asks for a PRL address, then starts mining in the background.

set -euo pipefail

MINER_URL="https://pearl.alphapool.tech/downloads/alpha-miner"
INSTALL_DIR="${ALPHA_MINER_DIR:-$HOME/alpha-pool}"
MINER_BIN="$INSTALL_DIR/alpha-miner"
LOG_FILE="$INSTALL_DIR/alpha-miner.log"
PID_FILE="$INSTALL_DIR/alpha-miner.pid"
PORT="5566"

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

stop_existing() {
  if [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    echo "stopping existing alpha-miner pid $(cat "$PID_FILE")"
    kill "$(cat "$PID_FILE")" || true
    sleep 2
  fi
  pkill -f "$MINER_BIN" >/dev/null 2>&1 || true
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
  echo

  read -r -p "PRL address (prl1p...): " address </dev/tty
  if [[ ! "$address" =~ ^prl1p[a-z0-9]+$ ]]; then
    echo "invalid PRL address: must start with prl1p" >&2
    exit 1
  fi

  local worker
  read -r -p "Worker name [rig01]: " worker </dev/tty
  worker="${worker:-rig01}"

  echo
  echo "testing AlphaPool endpoints..."
  local best_host="" best_ms=999999
  for item in "${ENDPOINTS[@]}"; do
    local host label ms
    host="${item%%:*}"
    label="${item#*:}"
    ms="$(tcp_latency_ms "$host")"
    if [[ "$ms" -lt 999999 ]]; then
      printf "  %-22s %5sms  %s\n" "$host" "$ms" "$label"
    else
      printf "  %-22s failed   %s\n" "$host" "$label"
    fi
    if [[ "$ms" -lt "$best_ms" ]]; then
      best_ms="$ms"
      best_host="$host"
    fi
  done

  if [[ -z "$best_host" || "$best_ms" -ge 999999 ]]; then
    echo "all endpoints failed; defaulting to us2.alphapool.tech"
    best_host="us2.alphapool.tech"
  fi

  echo
  echo "downloading alpha-miner..."
  curl -fL -o "$MINER_BIN" "$MINER_URL"
  chmod +x "$MINER_BIN"

  stop_existing

  echo "starting miner: $best_host:$PORT"
  nohup "$MINER_BIN" \
    --pool "stratum+tcp://$best_host:$PORT" \
    --address "$address" \
    --worker "$worker" \
    >"$LOG_FILE" 2>&1 &

  echo $! > "$PID_FILE"
  echo "started pid $(cat "$PID_FILE")"
  echo "logs: tail -f $LOG_FILE"
  echo "stop: kill \$(cat $PID_FILE)"
}

main "$@"
