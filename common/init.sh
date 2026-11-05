#!/usr/bin/env bash

source "${BASH_SOURCE[0]%/*}/user.sh"

source "${BASH_SOURCE[0]%/*}/agent-cli.sh"

source "${BASH_SOURCE[0]%/*}/extra-tools.sh"

common_update_once() {
  case "$AGENT_CLI_MANAGER_SELECTED" in
    '' | none) return 0 ;;
  esac
  agent_cli_update_all || agent_cli_log "update cycle failed; continuing"
}

common_updates_enabled() {
  case "$AGENT_CLI_MANAGER_SELECTED" in
    '' | none) return 1 ;;
  esac
  [[ "${CLI_INSTALL_MODE:-update}" != skip ]] || return 1
  [[ "${CLI_UPDATE_INTERVAL:-86400}" =~ ^[1-9][0-9]*$ ]]
}

common_update_loop() {
  local interval="${CLI_UPDATE_INTERVAL:-86400}"
  while common_updates_enabled; do
    sleep "$interval" || return
    common_update_once
  done
}

common_initialize() {
  [[ "${COMMON_INITIALIZED_PID:-}" == "$BASHPID" ]] && return 0
  common_prepare_user || return
  agent_cli_initialize || return
  common_update_once
  if common_updates_enabled; then
    common_update_loop &
  fi
  extra_tools_initialize
  export PATH="$AGENT_CLI_MANAGER_ROOT/bin:$PATH"
  COMMON_INITIALIZED_PID="$BASHPID"
}

common_run_updates() {
  common_prepare_user || return
  agent_cli_initialize || return
  common_update_once
  local tools_pid=''
  if extra_tools_enabled; then
    extra_tools_initialize &
    tools_pid="$!"
  fi
  common_update_loop
  if [[ -n "$tools_pid" ]]; then wait "$tools_pid"; fi
}
