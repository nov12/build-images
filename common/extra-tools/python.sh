#!/usr/bin/env bash

extra_tools_install_python() {
  local request="$1" metadata version interpreter
  local -a python_targets=()
  case "$request" in
    lts | sts) extra_tools_log "Python does not support $request"; return 1 ;;
    latest | stable) ;;
    *) python_targets=("$request") ;;
  esac
  extra_tools_require_uv || return
  metadata="$("$EXTRA_TOOLS_INTERNAL_UV" python list "${python_targets[@]}" --only-downloads --output-format json)" || return
  version="$(jq -er '[.[] | select(.implementation == "cpython" and .variant == "default") |
    .version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] |
    sort_by(split(".") | map(tonumber)) | last // empty' <<<"$metadata")" || return
  EXTRA_TOOLS_INTERNAL_VERSION="$version"
  extra_tools_try_existing python "$version" && return 0
  timeout 600s "$EXTRA_TOOLS_INTERNAL_UV" python install --no-bin "$version" || return
  interpreter="$("$EXTRA_TOOLS_INTERNAL_UV" python find --managed-python --system --no-project "$version")" || return
  extra_tools_adopt_system python "$interpreter" "$version" || return
  EXTRA_TOOLS_INTERNAL_INTERPRETER="$interpreter"
}

extra_tools_prepare_python() (
  local interpreter="$1" identity current candidate='' directory key cached
  trap '[[ -z "$candidate" ]] || rm -rf -- "$candidate"' EXIT
  [[ -x "$EXTRA_TOOLS_INTERNAL_UV" ]] || { extra_tools_log 'Python installation requires uv'; return 1; }
  interpreter="$(readlink -f -- "$interpreter")" || return
  identity="$("$interpreter" -c 'import sys; print(sys.executable); print(sys.version)')" || return
  key="$(printf '%s\0' "$identity" "${packages[@]}" | sha256sum)" || return
  key="${key%% *}"
  directory="$(uv_environments_root)/packages/$key"
  current="$(readlink -f -- "$EXTRA_TOOLS_INTERNAL_PROFILE/python/current" 2>/dev/null || true)"
  if [[ "${TOOLS_INSTALL_MODE:-update}" != overwrite ]]; then
    if [[ "$current" == "$directory/"* && -f "$current/.environment-key" && "$(cat "$current/.environment-key")" == "$key" ]] && extra_tools_usable python; then
      return 0
    fi
    cached="$(readlink -f -- "$directory/complete" 2>/dev/null || true)"
    if [[ -f "$cached/.environment-key" && "$(cat "$cached/.environment-key")" == "$key" ]] &&
      extra_tools_probe python "$cached" >/dev/null 2>&1; then
      extra_tools_activate_release "$cached" "$EXTRA_TOOLS_INTERNAL_PROFILE/python/current"
      return
    fi
  fi
  mkdir -p -- "$directory" || return
  candidate="$(mktemp -d "$directory/env-XXXXXXXX")" || return
  "$EXTRA_TOOLS_INTERNAL_UV" venv --relocatable --python "$interpreter" "$candidate" || return
  printf '%s' "$identity" >"$candidate/.interpreter" || return
  printf '%s' "$key" >"$candidate/.environment-key" || return
  extra_tools_activate_release "$candidate" "$EXTRA_TOOLS_INTERNAL_PROFILE/python/current" || return
  candidate=''
)

extra_tools_python_requirement_name() {
  local spec="$1" result=''
  if [[ "$spec" =~ ^([a-zA-Z0-9][a-zA-Z0-9._-]*) ]]; then result="${BASH_REMATCH[1],,}"; fi
  result="${result//_/-}"
  result="${result//./-}"
  while [[ "$result" == *--* ]]; do result="${result//--/-}"; done
  printf '%s' "$result"
}

extra_tools_install_python_package() (
  local spec="$1" protected="$2" current candidate='' installed name line package_name
  local -a constraints=()
  trap '[[ -z "$candidate" ]] || rm -rf -- "$candidate"' EXIT
  [[ -n "$spec" && "$spec" != -* && "$spec" != *$'\n'* && "$spec" != *$'\r'* ]] || return 1
  current="$(readlink -f -- "$EXTRA_TOOLS_INTERNAL_PROFILE/python/current")" || return
  installed="$EXTRA_TOOLS_INTERNAL_TEMP/installed.txt"
  "$EXTRA_TOOLS_INTERNAL_UV" pip freeze --python "$current/bin/python" --exclude-editable >"$installed" || return
  if [[ "${TOOLS_INSTALL_MODE:-update}" != overwrite ]] &&
    "$EXTRA_TOOLS_INTERNAL_UV" pip install --python "$current/bin/python" --check -- "$spec" >/dev/null 2>&1; then
    while IFS= read -r line; do
      extra_tools_python_requirement_name "$line"; printf '\n'
    done <"$installed" >>"$protected"
    return 0
  fi
  candidate="$(mktemp -d "${current%/*}/env-XXXXXXXX")" || return
  cp --archive --reflink=auto "$current/." "$candidate/" || return
  name="$(extra_tools_python_requirement_name "$spec")"
  : >"$candidate/.constraints.txt"
  while IFS= read -r line; do
    package_name="$(extra_tools_python_requirement_name "$line")"
    if [[ -z "$name" || "$package_name" != "$name" ]] || grep -Fxq -- "$name" "$protected"; then
      printf '%s\n' "$line" >>"$candidate/.constraints.txt" || return
    fi
  done <"$installed"
  if [[ -s "$candidate/.constraints.txt" ]]; then constraints=(--constraint "$candidate/.constraints.txt"); fi
  if [[ "${TOOLS_INSTALL_MODE:-update}" == overwrite ]]; then constraints+=(--reinstall); fi
  timeout 600s "$EXTRA_TOOLS_INTERNAL_UV" pip install --python "$candidate/bin/python" "${constraints[@]}" -- "$spec" || return
  "$EXTRA_TOOLS_INTERNAL_UV" pip check --python "$candidate/bin/python" || return
  "$EXTRA_TOOLS_INTERNAL_UV" pip freeze --python "$candidate/bin/python" --exclude-editable >"$EXTRA_TOOLS_INTERNAL_TEMP/updated.txt" || return
  if [[ "${TOOLS_INSTALL_MODE:-update}" == overwrite ]] || ! cmp -s "$installed" "$EXTRA_TOOLS_INTERNAL_TEMP/updated.txt"; then
    extra_tools_activate_release "$candidate" "$EXTRA_TOOLS_INTERNAL_PROFILE/python/current" || return
    candidate=''
  fi
  while IFS= read -r line; do
    extra_tools_python_requirement_name "$line"; printf '\n'
  done <"$EXTRA_TOOLS_INTERNAL_TEMP/updated.txt" >>"$protected"
)

extra_tools_install_python_packages() {
  local spec current interpreter failed=0 lock_fd protected="$EXTRA_TOOLS_INTERNAL_TEMP/protected-packages"
  [[ -x "$EXTRA_TOOLS_INTERNAL_UV" ]] || { extra_tools_log 'Python packages require uv'; return 1; }
  # Tool stores may differ while the environment store is shared.
  mkdir -p -- "$(uv_environments_root)" || return
  exec {lock_fd}>"$(uv_environments_root)/.packages.lock" || return
  flock --wait 600 "$lock_fd" || return
  current="$EXTRA_TOOLS_INTERNAL_PROFILE/python/current"
  interpreter="$("$current/bin/python" -c 'import sys; print(sys._base_executable)')" || return
  extra_tools_prepare_python "$interpreter" || return
  : >"$protected" || return
  for spec in "$@"; do
    extra_tools_log "Python package $spec: checking/installing"
    if ! extra_tools_install_python_package "$spec" "$protected"; then
      extra_tools_log "Python package $spec: failed; keeping previous environment"
      failed=1
    fi
  done
  if ((failed)); then return 1; fi
  current="$(readlink -f -- "$current")" || return
  extra_tools_activate_release "$current" "${current%/*}/complete"
}
