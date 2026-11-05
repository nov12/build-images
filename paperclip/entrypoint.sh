#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/lib/container-common/init.sh
common_initialize

cd /app
exec "$@"
