#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/lib/container-common/init.sh

prepare_node_runtime() {
  local data_dir="${AIONUI_DATA_DIR:-$HOME/.aionui-web}"
  local version arch runtime stage arg
  local previous=""
  for arg in "$@"; do
    if [[ "$previous" == --data-dir ]]; then data_dir="$arg"; fi
    previous="$arg"
  done
  version="$(cat /usr/local/share/aionui/managed-node-version)"
  arch="$(node -p process.arch)"
  runtime="$data_dir/runtime/node/node-v$version-linux-$arch"
  [[ -e "$runtime" ]] && return 0
  mkdir -p "$(dirname "$runtime")"
  stage="$(mktemp -d "$(dirname "$runtime")/.system-node.XXXXXXXX")"
  mkdir -p "$stage/bin" "$stage/lib/node_modules"
  for arg in node npm npx; do
    ln -s "/usr/local/bin/$arg" "$stage/bin/$arg"
  done
  ln -s /usr/local/lib/node_modules/npm "$stage/lib/node_modules/npm"
  if ! mv -Tn "$stage" "$runtime"; then
    rm -rf -- "$stage"
    return 1
  fi
  [[ ! -d "$stage" ]] || rm -rf -- "$stage"
}

if [[ -f /usr/local/share/aionui/managed-node-version ]]; then
  prepare_node_runtime "$@"
fi

common_initialize
exec "$@"
