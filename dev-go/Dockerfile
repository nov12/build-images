# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.14.8
ARG GO_VERSION=1.27.1
ARG NODE_VERSION=24.21.0

# 准备 Go 工具链
FROM golang:${GO_VERSION}-trixie AS go-sdk

RUN rm -rf \
    /usr/local/go/api \
    /usr/local/go/doc \
    /usr/local/go/misc \
    /usr/local/go/test

# 准备 Node.js 和 npm
FROM node:${NODE_VERSION}-trixie-slim AS node-runtime

# 合并工具文件
FROM scratch AS tools

COPY --from=go-sdk /usr/local/go /usr/local/go
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm

# 最终镜像
FROM python:${PYTHON_VERSION}-slim-trixie

ARG TARGETARCH

ENV GOPATH=/go
ENV GOTOOLCHAIN=local

ENV PYTHONPATH=/pythonlib
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1

ENV PATH="/usr/local/go/bin:/go/bin:${PATH}"

# 一次性复制 Go、Node.js 和 npm
COPY --from=tools / /

# 安装系统工具和 Task
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl \
        git \
        libatomic1 \
        openssh-server \
        sudo \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    \
    ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx; \
    \
    TASK_ARCHIVE="task_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSL \
        "https://github.com/go-task/task/releases/latest/download/${TASK_ARCHIVE}" \
        -o "/tmp/${TASK_ARCHIVE}"; \
    curl -fsSL \
        "https://github.com/go-task/task/releases/latest/download/task_checksums.txt" \
        -o /tmp/task_checksums.txt; \
    cd /tmp; \
    TASK_SHA256="$(awk -v file="$TASK_ARCHIVE" '$2 == file {print $1}' task_checksums.txt)"; \
    test -n "$TASK_SHA256"; \
    echo "${TASK_SHA256}  ${TASK_ARCHIVE}" | sha256sum -c -; \
    tar -xzf "$TASK_ARCHIVE" task; \
    install -m 755 task /usr/local/bin/task; \
    rm -rf /tmp/task /tmp/task_checksums.txt "/tmp/${TASK_ARCHIVE}"; \
    \
    mkdir -p \
        /workspace \
        /pythonlib \
        /go \
        /config/ssh \
        /run/sshd; \
    \
    python --version; \
    pip --version; \
    go version; \
    node --version; \
    npm --version; \
    task --version; \
    git --version; \
    /usr/sbin/sshd -t

# 安装初始化脚本
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint

WORKDIR /workspace

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint"]

CMD ["/usr/sbin/sshd", "-D", "-e"]