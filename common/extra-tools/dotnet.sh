#!/usr/bin/env bash

extra_tools_install_dotnet() {
  local request="$1" architecture metadata channel version url release hash
  case "$(uname -sm)" in
    'Linux x86_64') architecture=x64 ;;
    'Linux aarch64' | 'Linux arm64') architecture=arm64 ;;
    *) extra_tools_log 'Unsupported .NET platform'; return 1 ;;
  esac
  metadata="$(extra_tools_fetch 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json')" || return
  channel="$(jq -ec --arg request "$request" '
    [."releases-index"[] | select(."channel-version" | test("^[0-9]+\\.[0-9]+$")) |
      select(."latest-sdk" | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) |
      select(if (["latest", "stable", "lts", "sts"] | index($request)) != null then
        (."support-phase" == "active" or ."support-phase" == "maintenance") and
        (($request != "lts" and $request != "sts") or ."release-type" == $request)
      else
        ($request | split(".") | .[:2] | join(".")) as $wanted |
        ."channel-version" == $wanted or (."channel-version" | startswith($wanted + "."))
      end)] | sort_by(."channel-version" | split(".") | map(tonumber)) | last // empty' <<<"$metadata")" || return
  version="$request"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    version="$(jq -r '."latest-sdk"' <<<"$channel")" || return
  fi
  url="$(jq -r '."releases.json"' <<<"$channel")" || return
  metadata="$(extra_tools_fetch "$url")" || return
  release="$(jq -er --arg version "$version" --arg rid "linux-$architecture" '
    [.releases[] | (.sdks // [.sdk])[] | select(.version == $version) |
      .files[] | select(.rid == $rid and (.url | endswith(".tar.gz")))] |
      first // empty | [.url, .hash] | @tsv' <<<"$metadata")" || return
  IFS=$'\t' read -r url hash <<<"$release"
  EXTRA_TOOLS_INTERNAL_VERSION="$version"
  extra_tools_try_existing dotnet "$version" && return 0
  extra_tools_install_archive dotnet "$version" "$url" "$hash" sha512 0
}
