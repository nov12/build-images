#!/usr/bin/env bash

extra_tools_root() {
  realpath -m -- "${EXTRA_TOOLS_ROOT:-$HOME/extra-tools}"
}

# Version selections and command entries belong to this container, not the volume.
extra_tools_profile_directory() {
  printf '%s\n' /tmp/extra-tools
}

agent_cli_root() {
  realpath -m -- "${AGENT_CLI_ROOT:-$HOME/agent-cli}"
}

python_packages_root() {
  realpath -m -- "${PYTHON_PACKAGES_ROOT:-$HOME/pythonlib}"
}

uv_environments_root() {
  realpath -m -- "${UV_ENVIRONMENTS_ROOT:-$HOME/uvenvs}"
}
