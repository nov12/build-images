# 公共初始化脚本

统一安装和更新 Agent CLI、可选开发工具；各镜像保留自己的用户、权限和服务启动逻辑。

## 接入镜像

构建上下文使用仓库根目录，复制整个 `common/`：

```dockerfile
COPY --chmod=755 common/ /usr/local/lib/container-common/
```

在自己的 Bash 入口中引入：

```bash
source /usr/local/lib/container-common/init.sh
common_initialize
exec "$@"
```

没有私有入口时，直接用 `/usr/local/lib/container-common/entrypoint.sh`；仅需降权后台更新时调用 `common_run_updates`。
`source` 只定义函数，不启动进程。初始化先检查 CLI，再启动一个 CLI 定时任务；额外工具只在启动时检查，不阻塞 CLI 定时更新。

## 选择安装内容

| 环境变量 | 默认值 | 用法 |
| --- | --- | --- |
| `AGENT_CLIS` | `codex,claude,opencode` | 如 `codex@0.166.0,claude@2.1.317`；`all` 安装常规全集；空值或 `none` 不安装、不更新 |
| `EXTRA_TOOLS` | 空 | 如 `go@1.26,rust,node@24,python@3.13`；空值或 `none` 不安装新工具 |
| `PYTHON_PACKAGES` | 空 | 如 `requests,ruff`；自动启用 Python，在独立虚拟环境安装 |

- CLI：`codex`、`claude`、`opencode`、`gemini`、`qwen`、`kimi`、`copilot`、`pi`、`cline`、`amp`；`agy` 需显式选择，或通过 `AGENT_CLI_ALL_EXTRA=agy` 加入 `all`，目前不支持指定版本。
- 开发工具：`go`、`dotnet`、`python`、`uv`、`rust`、`node`（npm/npx）、`bun`（bunx）、`deno`、`java`（Temurin JDK）。Node、.NET、Java 默认 LTS，其余默认稳定版。
- CLI 和开发工具统一使用 `名称@版本`：完整版本固定不追新版，主版本或次版本选择该范围内的最新稳定版；未指定则按默认频道。重复名称只处理第一项。
- Python 包的范围若含逗号，保留内层引号，例如 `PYTHON_PACKAGES='"requests>=2,<3",ruff'`。未启用的已有缓存不会被卸载。

## 已有安装：跳过、更新或覆盖

分别设置 `CLI_INSTALL_MODE` 和 `TOOLS_INSTALL_MODE`，默认都是 `update`：

| 模式 | Agent CLI | 开发工具 |
| --- | --- | --- |
| `skip` | 已有可用且符合所选版本就复用，不查询新版、不定时升级；缺失或版本不符仍安装 | 已有工具就复用，数字版本须匹配；缺失或版本不符仍安装 |
| `update` | 查询所选范围的最新版，已有合适版本就复用；固定完整版本满足时直接跳过 | 按检查间隔解析目标版本，按需安装；固定完整版本满足时直接复用 |
| `overwrite` | 每次检查重新安装所选版本，未指定则最新版 | 忽略检查间隔，按目标版本重新部署工具环境 |

Python 包也使用 `TOOLS_INSTALL_MODE`：`skip` / `update` 只安装缺失或不满足要求的包，`overwrite` 重装所选包；不操作系统 Python。

**覆盖只作用于 common 管理的安装，不改系统文件。** 系统已有工具可以复用；新安装进入下方目录。CLI 运行中会推迟替换，安装失败保留可用旧版。`agy` 使用官方安装器和自带更新命令。

## 检查时间与安装目录

| 环境变量 | 默认值 | 含义 |
| --- | --- | --- |
| `CLI_UPDATE_INTERVAL` | `86400` 秒 | 启动检查一次，再按周期检查；`0` 仅关闭定时检查，不跳过启动检查 |
| `TOOLS_UPDATE_INTERVAL` | `86400` 秒 | 只在启动时判断是否到期；`0` 复用已有合适版本，缺失或版本不符仍安装；`overwrite` 不受此间隔限制 |
| `AGENT_CLI_ROOT` | `/opt/agent-cli` | CLI 安装根目录，需当前用户可写 |
| `EXTRA_TOOLS_HOME` | `$HOME/.local/share/extra-tools` | 工具安装根目录；兼容 `CONTAINER_TOOLS_HOME`，统一入口为其 `bin/` |

常规 CLI 沿用 npm 安装，Go/.NET 等沿用官方发布包，Python 沿用 uv；不引入其他版本管理器。两类安装各用自己的锁和状态，不清理应用缓存。

## 镜像要求与自检

- Linux/glibc（x86_64、arm64），Bash 4.3+，coreutils、findutils、util-linux（flock），curl、CA 证书、tar、gzip、unzip、jq。CLI 另需 Node/npm；开发工具安装不依赖 Node。
- 必备工具、动态库、编译链接器放 Dockerfile；common 不运行系统包管理器。CLI 更新固定使用镜像自带的 Node/npm，主服务也固定使用镜像自带的运行时，不随可选 Node/Bun 切换。
- 自检：`bash common/check.sh`。CI 会执行；自检和本文不打包进镜像。
