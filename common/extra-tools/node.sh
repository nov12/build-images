#!/usr/bin/env bash

extra_tools_install_node() {
  local request="$1" architecture metadata version filename checksums hash
  architecture="$(extra_tools_architecture)" || return
  metadata="$(extra_tools_fetch 'https://nodejs.org/dist/index.json')" || return
  version="$(jq -er --arg request "$request" --arg platform "linux-$architecture" '
    [.[] | select(.files | index($platform)) |
      select(.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) |
      select(if $request == "lts" then .lts != false
        elif $request == "latest" or $request == "stable" then true
        else .version == "v" + $request or (.version | startswith("v" + $request + ".")) end)] |
      sort_by(.version | ltrimstr("v") | split(".") | map(tonumber)) | last // empty | .version' <<<"$metadata")" || return
  EXTRA_TOOLS_INTERNAL_VERSION="${version#v}"
  extra_tools_try_existing node "${version#v}" && return 0
  filename="node-$version-linux-$architecture.tar.gz"
  checksums="$(extra_tools_fetch "https://nodejs.org/dist/$version/SHASUMS256.txt")" || return
  hash="$(awk -v filename="$filename" '$2 == filename {print $1}' <<<"$checksums")"
  extra_tools_install_archive node "${version#v}" "https://nodejs.org/dist/$version/$filename" "$hash" sha256 1
}
