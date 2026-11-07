# 公共初始化脚本

准备运行用户身份，统一安装和更新 Agent CLI、可选开发工具；具体服务由入口启动。

## 一、接入镜像

1. 构建上下文使用仓库根目录，复制整个 `common/`：

   ```dockerfile
   COPY --chmod=755 common/ /usr/local/lib/container-common/
   COPY common/profile.sh /etc/profile.d/container-common.sh
   ```

2. 在自己的 Bash 入口中引入：

   ```bash
   source /usr/local/lib/container-common/init.sh
   common_initialize
   exec "$@"
   ```

没有私有入口时，直接用 `/usr/local/lib/container-common/entrypoint.sh`；仅需降权后台更新时调用 `common_run_updates`。
`source` 只定义函数，不启动进程。初始化先检查 CLI，再启动一个 CLI 定时任务；额外工具只在启动时检查，不阻塞 CLI 定时更新。

## 二、运行用户

镜像默认普通用户的 UID/GID 统一为 `666:666`，Compose 可通过 `user` 指定其他数字 UID/GID。`user.sh` 按实际运行身份准备用户记录，供 SSH、Git 和 Node 查询；它使用 `libnss-wrapper`，不修改系统用户表或挂载目录属主，同一用户的 `docker exec` 也可使用这些记录。接入镜像时需安装该库，并按现有 Dockerfile 设置 NSS 环境变量。

挂载目录需要允许所指定的用户访问；只读根文件系统需要给 `/tmp` 提供可写空间。SSH 服务由 root 启动时创建默认 `666:666` 的登录账户；以数字用户启动时使用公钥登录，系统密码和 sudo 需要 root 初始化。若系统不允许非特权进程监听 22 端口，可设置 `SSH_LISTEN_PORT` 并相应调整端口映射。

## 三、选择安装内容

| 环境变量 | 默认值 | 用法 |
| --- | --- | --- |
| `AGENT_CLIS` | `codex,claude,opencode` | 如 `codex@0.166.0,claude@2.1.317`；`all` 安装常规全集；空值或 `none` 不安装、不更新 |
| `EXTRA_TOOLS` | 空 | 如 `go@1.26,rust,node@24,python@3.13`；空值或 `none` 不安装新工具 |
| `PYTHON_PACKAGES` | 空 | 如 `requests,ruff`；自动启用 Python，在独立虚拟环境安装 |

- CLI：`codex`、`claude`、`opencode`、`gemini`、`qwen`、`kimi`、`copilot`、`pi`、`cline`、`amp`；`agy` 需显式选择，或通过 `AGENT_CLI_ALL_EXTRA=agy` 加入 `all`，目前不支持指定版本。
- 开发工具：`go`、`dotnet`、`python`、`uv`、`rust`、`node`（npm/npx）、`bun`（bunx）、`deno`、`java`（Temurin JDK）。Node、.NET、Java 默认 LTS，其余默认稳定版。
- CLI 和开发工具统一使用 `名称@版本`：完整版本固定不追新版，主版本或次版本选择该范围内的最新稳定版；未指定则按默认频道。重复名称只处理第一项。
- Python 包的范围若含逗号，保留内层引号，例如 `PYTHON_PACKAGES='"requests>=2,<3",ruff'`。未启用的已有缓存不会被卸载。

## 四、已有安装：跳过、更新或覆盖

分别设置 `CLI_INSTALL_MODE` 和 `TOOLS_INSTALL_MODE`，默认都是 `update`：

| 模式 | Agent CLI | 开发工具 |
| --- | --- | --- |
| `skip` | 已有可用且符合所选版本就复用，不查询新版、不定时升级；缺失或版本不符仍安装 | 已有工具就复用，数字版本须匹配；缺失或版本不符仍安装 |
| `update` | 查询所选范围的最新版，已有合适版本就复用；固定完整版本满足时直接跳过 | 按检查间隔解析目标版本，按需安装；固定完整版本满足时直接复用 |
| `overwrite` | 每次检查重新安装所选版本，未指定则最新版 | 忽略检查间隔，按目标版本重新部署工具环境 |

Python 包也使用 `TOOLS_INSTALL_MODE`：`skip` / `update` 只安装缺失或不满足要求的包，`overwrite` 重装所选包；不操作系统 Python。

**覆盖只作用于 common 管理的安装，不改系统文件。** 系统已有工具可以复用；新安装进入下方目录。CLI 运行中会推迟替换，安装失败保留可用旧版。`agy` 使用官方安装器和自带更新命令。

## 五、检查时间与安装目录

| 环境变量 | 默认值 | 含义 |
| --- | --- | --- |
| `CLI_UPDATE_INTERVAL` | `86400` 秒 | 启动检查一次，再按周期检查；`0` 仅关闭定时检查，不跳过启动检查 |
| `TOOLS_UPDATE_INTERVAL` | `86400` 秒 | 只在启动时判断是否到期；`0` 复用已有合适版本，缺失或版本不符仍安装；`overwrite` 不受此间隔限制 |
| `AGENT_CLI_ROOT` | `$HOME/agent-cli` | Agent CLI 安装根目录 |
| `EXTRA_TOOLS_ROOT` | `$HOME/extra-tools` | 可共享的工具版本库，包含 Python 解释器和 uv 程序 |
| `PYTHON_PACKAGES_ROOT` | `$HOME/pythonlib` | 普通 pip 和 `uv pip install` 的共享包目录 |
| `UV_ENVIRONMENTS_ROOT` | `$HOME/uvenvs` | uv 项目、工具及 `PYTHON_PACKAGES` 的隔离环境存储根目录 |

常规 CLI 沿用 npm 安装，Go/.NET 等沿用官方发布包，Python 沿用 uv；不引入其他版本管理器。两类安装各用自己的锁和状态，不清理应用缓存。

四个目录均需当前用户可写。默认路径根据实际 `$HOME` 生成：多数镜像为 `/home/node`，`dev-go` 则使用登录用户的 home。不要在 Compose 中直接写 `$HOME/xxx`，因为 Compose 会使用宿主机的环境变量展开；需要自定义时填写明确的容器内路径。

示例 Compose 默认只挂载 home，工具、包和环境随 home 卷持久化；无需额外挂载这四个子目录。容器重建时需继续使用原来的卷；完全没有持久化挂载，或删除 home 卷，仍会丢失数据。需要跨容器共享时，再单独挂载对应子目录。例如只共享工具版本：

```yaml
services:
  app:
    volumes:
      - app-home:/home/node
      - /srv/shared/extra-tools:/home/node/extra-tools

volumes:
  app-home:
```

也可以分别挂载 `/home/node/agent-cli`、`/home/node/pythonlib`、`/home/node/uvenvs`。独立挂载的子目录使用自己的存储，其余内容仍保存在 home 卷中。

### 多容器共享工具版本

把同一个卷挂载到各容器的 `/home/node/extra-tools`，每个容器照常配置自己的 `EXTRA_TOOLS`。例如 A 使用 `go@1.25.3`，B 使用 `go@1.26.1`：两个版本都保存在共享卷中，各自的版本选择和命令入口由容器内部自动维护，无需配置额外目录，互不切换。后续容器请求已经安装的完整版本时直接复用；主版本、次版本和频道仍遵守更新检查设置。

共享目录保留所有成功安装的版本，包括 `overwrite` 之前的版本，不再自动清理，以免删除其他容器正在使用的文件。共享安装锁只串行化安装和更新，不影响工具运行。Python 解释器共享存储，虚拟环境按解释器和 `PYTHON_PACKAGES` 配置缓存；修改包时创建新环境，同一配置可以复用，不修改其他容器已经选择的环境。

同一 Compose 项目中的服务可引用同一个卷；跨项目共享命名卷时，先执行 `docker volume create shared-extra-tools`，再在各项目中配置：

```yaml
services:
  app:
    environment:
      EXTRA_TOOLS: "go@1.26.1,python@3.13"
    volumes:
      - app-home:/home/node
      - extra-tools:/home/node/extra-tools

volumes:
  app-home:
  extra-tools:
    external: true
    name: shared-extra-tools
```

各容器使用相同的挂载路径、兼容的 CPU 架构和系统运行库，并确保运行用户可写该卷。复用镜像自带工具时仍可能保留系统路径软链接；其他镜像会检查工具是否可运行，不可用时另行安装。

Agent CLI 的共享目录仍共用命令入口和更新状态；需要不同 CLI 版本时使用各自的 `AGENT_CLI_ROOT`，不要把开发工具的独立版本选择能力等同于 Agent CLI 的行为。

旧版工具目录为 `/opt/extra-tools` 或 `$HOME/.local/share/extra-tools`，CLI 目录为 `/opt/agent-cli`，部分镜像曾使用 `$HOME/.local` 或 `$HOME/.local/share/agent-cli`。迁移时可以保留旧卷并设置相应的 `*_ROOT`，也可以停用旧容器后将安装目录完整复制到新 home 子目录；不要删除尚未迁移的卷。包含绝对路径的 Python 虚拟环境应按原配置重新生成，不能保证搬动后可用。不要同时在同一卷上运行新旧安装器，因为旧版仍会清理版本。旧的工具共享 `bin/` 和 `current` 不再作为新容器的入口，新入口会根据各容器配置重新生成。

### Python 包与 uv 环境

启动时默认设置 `PIP_TARGET=$PYTHON_PACKAGES_ROOT`，将包目录加入 `PYTHONPATH`，并把其 `bin/` 加入 `PATH`。因此普通 `pip install requests` 和 `python -m pip install requests` 默认写入 `$HOME/pythonlib`；显式 `--target` 或自定义 `PIP_TARGET` 优先。不同 Python 版本、CPU 架构、系统运行库不能无条件共用二进制包；同一目录也不能同时保留同名包的多个版本，分享这个目录意味着接受同一套包。

启动时已有 uv，或通过 `EXTRA_TOOLS` 安装 uv 时，容器命令入口为无显式目标的 `uv pip install`、`uninstall`、`list`、`freeze`、`show` 使用同一个包目录。指定 `--target`、`--prefix`、`--python`、`--system`，或已激活虚拟环境时，保留 uv 自己的环境选择。未安装 uv 时不会创建 uv 命令入口，也不影响 pip 安装包的使用。启动后手动安装的 uv 需要重启容器以生成入口；直接调用安装目录中的原始可执行文件会绕过这些容器默认规则。

`uv run`、`uv sync`、`uv add`、`uv remove` 使用 `$UV_ENVIRONMENTS_ROOT/projects/<配置标识>`，标识包含工作区路径、Python 选择、`pyproject.toml`、已有的 `uv.lock` 和 `.python-version`。不同项目或依赖配置分开存储；尚无 lockfile 的项目首次生成锁文件后，下次会选择新的配置目录。uv 自己负责解析 workspace 根目录；不支持 `uv workspace dir` 的旧版本保留原生 `.venv` 行为。显式 `UV_PROJECT_ENVIRONMENT`、`--active`、`--script`、`--no-project` 保留原生行为。项目命令会移除容器默认的共享包搜索路径和安装目标，避免共享包覆盖项目依赖，也不会修改用户的 uv 配置文件。

uv 工具环境默认位于 `$UV_ENVIRONMENTS_ROOT/tools`（可用原生 `UV_TOOL_DIR` 覆盖），Python 解释器默认位于 `$EXTRA_TOOLS_ROOT/python-interpreters`（可用原生 `UV_PYTHON_INSTALL_DIR` 覆盖）。uv/uvx 程序本身仍由 `EXTRA_TOOLS_ROOT` 管理。`PYTHON_PACKAGES` 保留原有的配置隔离和失败恢复，环境移至 `$UV_ENVIRONMENTS_ROOT/packages/`，不会把不同容器声明的包配置合并进 `pythonlib`。

手动激活普通 venv 后直接运行 pip 时，继承的 `PIP_TARGET` 仍然有效。需要项目隔离时取消这些默认值，例如 `env -u PIP_TARGET -u PYTHONPATH .venv/bin/python -m pip install requests`。项目安装器可以绕过默认目录；使用 pip 的 `--user`、`--prefix` 等与 `PIP_TARGET` 冲突的选项时，也需要先取消 `PIP_TARGET`。

跨容器共享虚拟环境仍要求相同的容器内路径和兼容的解释器、架构、系统库，通常还要挂载对应的解释器目录。不要让不同依赖需求同时修改同一项目环境；`uv add/remove/sync` 会修改选中的环境。普通 pip 共享目录的并发手动安装也需要调用方协调。

镜像环境提供默认路径，Bash 登录 shell 会按实际 home 和 `*_ROOT` 重新计算；`dev-go` 的 SSH 配置也传递这些变量。通过 `docker exec` 使用自定义根目录时建议执行 `bash -lc '你的命令'`；直接执行命令不会继承入口进程后来导出的环境变量。

## 六、镜像要求

- Linux/glibc（x86_64、arm64），Bash 4.3+，coreutils、findutils、awk、util-linux（flock）、libnss-wrapper、curl、CA 证书、tar、gzip、unzip、jq。CLI 另需 Node/npm；开发工具安装不依赖 Node。
- 必备工具、动态库、编译链接器放 Dockerfile；common 不运行系统包管理器。CLI 更新固定使用镜像自带的 Node/npm，主服务也固定使用镜像自带的运行时，不随可选 Node/Bun 切换。
