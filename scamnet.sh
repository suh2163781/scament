#!/bin/bash
# scamnet - non-interactive version (ip.txt input)

set -euo pipefail
IFS=$'\n\t'

GREEN='\033[32m'
BLUE='\033[34m'
NC='\033[0m'

succ() {
  echo -e "${GREEN}[$(date '+%H:%M:%S')] [+] $*${NC}" | tee -a "$SUCCESS_LOG"
}

CONNECTED_FILE="socks5_connected.txt"
LOG_DIR="logs"
IP_FILE="ip.txt"

mkdir -p "$LOG_DIR"

SUCCESS_LOG="$LOG_DIR/success.log"
PID_FILE="$LOG_DIR/scamnet.pid"
DONE_FILE="$LOG_DIR/done.count"

MAX_PROCS=5
LAST_PERCENT=-1

> "$CONNECTED_FILE"
> "$SUCCESS_LOG"
echo "0" > "$DONE_FILE"
echo "# SOCKS5 Connected" > "$CONNECTED_FILE"
echo "# Generated: $(date)" >> "$CONNECTED_FILE"
echo "# Success Only" >> "$SUCCESS_LOG"

# ==============================
# 读取 IP 文件（核心修改点）
# ==============================
if [[ ! -f "$IP_FILE" ]]; then
  echo "❌ ip.txt not found"
  exit 1
fi

IPS=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^# ]] && continue
  IPS+=("$line")
done < "$IP_FILE"

# ==============================
# ports（固定或可改）
# ==============================
PORTS_STR=${PORTS_STR:-1080,8080,8888,5555}

IFS=',' read -ra PORTS <<< "$PORTS_STR"

expanded=()
for p in "${PORTS[@]}"; do
  if [[ $p == *-* ]]; then
    r=(${p//-/ })
    for ((i=${r[0]}; i<=${r[1]}; i++)); do expanded+=($i); done
  else
    expanded+=($p)
  fi
done
PORTS=("${expanded[@]}")

# ==============================
# 日志函数
# ==============================
log() {
  echo -e "${BLUE}[$(date '+%H:%M:%S')] $*${NC}"
}

log "扫描器启动 (non-interactive mode)"
log "IP数量: ${#IPS[@]}"
log "端口: ${PORTS[*]}"
log "并发: $MAX_PROCS"

# ==============================
# SOCKS5 payload
# ==============================
printf -v PAYLOAD '\x05\x01\x00\x05\x01\x00\x03\x0Cifconfig.me\x00\x50GET / HTTP/1.1\r\nHost: ifconfig.me\r\n\r\n'

increment_done() {
  {
    flock 200
    current=$(cat "$DONE_FILE")
    echo $((current + 1)) > "$DONE_FILE"
  } 200<"$DONE_FILE"
}

test_proxy() {
  local ip=$1
  local port=$2
  local timeout=6

  local output
  output=$(printf -- "$PAYLOAD" | nc -w "$timeout" -q 0 "$ip" "$port" 2>/dev/null || true)

  if echo "$output" | grep -qE "HTTP/1\.1 [0-9]+|([0-9]{1,3}\.){3}[0-9]{1,3}"; then
    local origin
    origin=$(echo "$output" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || echo "unknown")

    {
      flock 200
      echo "socks5://$ip:$port" >> "$CONNECTED_FILE"
      num=$(grep -v '^#' "$CONNECTED_FILE" | wc -l)
      succ "通 #$num socks5://$ip:$port 出站:$origin"
    } 200<"$CONNECTED_FILE"
  fi

  increment_done
}

# ==============================
# 扫描主循环
# ==============================
log "开始扫描..."

for ip in "${IPS[@]}"; do
  for port in "${PORTS[@]}"; do
    while (( $(jobs -r | wc -l) >= MAX_PROCS )); do
      sleep 0.01
    done
    test_proxy "$ip" "$port" &
  done
done

wait

# ==============================
# 去重
# ==============================
{
  flock 200
  sort -u "$CONNECTED_FILE" -o "$CONNECTED_FILE"
} 200<"$CONNECTED_FILE"

rm -f "$PID_FILE" "$DONE_FILE"

succ "扫描完成！"
log "结果: cat $CONNECTED_FILE"
