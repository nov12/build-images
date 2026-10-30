#!/usr/bin/env bash
set -Eeuo pipefail

selected="${PASEO_PLUGINS:-}"
selected="${selected//[[:space:]]/}"

case "$selected" in
  '' | none) ;;
  *)
    helper="$(dirname -- "$0")/plugins.mjs"
    # 在 daemon 启动前设置默认值，避免与 daemon 的配置写入发生竞争。
    if node "$helper" prepare; then
      # 安装依赖已就绪的 daemon；后台初始化不阻塞主服务。
      node "$helper" install &
    else
      echo '[paseo-plugins] Initialization failed; continuing to start Paseo' >&2
    fi
    ;;
esac

exec "$@"
