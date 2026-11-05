#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# == 0 )); then
  echo 'Usage: entrypoint command [args...]' >&2
  exit 64
fi

# 设置环境
USER_NAME="${USER_NAME:-apple}"

export TZ="${TZ:-Asia/Singapore}"

PASSWORD_ACCESS="${PASSWORD_ACCESS:-false}"
USER_PASSWORD="${USER_PASSWORD:-}"

SUDO_ACCESS="${SUDO_ACCESS:-false}"
PUBLIC_KEY="${PUBLIC_KEY:-}"

CONFIG_DIR="${CONFIG_DIR:-/config}"
SSH_CONFIG_DIR="${CONFIG_DIR}/ssh"

SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
SSHD_CONFIG="${SSHD_CONFIG_DIR}/00-container.conf"

AGENT_CLI_ROOT="${AGENT_CLI_ROOT:-/opt/agent-cli}"
export AGENT_CLI_ROOT
export PATH="$AGENT_CLI_ROOT/bin:$PATH"

source /usr/local/lib/container-common/init.sh
if [[ "$1" == sshd ]]; then shift; set -- /usr/sbin/sshd "$@"; fi

if [[ "$(id -u)" != 0 ]]; then
  # 数字用户没有系统家目录时，使用镜像的默认用户目录。
  if [[ "${HOME:-/}" == / || "$HOME" == /root ]]; then
    export HOME="/home/$USER_NAME"
  fi
  if [[ "$1" != /usr/sbin/sshd ]]; then
    common_initialize
    exec "$@"
  fi
  common_prepare_user "$USER_NAME"
  if [[ "$PASSWORD_ACCESS" != false || "$SUDO_ACCESS" != false ]]; then
    echo '[error] Password and sudo setup require root; numeric-user SSH uses public keys' >&2
    exit 1
  fi
  SSH_LISTEN_PORT="${SSH_LISTEN_PORT:-22}"
  mkdir -p "$SSH_CONFIG_DIR" "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [[ -n "$PUBLIC_KEY" ]]; then
    printf '%s\n' "$PUBLIC_KEY" > "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
  fi
  for TYPE in ed25519 rsa; do
    KEY="$SSH_CONFIG_DIR/ssh_host_${TYPE}_key"
    if [[ ! -f "$KEY" ]]; then
      ssh-keygen -q -N '' -t "$TYPE" -f "$KEY"
    fi
  done
  EXTRA_TOOLS_HOME="${EXTRA_TOOLS_HOME:-${CONTAINER_TOOLS_HOME:-$HOME/.local/share/extra-tools}}"
  export EXTRA_TOOLS_HOME
  export PATH="$AGENT_CLI_ROOT/bin:$EXTRA_TOOLS_HOME/bin:$PATH"
  # 无需系统账户、PAM 或特权切换；SSH 登录后仍使用当前 UID/GID。
  SSHD_CONFIG="$SSH_CONFIG_DIR/sshd_config"
  cat > "$SSHD_CONFIG" <<CONFIG
Port $SSH_LISTEN_PORT
HostKey "$SSH_CONFIG_DIR/ssh_host_ed25519_key"
HostKey "$SSH_CONFIG_DIR/ssh_host_rsa_key"
PidFile "$SSH_CONFIG_DIR/sshd.pid"
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers $USER_NAME
Subsystem sftp internal-sftp
CONFIG
  printf 'SetEnv' >> "$SSHD_CONFIG"
  for variable in PATH AGENT_CLI_ROOT EXTRA_TOOLS_HOME GOPATH GOTOOLCHAIN PYTHONPATH PYTHONDONTWRITEBYTECODE PIP_DISABLE_PIP_VERSION_CHECK PIP_NO_CACHE_DIR LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP; do
    [[ -v "$variable" ]] || continue
    value="${!variable}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf ' "%s=%s"' "$variable" "$value" >> "$SSHD_CONFIG"
  done
  printf '\n' >> "$SSHD_CONFIG"
  /usr/sbin/sshd -t -f "$SSHD_CONFIG"
  common_run_updates &
  exec "$@" -f "$SSHD_CONFIG"
fi

# 系统账户准备期间使用真实用户表，避免 NSS 快照影响 useradd/runuser。
nss_preload="${LD_PRELOAD:-}"
nss_passwd="${NSS_WRAPPER_PASSWD:-}"
nss_group="${NSS_WRAPPER_GROUP:-}"
unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP

# 验证参数
case "$PASSWORD_ACCESS" in
  true | false) ;;
  *)
    echo "[error] PASSWORD_ACCESS must be true or false"
    exit 1
    ;;
esac

case "$SUDO_ACCESS" in
  true | false) ;;
  *)
    echo "[error] SUDO_ACCESS must be true or false"
    exit 1
    ;;
esac

# 设置时区
if [ -e "/usr/share/zoneinfo/$TZ" ]; then
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
  printf '%s\n' "$TZ" >/etc/timezone
else
  echo "[warn] Invalid timezone: $TZ"
fi

# 创建文件夹
mkdir -p \
  /run/sshd \
  "$SSH_CONFIG_DIR" \
  "$SSHD_CONFIG_DIR"

# 默认 SSH 登录账户固定为 666:666；Compose 指定的非 root 用户走上面的分支。
if ! id "$USER_NAME" >/dev/null 2>&1; then
  if ! getent group 666 >/dev/null 2>&1; then
    groupadd --gid 666 "$USER_NAME"
  fi
  useradd --create-home --uid 666 --gid 666 --shell /bin/bash "$USER_NAME"
  echo "[init] Created user: $USER_NAME"
fi

USER_UID="$(id -u "$USER_NAME")"
USER_GID="$(id -g "$USER_NAME")"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
EXTRA_TOOLS_HOME="${EXTRA_TOOLS_HOME:-${CONTAINER_TOOLS_HOME:-$HOME_DIR/.local/share/extra-tools}}"
export EXTRA_TOOLS_HOME
export PATH="$AGENT_CLI_ROOT/bin:$EXTRA_TOOLS_HOME/bin:$PATH"

# 设置目录归属
chown "$USER_UID:$USER_GID" "$HOME_DIR" /go /pythonlib /workspace

# 设置用户密码
if [ -n "$USER_PASSWORD" ]; then
  printf '%s:%s\n' "$USER_NAME" "$USER_PASSWORD" | chpasswd
fi

if [ "$PASSWORD_ACCESS" = "true" ]; then
  PASSWORD_AUTH="yes"

  if [ -z "$USER_PASSWORD" ]; then
    echo "[warn] PASSWORD_ACCESS=true but USER_PASSWORD is empty"
  fi
else
  PASSWORD_AUTH="no"
fi

# 配置 SSH 公钥
mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

if [ -n "$PUBLIC_KEY" ]; then
  printf '%s\n' "$PUBLIC_KEY" >"$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"

  echo "[init] SSH public key configured"
fi

chown -R "$USER_UID:$USER_GID" "$HOME_DIR/.ssh"

# 配置 sudo
SUDOERS_FILE="/etc/sudoers.d/$USER_NAME"

if [ "$SUDO_ACCESS" = "true" ]; then
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" >"$SUDOERS_FILE"

  chmod 440 "$SUDOERS_FILE"
  visudo -cf "$SUDOERS_FILE" >/dev/null

  echo "[init] sudo enabled"
else
  rm -f "$SUDOERS_FILE"
fi

# 持久化 SSH 主机密钥，避免重建容器后更换服务器身份
for TYPE in ed25519 rsa; do
  KEY="$SSH_CONFIG_DIR/ssh_host_${TYPE}_key"

  if [ ! -f "$KEY" ]; then
    echo "[init] Generating SSH $TYPE host key"

    ssh-keygen \
      -q \
      -N "" \
      -t "$TYPE" \
      -f "$KEY"
  fi

  ln -sf "$KEY" "/etc/ssh/ssh_host_${TYPE}_key"
  ln -sf "$KEY.pub" "/etc/ssh/ssh_host_${TYPE}_key.pub"
done

# SSH 服务器配置
cat >"$SSHD_CONFIG" <<EOF
Port ${SSH_LISTEN_PORT:-22}

PermitRootLogin no
PermitEmptyPasswords no
PasswordAuthentication ${PASSWORD_AUTH}

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

AllowUsers ${USER_NAME}

SetEnv PATH=${PATH} AGENT_CLI_ROOT=${AGENT_CLI_ROOT}
SetEnv GOPATH=/go GOTOOLCHAIN=local
SetEnv PYTHONPATH=/pythonlib PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
EOF

chmod 644 "$SSHD_CONFIG"

# 验证 SSH 配置
/usr/sbin/sshd -t

# 输出启动配置
echo "[init] User: $USER_NAME"
echo "[init] UID:GID: $USER_UID:$USER_GID"
echo "[init] Timezone: $TZ"
echo "[init] SSH port: ${SSH_LISTEN_PORT:-22}"
echo "[init] Password authentication: $PASSWORD_AUTH"
echo "[init] sudo: $SUDO_ACCESS"

# 以 SSH 用户身份复用已有 CLI 管理入口，后台安装更新不阻塞 SSH
case "${AGENT_CLIS-codex,claude,opencode}" in
  '' | none) ;;
  *)
    install -d -o "$USER_UID" -g "$USER_GID" \
      "$AGENT_CLI_ROOT" "$AGENT_CLI_ROOT/bin" "$AGENT_CLI_ROOT/releases"
    ;;
esac

runuser -u "$USER_NAME" -- bash -ec '
  source /usr/local/lib/container-common/init.sh
  common_run_updates
' &

export LD_PRELOAD="$nss_preload" NSS_WRAPPER_PASSWD="$nss_passwd" NSS_WRAPPER_GROUP="$nss_group"
common_prepare_user
if [[ "$1" == /usr/sbin/sshd ]]; then
  exec env -u LD_PRELOAD -u NSS_WRAPPER_PASSWD -u NSS_WRAPPER_GROUP "$@"
fi
exec "$@"
