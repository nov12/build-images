#!/usr/bin/env bash

# 按实际 UID/GID 提供用户记录，不修改系统用户表或挂载目录。
common_prepare_user() {
  [[ "${COMMON_USER_INITIALIZED_PID:-}" == "$BASHPID" ]] && return 0
  local passwd="${NSS_WRAPPER_PASSWD:-}" group="${NSS_WRAPPER_GROUP:-}"
  [[ -n "$passwd" && -n "$group" ]] || return 0

  local uid gid directory record username password description shell groups temp_dir
  local requested_name="${1:-}" requested_record
  local preload="${LD_PRELOAD:-}"
  [[ "$preload" == *libnss_wrapper.so* ]] || preload="libnss_wrapper.so${preload:+:$preload}"
  uid="$(id -u)" && gid="$(id -g)" || return
  directory="${passwd%/*}"
  if [[ "${HOME:-}" != /* || "$HOME" == *:* || "$HOME" == *$'\n'* ]]; then
    echo '[container-user] HOME must be an absolute path without colons or newlines' >&2
    return 1
  fi

  # 用户记录供同一用户的 docker exec 复用，只允许当前用户访问。
  if [[ -L "$directory" ]] || ! (umask 077; mkdir -p -- "$directory") || ! chmod 700 -- "$directory"; then
    echo "[container-user] Cannot prepare private directory: $directory" >&2
    return 1
  fi

  record=''
  if [[ -f "$passwd" ]]; then record="$(LD_PRELOAD="$preload" getent passwd "$uid" || true)"; fi
  if [[ -z "$record" ]]; then record="$(env -u LD_PRELOAD getent -s files passwd "$uid" || true)"; fi
  if [[ -n "$record" ]]; then
    IFS=: read -r username password _ _ description _ shell <<< "$record"
  else
    username="container-$uid"
    while env -u LD_PRELOAD getent -s files passwd "$username" >/dev/null; do username+='_'; done
    password=x description='Container user' shell=/bin/bash
  fi

  # SSH 服务需要固定登录名，避免和其他系统账户重名。
  if [[ -n "$requested_name" ]]; then
    if [[ ! "$requested_name" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
      echo '[container-user] Invalid login name' >&2
      return 1
    fi
    requested_record="$(env -u LD_PRELOAD getent -s files passwd "$requested_name" || true)"
    if [[ -n "$requested_record" && "$(cut -d: -f3 <<< "$requested_record")" != "$uid" ]]; then
      echo "[container-user] Login name $requested_name belongs to another UID" >&2
      return 1
    fi
    username="$requested_name" password=x shell=/bin/bash
  fi

  groups="$(id -G)" || return
  temp_dir="$(umask 077; mktemp -d "$directory/.setup.XXXXXXXX")" || return
  # 保留系统账户及组，为当前 UID、主组和附加组补齐记录。
  if ! (
    umask 077
    awk -F: -v uid="$uid" '$3 != uid' /etc/passwd > "$temp_dir/passwd" &&
    printf '%s:%s:%s:%s:%s:%s:%s\n' "$username" "$password" "$uid" "$gid" "$description" "$HOME" "$shell" >> "$temp_dir/passwd" &&
    awk -F: -v OFS=: -v groups="$groups" -v username="$username" '
      BEGIN { count = split(groups, ids, " "); for (i = 1; i <= count; i++) pending[ids[i]] = 1 }
      {
        names[$1] = 1
        if ($3 in pending) {
          if (!index("," $4 ",", "," username ",")) $4 = $4 ? $4 "," username : username
          delete pending[$3]
        }
        print
      }
      END {
        for (id in pending) {
          name = "container-" id
          while (name in names) name = name "_"
          print name, "x", id, username
          names[name] = 1
        }
      }
    ' /etc/group > "$temp_dir/group" &&
    mv -fT -- "$temp_dir/passwd" "$passwd" && mv -fT -- "$temp_dir/group" "$group"
  ); then
    rm -rf -- "$temp_dir"
    return 1
  fi
  rmdir -- "$temp_dir" || return
  export LD_PRELOAD="$preload"
  if ! getent passwd "$uid" >/dev/null || ! getent group "$gid" >/dev/null; then
    echo "[container-user] Cannot resolve UID $uid or GID $gid; check libnss-wrapper" >&2
    return 1
  fi
  export USER="$username" LOGNAME="$username"
  COMMON_USER_INITIALIZED_PID="$BASHPID"
}
