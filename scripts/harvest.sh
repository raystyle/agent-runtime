#!/usr/bin/env bash
# harvest.sh —— 从现役镜像提取权威件(一次性种子化动作;stage.sh 缺件时也会调)
#
# 背景:acpsup/uv(0.13.4)/uvx 的源码不在仓不在机,唯一权威来源=现役镜像内
# 已烤入的二进制。本脚本起一次性容器拉出三件 + 顺带核对九件套版本与 sha256。
#
# 用法:scripts/harvest.sh [输出目录,默认 ./staging]
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source versions.env
source scripts/lib.sh

OUT="${1:-staging}"
CTR="hxr-harvest"

need_cmd incus
mkdir -p "$OUT"

log "起一次性容器(现役镜像 $INCUMBENT_FINGERPRINT)——凭证会首启自生,容器毕即删,不入镜"
sudo incus delete --force "$CTR" >/dev/null 2>&1 || true
sudo incus launch "$INCUMBENT_FINGERPRINT" "$CTR" >/dev/null 2>&1
trap 'sudo incus delete --force "$CTR" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 30); do
  incus_run "$CTR" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 1
done

log "版本快照(应与 versions.env 钉子逐件相等)"
incus_run "$CTR" bash -ec '
for b in acpsup browse claude grok codex uv; do printf "%s: " "$b"; /usr/local/bin/$b --version 2>&1 | head -1; done
printf "node: "; node --version; printf "npm: "; npm --version; printf "python3: "; python3 --version'

log "拉取 harvest 件(acpsup / uv / uvx / browse 实体)"
sudo incus file pull "$CTR/usr/local/bin/acpsup" "$OUT/acpsup"
sudo incus file pull "$CTR/usr/local/bin/uv"     "$OUT/uv"
sudo incus file pull "$CTR/usr/local/bin/uvx"    "$OUT/uvx"
sudo incus file pull "$CTR/opt/browse/${V_BROWSE}/browse" "$OUT/browse"
sudo chown "$(id -u):$(id -g)" "$OUT"/{acpsup,uv,uvx,browse}
chmod 0755 "$OUT"/{acpsup,uv,uvx,browse}

log "sha256 核对(应与 versions.env 台账相等)"
sha256sum "$OUT"/{acpsup,uv,uvx,browse}
log "harvest 毕,容器已由 trap 清理"
