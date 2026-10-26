#!/usr/bin/env bash
# verify-image.sh —— 镜像发布闸(唯一验证入口;六道闸全绿才可晋升)
#
# 六闸:①launch 复刻编排器同形(project haoxuan/3GiB/3cpu/acp proxy)
#      ②四 unit 活 ③acpsup health 401→200 阶梯 ④VNC WS 101 binary
#      ⑤凭证卫生(首启自生=scrub 净+desktop-auth-gen 工作)
#      ⑥基线 diff(对照现役镜像,九件版本硬等+清单只多不少)
#
# 用法:./verify-image.sh [--alias <名>] [--baseline <名>] [--port <口>]
#                        [--keep] [--skip-baseline-diff] [-h]
set -Eeuo pipefail
cd "$(dirname "$0")"
source versions.env
source scripts/lib.sh

ALIAS="$ALIAS_VERIFY_DEFAULT"; BASELINE="haoxun-v3"; PORT=17699
KEEP=0; SKIP_DIFF=0
V_CTR="haoxuan-vfy-new-$$"; B_CTR="haoxuan-vfy-base-$$"
declare -a RESULTS=()

while [ $# -gt 0 ]; do case "$1" in
  --alias) ALIAS="$2"; shift 2 ;;
  --baseline) BASELINE="$2"; shift 2 ;;
  --port) PORT="$2"; shift 2 ;;
  --keep) KEEP=1; shift ;;
  --skip-baseline-diff) SKIP_DIFF=1; shift ;;
  -h|--help) sed -n '3,13p' "$0"; exit 0 ;;
  *) die "未知参数: $1" ;;
esac; done

gate() { # gate <闸名> <0|1> <细节>
  if [ "$2" -eq 0 ]; then RESULTS+=("✓ 闸$1"); else RESULTS+=("✗ 闸$1"); fi
  log "闸$1: $([ "$2" -eq 0 ] && echo PASS || echo FAIL) $3"
  return 0
}
# vexec <容器> <命令...> : 容器内执行(project haoxuan 域;incus exec 不继承 launch 的 --project)
vexec() {
  local c="$1"; shift
  sudo incus exec "$c" --project haoxuan -- "$@"
}
cleanup() {
  sudo incus delete --force "$V_CTR" --project haoxuan >/dev/null 2>&1 || true
  [ -n "${B_CTR:-}" ] && sudo incus delete --force "$B_CTR" --project haoxuan >/dev/null 2>&1 || true
  if [ "$KEEP" -eq 1 ]; then log "--keep:验容器保留:$V_CTR(基线容器仍清)"; fi
  exit 0
}
trap cleanup EXIT

# ── 闸0:launch 复刻编排器 LaunchInstance 同形 ────────────────
log "launch $ALIAS(project haoxuan,编排器同形)"
sudo incus launch "$ALIAS" "$V_CTR" --project haoxuan \
  -c limits.memory=3GiB -c limits.cpu=3 >/dev/null 2>&1 || die "launch fail"
sudo incus config device add "$V_CTR" acp proxy --project haoxuan \
  listen=tcp:127.0.0.1:$PORT connect=tcp:127.0.0.1:$ACP_PORT >/dev/null
for i in $(seq 1 60); do
  vexec "$V_CTR" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 1
done
gate "0 launch+systemd" 0 ""

# ── 闸1:四 unit ───────────────────────────────────────────────
g=0
for u in xvfb99 openbox99 x11vnc99 acpsup; do
  st=$(vexec "$V_CTR" systemctl is-active "$u" 2>/dev/null || true)
  [ "$st" = active ] || { g=1; log "  unit $u: $st"; }
done
gate "1 四 unit active" $g ""

# ── 闸2/3:acpsup health 阶梯(编排器 waitHealthy 同径)────────
code=$(vexec "$V_CTR" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ACP_PORT/health" 2>/dev/null || true)
gate "2 无 token health=401" $([ "$code" = 401 ] && echo 0 || echo 1) "得 $code"
sleep 3  # 首启凭证/token 自生窗口
key=$(vexec "$V_CTR" cat /var/lib/acpsup/token 2>/dev/null || true)
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${key}" \
  "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
gate "3 经 proxy Bearer health=200" $([ "$code" = 200 ] && echo 0 || echo 1) "得 $code"

# ── 闸4:VNC WS 101 binary(复刻 vncprobe.go)────────────────
if ws101_probe "http://127.0.0.1:$PORT/vnc?display=desktop" "$key"; then g=0; else g=1; fi
gate "4 VNC WS 101 binary" $g ""

# ── 闸5:凭证卫生(一生一次自生)──────────────────────────────
g=0
for f in /var/lib/desktop/x99.auth /var/lib/desktop/vnc.passwd.plain \
         /var/lib/acpsup/token /var/lib/acpsup/keys.json; do
  vexec "$V_CTR" test -s "$f" 2>/dev/null || { g=1; log "  缺 $f"; }
done
gate "5 凭证自生" $g "x99.auth/vnc.passwd.plain/token/keys.json"

# ── 闸6:基线 diff ─────────────────────────────────────────────
REPORT="/tmp/agent-runtime-verify-$(date +%Y%m%d-%H%M%S).md"
if [ "$SKIP_DIFF" -eq 1 ]; then
  gate "6 基线 diff" 0 "(--skip-baseline-diff 跳过)"
else
  log "对照容器 $B_CTR(baseline=$BASELINE)"
  sudo incus launch "$BASELINE" "$B_CTR" --project haoxuan \
    -c limits.memory=3GiB -c limits.cpu=3 >/dev/null 2>&1 || die "基线 launch fail"
  sleep 8
  collect() { # collect <容器> : 版本+清单+unit 集+包集
    vexec "$1" bash -ec '
echo "--versions--"
for b in acpsup browse claude grok codex uv pi; do printf "%s=" "$b"; /usr/local/bin/$b --version 2>&1 | head -1; done
printf "node="; node --version; printf "npm="; npm --version; printf "python3="; python3 --version 2>&1
echo "--bins--"; ls -1 /usr/local/bin | sort
echo "--opt--"; ls -1 /opt | sort
echo "--units--"; systemctl list-unit-files 2>/dev/null | grep -iE "xvfb|openbox|x11vnc|desktop|acpsup" | awk "{print \$1}" | sort
echo "--pkgs--"; dpkg -l 2>/dev/null | grep "^ii" | awk "{print \$2}" | sort' > "/tmp/hxr-c-$(basename "$1").txt"
  }
  collect "$V_CTR"; collect "$B_CTR"
  NEW_F="/tmp/hxr-c-$(basename "$V_CTR").txt"; BASE_F="/tmp/hxr-c-$(basename "$B_CTR").txt"
  ver_new=$(sed -n '/--versions--/,/--bins--/p' "$NEW_F" | grep -v '^--')
  ver_base=$(sed -n '/--versions--/,/--bins--/p' "$BASE_F" | grep -v '^--')
  g=0
  # 版本面:基线无此件(新入件,如 pi)不进硬比对;双方都有才逐行比
  ver_new_core=$(grep -vE '^(pi)=' <<<"$ver_new"); ver_base_core=$(grep -vE '^(pi)=' <<<"$ver_base")
  if [ "$ver_new_core" != "$ver_base_core" ]; then
    g=1; log "  九件版本 diff:"; diff <(echo "$ver_base_core") <(echo "$ver_new_core") || true
  fi
  bins_new=$(sed -n '/--bins--/,/--opt--/p' "$NEW_F" | grep -v '^--')
  bins_base=$(sed -n '/--bins--/,/--opt--/p' "$BASE_F" | grep -v '^--')
  # 新入件白名单(本批意图性新增,清单化防夹带):pi 官方发行
  EXPECT_NEW="pi"
  new_only=$(comm -23 <(sort -u <<<"$bins_new") <(sort -u <<<"$bins_base") | tr '\n' ' ')
  unexpected=""
  for b in $new_only; do echo " $EXPECT_NEW " | grep -q " $b " || unexpected="$unexpected$b "; done
  [ -n "$unexpected" ] && { g=1; log "  预期外新增(白名单外):$unexpected"; }
  missing=$(comm -13 <(sort -u <<<"$bins_new") <(sort -u <<<"$bins_base") | tr '\n' ' ')
  [ -n "$missing" ] && { g=1; log "  基线有而新镜像缺:$missing"; }
  gate "6 基线 diff" $g "新增(白名单):${new_only:-无};缺失:${missing:-无}"
fi

# ── 报告 ──────────────────────────────────────────────────────
{
  echo "# agent-runtime 验证报告 $ALIAS vs $BASELINE"
  echo "- 时间:$(date '+%F %T')  验容器:$V_CTR(proxy 127.0.0.1:$PORT)"
  printf '%s\n' "${RESULTS[@]}"
  echo "- 报告件:/tmp/hxr-c-*.txt(收集快照)"
} | tee "$REPORT"
log "报告:$REPORT"
pass=0; for r in "${RESULTS[@]}"; do [[ "$r" == ✗* ]] && pass=1; done
[ "$pass" -eq 0 ] && log "六闸全绿——可晋升(runbook §2.1 人工迁别名三步)" || die "存在 FAIL 闸,不晋升"
