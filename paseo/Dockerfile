# syntax=docker/dockerfile:1

# 安装官方 npm 发行包，包含 daemon 和 Web UI
FROM node:24-trixie-slim AS paseo-builder

ARG PASEO_VERSION

# sherpa-onnx 已携带运行库，避免重复下载额外的 ONNX 运行时
ENV ONNXRUNTIME_NODE_INSTALL=skip

# 原生终端模块没有可用预编译包时，允许在构建阶段编译
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        g++ \
        git \
        make \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    test -n "$PASEO_VERSION"; \
    npm install --prefix /opt/paseo \
        --no-save --no-package-lock \
        --omit=dev --include=optional \
        --no-audit --no-fund \
        "@getpaseo/cli@$PASEO_VERSION"; \
    test -s /opt/paseo/node_modules/@getpaseo/server/dist/server/web-ui/index.html; \
    npm cache clean --force

# 运行环境
FROM node:24-trixie-slim

ARG USER_UID=1000
ARG USER_GID=1000

# 仅保留 Paseo、终端和共用 Agent CLI 管理脚本所需组件
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        gzip \
        lbzip2 \
        libatomic1 \
        libgomp1 \
        openssh-client \
        procps \
        ripgrep \
        tar \
        tini \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# 复用基础镜像的非 root 用户，默认 UID/GID 为 1000:1000
RUN set -eux; \
    if ! getent group "$USER_GID" >/dev/null; then \
        groupadd -g "$USER_GID" agent; \
    fi; \
    if [ "$(id -u node)" != "$USER_UID" ]; then \
        usermod -u "$USER_UID" node; \
    fi; \
    usermod -g "$USER_GID" node; \
    install -d -m 0755 \
        -o "$USER_UID" -g "$USER_GID" \
        /home/node /home/node/.paseo /opt/agent-cli /workspace

COPY --from=paseo-builder /opt/paseo/ /opt/paseo/

# 使用仓库根目录作为构建上下文，直接复用已有 Agent CLI 管理入口
COPY --chmod=755 t3code/entrypoint.sh /usr/local/bin/entrypoint.sh

# 检查最终运行环境能加载原生终端模块；CLI 版本由 CI 验证
RUN node -e "require('/opt/paseo/node_modules/node-pty')"

ENV HOME=/home/node \
    PATH="/opt/paseo/node_modules/.bin:/opt/agent-cli/bin:/home/node/.local/bin:${PATH}" \
    PASEO_HOME=/home/node/.paseo \
    PASEO_LISTEN=0.0.0.0:6767 \
    PASEO_WEB_UI_ENABLED=true \
    PASEO_LOG_FORMAT=json \
    PASEO_LOG_LEVEL=info \
    CLI_UPDATE_INTERVAL=86400 \
    NPM_CONFIG_CACHE=/tmp/t3-agent-npm-cache

USER node

WORKDIR /workspace

EXPOSE 6767

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

CMD ["node", "/opt/paseo/node_modules/@getpaseo/server/dist/scripts/supervisor-entrypoint.js"]
