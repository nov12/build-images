#!/bin/sh
set -eu

# 设置环境
USER_NAME="${USER_NAME:-apple}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

TZ="${TZ:-Asia/Singapore}"

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

# 验证参数
case "$PUID" in
  '' | *[!0-9]*)
    echo "[error] Invalid PUID: $PUID"
    exit 1
    ;;
esac

case "$PGID" in
  '' | *[!0-9]*)
    echo "[error] Invalid PGID: $PGID"
    exit 1
    ;;
esac

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

# 设置用户组
if ! getent group "$PGID" >/dev/null 2>&1; then
  groupadd \
    --gid "$PGID" \
    "$USER_NAME"

  echo "[init] Created group: $USER_NAME ($PGID)"
fi

# 设置用户
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd \
    --create-home \
    --uid "$PUID" \
    --gid "$PGID" \
    --shell /bin/bash \
    "$USER_NAME"

  echo "[init] Created user: $USER_NAME ($PUID:$PGID)"
fi

HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"

# 设置目录归属
chown "$PUID:$PGID" "$HOME_DIR" /go /pythonlib /workspace

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

chown -R "$PUID:$PGID" "$HOME_DIR/.ssh"

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
Port 22

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
echo "[init] UID:GID: $PUID:$PGID"
echo "[init] Timezone: $TZ"
echo "[init] SSH port: 22"
echo "[init] Password authentication: $PASSWORD_AUTH"
echo "[init] sudo: $SUDO_ACCESS"

# 以 SSH 用户身份复用已有 CLI 管理入口，后台安装更新不阻塞 SSH
case "${AGENT_CLIS-codex,claude,opencode}" in
  '' | none) ;;
  *)
    install -d -o "$PUID" -g "$PGID" \
      "$AGENT_CLI_ROOT" "$AGENT_CLI_ROOT/bin" "$AGENT_CLI_ROOT/releases"
    runuser -u "$USER_NAME" -- /usr/local/bin/agent-cli sleep infinity &
    ;;
esac

exec "$@"
