#!/usr/bin/env bash

source "${BASH_SOURCE[0]%/*}/extra-tools/paths.sh"

common_python_environment() {
  PYTHON_PACKAGES_ROOT="$(python_packages_root)" || return
  UV_ENVIRONMENTS_ROOT="$(uv_environments_root)" || return
  export PYTHON_PACKAGES_ROOT UV_ENVIRONMENTS_ROOT
  # Replace image defaults when HOME or the package root was customized.
  if [[ "$PYTHON_PACKAGES_ROOT" != /home/node/pythonlib ]]; then
    common_python_isolate /home/node/pythonlib
  fi
  export PIP_TARGET="${PIP_TARGET:-$PYTHON_PACKAGES_ROOT}"
  if [[ ":${PYTHONPATH:-}:" != *":$PYTHON_PACKAGES_ROOT:"* ]]; then
    export PYTHONPATH="$PYTHON_PACKAGES_ROOT${PYTHONPATH:+:$PYTHONPATH}"
  fi
  if [[ ":$PATH:" != *":$PYTHON_PACKAGES_ROOT/bin:"* ]]; then
    export PATH="$PYTHON_PACKAGES_ROOT/bin:$PATH"
  fi
}

# Keep container defaults out of project environments and their build subprocesses.
common_python_isolate() {
  local root="${1:-$PYTHON_PACKAGES_ROOT}" entry isolated=''
  local -a entries=()
  if [[ "${PIP_TARGET:-}" == "$root" ]]; then unset PIP_TARGET; fi
  IFS=: read -r -a entries <<<"${PYTHONPATH:-}"
  for entry in "${entries[@]}"; do
    [[ "$entry" != "$root" ]] || continue
    isolated+="${isolated:+:}$entry"
  done
  if [[ -n "$isolated" ]]; then export PYTHONPATH="$isolated"; else unset PYTHONPATH; fi
  isolated=''
  IFS=: read -r -a entries <<<"$PATH"
  for entry in "${entries[@]}"; do
    [[ "$entry" != "$root/bin" ]] || continue
    isolated+="${isolated:+:}$entry"
  done
  export PATH="$isolated"
}

common_uv_binary() {
  local profile binary
  profile="$(extra_tools_profile_directory)" || return
  if [[ -x "$profile/uv/current/uv" ]]; then
    printf '%s\n' "$profile/uv/current/uv"
    return
  fi
  while IFS= read -r binary; do
    [[ "$binary" != "$profile/"* ]] || continue
    printf '%s\n' "$binary"
    return
  done < <(type -aP uv 2>/dev/null || true)
  return 1
}

common_python_publish_uv() {
  local binary profile wrapper helper command target kind
  binary="$(common_uv_binary)" || return 0
  profile="$(extra_tools_profile_directory)" || return
  helper="$(realpath -- "${BASH_SOURCE[0]%/*}/python-command.sh")" || return
  for command in uv uvx; do
    target="${binary%/*}/$command"
    [[ -x "$target" ]] || continue
    kind=uv
    if [[ "$command" == uvx ]]; then kind=environment; fi
    wrapper="$profile/.commands/uv/$command"
    mkdir -p -- "${wrapper%/*}" "$profile/bin" || return
    printf '#!/usr/bin/env bash\nexec %q %s %q "$@"\n' "$helper" "$kind" "$target" >"$wrapper.tmp.$BASHPID" || return
    chmod 755 "$wrapper.tmp.$BASHPID" && mv -f -- "$wrapper.tmp.$BASHPID" "$wrapper" || return
    ln -sfn -- "$wrapper" "$profile/bin/$command" || return
  done
}
