# syntax=docker/dockerfile:1

ARG NODE_VERSION=lts

# 下载并校验官方 T3 Code
FROM --platform=$BUILDPLATFORM alpine:3 AS t3-builder

RUN apk add --no-cache \
    ca-certificates \
    curl \
    tar

ARG T3_VERSION
ARG TARGETARCH

RUN set -eux; \
    test -n "$T3_VERSION"; \
    case "$TARGETARCH" in \
        amd64) ARCH=x64 ;; \
        arm64) ARCH=arm64 ;; \
        *) echo "Unsupported architecture: $TARGETARCH"; exit 1 ;; \
    esac; \
    \
    ASSET="t3-${T3_VERSION}-linux-${ARCH}.tar.gz"; \
    URL="https://github.com/pingdotgg/t3code/releases/download/v${T3_VERSION}"; \
    \
    mkdir -p /opt/t3 /tmp/download; \
    cd /tmp/download; \
    \
    curl -fL --retry 3 -o "$ASSET" "$URL/$ASSET"; \
    curl -fL --retry 3 -o SHA256SUMS "$URL/SHA256SUMS"; \
    \
    EXPECTED="$(awk -v f="$ASSET" \
        '$2 == f || $2 == "*" f || $2 == "./" f {print $1}' SHA256SUMS)"; \
    test "$(printf '%s\n' "$EXPECTED" | wc -l)" -eq 1; \
    test -n "$EXPECTED"; \
    printf '%s  %s\n' "$EXPECTED" "$ASSET" | sha256sum -c -; \
    \
    tar -xzf "$ASSET" -C /opt/t3 --strip-components=1; \
    test -x /opt/t3/t3; \
    rm -rf /opt/t3/node_modules/@ff-labs/fff-bin-linux-*-musl \
        /opt/t3/node_modules/node-pty/src \
        /opt/t3/node_modules/node-pty/third_party

# 运行环境
FROM node:${NODE_VERSION}-trixie-slim AS runtime-system

ARG USER_UID=666
ARG USER_GID=666

# 只安装运行所需工具
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        jq \
        gzip \
        libatomic1 \
        libicu76 \
        libnss-wrapper \
        libssl3t64 \
        openssh-client \
        procps \
        ripgrep \
        tar \
        tini \
        unzip \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# 复用基础镜像的非 root 用户，默认 UID/GID 为 666:666
RUN set -eux; \
    if ! getent group "$USER_GID" >/dev/null; then \
        groupadd -g "$USER_GID" agent; \
    fi; \
    if [ "$(id -u node)" != "$USER_UID" ]; then \
        usermod -u "$USER_UID" node; \
    fi; \
    usermod -g "$USER_GID" node; \
    \
    install -d -m 0755 \
        -o "$USER_UID" -g "$USER_GID" \
        /home/node /home/node/agent-cli /home/node/extra-tools /home/node/pythonlib /home/node/uvenvs /workspace

# 只复制 T3 的正式发行程序
COPY --from=t3-builder /opt/t3/ /opt/t3/
COPY --from=t3-builder /tmp/download/SHA256SUMS /usr/local/share/build-images/t3-SHA256SUMS

# 构建期检查发行程序能否启动
RUN /opt/t3/t3 --help >/dev/null

ENV HOME=/home/node \
    PATH="/opt/t3:/home/node/agent-cli/bin:/tmp/extra-tools/bin:/home/node/pythonlib/bin:/home/node/.local/bin:${PATH}" \
    T3CODE_NO_BROWSER=1 \
    CLI_UPDATE_INTERVAL=86400

COPY --chmod=755 common/ /usr/local/lib/container-common/
COPY common/profile.sh /etc/profile.d/container-common.sh

ENV PIP_TARGET=/home/node/pythonlib \
    PYTHONPATH=/home/node/pythonlib

ENV LD_PRELOAD=libnss_wrapper.so \
    NSS_WRAPPER_PASSWD=/tmp/container-user/passwd \
    NSS_WRAPPER_GROUP=/tmp/container-user/group

USER node

WORKDIR /workspace

EXPOSE 3773

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/env", "-u", "LD_PRELOAD", "/usr/local/lib/container-common/entrypoint.sh"]

CMD ["t3", "serve", "--host", "0.0.0.0", "--port", "3773"]
