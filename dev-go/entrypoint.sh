#!/bin/sh
set -eu

# -----------------------------------------------------------------------------
# 设置环境
# -----------------------------------------------------------------------------

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


# -----------------------------------------------------------------------------
# 验证参数
# -----------------------------------------------------------------------------

case "$PUID" in
    ''|*[!0-9]*)
        echo "[error] Invalid PUID: $PUID"
        exit 1
        ;;
esac

case "$PGID" in
    ''|*[!0-9]*)
        echo "[error] Invalid PGID: $PGID"
        exit 1
        ;;
esac

case "$PASSWORD_ACCESS" in
    true|false) ;;
    *)
        echo "[error] PASSWORD_ACCESS must be true or false"
        exit 1
        ;;
esac

case "$SUDO_ACCESS" in
    true|false) ;;
    *)
        echo "[error] SUDO_ACCESS must be true or false"
        exit 1
        ;;
esac


# -----------------------------------------------------------------------------
# 设置时区
# -----------------------------------------------------------------------------

if [ -e "/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    printf '%s\n' "$TZ" > /etc/timezone
else
    echo "[warn] Invalid timezone: $TZ"
fi


# -----------------------------------------------------------------------------
# 创建文件夹
# -----------------------------------------------------------------------------

mkdir -p \
    /run/sshd \
    "$SSH_CONFIG_DIR" \
    "$SSHD_CONFIG_DIR"


# -----------------------------------------------------------------------------
# 设置用户组
# -----------------------------------------------------------------------------

if ! getent group "$PGID" >/dev/null 2>&1; then
    groupadd \
        --gid "$PGID" \
        "$USER_NAME"

    echo "[init] Created group: $USER_NAME ($PGID)"
fi


# -----------------------------------------------------------------------------
# 设置用户
# -----------------------------------------------------------------------------

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


# -----------------------------------------------------------------------------
# 设置目录归属
# -----------------------------------------------------------------------------
chown "$PUID:$PGID" /go


# -----------------------------------------------------------------------------
# 设置用户密码
# -----------------------------------------------------------------------------

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


# -----------------------------------------------------------------------------
# SSH authorized_keys 密钥设置
# -----------------------------------------------------------------------------

mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

if [ -n "$PUBLIC_KEY" ]; then
    printf '%s\n' "$PUBLIC_KEY" > "$HOME_DIR/.ssh/authorized_keys"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"

    echo "[init] SSH public key configured"
fi

chown -R "$PUID:$PGID" "$HOME_DIR/.ssh"


# -----------------------------------------------------------------------------
# sudo 设置
# -----------------------------------------------------------------------------

SUDOERS_FILE="/etc/sudoers.d/$USER_NAME"

if [ "$SUDO_ACCESS" = "true" ]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" > "$SUDOERS_FILE"

    chmod 440 "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE" >/dev/null

    echo "[init] sudo enabled"
else
    rm -f "$SUDOERS_FILE"
fi


# -----------------------------------------------------------------------------
# SSH host keys
#
# 设置 CONFIG_DIR 变量默认为 /config 并通过挂载，
# 可以让 ssh 私钥不必重复设置。
# -----------------------------------------------------------------------------

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


# -----------------------------------------------------------------------------
# SSH 服务器配置
# -----------------------------------------------------------------------------

cat > "$SSHD_CONFIG" <<EOF
Port 22

PermitRootLogin no
PermitEmptyPasswords no
PasswordAuthentication ${PASSWORD_AUTH}

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

AllowUsers ${USER_NAME}
EOF

chmod 644 "$SSHD_CONFIG"


# -----------------------------------------------------------------------------
# 验证
# -----------------------------------------------------------------------------

/usr/sbin/sshd -t


# -----------------------------------------------------------------------------
# 总结
# -----------------------------------------------------------------------------

echo "[init] User: $USER_NAME"
echo "[init] UID:GID: $PUID:$PGID"
echo "[init] Timezone: $TZ"
echo "[init] SSH port: 22"
echo "[init] Password authentication: $PASSWORD_AUTH"
echo "[init] sudo: $SUDO_ACCESS"


# -----------------------------------------------------------------------------
# 启动
# -----------------------------------------------------------------------------

exec "$@"
