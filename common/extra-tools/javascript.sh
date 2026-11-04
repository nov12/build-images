#!/usr/bin/env bash

extra_tools_install_javascript_runtime() {
  local name="$1" request="$2" architecture repository prefix asset metadata version url hash checksum_url checksums
  architecture="$(extra_tools_architecture)" || return
  case "$name" in
    bun)
      repository=oven-sh/bun; prefix=bun-v
      case "$architecture" in x64) asset=bun-linux-x64-baseline.zip ;; arm64) asset=bun-linux-aarch64.zip ;; esac ;;
    deno)
      repository=denoland/deno; prefix=v
      case "$architecture" in x64) asset=deno-x86_64-unknown-linux-gnu.zip ;; arm64) asset=deno-aarch64-unknown-linux-gnu.zip ;; esac ;;
  esac
  metadata="$(extra_tools_github_release "$repository" "$request" "$prefix")" || return
  version="$(jq -er --arg prefix "$prefix" '.tag_name | ltrimstr($prefix)' <<<"$metadata")" || return
  EXTRA_TOOLS_INTERNAL_VERSION="$version"
  extra_tools_try_existing "$name" "$version" && return 0
  url="$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' <<<"$metadata")" || return
  hash="$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // "" | ltrimstr("sha256:")' <<<"$metadata")" || return
  if [[ -z "$hash" ]]; then
    if [[ "$name" == bun ]]; then
      checksum_url="$(jq -er '.assets[] | select(.name == "SHASUMS256.txt") | .browser_download_url' <<<"$metadata")" || return
      checksums="$(extra_tools_fetch "$checksum_url")" || return
      hash="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset {print $1}' <<<"$checksums")"
    else
      hash="$(extra_tools_fetch "$url.sha256sum")" || return
      hash="${hash%%[[:space:]]*}"
    fi
  fi
  extra_tools_install_archive "$name" "$version" "$url" "$hash" sha256 0
}

extra_tools_install_bun() {
  extra_tools_install_javascript_runtime bun "$@"
}

extra_tools_install_deno() {
  extra_tools_install_javascript_runtime deno "$@"
}
