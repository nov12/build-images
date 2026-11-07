#!/usr/bin/env bash

extra_tools_relative_binary() {
  case "$1" in
    dotnet | bun | deno | uv) printf '%s\n' "$1" ;;
    rust) printf 'bin/rustc\n' ;;
    *) printf 'bin/%s\n' "$1" ;;
  esac
}

extra_tools_version() {
  local name="$1" binary="$2" output flag=--version
  case "$name" in go) flag=version ;; java) flag=-version ;; esac
  output="$(timeout 20s "$binary" "$flag" 2>&1)" || return
  [[ "$output" != *-nightly* && "$output" != *-beta* && "$output" != *-rc* && "$output" != *devel* ]] || return 1
  if [[ "$name" == java && "$output" =~ build\ ([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$name" == java && "$output" =~ build\ 1\.8\.0_([0-9]+)-b([0-9]+) ]]; then
    printf '8.0.%s+%s\n' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))"
  elif [[ "$output" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    if [[ "$name" == go ]]; then printf 'go'; fi
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

extra_tools_version_matches() {
  local version="${1#go}" request="$2"
  version="${version%%+*}"
  case "$request" in
    latest | stable | lts | sts) return 0 ;;
    *) [[ "$version" == "$request" || "$version" == "$request."* ]] ;;
  esac
}

extra_tools_system_directory() {
  local name="$1" binary="$2"
  case "$name" in
    go | java) binary="$(readlink -f -- "$binary")" || return ;;
  esac
  printf '%s\n' "${binary%/*}"
}

extra_tools_detect_system() {
  local name="$1" command binary directory version required
  local -a commands=("$name")
  case "$name" in rust) commands=(rustc) ;; python) commands=(python3 python) ;; esac
  for command in "${commands[@]}"; do
    while IFS= read -r binary; do
      [[ "$binary" == /* ]] || binary="$PWD/$binary"
      [[ "$binary" != "$EXTRA_TOOLS_INTERNAL_ROOT/"* ]] || continue
      [[ "$binary" != "$EXTRA_TOOLS_INTERNAL_PROFILE/"* ]] || continue
      version="$(extra_tools_version "$name" "$binary")" || continue
      extra_tools_version_matches "$version" "$EXTRA_TOOLS_INTERNAL_REQUEST" || continue
      directory="$(extra_tools_system_directory "$name" "$binary")" || continue
      case "$name" in
        node) required=npm; [[ -x "$directory/npx" ]] || continue ;;
        rust) required=cargo ;;
        java) required=javac ;;
        go) required=gofmt ;;
        *) required="${binary##*/}" ;;
      esac
      [[ -x "$directory/$required" ]] || continue
      EXTRA_TOOLS_INTERNAL_SYSTEM_BINARY="$binary"
      EXTRA_TOOLS_INTERNAL_SYSTEM_VERSION="$version"
      return 0
    done < <(type -aP "$command" 2>/dev/null || true)
  done
  return 1
}

extra_tools_adopt_system() (
  local name="$1" binary="$2" version="$3" directory candidate='' destination command
  local -a commands=()
  trap '[[ -z "$candidate" ]] || rm -rf -- "$candidate"' EXIT
  directory="$(extra_tools_system_directory "$name" "$binary")" || return
  case "$name" in
    go) commands=(go gofmt) ;;
    dotnet) commands=(dotnet) ;;
    python) commands=(python python3) ;;
    rust) commands=(rustc cargo rustdoc rustfmt cargo-fmt clippy-driver cargo-clippy) ;;
    node) commands=(node npm npx corepack) ;;
    bun) commands=(bun bunx) ;;
    deno) commands=(deno) ;;
    uv) commands=(uv uvx) ;;
    java)
      for command in "$directory"/*; do
        if [[ -f "$command" && -x "$command" ]]; then commands+=("${command##*/}"); fi
      done ;;
  esac
  mkdir -p -- "$EXTRA_TOOLS_INTERNAL_ROOT/$name/releases" || return
  candidate="$(mktemp -d "$EXTRA_TOOLS_INTERNAL_ROOT/$name/releases/system-$version.XXXXXXXX")" || return
  : >"$candidate/.installing" || return
  destination="$candidate"
  case "$name" in dotnet | bun | deno | uv) ;; *) destination+=/bin ;; esac
  mkdir -p -- "$destination" || return
  for command in "${commands[@]}"; do
    if [[ "$name" == python || "$name:$command" == bun:bunx ]]; then
      ln -s -- "$binary" "$destination/$command" || return
    elif [[ -f "$directory/$command" && -x "$directory/$command" ]]; then
      ln -s -- "$directory/$command" "$destination/$command" || return
    fi
  done
  rm -- "$candidate/.installing" || return
  printf '%s\n' "$version" >"$candidate/.version" || return
  extra_tools_activate_release "$candidate" "$EXTRA_TOOLS_INTERNAL_PROFILE/$name/current" || return
  candidate=''
)

extra_tools_cached_releases() {
  local name="$1" directory version
  for directory in "$EXTRA_TOOLS_INTERNAL_ROOT/$name/releases/"*; do
    [[ -d "$directory" ]] || continue
    [[ ! -e "$directory/.installing" ]] || continue
    if [[ -f "$directory/.version" ]]; then
      read -r version <"$directory/.version" || continue
    else
      # Releases installed before shared storage did not have a version marker.
      version="$(extra_tools_version "$name" "$directory/$(extra_tools_relative_binary "$name")")" || continue
    fi
    extra_tools_version_matches "$version" "$EXTRA_TOOLS_INTERNAL_REQUEST" || continue
    printf '%s\t%s\n' "$version" "$directory"
  done | sort -t $'\t' -k1,1Vr
}

extra_tools_try_existing() {
  local name="$1" wanted="${2#go}" binary version highest source directory base
  [[ "${TOOLS_INSTALL_MODE:-update}" != overwrite ]] || return 1
  while IFS=$'\t' read -r source version directory; do
    base=''
    if [[ "$source" == current ]]; then
      directory="$EXTRA_TOOLS_INTERNAL_PROFILE/$name/current"
      binary="$directory/$(extra_tools_relative_binary "$name")"
      version="$EXTRA_TOOLS_INTERNAL_CURRENT_VERSION"
    elif [[ "$source" == system ]]; then
      binary="$EXTRA_TOOLS_INTERNAL_SYSTEM_BINARY"
      version="$EXTRA_TOOLS_INTERNAL_SYSTEM_VERSION"
    else
      binary="$directory/$(extra_tools_relative_binary "$name")"
      # A cached system link may not exist in this image.
      version="$(extra_tools_version "$name" "$binary")" || continue
    fi
    if [[ -z "$version" ]] || ! extra_tools_version_matches "$version" "$EXTRA_TOOLS_INTERNAL_REQUEST"; then continue; fi
    if [[ -n "$wanted" ]]; then
      highest="$(printf '%s\n%s\n' "${version#go}" "$wanted" | sort -V | tail -n 1)"
      [[ "$highest" == "${version#go}" ]] || continue
      case "$EXTRA_TOOLS_INTERNAL_REQUEST" in
        lts | sts) [[ "${version%%.*}" == "${wanted%%.*}" ]] || continue ;;
      esac
    fi
    if [[ "$name" == python ]]; then
      if [[ -f "$directory/pyvenv.cfg" ]]; then
        base="$("$binary" -c 'import sys; print(sys._base_executable)')" || continue
        binary="$base"
      fi
      if [[ "$source" == system ]] || [[ -n "$base" && "${#packages[@]}" == 0 ]]; then
        extra_tools_adopt_system "$name" "$binary" "$version" || return
      elif [[ "$source" == cache ]]; then
        extra_tools_activate_release "$directory" "$EXTRA_TOOLS_INTERNAL_PROFILE/$name/current" || return
      fi
      EXTRA_TOOLS_INTERNAL_INTERPRETER="$binary"
    elif [[ "$source" == system ]]; then
      extra_tools_adopt_system "$name" "$binary" "$version" || return
    elif [[ "$source" == cache ]]; then
      extra_tools_activate_release "$directory" "$EXTRA_TOOLS_INTERNAL_PROFILE/$name/current" || return
    fi
    EXTRA_TOOLS_INTERNAL_VERSION="$version"
    extra_tools_log "$name: reusing $source installation ($version)"
    return 0
  done < <(
    printf 'current\t-\t-\n'
    while IFS=$'\t' read -r version directory; do
      printf 'cache\t%s\t%s\n' "$version" "$directory"
    done < <(extra_tools_cached_releases "$name")
    printf 'system\t-\t-\n'
  )
  return 1
}
