#!/usr/bin/env bash

extra_tools_require_uv() {
  if [[ -x "$EXTRA_TOOLS_INTERNAL_ROOT/uv/current/uv" ]]; then EXTRA_TOOLS_INTERNAL_UV="$EXTRA_TOOLS_INTERNAL_ROOT/uv/current/uv"; fi
  [[ -z "$EXTRA_TOOLS_INTERNAL_UV" ]] || return 0
  extra_tools_update_tool uv latest || return
  EXTRA_TOOLS_INTERNAL_UV="$EXTRA_TOOLS_INTERNAL_ROOT/uv/current/uv"
}

extra_tools_install_uv() {
  local request="$1" architecture triple asset metadata version url hash
  architecture="$(extra_tools_architecture)" || return
  case "$architecture" in x64) triple=x86_64-unknown-linux-gnu ;; arm64) triple=aarch64-unknown-linux-gnu ;; esac
  asset="uv-$triple.tar.gz"
  metadata="$(extra_tools_github_release astral-sh/uv "$request" '')" || return
  version="$(jq -er '.tag_name' <<<"$metadata")" || return
  EXTRA_TOOLS_INTERNAL_VERSION="$version"
  extra_tools_try_existing uv "$version" && return 0
  url="$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' <<<"$metadata")" || return
  hash="$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // "" | ltrimstr("sha256:")' <<<"$metadata")" || return
  if [[ -z "$hash" ]]; then
    hash="$(extra_tools_fetch "$url.sha256")" || return
    hash="${hash%%[[:space:]]*}"
  fi
  extra_tools_install_archive uv "$version" "$url" "$hash" sha256 1
}
