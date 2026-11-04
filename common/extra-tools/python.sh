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
  extra_tools_prepare_python "$interpreter" || return
  EXTRA_TOOLS_INTERNAL_INTERPRETER="$interpreter"
}

extra_tools_prepare_python() (
  local interpreter="$1" identity current candidate='' directory
  trap '[[ -z "$candidate" ]] || rm -rf -- "$candidate"' EXIT
  [[ -x "$EXTRA_TOOLS_INTERNAL_UV" ]] || { extra_tools_log 'Python installation requires uv'; return 1; }
  identity="$("$interpreter" -c 'import sys; print(sys.executable); print(sys.version)')" || return
  directory="$EXTRA_TOOLS_INTERNAL_ROOT/python"
  current="$(readlink -f -- "$directory/current" 2>/dev/null || true)"
  if [[ "${TOOLS_INSTALL_MODE:-update}" == overwrite || -z "$current" || ! -f "$current/.interpreter" || "$(cat "$current/.interpreter")" != "$identity" ]] ||
    ! extra_tools_usable python; then
    mkdir -p -- "$directory" || return
    candidate="$(mktemp -d "$directory/env-XXXXXXXX")" || return
    "$EXTRA_TOOLS_INTERNAL_UV" venv --relocatable --python "$interpreter" "$candidate" || return
    if [[ -f "$current/pyvenv.cfg" && -x "$current/bin/python" ]]; then
      "$EXTRA_TOOLS_INTERNAL_UV" pip freeze --python "$current/bin/python" --exclude-editable >"$candidate/.previous-requirements.txt" || return
      if [[ -s "$candidate/.previous-requirements.txt" ]]; then
        timeout 600s "$EXTRA_TOOLS_INTERNAL_UV" pip install --python "$candidate/bin/python" --requirements "$candidate/.previous-requirements.txt" || return
      fi
    fi
    printf '%s' "$identity" >"$candidate/.interpreter" || return
    extra_tools_activate_release "$candidate" "$directory/current" "$directory" env- || return
    candidate=''
  fi
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
  current="$(readlink -f -- "$EXTRA_TOOLS_INTERNAL_ROOT/python/current")" || return
  installed="$EXTRA_TOOLS_INTERNAL_TEMP/installed.txt"
  "$EXTRA_TOOLS_INTERNAL_UV" pip freeze --python "$current/bin/python" --exclude-editable >"$installed" || return
  if [[ "${TOOLS_INSTALL_MODE:-update}" != overwrite ]] &&
    "$EXTRA_TOOLS_INTERNAL_UV" pip install --python "$current/bin/python" --check -- "$spec" >/dev/null 2>&1; then
    while IFS= read -r line; do
      extra_tools_python_requirement_name "$line"; printf '\n'
    done <"$installed" >>"$protected"
    return 0
  fi
  candidate="$(mktemp -d "$EXTRA_TOOLS_INTERNAL_ROOT/python/env-XXXXXXXX")" || return
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
    extra_tools_activate_release "$candidate" "$EXTRA_TOOLS_INTERNAL_ROOT/python/current" "$EXTRA_TOOLS_INTERNAL_ROOT/python" env- || return
    candidate=''
  fi
  while IFS= read -r line; do
    extra_tools_python_requirement_name "$line"; printf '\n'
  done <"$EXTRA_TOOLS_INTERNAL_TEMP/updated.txt" >>"$protected"
)

extra_tools_install_python_packages() {
  local spec protected="$EXTRA_TOOLS_INTERNAL_TEMP/protected-packages"
  [[ -x "$EXTRA_TOOLS_INTERNAL_UV" ]] || { extra_tools_log 'Python packages require uv'; return 1; }
  : >"$protected" || return
  for spec in "$@"; do
    extra_tools_log "Python package $spec: checking/installing"
    extra_tools_install_python_package "$spec" "$protected" || extra_tools_log "Python package $spec: failed; keeping previous environment"
  done
}
