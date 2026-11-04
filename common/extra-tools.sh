#!/usr/bin/env bash

source "${BASH_SOURCE[0]%/*}/extra-tools/existing.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/go.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/dotnet.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/python.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/rust.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/node.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/javascript.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/java.sh"
source "${BASH_SOURCE[0]%/*}/extra-tools/uv.sh"

extra_tools_log() {
  printf '[extra-tools] %s\n' "$*" >&2
}

extra_tools_enabled() {
  local root="${EXTRA_TOOLS_HOME:-${CONTAINER_TOOLS_HOME:-$HOME/.local/share/extra-tools}}"
  local tools="${EXTRA_TOOLS:-}" packages="${PYTHON_PACKAGES:-}"
  tools="${tools//[[:space:]]/}"
  packages="${packages//[[:space:]]/}"
  [[ -n "$tools" && "$tools" != none ]] || [[ -n "$packages" && "$packages" != none ]] ||
    [[ -d "$root/bin" || -e "$root/python/current" || -f "$root/extra-tools-state.json" ]]
}

extra_tools_parse_list() {
  local value="$1" character quote='' item='' depth=0 index
  local -n output="$2"
  output=()
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    if [[ -n "$quote" ]]; then
      if [[ "$character" == "$quote" ]]; then
        quote=''
      elif [[ "$character" == "\\" && "${value:index+1:1}" == "$quote" ]]; then
        index=$((index + 1))
        item+="${value:index:1}"
      else
        item+="$character"
      fi
    else
      case "$character" in
        "'" | '"') quote="$character" ;;
        '[') depth=$((depth + 1)); item+="$character" ;;
        ']') depth=$((depth - 1)); ((depth >= 0)) || return 1; item+="$character" ;;
        ',' | [[:space:]])
          if ((depth == 0)); then
            if [[ -n "$item" ]]; then output+=("$item"); item=''; fi
          else
            item+="$character"
          fi ;;
        *) item+="$character" ;;
      esac
    fi
  done
  [[ -z "$quote" && "$depth" == 0 ]] || return 1
  if [[ -n "$item" ]]; then output+=("$item"); fi
  if [[ "${#output[@]}" == 1 && "${output[0]}" == none ]]; then output=(); fi
}

extra_tools_fetch() {
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 \
    --connect-timeout 15 --max-time 45 "$1"
}

extra_tools_github_release() {
  local repository="$1" request="$2" prefix="$3" metadata version
  case "$request" in
    latest | stable) extra_tools_fetch "https://api.github.com/repos/$repository/releases/latest" ;;
    *.*.*) extra_tools_fetch "https://api.github.com/repos/$repository/releases/tags/$prefix$request" ;;
    lts | sts) extra_tools_log "$repository does not support $request"; return 1 ;;
    *)
      metadata="$(extra_tools_fetch "https://api.github.com/repos/$repository/git/matching-refs/tags/$prefix$request.")" || return
      version="$(jq -er --arg prefix "refs/tags/$prefix" '
        [.[] | .ref | ltrimstr($prefix) | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] |
        sort_by(split(".") | map(tonumber)) | last // empty' <<<"$metadata")" || return
      extra_tools_fetch "https://api.github.com/repos/$repository/releases/tags/$prefix$version" ;;
  esac
}

extra_tools_activate() {
  local target="$1" link="$2" temporary
  temporary="${link}.tmp.${BASHPID}"
  ln -s -- "$target" "$temporary" || return
  if ! mv -Tf -- "$temporary" "$link"; then
    rm -f -- "$temporary"
    return 1
  fi
}

extra_tools_activate_release() {
  local candidate="$1" link="$2" directory="$3" prefix="${4:-}"
  local previous current entry
  previous="$(readlink -f -- "$link" 2>/dev/null || true)"
  extra_tools_activate "$candidate" "$link" || return
  current="$(readlink -f -- "$link")" || return
  for entry in "$directory"/"$prefix"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    if [[ "$entry" != "$previous" && "$entry" != "$current" ]]; then
      rm -rf -- "$entry" || extra_tools_log "Cannot remove old release: $entry"
    fi
  done
}

extra_tools_architecture() {
  case "$(uname -sm)" in
    'Linux x86_64') printf 'x64\n' ;;
    'Linux aarch64' | 'Linux arm64') printf 'arm64\n' ;;
    *) extra_tools_log 'Unsupported platform; expected Linux x86_64 or arm64'; return 1 ;;
  esac
}

extra_tools_probe() {
  local name="$1" directory="$2" binary flag=--version
  case "$name" in
    go) binary=bin/go; flag=version ;;
    dotnet) binary=dotnet ;;
    python) binary=bin/python ;;
    rust) binary=bin/rustc ;;
    node) binary=bin/node ;;
    bun) binary=bun ;;
    deno) binary=deno ;;
    java) binary=bin/java; flag=-version ;;
    uv) binary=uv ;;
    *) return 1 ;;
  esac
  timeout 20s "$directory/$binary" "$flag"
}

extra_tools_usable() {
  extra_tools_probe "$1" "$EXTRA_TOOLS_INTERNAL_ROOT/$1/current" >/dev/null 2>&1
}

extra_tools_download() {
  local url="$1" destination="$2" hash="$3" algorithm="$4"
  [[ "$url" == https://* ]] || return 1
  case "$algorithm" in
    sha256) [[ "$hash" =~ ^[a-fA-F0-9]{64}$ ]] || return 1 ;;
    sha512) [[ "$hash" =~ ^[a-fA-F0-9]{128}$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
    --connect-timeout 20 --max-time 600 -o "$destination" "$url" || return
  printf '%s  %s\n' "$hash" "$destination" | "${algorithm}sum" -c -
}

extra_tools_install_archive() (
  local name="$1" version="$2" url="$3" hash="$4" algorithm="$5" strip="$6"
  local directory="$EXTRA_TOOLS_INTERNAL_ROOT/$name/releases" candidate='' archive='' unpacked executable
  trap '[[ -z "$candidate" ]] || rm -rf -- "$candidate"; [[ -z "$archive" ]] || rm -f -- "$archive"' EXIT
  [[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || return 1
  mkdir -p -- "$directory" || return
  candidate="$(mktemp -d "$directory/$version.XXXXXXXX")" || return
  archive="$candidate.archive"
  extra_tools_download "$url" "$archive" "$hash" "$algorithm" || return
  case "$name" in
    bun | deno)
      unpacked="$EXTRA_TOOLS_INTERNAL_TEMP/$name-unpacked"
      mkdir -p -- "$unpacked" || return
      unzip -q "$archive" -d "$unpacked" || return
      executable="$(find "$unpacked" -type f -name "$name" -print -quit)"
      [[ -n "$executable" ]] || return 1
      cp -- "$executable" "$candidate/$name" && chmod 755 "$candidate/$name" || return
      if [[ "$name" == bun ]]; then ln -s bun "$candidate/bunx" || return; fi ;;
    rust)
      unpacked="$EXTRA_TOOLS_INTERNAL_TEMP/rust-unpacked"
      mkdir -p -- "$unpacked" || return
      tar -xzf "$archive" -C "$unpacked" --strip-components=1 || return
      bash "$unpacked/install.sh" --prefix="$candidate" --disable-ldconfig \
        --components="rustc,cargo,rust-std-$strip" || return ;;
    *) tar -xzf "$archive" -C "$candidate" --strip-components="$strip" || return ;;
  esac
  extra_tools_probe "$name" "$candidate" >/dev/null || return
  extra_tools_activate_release "$candidate" "$EXTRA_TOOLS_INTERNAL_ROOT/$name/current" "$directory" || return
  candidate=''
)

extra_tools_publish_commands() {
  local name directory target command wrapper link destination temporary quoted
  for name in go dotnet python rust node bun deno java uv; do
    directory="$EXTRA_TOOLS_INTERNAL_ROOT/$name/current/bin"
    case "$name" in dotnet | bun | deno | uv) directory="$EXTRA_TOOLS_INTERNAL_ROOT/$name/current" ;; esac
    if [[ -d "$directory" ]]; then
      for wrapper in "$EXTRA_TOOLS_INTERNAL_ROOT/.commands/$name/"*; do
        command="${wrapper##*/}"
        [[ -f "$directory/$command" && -x "$directory/$command" ]] && continue
        link="$EXTRA_TOOLS_INTERNAL_ROOT/bin/$command"
        if [[ "$(readlink -- "$link" 2>/dev/null || true)" == "$wrapper" ]]; then
          rm -f -- "$link" || return
        fi
      done
      for target in "$directory"/*; do
        [[ -f "$target" && -x "$target" ]] || continue
        command="${target##*/}"
        [[ "$command" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || continue
        wrapper="$EXTRA_TOOLS_INTERNAL_ROOT/.commands/$name/$command"
        link="$EXTRA_TOOLS_INTERNAL_ROOT/bin/$command"
        if [[ -e "$link" || -L "$link" ]]; then
          destination="$(readlink -- "$link" 2>/dev/null || true)"
          if [[ "$destination" != "$wrapper" && "$destination" != "$target" ]]; then
            extra_tools_log "$command: existing command belongs to another owner; keeping it"
            continue
          fi
        fi
        mkdir -p -- "${wrapper%/*}" "${link%/*}" || return
        temporary="$wrapper.tmp.$BASHPID"
        quoted="${target//\'/\'\\\'\'}"
        printf '#!/bin/sh\nexec '\''%s'\'' "$@"\n' "$quoted" >"$temporary" || return
        chmod 755 "$temporary" && mv -f -- "$temporary" "$wrapper" || return
        extra_tools_activate "$wrapper" "$link" || return
      done
    fi
  done
}

extra_tools_supported() {
  case "$1" in
    go | dotnet | python | rust | node | bun | deno | java | uv) return 0 ;;
    *) return 1 ;;
  esac
}

extra_tools_update_tool() (
  local name="$1" request="$2" state previous version checked now interval due=1 repair_request
  local mode="${TOOLS_INSTALL_MODE:-update}"
  local EXTRA_TOOLS_INTERNAL_VERSION='' EXTRA_TOOLS_INTERNAL_INTERPRETER=''
  local EXTRA_TOOLS_INTERNAL_CURRENT_VERSION EXTRA_TOOLS_INTERNAL_SYSTEM_BINARY='' EXTRA_TOOLS_INTERNAL_SYSTEM_VERSION=''
  local EXTRA_TOOLS_INTERNAL_REQUEST="$request"
  EXTRA_TOOLS_INTERNAL_CURRENT_VERSION="$(extra_tools_version "$name" "$EXTRA_TOOLS_INTERNAL_ROOT/$name/current/$(extra_tools_relative_binary "$name")" || true)"
  extra_tools_detect_system "$name" || true
  state="$EXTRA_TOOLS_INTERNAL_ROOT/extra-tools-state.json"
  previous="$(jq --arg name "$name" '.[$name] // {}' "$state" 2>/dev/null || printf '{}')"
  version="$(jq -r '.version // ""' <<<"$previous")" || return
  checked="$(jq -r '.checkedAt // 0' <<<"$previous")" || return
  now="$(date +%s)" || return
  interval="${TOOLS_UPDATE_INTERVAL:-86400}"
  if [[ ! "$interval" =~ ^[0-9]{1,9}$ ]]; then
    extra_tools_log 'Invalid update interval; using 86400 seconds'
    interval=86400
  fi
  interval=$((10#$interval))
  if [[ "$mode" == skip ]]; then interval=0; fi
  if [[ "$(jq -r '.request // ""' <<<"$previous")" == "$request" &&
    "$(jq -r '.mode // "update"' <<<"$previous")" == "$mode" && "$checked" =~ ^[0-9]{1,16}$ ]]; then
    if ((interval == 0 || now - checked / 1000 < interval)); then due=0; fi
  fi
  if [[ "$mode" == overwrite ]]; then due=1; fi
  if ((due == 0)) && [[ -n "$version" && "$EXTRA_TOOLS_INTERNAL_CURRENT_VERSION" == "$version" ]]; then
    if [[ "$name" != python || "${#packages[@]}" == 0 || -f "$EXTRA_TOOLS_INTERNAL_ROOT/python/current/pyvenv.cfg" ]]; then return 0; fi
  fi
  repair_request="$request"
  if ((due == 0)) && [[ -n "$version" ]]; then repair_request="${version#go}"; fi
  extra_tools_log "$name@$repair_request: checking/installing"
  if [[ "$request" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ((interval == 0)); then
    extra_tools_try_existing "$name" '' || true
  fi
  if [[ -z "$EXTRA_TOOLS_INTERNAL_VERSION" ]]; then
    "extra_tools_install_$name" "$repair_request" "$version" || return
  fi
  if ! jq -e 'type == "object"' "$state" >/dev/null 2>&1; then
    printf '{}\n' >"$EXTRA_TOOLS_INTERNAL_TEMP/state-base.json" || return
    state="$EXTRA_TOOLS_INTERNAL_TEMP/state-base.json"
  fi
  jq --arg name "$name" --arg request "$request" --arg mode "$mode" --arg version "$EXTRA_TOOLS_INTERNAL_VERSION" \
    --arg interpreter "$EXTRA_TOOLS_INTERNAL_INTERPRETER" --argjson checked "$((now * 1000))" \
    '.[$name] = ({request: $request, mode: $mode, version: $version, checkedAt: $checked} +
      (if $interpreter == "" then {} else {interpreter: $interpreter} end))' \
    "$state" >"$EXTRA_TOOLS_INTERNAL_TEMP/state.json" || return
  mv -f -- "$EXTRA_TOOLS_INTERNAL_TEMP/state.json" "$EXTRA_TOOLS_INTERNAL_ROOT/extra-tools-state.json" || return
  extra_tools_log "$name: ready ($EXTRA_TOOLS_INTERNAL_VERSION)"
)

extra_tools_install() (
  local EXTRA_TOOLS_INTERNAL_ROOT="$1" EXTRA_TOOLS_INTERNAL_TEMP='' lock_fd specification name request
  local EXTRA_TOOLS_INTERNAL_UV
  local -a tools=() packages=()
  local -A selected=()
  trap '[[ -z "$EXTRA_TOOLS_INTERNAL_TEMP" ]] || rm -rf -- "$EXTRA_TOOLS_INTERNAL_TEMP"' EXIT
  case "${TOOLS_INSTALL_MODE:-update}" in
    skip | update | overwrite) ;;
    *) extra_tools_log 'TOOLS_INSTALL_MODE must be skip, update or overwrite'; return 1 ;;
  esac
  extra_tools_parse_list "${EXTRA_TOOLS:-}" tools || { extra_tools_log 'Invalid EXTRA_TOOLS list'; return 1; }
  extra_tools_parse_list "${PYTHON_PACKAGES:-}" packages || { extra_tools_log 'Invalid PYTHON_PACKAGES list'; return 1; }
  if ((${#tools[@]} || ${#packages[@]})) && ! command -v jq >/dev/null; then
    extra_tools_log 'Installation requires jq'
    return 1
  fi
  mkdir -p -- "$EXTRA_TOOLS_INTERNAL_ROOT" || return
  exec {lock_fd}>"$EXTRA_TOOLS_INTERNAL_ROOT/.extra-tools.lock" || return
  flock --wait 600 "$lock_fd" || return
  EXTRA_TOOLS_INTERNAL_TEMP="$(mktemp -d "$EXTRA_TOOLS_INTERNAL_ROOT/.install.XXXXXXXX")" || return
  export UV_PYTHON_INSTALL_DIR="$EXTRA_TOOLS_INTERNAL_ROOT/python-interpreters"
  export UV_CACHE_DIR="$EXTRA_TOOLS_INTERNAL_ROOT/cache/uv"
  EXTRA_TOOLS_INTERNAL_UV="$(type -P uv || true)"
  if [[ -x "$EXTRA_TOOLS_INTERNAL_ROOT/uv/current/uv" ]]; then EXTRA_TOOLS_INTERNAL_UV="$EXTRA_TOOLS_INTERNAL_ROOT/uv/current/uv"; fi
  if ((${#packages[@]})); then
    local has_python=0
    for specification in "${tools[@]}"; do
      if [[ "${specification,,}" == python || "${specification,,}" == python@* ]]; then has_python=1; fi
    done
    if ((has_python == 0)); then tools+=(python); fi
  fi
  for specification in "${tools[@]}"; do
    case "${specification,,}" in
      uv | uv@*) tools=("$specification" "${tools[@]}"); break ;;
    esac
  done
  for specification in "${tools[@]}"; do
    specification="${specification,,}"
    name="${specification%%@*}"
    request="${specification#*@}"
    if [[ "$request" == "$specification" ]]; then
      request=latest
      if [[ "$name" == dotnet || "$name" == node || "$name" == java ]]; then request=lts; fi
    fi
    if ! extra_tools_supported "$name" || [[ ! "$request" =~ ^(latest|stable|lts|sts|[0-9]+(\.[0-9]+){0,2})$ ]]; then
      extra_tools_log "$specification: unsupported tool/version; skipping"
      continue
    fi
    case "$request" in
      lts) [[ "$name" == dotnet || "$name" == node || "$name" == java ]] || { extra_tools_log "$name: LTS channel is not supported"; continue; } ;;
      sts) [[ "$name" == dotnet ]] || { extra_tools_log "$name: STS channel is not supported"; continue; } ;;
    esac
    [[ -z "${selected[$name]+x}" ]] || continue
    selected[$name]=1
    extra_tools_update_tool "$name" "$request" || extra_tools_log "$specification: installation failed; keeping available version"
    if [[ "$name" == uv && -x "$EXTRA_TOOLS_INTERNAL_ROOT/uv/current/uv" ]]; then
      EXTRA_TOOLS_INTERNAL_UV="$EXTRA_TOOLS_INTERNAL_ROOT/uv/current/uv"
    fi
  done
  if ((${#packages[@]})); then
    if extra_tools_require_uv; then extra_tools_install_python_packages "${packages[@]}"; fi
  fi
  extra_tools_publish_commands
)

extra_tools_initialize() {
  extra_tools_enabled || return 0
  local root="${EXTRA_TOOLS_HOME:-${CONTAINER_TOOLS_HOME:-$HOME/.local/share/extra-tools}}"
  root="$(realpath -m -- "$root")" || return
  extra_tools_install "$root" || extra_tools_log 'Initialization failed; using available tools'
  if [[ -d "$root/bin" && ":$PATH:" != *":$root/bin:"* ]]; then export PATH="$root/bin:$PATH"; fi
  if [[ -f "$root/python/current/pyvenv.cfg" && -x "$root/python/current/bin/python" ]]; then export VIRTUAL_ENV="$root/python/current"; fi
  return 0
}
