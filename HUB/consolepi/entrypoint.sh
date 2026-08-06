#!/usr/bin/env bash
set -euo pipefail

CONSOLEPI_HOME="/etc/ConsolePi"
RUNTIME_DIR="/data/runtime"
TRUSTED_SSH_INTERFACE="${TRUSTED_SSH_INTERFACE:-wg0}"
UNTRUSTED_SSH_INTERFACE="${UNTRUSTED_SSH_INTERFACE:-}"
MGMT_SSH_ALLOW_CIDRS="${MGMT_SSH_ALLOW_CIDRS:-}"
CONSOLEPI_SSH_PASSWORD_AUTH="${CONSOLEPI_SSH_PASSWORD_AUTH:-false}"
CONSOLEPI_ALLOW_USERS="${CONSOLEPI_ALLOW_USERS:-consolepi}"
CONSOLEPI_USERS_FILE="${CONSOLEPI_USERS_FILE:-/data/ssh/users.conf}"
CONSOLEPI_GRANT_SUDO="${CONSOLEPI_GRANT_SUDO:-true}"
CONSOLEPI_MENU_USERS=""
CONSOLEPI_MENU_EXIT_ACTION="${CONSOLEPI_MENU_EXIT_ACTION:-logout}"
CONSOLEPI_MENU_NOPASSWD_SUDO="${CONSOLEPI_MENU_NOPASSWD_SUDO:-true}"

# Accept comma-separated env input to avoid shell parsing issues in .env files.
CONSOLEPI_ALLOW_USERS="${CONSOLEPI_ALLOW_USERS//,/ }"

add_allow_user() {
  local user="$1"
  case " ${CONSOLEPI_ALLOW_USERS} " in
    *" ${user} "*)
      ;;
    *)
      CONSOLEPI_ALLOW_USERS="${CONSOLEPI_ALLOW_USERS} ${user}"
      ;;
  esac
}

add_menu_user() {
  local user="$1"
  case " ${CONSOLEPI_MENU_USERS} " in
    *" ${user} "*)
      ;;
    *)
      CONSOLEPI_MENU_USERS="${CONSOLEPI_MENU_USERS} ${user}"
      ;;
  esac
}

trim_spaces() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

provision_user_from_file() {
  local user="$1"
  local login_mode="$2"
  local password_hash="$3"

  [[ "${user}" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
    echo "Skipping invalid username in ${CONSOLEPI_USERS_FILE}: ${user}" >&2
    return 0
  }

  [[ -n "${password_hash}" ]] || {
    echo "Skipping ${user}: empty password hash in ${CONSOLEPI_USERS_FILE}" >&2
    return 0
  }

  if id "${user}" >/dev/null 2>&1; then
    usermod -p "${password_hash}" "${user}"
  else
    useradd -m -s /bin/bash -p "${password_hash}" "${user}"
  fi

  install -d -m 700 -o "${user}" -g "${user}" "/home/${user}/.ssh"

  if [[ "${CONSOLEPI_GRANT_SUDO}" == "true" ]]; then
    usermod -aG sudo "${user}" || true
  fi

  add_allow_user "${user}"

  if [[ "${login_mode}" == "menu" ]]; then
    add_menu_user "${user}"
  fi
}

mkdir -p "${RUNTIME_DIR}" /data/ssh

# Seed runtime config from example only if one does not exist yet.
if [[ ! -f "${RUNTIME_DIR}/ConsolePi.yaml" ]]; then
  cp /etc/ConsolePi.yaml "${RUNTIME_DIR}/ConsolePi.yaml"
fi

# Make config available where ConsolePi expects it.
ln -sf "${RUNTIME_DIR}/ConsolePi.yaml" "${CONSOLEPI_HOME}/ConsolePi.yaml"

# Optional shared SSH material for hub->spoke auth.
if [[ -d /data/ssh ]]; then
  mkdir -p /root/.ssh
  cp -n /data/ssh/* /root/.ssh/ 2>/dev/null || true
  chmod 700 /root/.ssh || true
  chmod 600 /root/.ssh/* 2>/dev/null || true

  # Optional inbound SSH key for connecting to this hub container.
  if [[ -f /data/ssh/authorized_keys ]]; then
    install -d -m 700 -o consolepi -g consolepi /home/consolepi/.ssh
    install -m 600 -o consolepi -g consolepi /data/ssh/authorized_keys /home/consolepi/.ssh/authorized_keys
  fi
fi

if [[ -f "${CONSOLEPI_USERS_FILE}" ]]; then
  while IFS=':' read -r raw_user raw_mode raw_hash; do
    raw_user="$(trim_spaces "${raw_user}")"
    raw_mode="$(trim_spaces "${raw_mode}")"
    raw_hash="$(trim_spaces "${raw_hash}")"

    [[ -n "${raw_user}" ]] || continue
    [[ "${raw_user}" == \#* ]] && continue

    # Backward compatible format: username:password_hash
    if [[ -z "${raw_hash}" ]]; then
      raw_hash="${raw_mode}"
      raw_mode="shell"
    fi

    case "${raw_mode}" in
      menu|shell)
        ;;
      *)
        echo "Skipping ${raw_user}: invalid login mode '${raw_mode}' in ${CONSOLEPI_USERS_FILE} (use menu or shell)" >&2
        continue
        ;;
    esac

    provision_user_from_file "${raw_user}" "${raw_mode}" "${raw_hash}"
  done < "${CONSOLEPI_USERS_FILE}"
fi

CONSOLEPI_ALLOW_USERS="$(trim_spaces "${CONSOLEPI_ALLOW_USERS}")"

if [[ "${CONSOLEPI_GRANT_SUDO}" == "true" ]]; then
  for user in ${CONSOLEPI_ALLOW_USERS}; do
    if id "${user}" >/dev/null 2>&1; then
      usermod -aG sudo "${user}" || true
    fi
  done
fi

# Harden SSH daemon for key-only access to the consolepi user.
if [[ -f /etc/ssh/sshd_config ]]; then
  if [[ "${CONSOLEPI_SSH_PASSWORD_AUTH}" == "true" ]]; then
    grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
  else
    grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
  fi
  grep -q '^PermitRootLogin no' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
  grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
  grep -q '^KbdInteractiveAuthentication no' /etc/ssh/sshd_config || echo 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config
  sed -i '/^AllowUsers /d' /etc/ssh/sshd_config
  if [[ -n "${CONSOLEPI_ALLOW_USERS}" ]]; then
    echo "AllowUsers ${CONSOLEPI_ALLOW_USERS}" >> /etc/ssh/sshd_config
  fi
fi

mkdir -p /var/run/sshd

# Restrict SSH access by WireGuard profile interface.
# Trusted profile interface is allowed; untrusted profile interface is denied.
if command -v iptables >/dev/null 2>&1; then
  if iptables -L >/dev/null 2>&1; then
    iptables -N CP_SSH_GUARD 2>/dev/null || true
    iptables -F CP_SSH_GUARD

    # Optional external management CIDR allow-list for dedicated SSH port mapping.
    if [[ -n "${MGMT_SSH_ALLOW_CIDRS}" ]]; then
      IFS=',' read -r -a mgmt_cidrs <<< "${MGMT_SSH_ALLOW_CIDRS}"
      for cidr in "${mgmt_cidrs[@]}"; do
        cidr="${cidr//[[:space:]]/}"
        [[ -n "${cidr}" ]] || continue
        iptables -A CP_SSH_GUARD -s "${cidr}" -j ACCEPT
      done
    fi

    iptables -A CP_SSH_GUARD -i "${TRUSTED_SSH_INTERFACE}" -j ACCEPT

    if [[ -n "${UNTRUSTED_SSH_INTERFACE}" ]]; then
      iptables -A CP_SSH_GUARD -i "${UNTRUSTED_SSH_INTERFACE}" -j DROP
    fi

    iptables -A CP_SSH_GUARD -j DROP

    if ! iptables -C INPUT -p tcp --dport 22 -j CP_SSH_GUARD 2>/dev/null; then
      iptables -I INPUT 1 -p tcp --dport 22 -j CP_SSH_GUARD
    fi
  else
    echo "WARNING: iptables is present but not permitted in this container; profile-based SSH restrictions were not applied" >&2
  fi
else
  echo "WARNING: iptables not found; profile-based SSH restrictions were not applied" >&2
fi

# Load consolepi command helpers into shell sessions.
if [[ -f /etc/profile.d/consolepi.sh ]]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/consolepi.sh
fi

CONSOLEPI_MENU_USERS="$(trim_spaces "${CONSOLEPI_MENU_USERS}")"

if [[ "${CONSOLEPI_MENU_NOPASSWD_SUDO}" == "true" ]]; then
  if [[ -n "${CONSOLEPI_MENU_USERS}" ]]; then
    {
      echo '# Managed by ConsolePi entrypoint'
      for user in ${CONSOLEPI_MENU_USERS}; do
        echo "${user} ALL=(ALL) NOPASSWD:ALL"
      done
    } > /etc/sudoers.d/consolepi-menu-users
    chmod 440 /etc/sudoers.d/consolepi-menu-users
  else
    rm -f /etc/sudoers.d/consolepi-menu-users
  fi
else
  rm -f /etc/sudoers.d/consolepi-menu-users
fi

cat > /usr/local/bin/consolepi-menu-login.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export CONSOLEPI_MENU_LAUNCHED=1

# ForceCommand sessions do not always inherit interactive shell PATH/profile.
if [[ -f /etc/profile.d/consolepi.sh ]]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/consolepi.sh
fi

if command -v consolepi-menu >/dev/null 2>&1; then
  consolepi-menu || true
elif [[ -x /etc/ConsolePi/src/consolepi-menu.sh ]]; then
  /etc/ConsolePi/src/consolepi-menu.sh || true
else
  echo "consolepi-menu command not found" >&2
fi

case "${CONSOLEPI_MENU_EXIT_ACTION:-logout}" in
  shell)
    # Optional fallback behavior for troubleshooting.
    export CONSOLEPI_NO_AUTO_MENU=1
    exec /bin/bash -l
    ;;
  logout|exit|disconnect)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 755 /usr/local/bin/consolepi-menu-login.sh

# Build sshd match rules for users set to "menu" mode.
if [[ -f /etc/ssh/sshd_config ]]; then
  sed -i '/^# BEGIN CONSOLEPI_FORCE_MENU$/,/^# END CONSOLEPI_FORCE_MENU$/d' /etc/ssh/sshd_config
  if [[ -n "${CONSOLEPI_MENU_USERS}" ]]; then
    {
      echo '# BEGIN CONSOLEPI_FORCE_MENU'
      for user in ${CONSOLEPI_MENU_USERS}; do
        echo "Match User ${user}"
        echo '  ForceCommand /usr/local/bin/consolepi-menu-login.sh'
      done
      echo '# END CONSOLEPI_FORCE_MENU'
    } >> /etc/ssh/sshd_config
  fi
fi

if [[ -n "${CONSOLEPI_MENU_USERS}" ]]; then
  cat > /etc/profile.d/consolepi-auto-menu.sh <<EOF
#!/usr/bin/env bash

case "\$-" in
  *i*)
    ;;
  *)
    return 0
    ;;
esac

[[ -n "\${SSH_TTY:-}" ]] || return 0
[[ -z "\${SSH_ORIGINAL_COMMAND:-}" ]] || return 0
[[ -z "\${CONSOLEPI_NO_AUTO_MENU:-}" ]] || return 0
[[ -z "\${CONSOLEPI_MENU_LAUNCHED:-}" ]] || return 0

case " ${CONSOLEPI_MENU_USERS} " in
  *" \${USER:-} "*)
    export CONSOLEPI_MENU_LAUNCHED=1
    if command -v consolepi-menu >/dev/null 2>&1; then
      consolepi-menu
    fi
    ;;
esac
EOF
  chmod 755 /etc/profile.d/consolepi-auto-menu.sh
else
  rm -f /etc/profile.d/consolepi-auto-menu.sh
fi

exec "$@"
