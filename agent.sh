#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/node-probe/agent.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

LOG_LEVEL="${LOG_LEVEL:-${log_level:-info}}"

NODE_ID="${NODE_ID:-${node_id:-}}"
NODE_NAME="${NODE_NAME:-${node_name:-}}"
REPORT_URL="${REPORT_URL:-${report_url:-}}"
REPORT_TOKEN="${REPORT_TOKEN:-${report_token:-}}"
REPORT_INTERVAL_SECONDS="${REPORT_INTERVAL_SECONDS:-${report_interval_seconds:-1}}"
REPORT_TIMEOUT_SECONDS="${REPORT_TIMEOUT_SECONDS:-${report_timeout_seconds:-10}}"
STATE_DIR="${STATE_DIR:-${state_dir:-/var/lib/node-probe}}"
PROC_ROOT="${PROC_ROOT:-${proc_root:-/proc}}"

if [[ -z "$REPORT_URL" || -z "$REPORT_TOKEN" ]]; then
  echo "Missing required env: REPORT_URL, REPORT_TOKEN" >&2
  exit 1
fi

if [[ -z "$NODE_ID" ]]; then
  echo "Missing required env: NODE_ID" >&2
  exit 1
fi

if [[ -z "$NODE_NAME" ]]; then
  NODE_NAME="$NODE_ID"
fi

log_info() {
  if [[ "$LOG_LEVEL" == "info" || "$LOG_LEVEL" == "debug" ]]; then
    echo "[INFO] $(date -Is) $*"
  fi
}

log_warn() {
  echo "[WARN] $(date -Is) $*" >&2
}

log_debug() {
  if [[ "$LOG_LEVEL" == "debug" ]]; then
    echo "[DEBUG] $(date -Is) $*"
  fi
}

if ! [[ "$REPORT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]; then
  REPORT_INTERVAL_SECONDS="60"
fi

if (( REPORT_INTERVAL_SECONDS < 1 )); then
  REPORT_INTERVAL_SECONDS="1"
fi

mkdir -p "$STATE_DIR"

state_file="$STATE_DIR/traffic.state"

read_traffic() {
  local rx=0
  local tx=0
  while read -r line; do
    if [[ "$line" == *:* ]]; then
      local iface
      iface="$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')"
      if [[ "$iface" == "lo" ]]; then
        continue
      fi
      local data
      data="$(echo "$line" | awk -F: '{print $2}')"
      local rx_bytes
      local tx_bytes
      rx_bytes="$(echo "$data" | awk '{print $1}')"
      tx_bytes="$(echo "$data" | awk '{print $9}')"
      rx=$((rx + rx_bytes))
      tx=$((tx + tx_bytes))
    fi
  done < "${PROC_ROOT}/net/dev"
  echo "$rx $tx"
}

read_cpu_usage() {
  local cpu_line
  cpu_line="$(head -n 1 "${PROC_ROOT}/stat")"
  local user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ <<< "$cpu_line"
  local idle_all=$((idle + iowait))
  local non_idle=$((user + nice + system + irq + softirq + steal))
  local total=$((idle_all + non_idle))
  echo "$idle_all $total"
}

read_mem_usage() {
  local mem_total mem_available
  mem_total="$(awk '/MemTotal/ {print $2}' "${PROC_ROOT}/meminfo")"
  mem_available="$(awk '/MemAvailable/ {print $2}' "${PROC_ROOT}/meminfo")"
  local mem_used=$((mem_total - mem_available))
  echo "$mem_total $mem_used"
}

read_swap_usage() {
  local swap_total swap_free
  swap_total="$(awk '/SwapTotal/ {print $2}' "${PROC_ROOT}/meminfo")"
  swap_free="$(awk '/SwapFree/ {print $2}' "${PROC_ROOT}/meminfo")"
  local swap_used=$((swap_total - swap_free))
  echo "$swap_total $swap_used"
}

read_disk_usage() {
  local line
  line="$(df -k / | tail -n 1)"
  local total used avail
  total="$(echo "$line" | awk '{print $2}')"
  used="$(echo "$line" | awk '{print $3}')"
  avail="$(echo "$line" | awk '{print $4}')"
  echo "$total $used $avail"
}

read_inode_usage() {
  local line
  line="$(df -i / | tail -n 1)"
  local total used avail
  total="$(echo "$line" | awk '{print $2}')"
  used="$(echo "$line" | awk '{print $3}')"
  avail="$(echo "$line" | awk '{print $4}')"
  echo "$total $used $avail"
}

read_loadavg() {
  awk '{print $1 " " $2 " " $3}' "${PROC_ROOT}/loadavg"
}

read_uptime() {
  awk '{print int($1)}' "${PROC_ROOT}/uptime"
}

load_state() {
  if [[ -f "$state_file" ]]; then
    local rx_prev tx_prev idle_prev total_prev rx_accum tx_accum
    read -r rx_prev tx_prev idle_prev total_prev rx_accum tx_accum < "$state_file"
    rx_prev="${rx_prev:-0}"
    tx_prev="${tx_prev:-0}"
    idle_prev="${idle_prev:-0}"
    total_prev="${total_prev:-0}"
    rx_accum="${rx_accum:-0}"
    tx_accum="${tx_accum:-0}"
    echo "$rx_prev $tx_prev $idle_prev $total_prev $rx_accum $tx_accum"
  else
    echo "0 0 0 0 0 0"
  fi
}

save_state() {
  echo "$1 $2 $3 $4 $5 $6" > "$state_file"
}

post_report() {
  local now_ts
  now_ts="$(date +%s)"

  local traffic_now
  traffic_now="$(read_traffic)"
  local rx_now tx_now
  read -r rx_now tx_now <<< "$traffic_now"

  local state
  state="$(load_state)"
  local rx_prev tx_prev idle_prev total_prev rx_accum tx_accum
  read -r rx_prev tx_prev idle_prev total_prev rx_accum tx_accum <<< "$state"

  local rx_delta=0
  local tx_delta=0
  if (( rx_now < rx_prev )); then
    rx_accum=$((rx_accum + rx_prev))
    rx_delta=$rx_now
  else
    rx_delta=$((rx_now - rx_prev))
  fi
  if (( tx_now < tx_prev )); then
    tx_accum=$((tx_accum + tx_prev))
    tx_delta=$tx_now
  else
    tx_delta=$((tx_now - tx_prev))
  fi

  local cpu_now
  cpu_now="$(read_cpu_usage)"
  local idle_now total_now
  read -r idle_now total_now <<< "$cpu_now"

  local cpu_usage=0
  local total_delta=$((total_now - total_prev))
  local idle_delta=$((idle_now - idle_prev))
  if [[ "$total_delta" -gt 0 ]]; then
    cpu_usage=$(( (1000 * (total_delta - idle_delta) / total_delta) ))
  fi

  local mem_usage
  mem_usage="$(read_mem_usage)"
  local mem_total mem_used
  read -r mem_total mem_used <<< "$mem_usage"

  local swap_usage
  swap_usage="$(read_swap_usage)"
  local swap_total swap_used
  read -r swap_total swap_used <<< "$swap_usage"

  local disk_usage
  disk_usage="$(read_disk_usage)"
  local disk_total disk_used disk_avail
  read -r disk_total disk_used disk_avail <<< "$disk_usage"

  local inode_usage
  inode_usage="$(read_inode_usage)"
  local inode_total inode_used inode_avail
  read -r inode_total inode_used inode_avail <<< "$inode_usage"

  local loadavg
  loadavg="$(read_loadavg)"
  local load_one load_five load_fifteen
  read -r load_one load_five load_fifteen <<< "$loadavg"

  local uptime_seconds
  uptime_seconds="$(read_uptime)"

  save_state "$rx_now" "$tx_now" "$idle_now" "$total_now" "$rx_accum" "$tx_accum"

  local rx_total_persistent=$((rx_accum + rx_now))
  local tx_total_persistent=$((tx_accum + tx_now))

  local payload
  payload="$(cat <<EOF
{
  "node_id": "${NODE_ID}",
  "node_name": "${NODE_NAME}",
  "timestamp": ${now_ts},
  "uptime_seconds": ${uptime_seconds},
  "traffic": {
    "rx_bytes_total": ${rx_now},
    "tx_bytes_total": ${tx_now},
    "rx_bytes_delta": ${rx_delta},
    "tx_bytes_delta": ${tx_delta},
    "rx_bytes_total_persistent": ${rx_total_persistent},
    "tx_bytes_total_persistent": ${tx_total_persistent}
  },
  "cpu": {
    "usage_permille": ${cpu_usage}
  },
  "memory": {
    "total_kb": ${mem_total},
    "used_kb": ${mem_used}
  },
  "swap": {
    "total_kb": ${swap_total},
    "used_kb": ${swap_used}
  },
  "load": {
    "one": ${load_one},
    "five": ${load_five},
    "fifteen": ${load_fifteen}
  },
  "disk": {
    "total_kb": ${disk_total},
    "used_kb": ${disk_used},
    "avail_kb": ${disk_avail},
    "inodes_total": ${inode_total},
    "inodes_used": ${inode_used},
    "inodes_avail": ${inode_avail}
  }
}
EOF
)"

  local http_code
  http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$REPORT_URL" \
    -H "authorization: Bearer ${REPORT_TOKEN}" \
    -H "content-type: application/json" \
    --connect-timeout 3 \
    --max-time "$REPORT_TIMEOUT_SECONDS" \
    --retry 2 \
    --retry-delay 1 \
    --data "$payload" || echo "000")"

  if [[ "$http_code" == "200" ]]; then
    log_info "report ok name=${NODE_NAME} id=${NODE_ID} rx=${rx_delta} tx=${tx_delta}"
  else
    log_warn "report failed http=${http_code} name=${NODE_NAME} id=${NODE_ID}"
  fi
}

while true; do
  post_report
  sleep "$REPORT_INTERVAL_SECONDS"
done
