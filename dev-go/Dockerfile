# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3
ARG GO_VERSION=1
ARG NODE_VERSION=current

# 准备 Go 工具链
FROM golang:${GO_VERSION}-trixie AS go-sdk

RUN rm -rf \
    /usr/local/go/api \
    /usr/local/go/doc \
    /usr/local/go/misc \
    /usr/local/go/test

# 准备 Python 和 pip
FROM python:${PYTHON_VERSION}-slim-trixie AS python-runtime

# 运行环境，使用官方 Node.js 稳定版基础镜像
FROM node:${NODE_VERSION}-trixie-slim

ARG TARGETARCH
ARG TASK_VERSION=v3.54.0

ENV GOPATH=/go \
    GOTOOLCHAIN=local \
    PYTHONPATH=/pythonlib \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    AGENT_CLI_ROOT=/opt/agent-cli \
    AGENT_CLIS=codex,claude,opencode \
    CLI_UPDATE_INTERVAL=86400

ENV PATH="/usr/local/go/bin:/go/bin:/opt/agent-cli/bin:${PATH}"

COPY --from=go-sdk /usr/local/go /usr/local/go
COPY --from=python-runtime /usr/local/ /usr/local/

# 安装 Python 动态库、SSH 和 Agent CLI 所需工具
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libatomic1 \
        libbz2-1.0 \
        libdb5.3t64 \
        libexpat1 \
        libffi8 \
        libgdbm6t64 \
        libgdbm-compat4t64 \
        liblzma5 \
        libncursesw6 \
        libreadline8t64 \
        libsqlite3-0 \
        libssl3t64 \
        libuuid1 \
        libzstd1 \
        netbase \
        openssh-server \
        ripgrep \
        sudo \
        tini \
        tzdata \
        unzip \
        util-linux \
        zlib1g \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    ldconfig; \
    \
    userdel node; \
    if getent group node >/dev/null; then \
        groupdel node; \
    fi; \
    rm -rf /home/node; \
    \
    test -n "$TASK_VERSION"; \
    TASK_ARCHIVE="task_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSL --retry 3 \
        "https://github.com/go-task/task/releases/download/${TASK_VERSION}/${TASK_ARCHIVE}" \
        -o "/tmp/${TASK_ARCHIVE}"; \
    curl -fsSL --retry 3 \
        "https://github.com/go-task/task/releases/download/${TASK_VERSION}/task_checksums.txt" \
        -o /tmp/task_checksums.txt; \
    cd /tmp; \
    TASK_SHA256="$(awk -v file="$TASK_ARCHIVE" '$2 == file {print $1}' task_checksums.txt)"; \
    test -n "$TASK_SHA256"; \
    echo "${TASK_SHA256}  ${TASK_ARCHIVE}" | sha256sum -c -; \
    tar -xzf "$TASK_ARCHIVE" task; \
    install -m 755 task /usr/local/bin/task; \
    rm -rf /tmp/task /tmp/task_checksums.txt "/tmp/${TASK_ARCHIVE}"; \
    \
    mkdir -p /workspace /pythonlib /go /config/ssh /run/sshd /opt/agent-cli; \
    printf '%s\n' 'export PATH="/usr/local/go/bin:/go/bin:${AGENT_CLI_ROOT:-/opt/agent-cli}/bin:$PATH"' \
        > /etc/profile.d/dev-go.sh; \
    \
    python --version; \
    python -c 'import ssl, sqlite3, ctypes, bz2, lzma, readline, curses, dbm.gnu, dbm.ndbm, decimal, pyexpat, uuid, compression.zstd'; \
    pip --version; \
    go version; \
    node --version; \
    npm --version; \
    task --version; \
    git --version; \
    rm -f /etc/ssh/ssh_host_*

# 使用仓库根目录作为构建上下文，复用已有 Agent CLI 管理入口
COPY --chmod=755 t3code/entrypoint.sh /usr/local/bin/agent-cli
COPY --chmod=755 dev-go/entrypoint.sh /usr/local/bin/entrypoint

WORKDIR /workspace

EXPOSE 22

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint"]

CMD ["/usr/sbin/sshd", "-D", "-e"]
