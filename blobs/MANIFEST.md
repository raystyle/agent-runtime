# blobs/MANIFEST.md -- 二进制件台账:不入仓大件权威记录

> 硬约束:claude 257MB / codex 294MB 超 GitHub 单文件 100MB 上限,物理不可入仓;
> 全部大件走 staging(构建期 `scripts/stage.sh` 组装并逐件 sha256 校验)。
> sha256 与 `versions.env` 同源(单一权威,本表是人读面)。宿主件与现役镜像
> 16b35bf1669c 内实测逐件相等(2026-10-24 核)。

| 件 | 版本 | sha256 | 来源① harvest(现役镜像) | 来源② 宿主本地产件 |
|---|---|---|---|---|
| acpsup | 0.2.0 | `93fd6312…2888a` | `/usr/local/bin/acpsup`(唯一源) | -- |
| uv | 0.13.4 | `5b2a2df4…e3c4fb` | `/usr/local/bin/uv` | -- (宿主 0.12.22 禁用) |
| uvx | 0.13.4 | `2044b4dd…849c7` | `/usr/local/bin/uvx` | -- 同上 |
| browse | 0.37.2 | `9ab30f9d…1c6a8` | `/opt/browse/0.37.2/browse` | `~/dev-chrome/browse-zigbuild/browse-v0.37.2-glibc2.17`(zigbuild glibc2.17 变体,见 recipe 坑1) |
| claude | 2.1.296 | `24972e3b…0d0de` | `/usr/local/bin/claude` | `~/.local/bin/claude` |
| grok | 1.0.50 | `c80de015…724d5` | `/usr/local/bin/grok` | `~/.local/bin/grok` |
| codex | 0.162.1 | `628e3548…0d92e1` | `/usr/local/bin/codex` | `~/.local/share/codex/bin/codex` |
| clean-chrome zip | 155.0.8059.39 | `97c96584…23acd` | `/opt/clean-chrome/chromium-155…gnu/`(树) | `~/dev-chrome/dist-gen8-r4/chromium-155.0.8059.39-x86_64-unknown-linux-gnu.zip`(镜像目录名无 gen9-r2 后缀,与此 zip 对名) |

- clean-chrome 备源:`~/dist-gen9-r2/chromium-155.0.8059.39-gen9-r2-…zip`(更新但目录名异,晋升换版时须同步改 wrapper 无关、仅目录名)。
- 三冗余原则:harvest 道(镜像)+ 宿主道(本机产件)+ 官方道(npm/releases)--前两道零 GitHub 依赖;官方道仅在现役镜像过期删除且宿主件丢失时兜底。
