#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/lib/container-common/init.sh
common_prepare_user

prepare_node_runtime() {
  local data_dir="${AIONUI_DATA_DIR:-$HOME/.aionui-web}"
  local version actual_version arch runtime actual_runtime stage arg
  local previous=""
  for arg in "$@"; do
    if [[ "$previous" == --data-dir ]]; then data_dir="$arg"; fi
    previous="$arg"
  done
  version="$(cat /usr/local/share/aionui/managed-node-version)"
  actual_version="$(/usr/local/bin/node -p process.versions.node)"
  arch="$(/usr/local/bin/node -p process.arch)"
  runtime="$data_dir/runtime/node/node-v$version-linux-$arch"
  actual_runtime="$data_dir/runtime/node/container-node-v$actual_version-linux-$arch"
  mkdir -p "$actual_runtime/bin" "$actual_runtime/lib/node_modules"
  for arg in node npm npx; do
    ln -sfnT "/usr/local/bin/$arg" "$actual_runtime/bin/$arg"
  done
  ln -sfnT /usr/local/lib/node_modules/npm "$actual_runtime/lib/node_modules/npm"
  printf '{"cacheKeyVersion":"%s","actualVersion":"%s"}\n' "$version" "$actual_version" > "$actual_runtime/container-runtime.json"
  if [[ -e "$runtime" && ! -L "$runtime" ]]; then
    stage="$(mktemp -d "$runtime.previous.XXXXXXXX")"
    rmdir -- "$stage"
    mv -T -- "$runtime" "$stage"
  fi
  stage="$(mktemp -d "$(dirname "$runtime")/.system-node.XXXXXXXX")"
  ln -s "${actual_runtime##*/}" "$stage/runtime"
  mv -Tf -- "$stage/runtime" "$runtime"
  rmdir -- "$stage"
  test "$("$runtime/bin/node" -p process.versions.node)" = "$actual_version"
  printf '[aionui] AionCore cache key %s uses actual Node %s\n' "$version" "$actual_version"
}

if [[ -f /usr/local/share/aionui/managed-node-version ]]; then
  prepare_node_runtime "$@"
fi

common_initialize
exec "$@"
