# 构建工作流

所有工作流使用 GitHub 已正式提供的 `ubuntu-26.04`，ARM64 构建使用 `ubuntu-26.04-arm`。`ubuntu-latest` 的迁移有过渡期，因此这里显式选择系统版本。

## 上游版本

- DeepSeek Harness：从官方 GitHub Releases 中按发布时间选择最新的 `dsh-v` 版本，包括预发行版，排除草稿和其他产品的标签。当前官方全部为预发行版，不能使用会排除它们的 `/releases/latest`。npm 仅提供选定版本的精确安装包和完整性信息；对应包尚未发布时构建失败，不回退到旧的 npm `latest`。
- T3 Code、Paseo、Paperclip、AionUi：使用官方 GitHub 指定的 Latest 正式 Release，保留各自原有的稳定版策略，不自动切到 nightly 或 beta。
- dev-go：Go、Python 使用官方稳定版索引，Node 使用官方 LTS 索引，Task 使用官方 GitHub Release。
- StratForge：镜像依赖由仓库中的 `pyproject.toml` 管理。

应用工作流与公共发布工作流共用 `.github/scripts/resolve-release.py`。更新镜像的 `latest` 标签前再次检查上游版本，防止较早的构建覆盖新版本。DeepSeek 记录 GitHub 标签对应的源代码提交，并把选定的 DSH、pnpm 和 uv 版本传给镜像构建。

公共检查覆盖所有工作流和共享脚本的修改，执行 actionlint、ShellCheck、发布选择与镜像清理测试。actionlint 的配置仅补充其内置列表尚未包含的 Ubuntu 26.04 官方 runner 标签，不禁用 runner 标签检查。Dependabot 每周检查 GitHub Actions 的版本更新。

## 2026-11-15 日志核查

本次读取了全部八类工作流最近一次运行的检查注释和日志，包括公共发布工作流展开后的双架构构建及发布 job。

已处理的配置问题：

- DeepSeek 不再因 npm `latest` 停在 `0.2.2-rc.1`，GitHub 发布解析已验证选中 `dsh-v0.2.2-rc.3`。
- 所有 runner 从 Ubuntu 24.04 更新到已 GA 的 26.04。
- DeepSeek 的 `setup-node` 更新到 v7，公共检查的 `setup-uv` 更新到已发布的精确标签 v10.3.3（上游没有 v10 主版本别名，首次 CI 已检出）；其他 Action 已核对当前发布主版本。
- DeepSeek 的 pnpm 安装使用解析出的精确版本，避免解析与安装之间发生版本漂移。
- 缓存失效参数改名为 `DEPENDENCY_CACHE_REVISION`，避免 `KEY` 名称触发凭据检查误报。
- Paperclip 的离线启动检查提供明确的 `PAPERCLIP_PUBLIC_URL`，补齐鉴权服务的外部地址。
- AionUi 的工作流脚本通过新增的 ShellCheck 检查。

仍需区分来源的提示（保留检查，不通过关闭警告隐藏）：

- Docker `SecretsUsedInArgOrEnv` 对 `NSS_WRAPPER_PASSWD` 的提示：其值固定为 `/tmp/container-user/passwd`，是 libnss-wrapper 的用户数据库路径，不是密码。该变量必须保留在镜像环境中，供 `docker exec` 解析自定义 UID。真实的凭据检查继续启用。
- `actions/download-artifact@v8` 下载时的 `DEP0005 Buffer()` 弃用警告：来自当前上游 Action 的依赖，需跟随上游修复；没有修改或屏蔽第三方 Action。
- DeepSeek 安装时的 `node-domexception` 弃用和 npm 安装脚本审核提示：来自上游包依赖，不能据此认定应用不可用；原生模块及离线启动检查仍须通过。
- T3 Code 离线测试关闭 Agent CLI 安装且不提供浏览器沙箱配置，因此日志中的 CLI 健康和浏览器沙箱提示需结合测试环境理解，不能作为生产环境功能已经通过验证的依据。
- Paperclip 使用显式 UID 666 时的 `useradd` 提示，以及公共 Python 安装兼容性测试中 uv 对 pip 生成的脚本 `RECORD` 路径的提示：分别对应容器 UID 约定和混合安装器场景，相关运行用户及包升级隔离检查继续保留。

查阅依据：[GitHub runner 支持列表](https://github.com/actions/runner-images#available-images)、[DeepSeek 官方 Releases](https://github.com/deepseek-ai/deepseek-harness/releases)、[DeepSeek 核查运行](https://github.com/nov12/build-images/actions/runs/43709200945)、[公共检查核查运行](https://github.com/nov12/build-images/actions/runs/43704976242)。
