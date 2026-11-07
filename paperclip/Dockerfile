# syntax=docker/dockerfile:1

ARG NODE_VERSION=lts

FROM rust:1-trixie AS rust-toolchain

FROM node:${NODE_VERSION}-trixie-slim AS paperclip-builder

ARG COREPACK_VERSION=latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        g++ \
        git \
        make \
        pkg-config \
        python3 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && npm install --global --engine-strict "corepack@$COREPACK_VERSION" \
    && corepack enable \
    && npm cache clean --force

# 直接复用官方 Rust 工具链；所需编译器版本仍由上游 rust-toolchain.toml 决定。
COPY --from=rust-toolchain /usr/local/cargo/ /usr/local/cargo/
COPY --from=rust-toolchain /usr/local/rustup/ /usr/local/rustup/

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    COREPACK_HOME=/opt/corepack \
    PATH=/usr/local/cargo/bin:${PATH}

# 与 Paseo 一致，由 Action 查询最新稳定版后传入，无固定默认版本。
ARG PAPERCLIP_VERSION
ARG PAPERCLIP_COMMIT

RUN test -n "$PAPERCLIP_VERSION" && test -n "$PAPERCLIP_COMMIT"

WORKDIR /app

# 下载本次 Action 解析出的源码提交。
ADD https://github.com/paperclipai/paperclip.git#${PAPERCLIP_COMMIT} /app

# 与上游容器一致，先同步锁文件元数据，再以 frozen lockfile 安装。
RUN mkdir -p /usr/local/share/build-images \
    && sha256sum pnpm-lock.yaml > /usr/local/share/build-images/paperclip-source-lock.sha256 \
    && pnpm install --resolution-only --ignore-scripts --no-frozen-lockfile \
    && pnpm install --frozen-lockfile

ENV PAPERCLIP_BUILD_COMMIT=${PAPERCLIP_COMMIT} \
    PAPERCLIP_BUILD_VERSION=${PAPERCLIP_VERSION} \
    NODE_OPTIONS=--max-old-space-size=4096

# server build 按当前架构编译 Rust Runner；各原生 Provider 的架构支持仍由上游决定。
RUN pnpm --filter @paperclipai/ui build \
    && pnpm --filter @paperclipai/plugin-sdk build \
    && pnpm --filter @paperclipai/plugin-workspace-diff build \
    && pnpm --filter @paperclipai/server build \
    && test -s server/dist/index.js \
    && test -s ui/dist/index.html \
    && rm -rf packages/paperclip-runner/runner/target

# 保留上游远程 Runner 所需的固定版本运行包，与用户安装的 Agent CLI 分开管理。
RUN PAPERCLIP_RUNNER_SOURCE_REVISION="$PAPERCLIP_COMMIT" \
        node packages/paperclip-runner/scripts/build-provider-pack.mjs /provider-pack \
    && chmod -R a+rX /provider-pack

COPY paperclip/prepare-runtime.mjs /usr/local/lib/prepare-runtime.mjs

RUN node /usr/local/lib/prepare-runtime.mjs /app /runtime/app \
    && du -sh /app /runtime/app

FROM node:${NODE_VERSION}-trixie-slim AS runtime-system

ARG COREPACK_VERSION=latest
ARG USER_UID=666
ARG USER_GID=666

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        g++ \
        gh \
        git \
        gzip \
        jq \
        lbzip2 \
        libatomic1 \
        libgomp1 \
        libicu76 \
        libnss-wrapper \
        libssl3t64 \
        make \
        openssh-client \
        pkg-config \
        procps \
        python3 \
        ripgrep \
        tar \
        tini \
        unzip \
        util-linux \
        zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && npm install --global --engine-strict "corepack@$COREPACK_VERSION" \
    && corepack enable \
    && npm cache clean --force

# 与 Paseo 一致，默认非 root 运行，挂载目录由调用方准备好 UID/GID 权限。
RUN set -eux; \
    if ! getent group "$USER_GID" >/dev/null; then \
        groupadd -g "$USER_GID" agent; \
    fi; \
    if [ "$(id -u node)" != "$USER_UID" ]; then \
        usermod -u "$USER_UID" node; \
    fi; \
    usermod -g "$USER_GID" node; \
    install -d -m 0755 -o "$USER_UID" -g "$USER_GID" \
        /home/node /paperclip /home/node/agent-cli /home/node/extra-tools /home/node/pythonlib /home/node/uvenvs /workspace

COPY --from=paperclip-builder --chown=${USER_UID}:${USER_GID} /runtime/app/ /app/
COPY --from=paperclip-builder --chown=${USER_UID}:${USER_GID} /opt/corepack/ /opt/corepack/
COPY --from=paperclip-builder /provider-pack/ /opt/paperclip-runner/provider-pack/
COPY --from=paperclip-builder /usr/local/share/build-images/ /usr/local/share/build-images/
# 与 Paseo 一致，私有入口调用公共初始化，再交接固定运行时启动应用。
COPY --chmod=755 common/ /usr/local/lib/container-common/
COPY common/profile.sh /etc/profile.d/container-common.sh
COPY --chmod=755 paperclip/entrypoint.sh /usr/local/lib/paperclip/entrypoint.sh

ARG PAPERCLIP_VERSION
ARG PAPERCLIP_COMMIT

ENV NODE_ENV=production \
    HOME=/home/node \
    COREPACK_HOME=/opt/corepack \
    PATH=/home/node/agent-cli/bin:/tmp/extra-tools/bin:/home/node/pythonlib/bin:/home/node/.local/bin:${PATH} \
    PAPERCLIP_HOME=/paperclip \
    PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
    PAPERCLIP_INSTANCE_ID=default \
    PAPERCLIP_BUILD_VERSION=${PAPERCLIP_VERSION} \
    PAPERCLIP_BUILD_COMMIT=${PAPERCLIP_COMMIT} \
    PAPERCLIP_RUNNER_REMOTE_PROVIDER_PACK_PATH=/opt/paperclip-runner/provider-pack \
    HOST=0.0.0.0 \
    PORT=3100 \
    SERVE_UI=true \
    PAPERCLIP_DEPLOYMENT_MODE=authenticated \
    PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
    OPENCODE_ALLOW_ALL_MODELS=true \
    GEMINI_SANDBOX=false \
    CLI_UPDATE_INTERVAL=86400

# 手动 npm install -g 使用 HOME 持久卷，非 root 用户也能安装和升级额外的 CLI。
ENV NPM_CONFIG_PREFIX=/home/node/.local \
    NPM_CONFIG_CACHE=/home/node/.npm

ENV PIP_TARGET=/home/node/pythonlib \
    PYTHONPATH=/home/node/pythonlib

ENV LD_PRELOAD=libnss_wrapper.so \
    NSS_WRAPPER_PASSWD=/tmp/container-user/passwd \
    NSS_WRAPPER_GROUP=/tmp/container-user/group

USER node

WORKDIR /workspace

EXPOSE 3100

# HTTP 200 也可能仍在恢复数据，必须等 health.status 为 ok。
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD ["/usr/local/bin/node", "--input-type=module", "-e", "const response = await fetch('http://127.0.0.1:' + (process.env.PORT || '3100') + '/api/health', { signal: AbortSignal.timeout(4000) }); if (!response.ok || (await response.json()).status !== 'ok') process.exit(1);"]

# Paperclip 负责依次停止 Agent 和内嵌 PostgreSQL，避免向整个进程组同时发送退出信号。
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/env", "-u", "LD_PRELOAD", "/usr/local/lib/paperclip/entrypoint.sh"]

CMD ["/usr/local/bin/node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
