# agent-runtime -- haoxuan 系统容器底坯镜像配方仓

本仓是 haoxuan 舰队「系统容器基础配置部署环境」的单一权威源:底坯镜像
`haoxuan-v3`(别名 hx-agent-base / hx-agent-base-v1-bookworm,现役指纹
16b35bf1669c)的构建配方、发布闸与再出版 SOP。以 git submodule 形态嵌套
维护于 haoxuan 父仓(raystyle/haoxuan)顶层 `agent-runtime/`;**Go ACP 网关
在父仓 gateway-zacp/,不属本仓**。

## 快速开始

    ./build-image.sh   --alias haoxuan-v3-verify   # 构建出版到测试别名(现役别名硬闸保护)
    ./verify-image.sh  --alias haoxuan-v3-verify   # 发布闸六道:launch 同形/四 unit/health 阶梯/VNC 101/凭证/基线 diff
    # 全绿后晋升(人工三步,见 gateway-zacp/docs/runbook-v3.md §2.1):
    FP=$(incus image info haoxuan-v3-verify | awk '/^Fingerprint/{print $2}')
    for a in haoxuan-v3 hx-agent-base hx-agent-base-v1-bookworm; do
      incus image alias delete $a && incus image alias create $a $FP
    done

## 仓结构

| 件 | 职责 |
|---|---|
| versions.env | 版本钉子单一权威源(九件套+sha256 台账+底坯+保护名单) |
| build-image.sh | 构建+出版唯一入口(preflight→apt→overlay→九件套断言→scrub→publish) |
| verify-image.sh | 发布闸唯一入口(六道闸,全绿才可晋升) |
| scripts/lib.sh | 公共库:log/die/retry/protect_alias/ws101_probe |
| scripts/harvest.sh | 从现役镜像提取权威件(acpsup/uv/uvx 源码不在,镜像是唯一源) |
| scripts/stage.sh | staging 组装+逐件 sha256 校验(--check 形供 build preflight) |
| rootfs/ | 烤入镜像的静态 overlay:四 unit、wrapper、desktop-auth-gen、nodesource 源 |
| blobs/MANIFEST.md | 不入仓大件台账(三冗余获取道:harvest/宿主/官方) |
| docs/recipe.md | 完整配方、路径布局、五坑、acpsup 契约、编排器接口 |

## 镜像契约摘要

- Debian bookworm 底 + Xvfb/openbox/x11vnc(:99,含 -xrandr)+ acpsup 督导
  127.0.0.1:7663(`/health` Bearer、`/vnc?display=desktop` WS 101 binary)。
- 九件套:claude/grok/codex/browse/clean-chrome/uv/node/python + noto-cjk
  (版本钉子见 versions.env)。
- **凭证不烤镜像**:`/var/lib/desktop/*`、`/var/lib/acpsup/{token,keys.json}`
  一生一次首启自生(build 的 scrub 步保证);xauth cookie 键=容器 hostname。
- 消费方:编排器 `imageFor()` 别名直透(incus.go),换镜像=改别名,零代码。

## 纪律

- 现役别名在 PROTECTED_ALIASES 保护名单,一切脚本出版操作前置断言;
  晋升只走人工迁别名三步,可一步回退。
- 大件不入仓(≥1MB;claude/codex 超 GitHub 100MB 单文件限),sha256 钉在
  versions.env + MANIFEST.md,构建期 stage.sh 逐件校验。
- 旧指纹晋升后保留 ≥7 天观察期再删;镜像默认 30 天过期,到期前再出版。
