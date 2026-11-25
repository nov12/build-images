# build-images

## 一、文档

1. [公共初始化脚本](docs/common.md)：运行用户、Agent CLI 和可选开发工具的配置说明。

## 二、镜像相对上游的主要调整

1. **DeepSeek Harness (`deepseek-harness`)**：
   - 支持通过 `DSH_TOKEN` 固定 Web 登录 Token（留空时每次启动随机生成）。
   - 适配容器网络与反向代理访问（支持 `DSH_PUBLIC_URL`、`DSH_TRUSTED_HOSTS` 与插件路由回环兼容），目录选择器默认起点为 `/workspace`。
2. **T3 Code (`t3code`)**：
   - 构建期移除产品遥测（PostHog、匿名设备标识）与 T3 Connect / Axiom 追踪上报。
   - 兼容自动发现 `agy`（Antigravity）CLI。
3. **Paperclip (`paperclip`)**：
   - 原生 Provider（Codex、Claude、OpenCode、Copilot）改为按需下载到持久缓存；补齐 HTTP 内网访问下的浏览器 `crypto.randomUUID` / `subtle.digest` 回退。
4. **AionUi (`aionui`)**：
   - 托管 Node 运行时目录以软链接复用镜像内置 Node，不重复下载。
