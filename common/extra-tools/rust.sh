#!/usr/bin/env bash

extra_tools_rust_field() {
  awk -F '"' -v section="[$2]" -v key="$3" '
    /^\[/ { selected = ($0 == section) }
    selected && $0 ~ "^" key " = " { print $2; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$1"
}

extra_tools_install_rust() {
  local request="$1" architecture triple manifest version url hash metadata
  architecture="$(extra_tools_architecture)" || return
  case "$architecture" in x64) triple=x86_64-unknown-linux-gnu ;; arm64) triple=aarch64-unknown-linux-gnu ;; esac
  case "$request" in
    latest | stable) request=stable ;;
    lts | sts) extra_tools_log "Rust does not support $request"; return 1 ;;
    *.*.*) ;;
    *)
      metadata="$(extra_tools_github_release rust-lang/rust "$request" '')" || return
      request="$(jq -er '.tag_name' <<<"$metadata")" || return ;;
  esac
  manifest="$EXTRA_TOOLS_INTERNAL_TEMP/rust-channel.toml"
  extra_tools_fetch "https://static.rust-lang.org/dist/channel-rust-$request.toml" >"$manifest" || return
  version="$(extra_tools_rust_field "$manifest" pkg.rust version)" || return
  version="${version%% *}"
  EXTRA_TOOLS_INTERNAL_VERSION="$version"
  extra_tools_try_existing rust "$version" && return 0
  url="$(extra_tools_rust_field "$manifest" "pkg.rust.target.$triple" url)" || return
  hash="$(extra_tools_rust_field "$manifest" "pkg.rust.target.$triple" hash)" || return
  extra_tools_install_archive rust "$version" "$url" "$hash" sha256 "$triple"
}
