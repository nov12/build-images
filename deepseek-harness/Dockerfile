# syntax=docker/dockerfile:1

ARG NODE_VERSION=lts
ARG UV_VERSION=latest
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM node:${NODE_VERSION}-trixie-slim AS dsh-builder

ARG DSH_VERSION=latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        g++ \
        git \
        make \
        python3 \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY deepseek-harness/entrypoint.sh /tmp/dsh-entrypoint.sh

# Refresh the installation cache when upstream latest releases change, without pinning pnpm.
ARG DEPENDENCY_CACHE_KEY

# Install and trim the DSH fallback and plugin package manager before copying them.
RUN npm install --prefix /out/dsh --save-exact \
        --omit=dev --include=optional --no-audit --no-fund \
        "@deepseek-ai/dsh@$DSH_VERSION" \
    && npm install --prefix /out/pnpm --save-exact \
        --omit=dev --no-audit --no-fund pnpm \
    && bash -c 'source /tmp/dsh-entrypoint.sh; dsh_trim_install /out/dsh; dsh_trim_install /out/pnpm' \
    && hardlink --ignore-time --reflink=never --exclude '\.(node|dll|dylib)$|\.so($|\.)' /out \
    && /out/dsh/node_modules/.bin/dsh --version \
    && /out/pnpm/node_modules/.bin/pnpm --version \
    && mkdir -p /build-record \
    && mv /out/dsh/package-lock.json /build-record/deepseek-harness-package-lock.json \
    && mv /out/pnpm/package-lock.json /build-record/pnpm-package-lock.json \
    && npm cache clean --force

FROM node:${NODE_VERSION}-trixie-slim AS runtime-system

ARG USER_UID=666
ARG USER_GID=666

# Runtime dependencies only; optional Python is installed by common through uv.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bash \
        bubblewrap \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        gzip \
        jq \
        libatomic1 \
        libgcc-s1 \
        libgssapi-krb5-2 \
        libicu76 \
        libnss-wrapper \
        libssl3t64 \
        libstdc++6 \
        openssh-client \
        procps \
        ripgrep \
        tar \
        tini \
        unzip \
        util-linux \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/
# Copy both outputs together so duplicate package files retain their hardlinks.
COPY --from=dsh-builder /out/ /opt/
COPY --from=dsh-builder /build-record/ /usr/local/share/build-images/

RUN set -eux; \
    if ! getent group "$USER_GID" >/dev/null; then groupadd -g "$USER_GID" agent; fi; \
    if [ "$(id -u node)" != "$USER_UID" ]; then usermod -u "$USER_UID" node; fi; \
    usermod -g "$USER_GID" node; \
    install -d -m 0755 -o "$USER_UID" -g "$USER_GID" \
        /home/node /home/node/.local /home/node/.local/bin \
        /home/node/.local/share/dsh-container /workspace; \
    chown -R "$USER_UID:$USER_GID" /home/node

COPY --chmod=755 common/ /usr/local/lib/container-common/
COPY --chmod=755 deepseek-harness/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN ln -s /usr/local/bin/entrypoint.sh /usr/local/bin/dsh

ENV HOME=/home/node \
    DSH_RUNTIME_ROOT=/home/node/.local/share/dsh-container \
    DSH_HOME=/home/node/.dsh \
    DSH_NODE=/usr/local/bin/node \
    DSH_VERSION=latest \
    DSH_UPDATE_INTERVAL=86400 \
    DSH_PORT=3080 \
    AGENT_CLIS=none \
    AGENT_CLI_ROOT=/home/node/.local/share/agent-cli \
    EXTRA_TOOLS_HOME=/home/node/.local/share/extra-tools \
    EXTRA_TOOLS= \
    PYTHON_PACKAGES= \
    TOOLS_INSTALL_MODE=update \
    TOOLS_UPDATE_INTERVAL=86400 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    UV_CACHE_DIR=/home/node/.cache/uv \
    UV_LINK_MODE=copy \
    UV_NO_PROGRESS=1 \
    NODE_USE_ENV_PROXY=1 \
    PATH="/home/node/.local/share/extra-tools/bin:/home/node/.local/share/agent-cli/bin:/home/node/.local/bin:/home/node/go/bin:/opt/pnpm/node_modules/.bin:${PATH}"

ENV LD_PRELOAD=libnss_wrapper.so \
    NSS_WRAPPER_PASSWD=/tmp/container-user/passwd \
    NSS_WRAPPER_GROUP=/tmp/container-user/group

USER node
WORKDIR /workspace
EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/bin/env", "-u", "LD_PRELOAD", "/usr/local/bin/entrypoint.sh"]
CMD ["web"]
