# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.14.8
ARG GO_VERSION=1.27.1
ARG NODE_VERSION=24.21.0



# Go
FROM golang:${GO_VERSION}-trixie AS go



# Node.js
FROM node:${NODE_VERSION}-trixie-slim AS node



# Final image
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



# Basic development tools
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libatomic1 \
        openssh-client \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*



# Go
# 只从 golang 官方镜像复制 Go toolchain，
# 不把整个 golang 镜像带进最终镜像。

COPY --from=go /usr/local/go /usr/local/go


# Node.js + npm
# 只从 node 官方 slim 镜像复制 Node 和 npm。

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx



# pnpm
RUN npm install --global "pnpm@${PNPM_VERSION}" \
    && npm cache clean --force


# Workspace
RUN mkdir -p \
        /workspace \
        /pythonlib \
        /go \
        /pnpm

WORKDIR /workspace


# Build-time verification
RUN python --version \
    && pip --version \
    && go version \
    && node --version \
    && npm --version \
    && pnpm --version \
    && git --version


CMD ["bash"]