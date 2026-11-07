#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/lib/container-common/init.sh
common_initialize
paseo_node="$AGENT_CLI_MANAGER_NODE"
paseo_runtime_path="$AGENT_CLI_MANAGER_PATH"

selected="${PASEO_PLUGINS:-}"
selected="${selected//[[:space:]]/}"

case "$selected" in
  '' | none) ;;
  *)
    helper="$(dirname -- "$0")/plugins.mjs"
    # 在 daemon 启动前设置默认值，避免与 daemon 的配置写入发生竞争。
    if PATH="$paseo_runtime_path" "$paseo_node" "$helper" prepare; then
      # 安装依赖已就绪的 daemon；后台初始化不阻塞主服务。
      PATH="$paseo_runtime_path" "$paseo_node" "$helper" install &
    else
      echo '[paseo-plugins] Initialization failed; continuing to start Paseo' >&2
    fi
    ;;
esac

exec "$@"
