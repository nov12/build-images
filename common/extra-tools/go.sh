#!/usr/bin/env bash

extra_tools_install_go() {
  local request="$1" architecture metadata release version url hash
  case "$(uname -sm)" in
    'Linux x86_64') architecture=amd64 ;;
    'Linux aarch64' | 'Linux arm64') architecture=arm64 ;;
    *) extra_tools_log 'Unsupported Go platform'; return 1 ;;
  esac
  url='https://go.dev/dl/?mode=json'
  case "$request" in latest | stable) ;; *) url+='&include=all' ;; esac
  metadata="$(extra_tools_fetch "$url")" || return
  release="$(jq -er --arg request "$request" --arg arch "$architecture" '
    [.[] | select(.stable and (.version | test("^go[0-9]+\\.[0-9]+\\.[0-9]+$"))) |
      select($request == "latest" or $request == "stable" or .version == "go" + $request or
        (.version | startswith("go" + $request + "."))) |
      . as $release | .files[] | select(.os == "linux" and .arch == $arch and .kind == "archive") |
      {version: $release.version, filename, sha256}] |
      sort_by(.version | ltrimstr("go") | split(".") | map(tonumber)) | last // empty |
      [.version, .filename, .sha256] | @tsv' <<<"$metadata")" || return
  IFS=$'\t' read -r version url hash <<<"$release"
  [[ "$url" != */* ]] || return 1
  EXTRA_TOOLS_INTERNAL_VERSION="$version"
  extra_tools_try_existing go "$version" && return 0
  extra_tools_install_archive go "$version" "https://go.dev/dl/$url" "$hash" sha256 1
}
