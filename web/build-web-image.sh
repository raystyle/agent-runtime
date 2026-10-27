#!/usr/bin/env bash
# build-web-image.sh —— haoxuan-web 容器镜像构建出版(web/ 配方唯一构建入口)
#
# web 容器 = 宿主伴生应用容器:haoxuan web 全家自包含——
#   容器自己的 herdr(HOME 隔离,绝不碰宿主 ~/.config/herdr)+
#   Ovis fork(raystyle/herdr-web-ui,烤入)+ zacp 网关(staging 二进制)。
# launch 接线(launch-web.sh):共享宿主 netns + bind-mount incus socket,/run/haoxuan。
# 红线:宿主系统 herdr 永不被 haoxuan 碰(插件装宿主的教训:乱 spawn+抢 socket)。
#
# 用法:web/build-web-image.sh [--alias <名>] [--staging <dir>] [--skip-publish]
#                                     [--keep-on-fail] [-h]
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source versions.env
source scripts/lib.sh

OPT_ALIAS="$WEB_ALIAS_VERIFY"; STAGING="${STAGING_DIR:-staging}"
SKIP_PUBLISH=0; KEEP_ON_FAIL=0
BUILD_CTR="hxr-web-build"

while [ $# -gt 0 ]; do case "$1" in
  --alias) OPT_ALIAS="$2"; shift 2 ;;
  --staging) STAGING="$2"; shift 2 ;;
  --skip-publish) SKIP_PUBLISH=1; shift ;;
  --keep-on-fail) KEEP_ON_FAIL=1; shift ;;
  -h|--help) sed -n '3,13p' "$0"; exit 0 ;;
  *) die "未知参数: $1(看 --help)" ;;
esac; done

cleanup() {
  local rc=$?
  if [ $rc -ne 0 ] && [ $KEEP_ON_FAIL -eq 1 ]; then
    log "失败保留 $BUILD_CTR 排障: incus exec $BUILD_CTR -- bash"; exit $rc
  fi
  sudo incus delete --force "$BUILD_CTR" --project haoxuan >/dev/null 2>&1 || \
    sudo incus delete --force "$BUILD_CTR" >/dev/null 2>&1 || true
  exit $rc
}
trap cleanup EXIT

# ── 1. preflight ──────────────────────────────────────────────
log "preflight:别名闸/底坯/staging"
protect_alias_web() { # web 保护名单与实例名单分立
  local a; for a in $WEB_PROTECTED_ALIASES; do
    if [ "$1" = "$a" ]; then die "别名 '$1' 在 web 保护名单,拒绝操作"; fi
  done; return 0
}
protect_alias_web "$OPT_ALIAS"
incus image info "$WEB_BASE_IMAGE" >/dev/null 2>&1 || die "底坯 $WEB_BASE_IMAGE 不在库"
for f in "$SRC_PI" "$SRC_ZACP" "$SRC_HERDR" "$SRC_CLAUDE" "$SRC_GROK" "$SRC_CODEX" "$SRC_KIMI"; do
  [ -s "$f" ] || die "staging 缺件: $f"
done
[ -s "$STAGING/pi-linux-x64.tar.gz" ] || cp "$SRC_PI" "$STAGING/pi-linux-x64.tar.gz"
[ -s "$STAGING/zacp" ] || cp "$SRC_ZACP" "$STAGING/zacp"
[ -s "$STAGING/herdr" ] || cp "$SRC_HERDR" "$STAGING/herdr"
got=$(sha256sum "$STAGING/pi-linux-x64.tar.gz" | awk '{print $1}')
[ "$got" = "$SHA_PI" ] || die "pi tar.gz sha 不符(得 $got)"
# 五家 agent CLI(chat 面 stdio 直起; zacp LookPath 判 installed)
for pair in "claude:$SRC_CLAUDE" "grok:$SRC_GROK" "codex:$SRC_CODEX" "kimi:$SRC_KIMI"; do
  n=${pair%%:*}; s=${pair#*:}
  [ -s "$STAGING/$n" ] || cp "$s" "$STAGING/$n"
done

# ── 2. init 构建容器 ──────────────────────────────────────────
log "init:$WEB_BASE_IMAGE → $BUILD_CTR"
sudo incus delete --force "$BUILD_CTR" >/dev/null 2>&1 || true
sudo incus init "$WEB_BASE_IMAGE" "$BUILD_CTR" -c limits.memory=4GiB >/dev/null
sudo incus start "$BUILD_CTR" >/dev/null
for i in $(seq 1 60); do
  incus_run "$BUILD_CTR" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 1
done
incus_run "$BUILD_CTR" systemctl is-system-running >/dev/null

# ── 3. apt 层 + bun + incus CLI ───────────────────────────────
log "apt:bun + incus CLI + 基础件"
incus_run "$BUILD_CTR" bash -ec '
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  curl ca-certificates git unzip openssh-client sqlite3 >/dev/null
# bun
curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1
mv /root/.bun/bin/bun /usr/local/bin/bun && rm -rf /root/.bun
/usr/local/bin/incus --version >/dev/null 2>&1 || true  # glibc 探针
bun --version'

# ── 4. 二进制 push(herdr/zacp/incus + 五家 agent CLI)────────
# incus CLI 烤宿主件(6.0.5 与宿主 daemon 同套,glibc 动态链 bookworm 2.36 可载)
log "push herdr + zacp + incus + 五家 CLI"
sudo incus file push "$STAGING/herdr" "$BUILD_CTR/usr/local/bin/herdr" --mode=0755 >/dev/null
sudo incus file push "$STAGING/zacp"  "$BUILD_CTR/usr/local/bin/zacp"  --mode=0755 >/dev/null
sudo incus file push /usr/bin/incus   "$BUILD_CTR/usr/local/bin/incus" --mode=0755 >/dev/null
for n in claude grok codex kimi; do
  sudo incus file push "$STAGING/$n" "$BUILD_CTR/usr/local/bin/$n" --mode=0755 >/dev/null
done
# 官方 pi:tar.gz 推入解包 /opt/pi 树 + 软链(与实例镜像同形)
sudo incus file push "$STAGING/pi-linux-x64.tar.gz" "$BUILD_CTR/tmp/pi.tgz" >/dev/null
incus_run "$BUILD_CTR" bash -ec '
mkdir -p /opt/pi && tar -xzf /tmp/pi.tgz -C /opt/pi
PIBIN=$(find /opt/pi -maxdepth 3 -type f -name pi | head -1)
[ -n "$PIBIN" ] && ln -sfn "$PIBIN" /usr/local/bin/pi
rm -f /tmp/pi.tgz'

# ── 5. Ovis fork 烤入(钉 commit)─────────────────────────────
log "Ovis 烤入: raystyle/herdr-web-ui@$WEB_V_OVIS"
incus_run "$BUILD_CTR" bash -ec "
git clone -q https://github.com/raystyle/herdr-web-ui /opt/herdr-web-ui
cd /opt/herdr-web-ui && git checkout -q $WEB_V_OVIS
bun install --frozen-lockfile >/dev/null 2>&1
bun run build >/dev/null 2>&1
[ -f dist/index.html ] || [ -f dist/index.js ] || { echo 'ovis dist 缺'; exit 1; }
rm -rf .git node_modules/src 2>/dev/null || true"

# ── 6. rootfs overlay(unit 四件 + provision)────────────────
log "rootfs overlay"
for u in haoxuan-web-provision haoxuan-web-herdr haoxuan-web-ovis haoxuan-web-zacp; do
  sudo incus file push "web/rootfs/etc/systemd/system/$u.service" \
    "$BUILD_CTR/etc/systemd/system/$u.service" --mode=0644 >/dev/null
done
sudo incus file push web/rootfs/usr/local/bin/haoxuan-web-provision \
  "$BUILD_CTR/usr/local/bin/haoxuan-web-provision" --mode=0755 >/dev/null
# 目录先建后推,零回退分支(前批 || 回退链在此翻车:file does not exist)
incus_run "$BUILD_CTR" mkdir -p /opt/haoxuan-web/bin /opt/haoxuan-web/node_modules
sudo incus file push web/rootfs/opt/haoxuan-web/config.toml.template \
  "$BUILD_CTR/opt/haoxuan-web/config.toml.template" --mode=0644 >/dev/null
# ACP 桥适配层+SDK(chat 面五家经它说 ACP;bun 跑 .mjs,零 node 依赖)
sudo incus file push ../bin/acpsup-bridge.mjs "$BUILD_CTR/opt/haoxuan-web/bin/acpsup-bridge.mjs" --mode=0755 >/dev/null
sudo incus file push -r ../node_modules/@agentclientprotocol "$BUILD_CTR/opt/haoxuan-web/node_modules/" >/dev/null
sudo incus file push -r ../node_modules/zod "$BUILD_CTR/opt/haoxuan-web/node_modules/" >/dev/null
# ── 7. mask 网络(共享宿主 netns 的守卫)──────────────────────
log "mask networkd/udevd(共享 netns 守卫)"
incus_run "$BUILD_CTR" systemctl mask systemd-networkd.service \
  systemd-networkd-wait-online.service systemd-udevd.service \
  systemd-udevd-control.socket systemd-udevd-kernel.socket >/dev/null 2>&1 || true

# ── 8. 启用 unit + 版本断言 ───────────────────────────────────
log "enable units + 断言"
incus_run "$BUILD_CTR" systemctl daemon-reload
incus_run "$BUILD_CTR" systemctl enable haoxuan-web-provision haoxuan-web-herdr haoxuan-web-ovis haoxuan-web-zacp >/dev/null 2>&1
incus_run "$BUILD_CTR" bash -ec "
herdr --version >/dev/null && echo '✓ herdr'
zacp --version 2>/dev/null || zacp --help >/dev/null 2>&1 && echo '✓ zacp'
bun --version >/dev/null && echo '✓ bun'
incus --version >/dev/null && echo '✓ incus'
for n in claude grok codex kimi pi; do command -v \$n >/dev/null && echo \"✓ \$n\"; done"

# ── 9. scrub + publish ────────────────────────────────────────
log "scrub"
incus_run "$BUILD_CTR" bash -ec "
: > /etc/machine-id; rm -f /var/lib/systemd/random-seed
journalctl --rotate >/dev/null 2>&1 || true; journalctl --vacuum-time=1s >/dev/null 2>&1 || true
apt-get clean; rm -rf /tmp/* /var/tmp/* /root/.cache/* /var/lib/apt/lists/* /root/.bun
grep -rl 'client.crt\|client.key' /root 2>/dev/null && exit 1 || true" || true

log "publish → $OPT_ALIAS"
sudo incus stop "$BUILD_CTR" >/dev/null
if [ "$SKIP_PUBLISH" -eq 1 ]; then log "--skip-publish:毕"; exit 0; fi
sudo incus publish "$BUILD_CTR" --alias "$OPT_ALIAS" \
  description="haoxuan-web rebuild $(date +%Y%m%d) by agent-runtime" >/dev/null
sudo incus image info "$OPT_ALIAS" | head -3
log "毕:web 镜像别名 $OPT_ALIAS(launch 走 web/launch-web.sh)"
