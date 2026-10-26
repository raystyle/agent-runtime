#!/usr/bin/env bash
# launch-web.sh —— haoxun-web 容器宿主侧 launch+接线(幂等;reattach 子命令)
#
# 接线四件:
#   raw.lxc lxc.namespace.share.net=1  共享宿主 netns(127.0.0.1:17xxx/18xxx/7318/8681 直达,网关零改动)
#   disk /run/haoxun                  实例 herdr socket 拨号(读写)
#   disk /var/lib/incus/unix.socket   编排道(同路径 bind,incus CLI 默认 socket 即对)
#   disk ~/.config/incus              B1 受限证书(launch 后推,凭证不烤镜像)
#
# 用法:web/launch-web.sh [--import-state <宿主归档目录>] | reattach
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source versions.env
source scripts/lib.sh

NAME="haoxun-web"; VOL="haoxun-web-data"
IMPORT=""

if [ "${1:-}" = "reattach" ]; then
  # incusd 重启后 bind-mount socket inode 失联:拔挂两设备再 restart 容器
  log "reattach:重挂 incus socket"
  sudo incus config device remove "$NAME" incussock >/dev/null 2>&1 || true
  sudo incus config device add "$NAME" incussock disk \
    source=/var/lib/incus/unix.socket path=/var/lib/incus/unix.socket >/dev/null
  sudo incus restart "$NAME" >/dev/null
  log "毕"; exit 0
fi
[ "${1:-}" = "--import-state" ] && IMPORT="$2"

need_cmd incus
sudo incus storage volume show zfspool "$VOL" >/dev/null 2>&1 || \
  sudo incus storage volume create zfspool "$VOL" >/dev/null

if sudo incus info "$NAME" >/dev/null 2>&1; then
  log "容器 $NAME 已在,幂等跳过 init(重建先:incus delete --force $NAME)"
else
  log "init $NAME(镜像 $WEB_ALIAS_VERIFY)"
  sudo incus init "$WEB_ALIAS_VERIFY" "$NAME" -c limits.memory=2GiB >/dev/null
  sudo incus config device add "$NAME" eth0 none >/dev/null 2>&1 || true
  sudo incus config set "$NAME" security.privileged=true
  sudo incus config set "$NAME" raw.lxc 'lxc.namespace.share.net=1'
  sudo incus config device add "$NAME" data disk pool=zfspool source="$VOL" path=/var/lib/haoxun-web >/dev/null
  sudo incus config device add "$NAME" runhaoxun disk source=/run/haoxuan path=/mnt/haoxuan-run >/dev/null
  sudo incus config device add "$NAME" incussock disk \
    source=/var/lib/incus/unix.socket path=/var/lib/incus/unix.socket >/dev/null
fi

log "start"
sudo incus start "$NAME" >/dev/null 2>&1 || sudo incus restart "$NAME" >/dev/null
for i in $(seq 1 60); do
  sudo incus exec "$NAME" -- systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 1
done

# B1 受限证书推入(每次幂等推,保 incusd 证书轮换后不失)
sudo incus file push -r "$HOME/.config/incus" "$NAME/root/.config/incus" >/dev/null

# 一次性状态迁移
if [ -n "$IMPORT" ] && [ -d "$IMPORT" ]; then
  log "迁入 Ovis 状态: $IMPORT"
  sudo incus exec "$NAME" -- mkdir -p /var/lib/haoxun-web/import
  sudo incus file push -r "$IMPORT" "$NAME/var/lib/haoxun-web/import/herdr-web-ui" >/dev/null
  sudo incus exec "$NAME" -- rm -f /var/lib/haoxun-web/.provisioned
  sudo incus restart "$NAME" >/dev/null
fi

log "验:三进程"
sleep 8
sudo incus exec "$NAME" -- bash -ec '
systemctl is-active haoxun-web-provision haoxun-web-herdr haoxun-web-ovis haoxun-web-zacp
[ -S /root/.config/herdr/herdr.sock ] && echo "✓ herdr.sock"
curl -s -o /dev/null -w "7318: %{http_code}\n" http://127.0.0.1:7318/api/health
curl -s -o /dev/null -w "8681: %{http_code}\n" http://127.0.0.1:8681/api/v1/agents'
log "毕:浏览器 http://127.0.0.1:8681/"
