#!/usr/bin/env bash
# lib.sh —— agent-runtime 脚本公共库(build/verify/stage/harvest 共用)
# 形态裁定:纯 bash + set -Eeuo pipefail,与仓文化同构(编排器 CLI 形先例)。

# log <msg>   : 步进日志(带时间戳)
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# die <msg>   : 失败即停
die()  { printf '[%s] FATAL: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# need_cmd <名> : 依赖断言
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺依赖: $1"; }

# retry <次数> <命令...> : 递增退避重试(网络不稳道用)
retry() {
  local n="$1"; shift
  for i in $(seq 1 "$n"); do
    if "$@"; then return 0; fi
    log "第 $i 次失败,${i}0s 后重试: $*"
    sleep $((i * 10))
  done
  die "重试 ${n} 次仍失败: $*"
}

# protect_alias <别名> : 硬闸——目标别名不得在保护名单(现役镜像线)
# 误出版到现役别名 = 全舰队实例源损坏,故为一切出版/别名操作的前置断言。
# 注意:末行显式 return 0——`[ ] && die` 判假时函数返 1 会连坐 set -e 杀主脚本。
protect_alias() {
  local a
  for a in ${PROTECTED_ALIASES}; do
    if [ "$1" = "$a" ]; then die "别名 '$1' 在保护名单(PROTECTED_ALIASES),拒绝操作"; fi
  done
  return 0
}

# incus_run <容器> <命令...> : 容器内执行(透传 sudo;编排器同款 CLI 道)
incus_run() {
  local c="$1"; shift
  sudo incus exec "$c" -- "$@"
}

# ws101_probe <url> <bearer> : VNC WebSocket 升级探测(复刻编排器 vncprobe.go)
# 成功判据:HTTP/1.1 101 + Sec-WebSocket-Protocol: binary。
# 101 后服务端等帧,curl 会超时——退出码忽略,只看头。
ws101_probe() {
  local url="$1" tok="$2" out
  out=$(curl -si --max-time 5 \
    -H "Authorization: Bearer ${tok}" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: $(head -c16 /dev/urandom | base64)" \
    -H "Sec-WebSocket-Protocol: binary" \
    "$url" 2>/dev/null || true)
  grep -m1 '^HTTP/1.1 101' <<<"$out" >/dev/null \
    && grep -qi 'sec-websocket-protocol: *binary' <<<"$out"
}
