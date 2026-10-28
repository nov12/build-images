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

    cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"

    if [[ "$cmd" == *"/releases/$name-"* ||
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

  find "$ROOT/releases" \
    -mindepth 1 -maxdepth 1 \
    -type d -name "${name}-*" \
    ! -name "${name}-${keep}" \
    -exec rm -rf -- {} +
}

# npm CLI 安装和自动更新
update_npm() {
  local name="$1" package="$2"
  local latest target link wanted stage tmp
  local -a flags=()

  latest="$(timeout 20s npm view "$package" version \
    --fetch-retries=0 \
    --fetch-timeout=12000 2>/dev/null || true)"

  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    log "$name: version check failed"
    return 0
  fi

  target="$ROOT/releases/${name}-${latest}"
  link="$ROOT/bin/$name"
  wanted="../releases/${name}-${latest}/node_modules/.bin/$name"

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

  # 仅允许所选包执行安装脚本
  flags+=("--allow-scripts=$package")

  if ! timeout 20s "$target/node_modules/.bin/$name" \
      --version >/dev/null 2>&1; then

    stage="$(mktemp -d "$ROOT/releases/.${name}.XXXXXXXX")"

    printf '{"name":"managed-agent","private":true,"version":"1.0.0"}\n' \
      > "$stage/package.json"

    log "$name: installing $latest"

    if ! timeout 360s npm install \
      --prefix "$stage" \
      --no-save --no-package-lock \
      --include=optional \
      --no-audit --no-fund \
      --foreground-scripts \
      --fetch-retries=0 \
      --fetch-timeout=20000 \
      "${flags[@]}" \
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

  IFS=',' read -r -a agents <<< "$selected"

  for agent in "${agents[@]}"; do
    case "$agent" in
      codex)    update_npm codex '@openai/codex' ;;
      claude)   update_npm claude '@anthropic-ai/claude-code' ;;
      opencode) update_npm opencode '@opencode/cli' ;;
      gemini)   update_npm gemini '@google/gemini-cli' ;;
      qwen)     update_npm qwen '@qwen-code/qwen-code' ;;
      kimi)     update_npm kimi '@moonshot-ai/kimi-code' ;;
      copilot)  update_npm copilot '@github/copilot' ;;
      pi)       update_npm pi '@mariozechner/pi-coding-agent' ;;
      cline)    update_npm cline 'cline' ;;
      amp)      update_npm amp '@ampcode/cli' ;;
      agy)      update_agy ;;
      "")       ;;
      *)        log "$agent: unsupported, skipped" ;;
    esac
  done

  rm -rf -- "$CACHE"
  exec {fd}>&-
}

# 首次启动检查并安装
update_all || log "Initial CLI update failed"

# 后台定期检查，不阻塞 AionUi
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