# syntax=docker/dockerfile:1

ARG NODE_VERSION=lts

# 从校验过的同版本官方发布包提取原生运行依赖。
FROM --platform=$BUILDPLATFORM alpine:3 AS t3-assets

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
    ROOT="${ASSET%.tar.gz}"; \
    tar -xzf "$ASSET" -C /opt/t3 --strip-components=1 --exclude="$ROOT/t3" --exclude="$ROOT/client"; \
    rm -rf /opt/t3/t3 /opt/t3/client; \
    test -d /opt/t3/node_modules; \
    rm -rf /opt/t3/node_modules/@ff-labs/fff-bin-linux-*-musl \
        /opt/t3/node_modules/node-pty/src \
        /opt/t3/node_modules/node-pty/third_party

# 在源码中移除产品遥测，再构建配套的服务端和网页。
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-trixie-slim AS t3-builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

ARG T3_VERSION
ARG T3_COMMIT

WORKDIR /src

RUN test -n "$T3_VERSION" \
    && git init . \
    && git remote add origin https://github.com/pingdotgg/t3code.git \
    && git sparse-checkout set --no-cone '/*' '!/.repos/' \
    && git fetch --depth=1 --filter=blob:none origin "${T3_COMMIT:-refs/tags/v${T3_VERSION}}" \
    && git checkout --detach FETCH_HEAD \
    && { test -z "$T3_COMMIT" || test "$(git rev-parse HEAD)" = "$T3_COMMIT"; } \
    && npm install --global --engine-strict "$(node -p 'require("./package.json").packageManager')" typescript@6.0.3

# 仅在旧版发现逻辑仍存在时补齐 agy CLI 的自动发现。
RUN node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import fs from 'node:fs';
const filename = 'apps/server/src/provider/AntigravityInstallation.ts';
if (fs.existsSync(filename)) {
  const source = fs.readFileSync(filename, 'utf8');
  const before = `      for (const candidate of yield* commandCandidates(names.executable, processEnvironment)) {
        const selected = yield* fromExternal(candidate, "path");
        if (selected) return selected;
      }`;
  const after = `      for (const command of [names.executable, "agy"]) {
        for (const candidate of yield* commandCandidates(command, processEnvironment)) {
          const selected = yield* fromExternal(candidate, "path");
          if (selected) return selected;
        }
      }`;
  if (source.includes(before)) {
    assert.equal(source.split(before).length, 2, 'Ambiguous Antigravity discovery code');
    fs.writeFileSync(filename, source.replace(before, after));
  }
}
NODE

RUN --mount=type=cache,target=/root/.cache/pnpm \
    pnpm install --frozen-lockfile --ignore-scripts \
        --filter t3... --filter @t3tools/web... --filter @t3tools/scripts... \
        --store-dir /root/.cache/pnpm/store

COPY t3code/remove-telemetry.cjs /usr/local/lib/t3-build/remove-telemetry.cjs
RUN node /usr/local/lib/t3-build/remove-telemetry.cjs \
    && node scripts/update-release-package-versions.ts "$T3_VERSION" \
    && if [ -f .env.example ]; then awk '!/^[[:space:]]*[^#]*OTLP_TRACES_/' .env.example > .env; fi \
    && pnpm --config.verify-deps-before-run=false --filter t3 run build:bundle \
    && test -s apps/server/dist/bin.mjs \
    && test -s apps/server/dist/claude-history-worker.mjs \
    && T3CODE_WEB_SOURCEMAP=false pnpm --config.verify-deps-before-run=false --filter @t3tools/web run build \
    && if [ -f scripts/apply-web-brand-assets.ts ]; then node scripts/apply-web-brand-assets.ts production apps/web/dist; fi \
    && test -s apps/web/dist/index.html \
    && mv apps/server/dist /out \
    && mv apps/web/dist /out/client

# 上游更新若重新引入已知发送器或设备标识，就阻止出镜像。
RUN if grep -rEl --include='*.mjs' --include='*.js' --include='*.map' \
        'ingest\.t3\.codes|us\.i\.posthog\.com|eu\.i\.posthog\.com|T3CODE_POSTHOG_|phc_[A-Za-z0-9]{20,}|AnalyticsService\.sendBatch|X-Axiom-Dataset|api\.axiom\.co|t3-code-relay-traces-|t3code:analytics-device-id' /out; then \
        exit 1; \
    else test "$?" -eq 1; fi

# 运行环境
FROM node:${NODE_VERSION}-trixie-slim AS runtime-system

ARG T3_VERSION
ARG USER_UID=666
ARG USER_GID=666

# 只安装运行和 Agent 远程/协作核心工具
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        gh \
        git \
        gzip \
        jq \
        libatomic1 \
        libicu76 \
        libnss-wrapper \
        libssl3t64 \
        openssh-client \
        procps \
        ripgrep \
        rsync \
        sshpass \
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

COPY --from=t3-assets /opt/t3/ /opt/t3/
COPY --from=t3-assets /tmp/download/SHA256SUMS /usr/local/share/build-images/t3-SHA256SUMS
COPY --from=t3-builder /out/ /opt/t3/
COPY --chmod=755 <<'SH' /opt/t3/t3
#!/bin/sh
script_dir="$(dirname -- "$(readlink -f -- "$0")")"
exec /usr/local/bin/node "$script_dir/bin.mjs" "$@"
SH

RUN /opt/t3/t3 --help >/dev/null \
    && test "$(/opt/t3/t3 --version)" = "t3 v${T3_VERSION}" \
    && gh --version >/dev/null \
    && ssh -V >/dev/null 2>&1 \
    && sshpass -V >/dev/null \
    && rsync --version >/dev/null

ENV LANG=C.UTF-8 \
    HOME=/home/node \
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
