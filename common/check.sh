#!/usr/bin/env bash
set -euo pipefail

common_directory="${BASH_SOURCE[0]%/*}"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

before_path="$PATH"
before_options="$-"
source "$common_directory/init.sh"
[[ "$PATH" == "$before_path" && "$-" == "$before_options" ]]

export AGENT_CLIS=none CLI_UPDATE_INTERVAL=0 EXTRA_TOOLS=none PYTHON_PACKAGES=none
export EXTRA_TOOLS_HOME="$temporary/tools"
common_initialize
common_initialize
[[ -z "$(jobs -p)" && ! -e "$EXTRA_TOOLS_HOME" ]]
[[ "$(bash "$common_directory/entrypoint.sh" printf '%s' 'literal argument')" == 'literal argument' ]]
PATH="$EXTRA_TOOLS_HOME/bin:$PATH" agent_cli_initialize
[[ ":$AGENT_CLI_MANAGER_PATH:" != *":$EXTRA_TOOLS_HOME/bin:"* ]]
if CLI_INSTALL_MODE=skip AGENT_CLI_MANAGER_SELECTED=codex CLI_UPDATE_INTERVAL=1 common_updates_enabled; then exit 1; fi
CLI_INSTALL_MODE=update AGENT_CLI_MANAGER_SELECTED=codex CLI_UPDATE_INTERVAL=1 common_updates_enabled
if TOOLS_INSTALL_MODE=overwrite extra_tools_try_existing node 24.0.0; then exit 1; fi
agent_cli_version_matches 1.2.3 1.2
agent_cli_version_matches 1.2.3 1.2.3
if agent_cli_version_matches 1.2.4 1.2.3; then exit 1; fi

items=()
extra_tools_parse_list 'go@1.26,"requests>=2,<3",httpx[http2,socks]' items
[[ "${#items[@]}" == 3 && "${items[1]}" == 'requests>=2,<3' && "${items[2]}" == 'httpx[http2,socks]' ]]

mkdir -p "$temporary/releases/old" "$temporary/releases/new"
extra_tools_activate "$temporary/releases/old" "$temporary/current"
extra_tools_activate_release "$temporary/releases/new" "$temporary/current" "$temporary/releases"
[[ "$(readlink "$temporary/current")" == "$temporary/releases/new" && -d "$temporary/releases/old" ]]
printf 'common check: OK\n'
