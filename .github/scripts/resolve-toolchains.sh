#!/usr/bin/env bash
set -euo pipefail

metadata="$(mktemp -d)"
trap 'rm -rf "$metadata"' EXIT
curl -fsSL --retry 3 --max-time 60 https://nodejs.org/dist/index.json > "$metadata/node.json"
node_version="$(jq -er '
  [.[] | select(.lts != false) | select(.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | select((.files | index("linux-x64")) and (.files | index("linux-arm64")))]
  | sort_by(.version | ltrimstr("v") | split(".") | map(tonumber)) | last | .version | ltrimstr("v")
' "$metadata/node.json")"
[[ "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
printf 'node_version=%s\n' "$node_version" >> "$GITHUB_OUTPUT"
curl -fsSL --retry 3 --max-time 60 "https://nodejs.org/dist/v$node_version/SHASUMS256.txt" > "$metadata/node-checksums.txt"
{
  printf '### Resolved toolchains\n\nNode LTS: `%s` (official release index)\n\n' "$node_version"
  for architecture in x64 arm64; do
    checksum="$(awk -v file="node-v$node_version-linux-$architecture.tar.gz" '$2 == file {print $1}' "$metadata/node-checksums.txt")"
    [[ "$checksum" =~ ^[a-f0-9]{64}$ ]]
    printf -- '- Node linux-%s SHA256: `%s`\n' "$architecture" "$checksum"
  done
} >> "$GITHUB_STEP_SUMMARY"

for tool in "$@"; do
  case "$tool" in
    bun)
      gh api repos/oven-sh/bun/releases/latest > "$metadata/bun.json"
      bun_version="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | ltrimstr("bun-v")' "$metadata/bun.json")"
      [[ "$bun_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
      printf 'bun_version=%s\n' "$bun_version" >> "$GITHUB_OUTPUT"
      printf '\nBun: `%s`\n' "$bun_version" >> "$GITHUB_STEP_SUMMARY"
      ;;
    corepack)
      npm view corepack@latest version dist.integrity --json > "$metadata/corepack.json"
      corepack_version="$(jq -er .version "$metadata/corepack.json")"
      [[ "$corepack_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
      integrity="$(jq -er '."dist.integrity" | select(startswith("sha512-"))' "$metadata/corepack.json")"
      printf 'corepack_version=%s\n' "$corepack_version" >> "$GITHUB_OUTPUT"
      printf '\nCorepack: `%s`, npm integrity: `%s`\n' "$corepack_version" "$integrity" >> "$GITHUB_STEP_SUMMARY"
      ;;
    *) printf 'Unsupported toolchain: %s\n' "$tool" >&2; exit 1 ;;
  esac
done
