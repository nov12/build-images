# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.14.8
ARG GO_VERSION=1.27.1
ARG NODE_VERSION=24.21.0

# 准备 Go 工具链和 Task
FROM golang:${GO_VERSION}-trixie AS go-tools

RUN GOBIN=/out \
    go install -ldflags="-s -w" github.com/go-task/task/v3/cmd/task@latest

# 删除 Go 开发中通常不需要的附加内容
RUN rm -rf \
    /usr/local/go/api \
    /usr/local/go/doc \
    /usr/local/go/misc \
    /usr/local/go/test

# Node.js 和 npm 来源
FROM node:${NODE_VERSION}-trixie-slim AS node-tools

# 最终镜像
FROM python:${PYTHON_VERSION}-slim-trixie

ENV DEBIAN_FRONTEND=noninteractive

ENV GOPATH=/go
ENV GOTOOLCHAIN=local

ENV PYTHONPATH=/pythonlib
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1

ENV PATH="/usr/local/go/bin:/go/bin:${PATH}"

# 安装开发和 SSH 所需系统包
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        git \
        libatomic1 \
        openssh-server \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# 复制 Go 工具链
COPY --from=go-tools /usr/local/go /usr/local/go

# 复制 Task
COPY --from=go-tools /out/task /usr/local/bin/task

# 复制 Node.js
COPY --from=node-tools /usr/local/bin/node /usr/local/bin/node

# 只复制 npm，不带其它 Node 全局工具
COPY --from=node-tools /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm

RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# 创建开发和运行目录
RUN mkdir -p \
    /workspace \
    /pythonlib \
    /go \
    /config/ssh \
    /run/sshd

# 安装初始化脚本
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint

# 检查主要工具
RUN python --version \
    && pip --version \
    && go version \
    && node --version \
    && npm --version \
    && npx --version \
    && task --version \
    && git --version \
    && /usr/sbin/sshd -t

WORKDIR /workspace

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint"]

CMD ["/usr/sbin/sshd", "-D", "-e"]