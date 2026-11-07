# shellcheck shell=bash
# Login shells also need defaults computed from their actual HOME (not root's).
[ -n "${BASH_VERSION:-}" ] || return 0
# shellcheck source=python.sh
source /usr/local/lib/container-common/python.sh
AGENT_CLI_ROOT="$(agent_cli_root)"
EXTRA_TOOLS_ROOT="$(extra_tools_root)"
export AGENT_CLI_ROOT EXTRA_TOOLS_ROOT
common_python_environment
PATH="$AGENT_CLI_ROOT/bin:$(extra_tools_profile_directory)/bin:$PATH"
export PATH
