#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/lib/container-common/init.sh
common_initialize

if [[ -z "${CODEX_PATH:-}" ]] && command -v codex >/dev/null 2>&1; then
  export CODEX_PATH="$(command -v codex)"
fi

export PAPERCLIP_PROVIDER_CACHE="${PAPERCLIP_PROVIDER_CACHE:-${AGENT_CLI_ROOT:-$HOME/agent-cli}/paperclip-native}"
if [[ -n "${PAPERCLIP_NATIVE_PROVIDERS:-}" && "$PAPERCLIP_NATIVE_PROVIDERS" != none ]]; then
  /usr/local/bin/node /usr/local/lib/paperclip/prepare-runtime.mjs --prefetch "$PAPERCLIP_NATIVE_PROVIDERS"
fi

cd /app
exec "$@"
