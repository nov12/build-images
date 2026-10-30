# syntax=docker/dockerfile:1

# 校验预编译 WebUI 服务端产物
FROM oven/bun:1.4.4-slim AS web-runtime

COPY --from=web-assets /server/webui.js /tmp/webui.js

RUN test -s /tmp/webui.js \
    && bun --version >/dev/null

# 运行环境
FROM node:24-trixie-slim AS runtime

ARG AIONCORE_NODE_VERSION
ARG USER_UID=1000
ARG USER_GID=1000

# 仅安装 AionCore、Agent CLI 和入口脚本必需的系统组件
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        gzip \
        libatomic1 \
        libicu76 \
        libssl3t64 \
        libsqlite3-0 \
        libudev1 \
        openssh-client \
        ripgrep \
        tar \
        tini \
        unzip \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# 保存上游缓存目录契约，入口脚本以符号链接复用现有 Node.js
RUN test -n "$AIONCORE_NODE_VERSION" \
    && mkdir -p /usr/local/share/aionui \
    && printf '%s\n' "$AIONCORE_NODE_VERSION" > /usr/local/share/aionui/managed-node-version

# 配置非 root 用户，默认 UID/GID 为 1000:1000
RUN set -eux; \
    if ! getent group "$USER_GID" >/dev/null; then \
        groupadd -g "$USER_GID" agent; \
    fi; \
    if [ "$(id -u node)" != "$USER_UID" ]; then \
        usermod -u "$USER_UID" node; \
    fi; \
    usermod -g "$USER_GID" node; \
    install -d -o "$USER_UID" -g "$USER_GID" \
        /data /workspace /home/node/.local; \
    chown -R "$USER_UID:$USER_GID" /home/node

WORKDIR /app

# 仅复制预编译 Bun、官方 AionCore 和 WebUI 服务端文件
COPY --from=web-runtime /usr/local/bin/bun /usr/local/bin/bun
COPY --from=web-runtime /tmp/webui.js /app/scripts/webui.js
COPY --from=core-bin --chmod=755 /aioncore /usr/local/bin/aioncore

# 仅复制静态资源，不引入 Electron、源码及 node_modules
COPY --from=web-assets /renderer/ /app/out/renderer/

# 保留现有 Coding Agent CLI 管理方式
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HOME=/home/node \
    NODE_ENV=production \
    PATH="/home/node/.local/bin:${PATH}" \
    AIONUI_ALLOW_REMOTE=1 \
    AIONUI_DATA_DIR=/data \
    AIONUI_LOG_LEVEL=info \
    AIONUI_STATIC_DIR=/app/out/renderer \
    AIONUI_BACKEND_BIN=/usr/local/bin/aioncore \
    AGENT_CLI_ROOT=/home/node/.local \
    CLI_UPDATE_INTERVAL=86400

# 构建期检查关键二进制及最终运行产物
RUN aioncore --help >/dev/null \
    && bun --version >/dev/null \
    && node --version >/dev/null \
    && npm --version >/dev/null \
    && test -s /app/scripts/webui.js \
    && test -s /app/out/renderer/index.html \
    && test ! -e /app/node_modules \
    && test ! -e /app/packages

USER node

WORKDIR /workspace

EXPOSE 25808

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

CMD ["bun", "/app/scripts/webui.js", "--remote"]
