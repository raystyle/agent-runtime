#!/usr/bin/env bash
# stage.sh —— 构建前置 staging 组装与校验
#
# 职责:把九件套二进制备齐到 staging/ 并逐件 sha256 校验(核 versions.env 台账)。
# 来源优先级:宿主本地产件(零网络,已实测与镜像逐件同 sha)→ 缺件时 harvest
# (现役镜像内拉)。claude/grok/codex/browse/chrome zip 宿主在位即用;
# acpsup/uv/uvx 必须 harvest(源码不在,宿主 uv 是 0.12.22 错版)。
#
# 用法:
#   scripts/stage.sh            # 组装(缺 harvest 件自动调 harvest.sh)
#   scripts/stage.sh --check    # 只校验不组装(build-image preflight 用)
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source versions.env
source scripts/lib.sh

OUT="${STAGING_DIR:-staging}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# 组装:宿主件拷入(硬链省空间)
if [ "$CHECK_ONLY" -eq 0 ]; then
  mkdir -p "$OUT"
  need_cmd incus
  for pair in "acpsup:acpsup" "uv:uv" "uvx:uvx" "browse:browse"; do
    dst="${pair%%:*}"; [ -s "$OUT/$dst" ] || { log "缺 $dst,调 harvest"; bash scripts/harvest.sh "$OUT"; break; }
  done
  [ -s "$OUT/claude" ] || cp "$SRC_CLAUDE" "$OUT/claude"
  [ -s "$OUT/grok" ]   || cp "$SRC_GROK"   "$OUT/grok"
  [ -s "$OUT/codex" ]  || cp "$SRC_CODEX"  "$OUT/codex"
  [ -s "$OUT/chrome.zip" ] || cp "$SRC_CHROME_ZIP" "$OUT/chrome.zip"
  # 官方 pi(earendil-works/pi release tar.gz;sha 钉台账)
  [ -s "$OUT/pi.tar.gz" ] || cp "$SRC_PI" "$OUT/pi.tar.gz"
  [ -s "$OUT/kimi" ] || cp "$SRC_KIMI" "$OUT/kimi"
  chmod 0755 "$OUT"/{acpsup,uv,uvx,browse,claude,grok,codex,kimi}
fi

# 校验:逐件 sha256 = versions.env 台账
fail=0
chk() { # chk <件> <期望sha>
  local f="$OUT/$1" got
  [ -s "$f" ] || { log "✗ $1 缺件"; fail=1; return; }
  got=$(sha256sum "$f" | awk '{print $1}')
  if [ "$got" = "$2" ]; then log "✓ $1"; else log "✗ $1 sha 不符(得 $got)"; fail=1; fi
}
chk acpsup    "$SHA_ACPSUP"
chk uv        "$SHA_UV"
chk uvx       "$SHA_UVX"
chk browse    "$SHA_BROWSE"
chk claude    "$SHA_CLAUDE"
chk grok      "$SHA_GROK"
chk codex     "$SHA_CODEX"
chk chrome.zip "$SHA_CHROME_ZIP"
chk pi.tar.gz "$SHA_PI"
chk kimi "$SHA_KIMI"

[ "$fail" -eq 0 ] || die "staging 校验未过(--check 形:先跑 scripts/stage.sh 组装)"
log "staging ${CHECK_ONLY:+校验}就绪: $OUT"
