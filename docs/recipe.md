# docs/recipe.md -- haoxuan-v3 底坯镜像完整配方与坑

> 权威源:本仓 `versions.env`(钉子)+ `rootfs/`(静态 overlay)。
> 本文档是人读面:为什么这么配、坑在哪、怎么排障。

## 1. 配方总览

| 层 | 内容 |
|---|---|
| 基底 | debian/12 bookworm(本地缓存指纹 `634810653f2d`,serial 20261022;apt 源 deb.debian.org) |
| X 栈 | Xvfb(:99,2560x1440x24)+ openbox + x11vnc(rfbport 5900, localhost, **-xrandr**)+ feh(编排器壁纸兜底) |
| systemd 四 unit | `xvfb99` / `openbox99` / `x11vnc99` / `acpsup`(全部 enabled;rootfs/etc/systemd/system/ 原样) |
| acpsup 督导 | 0.2.0(go),听 127.0.0.1:7663,`/health` Bearer、`/vnc?display=desktop` WS 101 binary;env `ACPSUP_SESSION_MAX=16 ACPSUP_KEY_SESSIONS=12` |
| 九件套 | claude 2.1.296 / grok 1.0.50 / codex 0.162.1 / browse 0.37.2 / clean-chrome 155.0.8059.39 / uv+uvx 0.13.4 / node 22.23.3+npm 10.9.9(NodeSource node_22.x)/ python 3.11.2(bookworm 自带)/ noto-cjk |
| 根修烤入 | x11-xserver-utils / x11-apps / tmux / dtach / fonts-noto-cjk / unzip(编排器 ensureDesktopXrandr/Term/Fonts 自愈件,镜像带上即 no-op) |
| 审计锚 | `/opt/hx/image-release.txt`(版本清单+recipe commit+构建时间) |

## 2. 路径布局

- `/usr/local/bin/`:acpsup browse claude grok codex uv uvx desktop-auth-gen clean-chrome;`chrome`、`chromium` → clean-chrome 软链。
- `/opt/clean-chrome/chromium-155.0.8059.39-x86_64-unknown-linux-gnu/`(857MB 树)+ `CURRENT` 软链指它;三个 wrapper 皆 `exec /opt/clean-chrome/CURRENT/chrome --no-sandbox "$@"`。
- `/opt/browse/0.37.2/browse`(实体);`/usr/local/bin/browse` 是 wrapper(`BROWSE_CHROME=/opt/clean-chrome/CURRENT/chrome`)。
- `/var/lib/desktop/`(镜像内**不存在**,首启自生)、`/var/lib/acpsup/`(同)。

## 3. 五坑实录勿踩回

1. **browse 必须 zigbuild glibc2.17 变体**:官方 release 要 GLIBC_2.39,bookworm 是 2.36 吃不下。宿主重出:`cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.17`(zig 在 `~/zig/zig-x86_64-linux-0.17.0`),产物 `~/dev-chrome/browse-zigbuild/browse-v0.37.2-glibc2.17`。
2. **xauth cookie 键 = 容器 hostname**:desktop-auth-gen 以 `$(hostname)/unix:99` 与 `:99` 双键铸凭证;凭证若从别的容器拷来(键是旧 hostname),x11vnc XOpenDisplay 必死。所以凭证必须一生一次(坑3)。
3. **凭证不烤镜像**:`/var/lib/desktop/*` 与 `/var/lib/acpsup/{token,keys.json}` 发布前必须清(build-image.sh scrub 步内置)。否则克隆改名后 X 鉴权死,且所有实例共享凭证破隔离。
4. **tuna 源病**:产线网对 tuna v4/v6 皆不可达(编排器运行时会 sed 换 archive 源)。build 默认用底坯自带 deb.debian.org;`--apt-mirror` 可覆盖。
5. **x11vnc 缺 `-xrandr` 则分辨率跟随崩**(2026-10-17 实报):unit 已烤入 `-xrandr`,勿删。

## 4. acpsup 契约与编排器消费面

- 无 token `GET /health` → **401 属正常**(证明 Bearer 闸在);带 `Authorization: Bearer $(cat /var/lib/acpsup/token)` → 200。
- `GET /vnc?display=desktop`(WS 升级,子协议 `binary`)→ 101;响应体含 `{display, rfb_port, password}`。
- 键/token/keys.json 首启自生,一生一次。

## 5. 与编排器的接口:haoxuan 父仓

- 消费面:`gateway-zacp/backend/internal/orchestrator/incus.go` `imageFor()`--别名直透,config `[orchestrator] image/app_image/agent_images` 可覆盖,默认常数 `haoxuan-v3` / `haoxuan-v3-app`。**换镜像=改别名,零代码。**
- launch 形态:project `haoxuan`、limits 3GiB/3cpu、acp proxy device(宿主 127.0.0.1:17xxx→容器 7663)。
- 冷建序(ensure* 系)会兜底装编排器自愈件--本镜像已根修烤入,自愈自动 no-op(「只多不少」原则)。

## 6. 已知缺口移交非本配方范围

- herdr 与 devswha/herdr-web-ui 插件未烤入(编排器 ensureHerdr/ensureHerdrWebUI launch 时置备,镜像烤入后自动 no-op)。
- pi 二进制与 `/opt/node/.../@agentclientprotocol/*-acp` npm 适配器未烤入(p4 发现#3)。
- `haoxuan-v3-app` 轻变体(app 二型,无桌面栈)尚未出版。
