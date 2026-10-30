#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${AGENT_CLI_ROOT:-$HOME/.local}"
CACHE="/tmp/aionui-npm-cache"
INTERVAL="${CLI_UPDATE_INTERVAL:-86400}"
SELECTED="${AGENT_CLIS-codex,claude,opencode}"

export PATH="$ROOT/bin:$PATH"
export NPM_CONFIG_CACHE="$CACHE"

log() {
  printf '[agent-update] %s\n' "$*"
}

# 检测对应 CLI 是否正在运行
is_running() {
  local name="$1" p cmd

  for p in /proc/[0-9]*; do
    [[ -r "$p/cmdline" ]] || continue
    [[ "${p##*/}" == "$$" ]] && continue

    cmd="$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null || true)"

    if [[ "$cmd" == *"/releases/$name/"* ||
      "$cmd" == *"/releases/$name-"* ||
      "$cmd" == *"/bin/$name "* ||
      "$cmd" == "$name "* ]]; then
      return 0
    fi
  done

  return 1
}

# 只保留当前安装版本；运行中的程序暂不清理
prune_old() {
  local name="$1" keep="$2"

  is_running "$name" && return 0

  find "$ROOT/releases/$name" \
    -mindepth 1 -maxdepth 1 -type d \
    ! -name "$keep" \
    -exec rm -rf -- {} +

  find "$ROOT/releases" \
    -mindepth 1 -maxdepth 1 \
    -type d -name "${name}-*" \
    -exec rm -rf -- {} +
}

# npm CLI 安装和自动更新
update_npm() {
  local name="$1" package="$2"
  local latest target legacy link wanted stage tmp

  latest="$(timeout 20s npm view "$package" version \
    --fetch-retries=0 \
    --fetch-timeout=12000 2>/dev/null || true)"

  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    log "$name: version check failed"
    return 0
  fi

  target="$ROOT/releases/$name/$latest"
  legacy="$ROOT/releases/${name}-${latest}"
  link="$ROOT/bin/$name"
  wanted="../releases/$name/$latest/node_modules/.bin/$name"

  if [[ "$(readlink "$link" 2>/dev/null || true)" == "$wanted" ]] \
    && timeout 20s "$link" --version >/dev/null 2>&1; then

    log "$name: current ($latest)"
    prune_old "$name" "$latest"
    return 0
  fi

  if is_running "$name"; then
    log "$name: busy, skipping update"
    return 0
  fi

  mkdir -p "$ROOT/releases/$name"

  if [[ ! -e "$target" ]] && timeout 20s "$legacy/node_modules/.bin/$name" \
    --version >/dev/null 2>&1; then
    mv -- "$legacy" "$target"
  fi

  if ! timeout 20s "$target/node_modules/.bin/$name" \
    --version >/dev/null 2>&1; then

    stage="$(mktemp -d "$ROOT/releases/$name/.stage.XXXXXXXX")"

    # npm 的本地安装从项目配置读取脚本白名单
    NODE_STAGE="$stage" NODE_PKG="$package" node <<'NODE_CONFIG'
const fs = require('node:fs');
const path = require('node:path');
fs.writeFileSync(path.join(process.env.NODE_STAGE, 'package.json'), JSON.stringify({
  name: 'managed-agent', private: true, version: '1.0.0',
  allowScripts: { [process.env.NODE_PKG]: true }
}));
NODE_CONFIG

    log "$name: installing $latest"

    if ! timeout 360s npm install \
      --prefix "$stage" \
      --no-save --no-package-lock \
      --include=optional \
      --no-audit --no-fund \
      --foreground-scripts \
      --fetch-retries=0 \
      --fetch-timeout=20000 \
      "$package@$latest"; then

      log "$name: installation failed"
      rm -rf -- "$stage"
      return 0
    fi

    if ! timeout 20s "$stage/node_modules/.bin/$name" \
      --version >/dev/null 2>&1; then

      log "$name: validation failed"
      rm -rf -- "$stage"
      return 0
    fi

    # 安装期间如果任务启动，放弃本次升级
    if is_running "$name"; then
      log "$name: became busy, update postponed"
      rm -rf -- "$stage"
      return 0
    fi

    rm -rf -- "$target"
    mv -- "$stage" "$target"
  fi

  if is_running "$name"; then
    log "$name: busy, activation postponed"
    return 0
  fi

  # 原子切换到新版本
  tmp="$ROOT/bin/.${name}.$$"
  ln -s "$wanted" "$tmp"
  mv -Tf -- "$tmp" "$link"

  log "$name: ready ($latest)"
  prune_old "$name" "$latest"
}

# Google Antigravity 使用官方独立安装器
update_agy() {
  local binary="$ROOT/bin/agy"
  local installer

  if is_running agy; then
    log "agy: busy, update postponed"
    return 0
  fi

  if [[ ! -x "$binary" ]]; then
    log "agy: installing"

    installer="$(mktemp)"

    if curl -fsSL --retry 2 --max-time 90 \
      https://antigravity.google/cli/install.sh \
      -o "$installer"; then

      bash "$installer" || log "agy: installation failed"
    else
      log "agy: installer download failed"
    fi

    rm -f -- "$installer"
  else
    timeout 120s "$binary" update \
      || log "agy: update check failed"
  fi
}

# 按环境变量选择 CLI
update_all() {
  if ! mkdir -p "$ROOT/bin" "$ROOT/releases"; then
    log "CLI directory is not writable"
    return 0
  fi

  local selected="${SELECTED//[[:space:]]/}"
  local agent fd
  local -a agents=()

  case "$selected" in
    all)
      selected="codex,claude,opencode,gemini,qwen,kimi,copilot,pi,cline,amp,agy"
      ;;
    none)
      selected=""
      ;;
  esac

  [[ -z "$selected" ]] && return 0

  # 防止多个更新周期并发执行
  exec {fd}>"$ROOT/.update.lock"

  if ! flock -n "$fd"; then
    exec {fd}>&-
    log "Another update is running"
    return 0
  fi

  IFS=',' read -r -a agents <<<"$selected"

  for agent in "${agents[@]}"; do
    case "$agent" in
      codex) update_npm codex '@openai/codex' ;;
      claude) update_npm claude '@anthropic-ai/claude-code' ;;
      opencode) update_npm opencode '@opencode/cli' ;;
      gemini) update_npm gemini '@google/gemini-cli' ;;
      qwen) update_npm qwen '@qwen-code/qwen-code' ;;
      kimi) update_npm kimi '@moonshot-ai/kimi-code' ;;
      copilot) update_npm copilot '@github/copilot' ;;
      pi) update_npm pi '@earendil-works/pi-coding-agent' ;;
      cline) update_npm cline 'cline' ;;
      amp) update_npm amp '@ampcode/cli' ;;
      agy) update_agy ;;
      "") ;;
      *) log "$agent: unsupported, skipped" ;;
    esac
  done

  rm -rf -- "$CACHE"
  exec {fd}>&-
}

# 按上游托管运行时目录契约复用镜像内的 Node.js，不改动已有用户缓存
prepare_node_runtime() {
  local data_dir="${AIONUI_DATA_DIR:-$HOME/.aionui-web}"
  local version arch runtime stage arg
  local previous=""
  for arg in "$@"; do
    if [[ "$previous" == --data-dir ]]; then data_dir="$arg"; fi
    previous="$arg"
  done
  version="$(cat /usr/local/share/aionui/managed-node-version)"
  arch="$(node -p process.arch)"
  runtime="$data_dir/runtime/node/node-v$version-linux-$arch"
  [[ -e "$runtime" ]] && return 0
  mkdir -p "$(dirname "$runtime")"
  stage="$(mktemp -d "$(dirname "$runtime")/.system-node.XXXXXXXX")"
  mkdir -p "$stage/bin" "$stage/lib/node_modules"
  for arg in node npm npx; do
    ln -s "/usr/local/bin/$arg" "$stage/bin/$arg"
  done
  ln -s /usr/local/lib/node_modules/npm "$stage/lib/node_modules/npm"
  if ! mv -Tn "$stage" "$runtime"; then
    rm -rf -- "$stage"
    return 1
  fi
  [[ ! -d "$stage" ]] || rm -rf -- "$stage"
}

if [[ -f /usr/local/share/aionui/managed-node-version ]]; then
  prepare_node_runtime "$@"
fi

# 首次启动检查并安装
update_all || log "Initial CLI update failed"

# 后台定期检查，不阻塞主进程
if [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] \
  && [[ -n "$SELECTED" && "$SELECTED" != "none" ]]; then

  (
    while sleep "$INTERVAL"; do
      update_all || log "Periodic update failed"
    done
  ) &
fi

log "Starting AionUi"
exec "$@"
