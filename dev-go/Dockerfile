# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.14.8
ARG GO_VERSION=1.27.1
ARG NODE_VERSION=24.21.0

# Go 工具链来源
FROM golang:${GO_VERSION}-trixie AS go

# Node.js 工具链来源
FROM node:${NODE_VERSION}-trixie-slim AS node

# 最终基础镜像
FROM python:${PYTHON_VERSION}-slim-trixie

ARG PNPM_VERSION=12.9.1

ENV DEBIAN_FRONTEND=noninteractive

ENV GOPATH=/go
ENV GOTOOLCHAIN=local

ENV PNPM_HOME=/pnpm

ENV PYTHONPATH=/pythonlib
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1

ENV PATH="/usr/local/go/bin:/go/bin:/pnpm:${PATH}"

# 安装开发和 SSH 所需系统包
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    libatomic1 \
    openssh-client \
    openssh-server \
    sudo \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# 复制 Go 工具链
COPY --from=go /usr/local/go /usr/local/go

# 复制 Node.js 和 npm
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# 安装指定版本 pnpm
RUN npm install --global "pnpm@${PNPM_VERSION}" \
    && npm cache clean --force

# 创建运行和开发目录
RUN mkdir -p \
    /workspace \
    /pythonlib \
    /go \
    /pnpm \
    /config/ssh \
    /run/sshd

# 安装容器初始化脚本
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint

# 构建时检查主要工具是否可用
RUN python --version \
    && pip --version \
    && go version \
    && node --version \
    && npm --version \
    && pnpm --version \
    && git --version \
    && /usr/sbin/sshd -t

WORKDIR /workspace

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint"]

CMD ["/usr/sbin/sshd", "-D", "-e"]