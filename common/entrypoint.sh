#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" == 0 ]]; then
  echo 'Usage: common/entrypoint.sh command [args...]' >&2
  exit 64
fi

source "${BASH_SOURCE[0]%/*}/init.sh"
common_initialize

exec "$@"
