#!/usr/bin/env bash

extra_tools_install_java() {
  local request="$1" architecture metadata range upper version url hash
  local -a components=()
  architecture="$(extra_tools_architecture)" || return
  case "$request" in
    latest | stable | lts)
      metadata="$(extra_tools_fetch 'https://api.adoptium.net/v3/info/available_releases')" || return
      if [[ "$request" == lts ]]; then
        request="$(jq -er '.most_recent_lts' <<<"$metadata")" || return
      else
        request="$(jq -er '.most_recent_feature_release' <<<"$metadata")" || return
      fi ;;
    sts) return 1 ;;
  esac
  if [[ "$request" == *+* ]]; then
    upper="${request##*+}"
    [[ "$upper" =~ ^[0-9]+$ ]] || return 1
    upper="${request%+*}+$((10#$upper + 1))"
    range="[$request,$upper)"
  else
    IFS=. read -r -a components <<<"$request"
    upper="${components[-1]}"
    components[-1]="$((10#$upper + 1))"
    upper="$(IFS=.; printf '%s' "${components[*]}")"
    range="[$request,$upper)"
  fi
  range="$(jq -rn --arg range "$range" '$range | @uri')" || return
  metadata="$(extra_tools_fetch "https://api.adoptium.net/v3/assets/version/$range?architecture=$architecture&image_type=jdk&os=linux&vendor=eclipse&page_size=1&sort_order=DESC&release_type=ga")" || return
  version="$(jq -er '.[0].version_data | "\(.major).\(.minor).\(.security)+\(.build)"' <<<"$metadata")" || return
  EXTRA_TOOLS_INTERNAL_VERSION="$version"
  extra_tools_try_existing java "$version" && return 0
  url="$(jq -er '.[0].binaries[0].package.link' <<<"$metadata")" || return
  hash="$(jq -er '.[0].binaries[0].package.checksum' <<<"$metadata")" || return
  extra_tools_install_archive java "$version" "$url" "$hash" sha256 1
}
