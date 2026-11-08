#!/usr/bin/env bash
set -Eeuo pipefail

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
  local common
  local -a args=()
  umask 077
  export DSH_NODE="${DSH_NODE:-$(type -P node)}"

  common="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../common/init.sh"
  [[ -f "$common" ]] || common=/usr/local/lib/container-common/init.sh
  # shellcheck source=../common/init.sh
  source "$common"
  common_prepare_user

  # DSH and Node are provided by the image; CLI calls skip tool initialization.
  if [[ "${0##*/}" == dsh ]]; then
    dsh_prepare_credentials
    exec "$DSH_NODE" /opt/dsh/node_modules/.bin/dsh "$@"
  fi

  export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
  export AGENT_CLIS="${AGENT_CLIS-none}"
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
