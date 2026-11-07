#!/usr/bin/env bash
set -Eeuo pipefail

dsh_log() { printf '[dsh-init] %s\n' "$*"; }
dsh_usable() { timeout --foreground 20s "${DSH_NODE:-node}" "$@" >/dev/null 2>&1; }

dsh_prepare_directory_picker() {
  "${DSH_NODE:-node}" --input-type=module - "$1" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
const require = createRequire(join(resolve(process.argv[2]), 'package.json'));
const filename = require.resolve('@deepseek-ai/dsh-host-directory-picker-browse');
const source = readFileSync(filename, 'utf8');
const before = 'const target = resolve(path ?? home);';
const after = 'const target = resolve(path ?? process.cwd());';
if (!source.includes(after)) {
  if (source.split(before).length !== 2) {
    throw new Error('Unsupported DSH directory picker; cannot apply the container working-directory default');
  }
  writeFileSync(filename, source.replace(before, after));
}
NODE
}

dsh_prepare_credentials() {
  "${DSH_NODE:-node}" --input-type=module <<'NODE'
import { closeSync, fchmodSync, fstatSync, lstatSync, mkdirSync, openSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
const configured = process.env.DSH_HOME?.trim() ? process.env.DSH_HOME : join(homedir(), '.dsh');
const home = resolve(configured === '~' ? homedir() : configured.replace(/^~[/\\]/, homedir() + '/'));
mkdirSync(home, { recursive: true, mode: 0o700 });
const filename = join(home, '.credentials.yaml');
try {
  const fd = openSync(filename, 'wx', 0o600);
  try { writeFileSync(fd, 'version: 1\n'); } finally { closeSync(fd); }
} catch (error) {
  if (error.code !== 'EEXIST') throw error;
}
if (!lstatSync(filename).isFile()) throw new Error('Expected a regular credentials file: ' + filename);
const fd = openSync(filename, 'r');
try {
  if ((fstatSync(fd).mode & 0o777) !== 0o600) fchmodSync(fd, 0o600);
  if ((fstatSync(fd).mode & 0o777) !== 0o600) {
    throw new Error('The mount does not honor mode 600 for ' + filename);
  }
} finally { closeSync(fd); }
NODE
}

dsh_trim_install() {
  local directory="$1" platform pty
  platform="$("${DSH_NODE:-node}" -p 'process.platform + "-" + process.arch')" || return 1
  find "$directory/node_modules" -type f \( -name '*.js.map' -o -name '*.mjs.map' -o -name '*.cjs.map' -o -name '*.css.map' -o -name '*.d.ts.map' \) -delete || return 1
  while IFS= read -r -d '' pty; do
    if [[ -d "$pty/prebuilds" ]]; then
      find "$pty/prebuilds" -mindepth 1 -maxdepth 1 -type d ! -name "$platform" -exec rm -rf -- {} + || return 1
    fi
    rm -rf -- "$pty/src" "$pty/third_party" || return 1
  done < <(find "$directory/node_modules" -type d -path '*/node_modules/node-pty' -print0 -prune)
}

dsh_activate_release() {
  local target="$1" directory="$DSH_RUNTIME_ROOT/dsh/releases"
  local link="$DSH_RUNTIME_ROOT/dsh/current" temporary previous current candidate
  previous="$(readlink -f -- "$link" 2>/dev/null || true)"
  mkdir -p "$(dirname -- "$link")" || return 1
  temporary="$(mktemp -d "${link}.XXXXXXXX")" || return 1
  if ln -s -- "$target" "$temporary/link" && mv -Tf -- "$temporary/link" "$link"; then
    rmdir -- "$temporary" || true
  else rm -rf -- "$temporary"; return 1; fi
  current="$(readlink -f -- "$link")" || return 1
  [[ -d "$directory" ]] || return 0
  while IFS= read -r -d '' candidate; do
    # Keep the active DSH release and one predecessor.
    if [[ "$candidate" != "$current" && "$candidate" != "$previous" ]]; then
      rm -rf -- "$candidate" || dsh_log "Cannot remove old release: $candidate"
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -type d -print0)
  return 0
}

dsh_update_due() {
  local request="$1" previous checked now
  previous="$(jq -r '.dsh.request // ""' <<<"$DSH_STATE")" || return 0
  checked="$(jq -r '.dsh.checkedAt // 0' <<<"$DSH_STATE")" || return 0
  [[ "$previous" == "$request" && "$checked" =~ ^[0-9]+$ ]] || return 0
  [[ "$checked" != 0 ]] || return 0
  now=$(( $(date +%s) * 1000 ))
  (( DSH_UPDATE_SECONDS>0 && now-checked>=DSH_UPDATE_SECONDS*1000 ))
}

dsh_save_state() {
  local request="$1" version="$2" updated temporary
  updated="$(jq -c --arg request "$request" --arg version "$version" \
    --argjson now "$(( $(date +%s) * 1000 ))" \
    '.dsh = {request:$request, version:$version, checkedAt:$now}' <<<"$DSH_STATE")" || return 1
  temporary="$(mktemp "$DSH_RUNTIME_ROOT/.state.XXXXXXXX")" || return 1
  if printf '%s\n' "$updated" >"$temporary" && mv -f -- "$temporary" "$DSH_RUNTIME_ROOT/state.json"; then
    DSH_STATE="$updated"
  else rm -f -- "$temporary"; return 1; fi
}

dsh_install() (
  local request="${DSH_VERSION:-latest}" version current seed previous releases release cache='' stage='' npm_pid=''
  trap '
    if [[ -n "$npm_pid" ]]; then
      kill -KILL -- "-$npm_pid" 2>/dev/null || kill -KILL "$npm_pid" 2>/dev/null || true
      wait "$npm_pid" 2>/dev/null || true
    fi
    if [[ -n "$stage" && "$(readlink -f -- "$DSH_RUNTIME_ROOT/dsh/current" 2>/dev/null || true)" != "$(readlink -f -- "$stage" 2>/dev/null || true)" ]]; then
      rm -rf -- "$stage"
    fi
    [[ -z "$cache" ]] || rm -rf -- "$cache"
  ' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  [[ "$request" =~ ^(latest|next|alpha|[0-9]+(\.[0-9]+){0,2}([-+][0-9A-Za-z.-]+)?)$ ]] || return 1
  current="$DSH_RUNTIME_ROOT/dsh/current/node_modules/.bin/dsh"
  if ! dsh_update_due "$request" && dsh_usable "$current" --version; then return 0; fi
  cache="$(mktemp -d "$DSH_RUNTIME_ROOT/.npm-cache.XXXXXXXX")" || return 1
  version="$(PATH="${DSH_NODE%/*}:$PATH" timeout --foreground 30s npm view "@deepseek-ai/dsh@$request" version --json \
    --cache "$cache" --fetch-retries=0 --fetch-timeout=20000 | jq -er 'if type=="array" then last else . end')" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || return 1
  previous="$(jq -r '.dsh.version // ""' <<<"$DSH_STATE")"
  if [[ "$previous" != "$version" ]] || ! dsh_usable "$current" --version; then
    seed="${DSH_SEED_DIR:-/opt/dsh}"
    releases="$DSH_RUNTIME_ROOT/dsh/releases"
    if [[ "$(jq -r .version "$seed/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null)" == "$version" ]] &&
       dsh_usable "$seed/node_modules/.bin/dsh" --version; then
      dsh_activate_release "$seed" || return 1
    else
      mkdir -p "$releases" || return 1
      stage="$(mktemp -d "$releases/.stage-$version.XXXXXXXX")" || return 1
      PATH="${DSH_NODE%/*}:$PATH" timeout 600s npm install --prefix "$stage" --no-save --no-package-lock --omit=dev \
        --include=optional --no-audit --no-fund --foreground-scripts --cache "$cache" "@deepseek-ai/dsh@$version" &
      npm_pid=$!
      if wait "$npm_pid"; then
        npm_pid=''
        dsh_prepare_directory_picker "$stage" && dsh_trim_install "$stage" &&
          dsh_usable "$stage/node_modules/.bin/dsh" --version || return 1
        release="${stage##*/}"
        release="$releases/${release#.stage-}"
        mv -- "$stage" "$release" || return 1
        stage="$release"
        dsh_activate_release "$stage" || return 1
        stage=''
      else return 1; fi
    fi
  fi
  dsh_save_state "$request" "$version" || return 1
  dsh_log "DSH: ready ($version)"
)

dsh_initialize() {
  DSH_NODE="${DSH_NODE:-$(type -P node)}"
  DSH_RUNTIME_ROOT="${DSH_RUNTIME_ROOT:-$HOME/.local/share/dsh-container}"
  DSH_UPDATE_SECONDS="${DSH_UPDATE_INTERVAL:-86400}"
  [[ "$DSH_UPDATE_SECONDS" =~ ^[0-9]{1,9}$ ]] || { dsh_log 'Invalid DSH update interval; using 86400'; DSH_UPDATE_SECONDS=86400; }
  DSH_UPDATE_SECONDS=$((10#$DSH_UPDATE_SECONDS))
  mkdir -p "$DSH_RUNTIME_ROOT" || return 1
  # The caller holds the install lock; these directories belong to interrupted installs.
  find "$DSH_RUNTIME_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.npm-cache.*' -exec rm -rf -- {} + || return 1
  if [[ -d "$DSH_RUNTIME_ROOT/dsh/releases" ]]; then
    find "$DSH_RUNTIME_ROOT/dsh/releases" -mindepth 1 -maxdepth 1 -type d -name '.stage-*' -exec rm -rf -- {} + || return 1
  fi
  DSH_STATE="$(jq -ce 'if type=="object" then . else {} end' "$DSH_RUNTIME_ROOT/state.json" 2>/dev/null || printf '{}')"
  dsh_install || dsh_log 'DSH update failed; using the existing installation or image fallback'
}

dsh_web_args() {
  local -n result="$1"
  local host="${DSH_HOST:-}" address fallback='127.0.0.1' trusted="${DSH_TRUSTED_HOSTS:-}"
  local -a hosts=()
  if [[ -z "$host" ]]; then
    for address in $(hostname -i); do
      [[ "$address" == 127.* || "$address" == ::1 ]] && continue
      fallback="$address"
      if [[ "$address" != *:* ]]; then host="$address"; break; fi
    done
    host="${host:-$fallback}"
  fi
  result=(dsh web --no-open --host "$host" --port 3080)
  [[ -z "${DSH_PUBLIC_URL:-}" ]] || result+=(--public-url "$DSH_PUBLIC_URL")
  trusted="${trusted//,/ }"
  read -r -a hosts <<<"${trusted//$'\n'/ }"
  for address in "${hosts[@]}"; do result+=(--trusted-host "$address"); done
}

main() {
  local binary common
  local -a args=()
  umask 077
  export DSH_RUNTIME_ROOT="${DSH_RUNTIME_ROOT:-$HOME/.local/share/dsh-container}"
  export DSH_NODE="${DSH_NODE:-$(type -P node)}"

  common="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../common/init.sh"
  [[ -f "$common" ]] || common=/usr/local/lib/container-common/init.sh
  # shellcheck source=../common/init.sh
  source "$common"
  common_prepare_user

  # Stable DSH calls skip tool initialization and use the image's Node.
  if [[ "${0##*/}" == dsh ]]; then
    binary="$DSH_RUNTIME_ROOT/dsh/current/node_modules/.bin/dsh"
    if ! dsh_usable "$binary" --version || ! dsh_prepare_directory_picker "$DSH_RUNTIME_ROOT/dsh/current"; then
      binary="${DSH_SEED_DIR:-/opt/dsh}/node_modules/.bin/dsh"
    fi
    dsh_prepare_credentials
    exec "$DSH_NODE" "$binary" "$@"
  fi

  export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
  export AGENT_CLIS="${AGENT_CLIS-none}"
  # Custom commands still prepare the user and common tools, without updating DSH.
  if [[ $# == 0 || "$1" == web || "$1" == dsh ]]; then
    mkdir -p "$DSH_RUNTIME_ROOT"
    (
      if flock --wait 600 9; then
        dsh_initialize || dsh_log 'Initialization failed; starting with available DSH'
      else dsh_log 'Another initialization is running; using available DSH'; fi
    ) 9>"$DSH_RUNTIME_ROOT/.install.lock"
  fi
  common_initialize

  if [[ $# == 0 || "$1" == web ]]; then
    [[ $# == 0 ]] || shift
    dsh_web_args args
    set -- "${args[@]}" "$@"
  fi
  exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
