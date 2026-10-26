#!/usr/bin/env bash
# build-image.sh —— haoxuan-v3 系统容器底坯镜像构建出版(唯一构建入口)
#
# 流水:preflight → init 容器 → apt 层 → rootfs overlay → 桌面栈启用 →
#       九件套(逐件版本断言)→ manifest → scrub(凭证不烤镜像)→ publish 测试别名
# 幂等:入口删旧构建容器;重跑即重来,无半成品态。
#
# 用法:./build-image.sh [--alias <名>] [--from <底坯>] [--apt-mirror <源>]
#                       [--staging <dir>] [--skip-publish] [--keep-on-fail] [-h]
# 默认别名 haoxuan-v3-verify(保护名单内的现役别名一律硬闸拒)。
set -Eeuo pipefail
cd "$(dirname "$0")"
source versions.env
source scripts/lib.sh

OPT_ALIAS="$ALIAS_VERIFY_DEFAULT"; OPT_FROM="$BASE_IMAGE"; OPT_MIRROR=""
STAGING="${STAGING_DIR:-staging}"; SKIP_PUBLISH=0; KEEP_ON_FAIL=0
BUILD_CTR="hxr-build"; FAILED=0

while [ $# -gt 0 ]; do case "$1" in
  --alias) OPT_ALIAS="$2"; shift 2 ;;
  --from) OPT_FROM="$2"; shift 2 ;;
  --apt-mirror) OPT_MIRROR="$2"; shift 2 ;;
  --staging) STAGING="$2"; shift 2 ;;
  --skip-publish) SKIP_PUBLISH=1; shift ;;
  --keep-on-fail) KEEP_ON_FAIL=1; shift ;;
  -h|--help) sed -n '3,14p' "$0"; exit 0 ;;
  *) die "未知参数: $1(看 --help)" ;;
esac; done

cleanup() {
  local rc=$?
  if [ $rc -ne 0 ]; then FAILED=1
    if [ $KEEP_ON_FAIL -eq 1 ]; then
      log "失败保留 $BUILD_CTR 排障: incus exec $BUILD_CTR -- bash"
      exit $rc
    fi
  fi
  sudo incus delete --force "$BUILD_CTR" >/dev/null 2>&1 || true
  exit $rc   # 保原退出码,勿让清理吞错
}
trap cleanup EXIT

# ── 1. preflight ──────────────────────────────────────────────
log "preflight:别名闸/底坯/staging"
protect_alias "$OPT_ALIAS"
incus image info "$OPT_FROM" >/dev/null 2>&1 || die "底坯 $OPT_FROM 不在本地镜像库"
STAGING_DIR="$STAGING" bash scripts/stage.sh --check

# ── 2. init 构建容器 ──────────────────────────────────────────
log "init:$OPT_FROM → $BUILD_CTR"
sudo incus delete --force "$BUILD_CTR" >/dev/null 2>&1 || true
sudo incus init "$OPT_FROM" "$BUILD_CTR" -c limits.memory=4GiB >/dev/null
sudo incus start "$BUILD_CTR" >/dev/null
for i in $(seq 1 60); do
  incus_run "$BUILD_CTR" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 1
done
incus_run "$BUILD_CTR" systemctl is-system-running >/dev/null

# ── 3. apt 层(底坯源;--apt-mirror 可换)────────────────────
log "apt 层:X 栈 + 编排器自愈件根修烤入(只多不少)"
incus_run "$BUILD_CTR" bash -ec "
${OPT_MIRROR:+sed -i \"s|http://deb.debian.org/debian|${OPT_MIRROR}|g\" /etc/apt/sources.list || true;}
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  xvfb openbox x11vnc feh xauth x11-xserver-utils x11-apps \
  tmux dtach unzip curl ca-certificates git fonts-noto-cjk xz-utils >/dev/null
fc-cache -f >/dev/null 2>&1 || true"

# ── 4. rootfs overlay(unit/wrapper/desktop-auth-gen 逐件推送)─
# 注意:incus file push -r 会把源目录名再建一层(落 .../system/system/),故逐件推。
log "rootfs overlay"
for u in acpsup openbox99 x11vnc99 xvfb99; do
  sudo incus file push "rootfs/etc/systemd/system/$u.service" \
    "$BUILD_CTR/etc/systemd/system/$u.service" --mode=0644 >/dev/null
done
for f in browse clean-chrome desktop-auth-gen; do
  sudo incus file push "rootfs/usr/local/bin/$f" "$BUILD_CTR/usr/local/bin/$f" --mode=0755 >/dev/null
done
incus_run "$BUILD_CTR" ln -sf clean-chrome /usr/local/bin/chrome
incus_run "$BUILD_CTR" ln -sf clean-chrome /usr/local/bin/chromium

# ── 5. 九件套(逐件 --version 断言=钉子,败即 die)──────────
log "九件套:browse/clean-chrome/uv 系(staging push)"
incus_run "$BUILD_CTR" mkdir -p /opt/browse/"$V_BROWSE" /opt/clean-chrome /opt/hx
sudo incus file push "$STAGING/browse" "$BUILD_CTR/opt/browse/$V_BROWSE/browse" --mode=0755 >/dev/null
sudo incus file push "$STAGING/acpsup" "$BUILD_CTR/usr/local/bin/acpsup" --mode=0755 >/dev/null
sudo incus file push "$STAGING/uv"     "$BUILD_CTR/usr/local/bin/uv"     --mode=0755 >/dev/null
sudo incus file push "$STAGING/uvx"    "$BUILD_CTR/usr/local/bin/uvx"    --mode=0755 >/dev/null
sudo incus file push "$STAGING/claude" "$BUILD_CTR/usr/local/bin/claude" --mode=0755 >/dev/null
sudo incus file push "$STAGING/grok"   "$BUILD_CTR/usr/local/bin/grok"   --mode=0755 >/dev/null
sudo incus file push "$STAGING/codex"  "$BUILD_CTR/usr/local/bin/codex"  --mode=0755 >/dev/null
sudo incus file push "$STAGING/kimi"   "$BUILD_CTR/usr/local/bin/kimi"   --mode=0755 >/dev/null
sudo incus file push "$STAGING/chrome.zip" "$BUILD_CTR/tmp/chrome.zip" >/dev/null
incus_run "$BUILD_CTR" bash -ec "
unzip -q /tmp/chrome.zip -d /opt/clean-chrome/
ln -sfn chromium-$V_CHROME-x86_64-unknown-linux-gnu /opt/clean-chrome/CURRENT
rm /tmp/chrome.zip"

log "十件套:官方 pi(earendil-works/pi $V_PI;插件链不载入)"
sudo incus file push "$STAGING/pi.tar.gz" "$BUILD_CTR/tmp/pi.tar.gz" >/dev/null
incus_run "$BUILD_CTR" bash -ec "
tar xzf /tmp/pi.tar.gz -C /opt/ && mv /opt/pi /opt/pi-$V_PI
ln -sfn /opt/pi-$V_PI/pi /usr/local/bin/pi
chmod 0755 /usr/local/bin/pi /opt/pi-$V_PI/pi
rm /tmp/pi.tar.gz"

log "九件套:node/npm(NodeSource node_22.x,精确钉版 $V_NODE)"
incus_run "$BUILD_CTR" bash -ec "
curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/ns.sh
bash /tmp/ns.sh >/dev/null 2>&1
# NodeSource 池滚动:setup 脚本引 latest(22.23.4),钉 22.23.3 须指名 deb
apt-get install -y -qq nodejs=$V_NODE-1nodesource1 >/dev/null && rm -f /tmp/ns.sh" \
  || die "NodeSource 道 fail(离线改 tarball 道:见 docs/recipe.md)"

log "九件套版本断言"
incus_run "$BUILD_CTR" bash -ec "
fail=0
chk(){ got=\"\$(\$1 --version 2>&1 | head -1)\"; if [ \"\$got\" = \"\$2\" ]; then echo \"  ✓ \$1\"; else echo \"  ✗ \$1: 得 '\$got' 望 '\$2'\"; fail=1; fi; }
chk acpsup 'acpsup 0.2.0 (go)'
chk browse 'browse $V_BROWSE'
chk claude '$V_CLAUDE (Claude Code)'
chk grok 'grok $V_GROK (c58f321264ba)'
chk codex 'codex-cli $V_CODEX'
chk uv 'uv $V_UV (x86_64-unknown-linux-gnu)'
chk pi '$V_PI'
chk kimi '$V_KIMI'
chk node 'v$V_NODE'
chk npm '$V_NPM'
python3 -c 'import sys; assert \"$V_PYTHON\" in sys.version' || { echo '  ✗ python3'; fail=1; }
[ \$fail -eq 0 ] || { echo '版本断言未过'; exit 1; }"

# ── 6. manifest(审计锚,烤入镜像)────────────────────────────
log "manifest → /opt/hx/image-release.txt"
incus_run "$BUILD_CTR" bash -ec "cat > /opt/hx/image-release.txt <<EOF
recipe=agent-runtime commit=\$(cat /opt/hx/.recipe_commit 2>/dev/null || echo unknown)
base=$OPT_FROM  built=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
acpsup=0.2.0 browse=$V_BROWSE claude=$V_CLAUDE grok=$V_GROK codex=$V_CODEX
chrome=$V_CHROME uv=$V_UV node=$V_NODE npm=$V_NPM python=$V_PYTHON
EOF"
[ -d .git ] && git rev-parse --short HEAD > /tmp/hxr-rc \
  && sudo incus file push /tmp/hxr-rc "$BUILD_CTR/opt/hx/.recipe_commit" >/dev/null || true

# ── 7. scrub(发布纪律:凭证不烤镜像)─────────────────────────
log "scrub:凭证/机痕/缓存"
incus_run "$BUILD_CTR" bash -ec "
systemctl stop acpsup xvfb99 openbox99 x11vnc99 2>/dev/null || true
rm -rf /var/lib/desktop /var/lib/acpsup
: > /etc/machine-id; rm -f /var/lib/systemd/random-seed
journalctl --rotate >/dev/null 2>&1 || true; journalctl --vacuum-time=1s >/dev/null 2>&1 || true
apt-get clean; rm -rf /tmp/* /var/tmp/* /root/.cache/* /var/lib/apt/lists/* /root/.ns-*"

log "桌面栈启用(四 unit,幂等)"
incus_run "$BUILD_CTR" systemctl daemon-reload
incus_run "$BUILD_CTR" systemctl enable acpsup xvfb99 openbox99 x11vnc99 >/dev/null 2>&1

# ── 8. publish ────────────────────────────────────────────────
log "publish → 别名 $OPT_ALIAS"
sudo incus stop "$BUILD_CTR" >/dev/null
if [ "$SKIP_PUBLISH" -eq 1 ]; then log "--skip-publish:只构不出版,容器由 trap 清理"; exit 0; fi
sudo incus publish "$BUILD_CTR" --alias "$OPT_ALIAS" \
  description="hx-agent-base bookworm rebuild $(date +%Y%m%d) by agent-runtime" >/dev/null
sudo incus image info "$OPT_ALIAS" | head -3
log "毕:测试别名 $OPT_ALIAS 已出版(现役别名未动;晋升走 runbook §2.1 人工三步)"
