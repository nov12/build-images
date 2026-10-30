#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${AGENT_CLI_ROOT:-/opt/agent-cli}"
INTERVAL="${CLI_UPDATE_INTERVAL:-86400}"
CACHE=/tmp/t3-agent-npm-cache

export PATH="$ROOT/bin:$PATH"

log() {
  printf '[agent-update] %s\n' "$*"
}

# 判断由本脚本管理的 Agent CLI 是否正在运行
is_running() {
  local name="$1" proc cmd exe

  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue

    cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
    exe="$(readlink "$proc/exe" 2>/dev/null || true)"

    if [[ "$cmd" == *"$ROOT/releases/$name/"* ||
      "$cmd" == *"$ROOT/bin/$name "* ||
      "$exe" == "$ROOT/releases/$name/"* ]]; then
      return 0
    fi
  done

  return 1
}

# 仅在 Agent 未运行时清理旧版本
prune_old() {
  local name="$1" keep="$2"

  is_running "$name" && return 0

  find "$ROOT/releases/$name" \
    -mindepth 1 -maxdepth 1 -type d \
    ! -name "$keep" \
    -exec rm -rf -- {} +
}

# 检查并按需更新一个 CLI
update_one() {
  local name="$1" package="$2"
  local latest wanted link dest stage temp_link current

  latest="$(timeout 20s npm view "$package" version \
    --cache "$CACHE" \
    --fetch-retries=0 \
    --fetch-timeout=12000 2>/dev/null || true)"

  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    log "$name: version check failed; skipping"
    return 0
  fi

  link="$ROOT/bin/$name"
  dest="$ROOT/releases/$name/$latest"
  wanted="../releases/$name/$latest/node_modules/.bin/$name"
  current="$(readlink "$link" 2>/dev/null || true)"

  # 兼容此前的全局 npm 安装结构
  if [[ "$current" == "$wanted" ||
    "$current" == "../releases/$name/$latest/bin/$name" ]]; then
    if timeout 15s "$link" --version >/dev/null 2>&1; then
      log "$name: up to date ($latest)"
      prune_old "$name" "$latest"
      return 0
    fi
  fi

  # 运行中的 Agent 不执行升级
  if is_running "$name"; then
    log "$name: running; update postponed"
    return 0
  fi

  mkdir -p "$ROOT/bin" "$ROOT/releases/$name"
  stage="$(mktemp -d "$ROOT/releases/$name/.stage.XXXXXXXX")"

  # 为当前 CLI 创建独立 npm 项目，允许必要的安装脚本
  NODE_STAGE="$stage" NODE_PKG="$package" node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

fs.writeFileSync(
  path.join(process.env.NODE_STAGE, 'package.json'),
  JSON.stringify({
    name: 't3code-agent-runtime',
    version: '1.0.0',
    private: true,
    allowScripts: {
      [process.env.NODE_PKG]: true
    }
  })
);
NODE

  log "$name: installing $latest"

  # 本地安装，避免全局 prefix/lib 路径问题
  if ! timeout 300s npm install \
    --prefix "$stage" \
    --no-save \
    --no-package-lock \
    --include=optional \
    --no-audit --no-fund \
    --foreground-scripts \
    --fetch-retries=0 \
    --fetch-timeout=20000 \
    --cache "$CACHE" \
    "$package@$latest"; then

    log "$name: installation failed; keeping old version"
    rm -rf -- "$stage"
    return 0
  fi

  # 验证新版本能够实际运行
  if ! timeout 15s "$stage/node_modules/.bin/$name" \
    --version >/dev/null 2>&1; then

    log "$name: validation failed; keeping old version"
    rm -rf -- "$stage"
    return 0
  fi

  # 避免安装期间 Agent 被启动
  if is_running "$name"; then
    log "$name: running; activation postponed"
    rm -rf -- "$stage"
    return 0
  fi

  # 安装成功后替换旧版本
  rm -rf -- "$dest"
  mv -- "$stage" "$dest"

  # 原子切换可执行入口
  temp_link="$ROOT/bin/.$name.$$"
  ln -s "$wanted" "$temp_link"
  mv -Tf -- "$temp_link" "$link"

  log "$name: ready ($latest)"

  # 只保留一个正式版本
  prune_old "$name" "$latest"

  # 清理旧脚本留下的全局 npm 安装
  if ! is_running "$name"; then
    rm -rf -- "$ROOT/lib/node_modules/$package"
  fi
}

# 检查 CLI 卷是否可写，不自动修改权限
if ! mkdir -p "$ROOT/bin" "$ROOT/releases" 2>/dev/null; then
  echo "[agent-update] ERROR: $ROOT is not writable by $(id -u):$(id -g)" >&2
  exit 1
fi

# 按环境变量安装、检查和更新选中的 CLI
update_all() {
  mkdir -p "$ROOT/bin" "$ROOT/releases" || {
    log "CLI directory is not writable"
    return 1
  }

  local selected="${AGENT_CLIS-codex,claude,opencode}"
  local agent
  local -a agents=()
  local -A seen=()

  selected="${selected//[[:space:]]/}"

  case "$selected" in
    all)
      selected="codex,claude,opencode,gemini,qwen,kimi,copilot,pi,cline,amp"
      ;;
    none)
      selected=""
      ;;
  esac

  IFS=',' read -r -a agents <<<"$selected"

  for agent in "${agents[@]}"; do
    [[ -z "$agent" || -n "${seen[$agent]+x}" ]] && continue
    seen[$agent]=1

    case "$agent" in
      codex) update_one codex '@openai/codex' ;;
      claude) update_one claude '@anthropic-ai/claude-code' ;;
      opencode) update_one opencode '@opencode/cli' ;;
      gemini) update_one gemini '@google/gemini-cli' ;;
      qwen) update_one qwen '@qwen-code/qwen-code' ;;
      kimi) update_one kimi '@moonshot-ai/kimi-code' ;;
      copilot) update_one copilot '@github/copilot' ;;
      pi) update_one pi '@earendil-works/pi-coding-agent' ;;
      cline) update_one cline 'cline' ;;
      amp) update_one amp '@ampcode/cli' ;;
      *) log "$agent: unsupported, skipping" ;;
    esac
  done

  # 清理临时 npm 缓存
  rm -rf -- "$CACHE" || true
}

# 首次启动检查
update_all || log "update cycle failed; continuing to start T3"

# 后台定期检查，不阻塞主进程
if [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  (
    while sleep "$INTERVAL"; do
      update_all || log "periodic check failed"
    done
  ) &
fi

# 启动主进程
exec "$@"
