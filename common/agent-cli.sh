#!/usr/bin/env bash

agent_cli_log() {
  printf '[agent-update] %s\n' "$*"
}

# 判断由本脚本管理的 Agent CLI 是否正在运行
agent_cli_is_running() {
  local name="$1" proc cmd exe

  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    [[ "${proc##*/}" == "$BASHPID" ]] && continue

    cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
    exe="$(readlink "$proc/exe" 2>/dev/null || true)"

    if [[ "$cmd" == *"$AGENT_CLI_MANAGER_ROOT/releases/$name/"* ||
      "$cmd" == *"$AGENT_CLI_MANAGER_ROOT/releases/$name-"* ||
      "$cmd" == *"$AGENT_CLI_MANAGER_ROOT/bin/$name "* ||
      "$cmd" == "$name "* ||
      "$exe" == "$AGENT_CLI_MANAGER_ROOT/releases/$name-"* ||
      "$exe" == "$AGENT_CLI_MANAGER_ROOT/releases/$name/"* ]]; then
      return 0
    fi
  done

  return 1
}

# 仅在 Agent 未运行时清理旧版本
agent_cli_prune_old() {
  local name="$1" keep="$2"

  agent_cli_is_running "$name" && return 0

  find "$AGENT_CLI_MANAGER_ROOT/releases/$name" \
    -mindepth 1 -maxdepth 1 -type d \
    ! -name "$keep" \
    -exec rm -rf -- {} +

  find "$AGENT_CLI_MANAGER_ROOT/releases" \
    -mindepth 1 -maxdepth 1 -type d \
    -name "${name}-*" \
    -exec rm -rf -- {} +
}

agent_cli_activate_entry() {
  local name="$1" target="$2" temporary
  temporary="$(mktemp -d "$AGENT_CLI_MANAGER_ROOT/bin/.$name.XXXXXXXX")" || return 1
  if ! ln -s -- "$target" "$temporary/$name" || ! mv -Tf -- "$temporary/$name" "$AGENT_CLI_MANAGER_ROOT/bin/$name"; then
    rm -rf -- "$temporary"
    return 1
  fi
  rm -rf -- "$temporary"
}

agent_cli_version_matches() {
  local version="$1" request="$2"
  case "$request" in
    latest | stable) return 0 ;;
    *.*.*) [[ "$version" == "$request" ]] ;;
    *) [[ "$version" == "$request."* && "$version" != *-* ]] ;;
  esac
}

agent_cli_reuse_existing() {
  local name="$1" wanted="${2:-}" request="${3:-latest}" binary output version highest
  while IFS= read -r binary; do
    [[ -x "$binary" ]] || continue
    output="$(PATH="$AGENT_CLI_MANAGER_PATH" timeout 15s "$binary" --version 2>&1)" || continue
    version=unknown
    if [[ "$output" =~ ([0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?) ]]; then version="${BASH_REMATCH[1]}"; fi
    agent_cli_version_matches "$version" "$request" || continue
    if [[ -n "$wanted" ]]; then
      [[ "$version" != unknown ]] || continue
      if [[ "$version" != "$wanted" && "$version" == *-* ]]; then continue; fi
      highest="$(printf '%s\n%s\n' "$version" "$wanted" | sort -V | tail -n 1)"
      [[ "$highest" == "$version" ]] || continue
    fi
    if [[ "$binary" != "$AGENT_CLI_MANAGER_ROOT/bin/$name" ]]; then
      if agent_cli_is_running "$name"; then
        agent_cli_log "$name: running; activation postponed"
        return 0
      fi
      [[ "$binary" == /* ]] || binary="$PWD/$binary"
      agent_cli_activate_entry "$name" "$binary" || return
    fi
    agent_cli_log "$name: reusing existing installation ($version)"
    return 0
  done < <(
    printf '%s\n' "$AGENT_CLI_MANAGER_ROOT/bin/$name"
    type -aP "$name" 2>/dev/null || true
  )
  return 1
}

# 检查并按需更新一个 CLI
agent_cli_update_one() {
  local name="$1" package="$2" request="${3:-latest}"
  local latest wanted dest legacy stage mode="${CLI_INSTALL_MODE:-update}"

  if [[ "$request" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    latest="$request"
    if [[ "$mode" != overwrite ]] && agent_cli_reuse_existing "$name" "$latest" "$request"; then return 0; fi
  else
    if [[ "$mode" == skip ]] && agent_cli_reuse_existing "$name" '' "$request"; then return 0; fi
    latest="$(PATH="$AGENT_CLI_MANAGER_PATH" timeout 20s "$AGENT_CLI_MANAGER_NODE" "$AGENT_CLI_MANAGER_NPM" view "$package@$request" version --json \
    --cache "$AGENT_CLI_MANAGER_CACHE" \
    --fetch-retries=0 \
    --fetch-timeout=12000 2>/dev/null | "$AGENT_CLI_MANAGER_NODE" -e '
const metadata = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
const versions = Array.isArray(metadata) ? metadata : [metadata];
for (const version of versions) {
  if (typeof version === "string" && /^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$/.test(version)) console.log(version);
}
' 2>/dev/null | sort -V | tail -n 1 || true)"
  fi

  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    agent_cli_log "$name: version check failed; skipping"
    return 0
  fi

  if [[ "$mode" != overwrite && "$request" != "$latest" ]] && agent_cli_reuse_existing "$name" "$latest" "$request"; then return 0; fi

  dest="$AGENT_CLI_MANAGER_ROOT/releases/$name/$latest"
  legacy="$AGENT_CLI_MANAGER_ROOT/releases/${name}-${latest}"
  wanted="../releases/$name/$latest/node_modules/.bin/$name"

  # 运行中的 Agent 不执行升级
  if agent_cli_is_running "$name"; then
    agent_cli_log "$name: running; update postponed"
    return 0
  fi

  mkdir -p "$AGENT_CLI_MANAGER_ROOT/bin" "$AGENT_CLI_MANAGER_ROOT/releases/$name" || return 1

  if [[ "$mode" != overwrite && ! -e "$dest" ]] && timeout 15s "$legacy/node_modules/.bin/$name" \
    --version >/dev/null 2>&1; then
    mv -- "$legacy" "$dest" || return 1
  fi

  if [[ "$mode" == overwrite ]] || ! timeout 15s "$dest/node_modules/.bin/$name" \
    --version >/dev/null 2>&1; then
    stage="$(mktemp -d "$AGENT_CLI_MANAGER_ROOT/releases/$name/.stage.XXXXXXXX")" || return 1

    # 为当前 CLI 创建独立 npm 项目，允许必要的安装脚本
    if ! NODE_STAGE="$stage" NODE_PKG="$package" "$AGENT_CLI_MANAGER_NODE" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

fs.writeFileSync(
  path.join(process.env.NODE_STAGE, 'package.json'),
  JSON.stringify({
    name: 'agent-cli-runtime',
    version: '1.0.0',
    private: true,
    allowScripts: {
      [process.env.NODE_PKG]: true
    }
  })
);
NODE
    then
      agent_cli_log "$name: setup failed; keeping old version"
      rm -rf -- "$stage"
      return 1
    fi

    agent_cli_log "$name: installing $latest"

    # 本地安装，避免全局 prefix/lib 路径问题
    if ! PATH="$AGENT_CLI_MANAGER_PATH" timeout 300s "$AGENT_CLI_MANAGER_NODE" "$AGENT_CLI_MANAGER_NPM" install \
      --prefix "$stage" \
      --no-save \
      --no-package-lock \
      --include=optional \
      --no-audit --no-fund \
      --foreground-scripts \
      --fetch-retries=0 \
      --fetch-timeout=20000 \
      --cache "$AGENT_CLI_MANAGER_CACHE" \
      "$package@$latest"; then

      agent_cli_log "$name: installation failed; keeping old version"
      rm -rf -- "$stage"
      return 0
    fi

    # 验证新版本能够实际运行
    if ! timeout 15s "$stage/node_modules/.bin/$name" \
      --version >/dev/null 2>&1; then

      agent_cli_log "$name: validation failed; keeping old version"
      rm -rf -- "$stage"
      return 0
    fi

    # 避免安装期间 Agent 被启动
    if agent_cli_is_running "$name"; then
      agent_cli_log "$name: running; activation postponed"
      rm -rf -- "$stage"
      return 0
    fi

    if [[ -e "$dest" ]]; then dest+=".${stage##*.}"; fi
    if ! mv -- "$stage" "$dest"; then
      agent_cli_log "$name: release activation failed"
      rm -rf -- "$stage"
      return 1
    fi
    wanted="../releases/$name/${dest##*/}/node_modules/.bin/$name"
  fi

  if agent_cli_is_running "$name"; then
    agent_cli_log "$name: running; activation postponed"
    return 0
  fi

  # 原子切换可执行入口
  if ! agent_cli_activate_entry "$name" "$wanted"; then
    agent_cli_log "$name: entry activation failed; keeping current entry"
    return 1
  fi

  agent_cli_log "$name: ready ($latest)"

  # 只保留一个正式版本
  agent_cli_prune_old "$name" "${dest##*/}"

  # 清理旧脚本留下的全局 npm 安装
  if ! agent_cli_is_running "$name"; then
    rm -rf -- "$AGENT_CLI_MANAGER_ROOT/lib/node_modules/$package"
  fi
}

agent_cli_update_agy() {
  local binary="$AGENT_CLI_MANAGER_ROOT/bin/agy"
  local installer stage mode="${CLI_INSTALL_MODE:-update}" resolved

  if [[ "$mode" == skip ]] && agent_cli_reuse_existing agy; then return 0; fi

  if agent_cli_is_running agy; then
    agent_cli_log "agy: busy, update postponed"
    return 0
  fi

  resolved="$(readlink -f -- "$binary" 2>/dev/null || true)"
  if [[ "$mode" == overwrite || ! -x "$binary" || "$resolved" != "$AGENT_CLI_MANAGER_ROOT/"* ]]; then
    agent_cli_log "agy: installing"
    installer="$(mktemp)" || return 1
    mkdir -p "$AGENT_CLI_MANAGER_ROOT/releases/agy" || { rm -f -- "$installer"; return 1; }
    stage="$(mktemp -d "$AGENT_CLI_MANAGER_ROOT/releases/agy/install.XXXXXXXX")" || { rm -f -- "$installer"; return 1; }

    if curl -fsSL --retry 2 --max-time 90 \
      https://antigravity.google/cli/install.sh \
      -o "$installer" &&
      NPM_CONFIG_CACHE="$AGENT_CLI_MANAGER_CACHE" timeout 300s bash "$installer" --dir "$stage" &&
      timeout 15s "$stage/agy" --version >/dev/null 2>&1; then
      if ! agent_cli_is_running agy && agent_cli_activate_entry agy "$stage/agy"; then
        agent_cli_prune_old agy "${stage##*/}"
        stage=''
      fi
    else
      agent_cli_log "agy: installation failed; keeping old version"
    fi

    rm -f -- "$installer"
    if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi
  else
    timeout 120s "$binary" update || agent_cli_log "agy: update check failed"
  fi
}

agent_cli_update_agent() {
  local specification="$1" name request=latest package
  name="${specification%%@*}"
  if [[ "$specification" == *@* ]]; then request="${specification#*@}"; fi
  if [[ "$request" == stable ]]; then request=latest; fi
  if [[ "$request" != latest && ! "$request" =~ ^[0-9]+(\.[0-9]+){0,2}$ &&
    ! "$request" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    agent_cli_log "$specification: unsupported version; skipping"
    return 0
  fi
  case "$name" in
    codex) package='@openai/codex' ;;
    claude) package='@anthropic-ai/claude-code' ;;
    opencode) package='@opencode/cli' ;;
    gemini) package='@google/gemini-cli' ;;
    qwen) package='@qwen-code/qwen-code' ;;
    kimi) package='@moonshot-ai/kimi-code' ;;
    copilot) package='@github/copilot' ;;
    pi) package='@earendil-works/pi-coding-agent' ;;
    cline) package='cline' ;;
    amp) package='@ampcode/cli' ;;
    agy)
      if [[ "$request" != latest ]]; then
        agent_cli_log 'agy: version selection is not supported; skipping'
        return 0
      fi
      agent_cli_update_agy
      return ;;
    *) agent_cli_log "$name: unsupported, skipping"; return 0 ;;
  esac
  agent_cli_update_one "$name" "$package" "$request"
}

# 按环境变量安装、检查和更新选中的 CLI
agent_cli_update_all() {
  mkdir -p "$AGENT_CLI_MANAGER_ROOT/bin" "$AGENT_CLI_MANAGER_ROOT/releases" || {
    agent_cli_log "CLI directory is not writable"
    return 1
  }

  local selected="$AGENT_CLI_MANAGER_SELECTED"
  local agent name fd AGENT_CLI_MANAGER_CACHE
  local -a agents=()
  local -A seen=()

  case "$selected" in
    all)
      selected="codex,claude,opencode,gemini,qwen,kimi,copilot,pi,cline,amp${AGENT_CLI_ALL_EXTRA:+,$AGENT_CLI_ALL_EXTRA}"
      selected="${selected//[[:space:]]/}"
      ;;
    none)
      selected=""
      ;;
  esac

  [[ -z "$selected" ]] && return 0

  if ! exec {fd}>"$AGENT_CLI_MANAGER_ROOT/.update.lock"; then
    agent_cli_log "CLI update lock is not writable"
    return 1
  fi

  if ! flock -n "$fd"; then
    exec {fd}>&-
    agent_cli_log "Another update is running"
    return 0
  fi

  if ! AGENT_CLI_MANAGER_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/agent-cli-cache.XXXXXXXX")"; then
    exec {fd}>&-
    return 1
  fi

  IFS=',' read -r -a agents <<<"$selected"

  for agent in "${agents[@]}"; do
    name="${agent%%@*}"
    [[ -z "$name" || -n "${seen[$name]+x}" ]] && continue
    seen[$name]=1

    agent_cli_update_agent "$agent" || agent_cli_log "$agent: update failed; continuing"
  done

  # 清理临时 npm 缓存
  rm -rf -- "$AGENT_CLI_MANAGER_CACHE" || true
  exec {fd}>&-
}

agent_cli_initialize() {
  local tools_root="${EXTRA_TOOLS_HOME:-${CONTAINER_TOOLS_HOME:-$HOME/.local/share/extra-tools}}" tools_bin path_entry
  local -a path_entries=()
  tools_bin="$(realpath -m -- "$tools_root/bin")" || return
  IFS=: read -r -a path_entries <<<"$PATH"
  AGENT_CLI_MANAGER_PATH=''
  for path_entry in "${path_entries[@]}"; do
    case "${path_entry%/}" in "$tools_bin" | "${tools_root%/}/bin") continue ;; esac
    AGENT_CLI_MANAGER_PATH+="${AGENT_CLI_MANAGER_PATH:+:}${path_entry:-.}"
  done
  AGENT_CLI_MANAGER_NODE="$(PATH="$AGENT_CLI_MANAGER_PATH" type -P node || true)"
  AGENT_CLI_MANAGER_NPM="$(PATH="$AGENT_CLI_MANAGER_PATH" type -P npm || true)"
  AGENT_CLI_MANAGER_PATH="$(dirname -- "$AGENT_CLI_MANAGER_NODE"):$AGENT_CLI_MANAGER_PATH"
  AGENT_CLI_MANAGER_ROOT="$(realpath -m -- "${AGENT_CLI_ROOT:-/opt/agent-cli}")" || return
  AGENT_CLI_MANAGER_SELECTED="${AGENT_CLIS-codex,claude,opencode}"
  AGENT_CLI_MANAGER_SELECTED="${AGENT_CLI_MANAGER_SELECTED//[[:space:]]/}"
  export PATH="$AGENT_CLI_MANAGER_ROOT/bin:$PATH"

  case "$AGENT_CLI_MANAGER_SELECTED" in
    '' | none) return 0 ;;
  esac

  case "${CLI_INSTALL_MODE:-update}" in
    skip | update | overwrite) ;;
    *) agent_cli_log 'CLI_INSTALL_MODE must be skip, update or overwrite'; return 1 ;;
  esac

  if ! mkdir -p "$AGENT_CLI_MANAGER_ROOT/bin" "$AGENT_CLI_MANAGER_ROOT/releases" 2>/dev/null; then
    echo "[agent-update] ERROR: $AGENT_CLI_MANAGER_ROOT is not writable by $(id -u):$(id -g)" >&2
    return 1
  fi

}
