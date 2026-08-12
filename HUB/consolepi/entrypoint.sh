#!/usr/bin/env bash
set -euo pipefail

CONSOLEPI_HOME="/etc/ConsolePi"
RUNTIME_DIR="/consolepi/runtime"
SSH_DIR="/ssh"
TRUSTED_SSH_INTERFACE="${TRUSTED_SSH_INTERFACE:-wg0}"
UNTRUSTED_SSH_INTERFACE="${UNTRUSTED_SSH_INTERFACE:-}"
MGMT_ALLOWED_DIRECT_SSH="${MGMT_ALLOWED_DIRECT_SSH:-${ALLOW_DIRECT_SSH_CIDRS:-${MGMT_SSH_ALLOW_CIDRS:-}}}"
CONSOLEPI_SSH_PASSWORD_AUTH="${CONSOLEPI_SSH_PASSWORD_AUTH:-false}"
CONSOLEPI_USERS_FILE="${CONSOLEPI_USERS_FILE:-/ssh/users.conf}"
CONSOLEPI_GRANT_SUDO="${CONSOLEPI_GRANT_SUDO:-true}"
ALLOWED_SSH_USERS="consolepi"
CONSOLEPI_MENU_USERS=""
CONSOLEPI_MENU_EXIT_ACTION="${CONSOLEPI_MENU_EXIT_ACTION:-logout}"
CONSOLEPI_MENU_NOPASSWD_SUDO="${CONSOLEPI_MENU_NOPASSWD_SUDO:-true}"

add_ssh_user() {
  local user="$1"
  case " ${ALLOWED_SSH_USERS} " in
    *" ${user} "*)
      ;;
    *)
      ALLOWED_SSH_USERS="${ALLOWED_SSH_USERS} ${user}"
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

apply_consolepi_rshell_empty_fix() {
  local menu_py="${CONSOLEPI_HOME}/src/pypkg/consolepi/menu.py"

  [[ -f "${menu_py}" ]] || return 0

  python3 - "${menu_py}" <<'PY'
import pathlib
import re
import sys

menu_path = pathlib.Path(sys.argv[1])
src = menu_path.read_text()

pattern = re.compile(
  r"^(?P<indent>[ \t]*)item = min\(\[item for sublist in items for item in sublist\]\)$",
  re.M,
)
replacement = (
  r"\g<indent>flat_items = [item for sublist in items for item in sublist]\n"
  r"\g<indent>if not flat_items:\n"
  r"\g<indent>    return menu_actions\n"
  r"\g<indent>item = min(flat_items)"
)

if "flat_items = [item for sublist in items for item in sublist]" in src:
    sys.exit(0)

if not pattern.search(src):
    sys.exit(0)

menu_path.write_text(pattern.sub(replacement, src, count=1))
PY
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

  add_ssh_user "${user}"

  if [[ "${login_mode}" == "menu" ]]; then
    add_menu_user "${user}"
  fi
}

mkdir -p "${RUNTIME_DIR}" "${SSH_DIR}"

# ConsolePi python menu expects this log path to exist and be writable.
install -d -m 0777 /var/log/ConsolePi
touch /var/log/ConsolePi/consolepi.log
chmod 0666 /var/log/ConsolePi/consolepi.log

# Workaround for upstream ConsolePi bug when Remote Shell menu has no entries.
apply_consolepi_rshell_empty_fix

# Seed runtime config from example only if one does not exist yet.
if [[ ! -f "${RUNTIME_DIR}/ConsolePi.yaml" ]]; then
  cp /etc/ConsolePi.yaml "${RUNTIME_DIR}/ConsolePi.yaml"
fi

# Seed persistent remote cache store for static/discovered remotes.
if [[ ! -f "${RUNTIME_DIR}/cloud.json" ]]; then
  printf '{}\n' > "${RUNTIME_DIR}/cloud.json"
fi

# Make config available where ConsolePi expects it.
ln -sf "${RUNTIME_DIR}/ConsolePi.yaml" "${CONSOLEPI_HOME}/ConsolePi.yaml"
ln -sf "${RUNTIME_DIR}/cloud.json" "${CONSOLEPI_HOME}/cloud.json"

# Optional shared SSH material for hub->spoke auth.
if [[ -d "${SSH_DIR}" ]]; then
  mkdir -p /root/.ssh
  cp -n "${SSH_DIR}"/* /root/.ssh/ 2>/dev/null || true
  chmod 700 /root/.ssh || true
  chmod 600 /root/.ssh/* 2>/dev/null || true

  # Optional inbound SSH key for connecting to this hub container.
  if [[ -f "${SSH_DIR}/authorized_keys" ]]; then
    install -d -m 700 -o consolepi -g consolepi /home/consolepi/.ssh
    install -m 600 -o consolepi -g consolepi "${SSH_DIR}/authorized_keys" /home/consolepi/.ssh/authorized_keys
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

ALLOWED_SSH_USERS="$(trim_spaces "${ALLOWED_SSH_USERS}")"

if [[ "${CONSOLEPI_GRANT_SUDO}" == "true" ]]; then
  for user in ${ALLOWED_SSH_USERS}; do
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
  if [[ -n "${ALLOWED_SSH_USERS}" ]]; then
    echo "AllowUsers ${ALLOWED_SSH_USERS}" >> /etc/ssh/sshd_config
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
    if [[ -n "${MGMT_ALLOWED_DIRECT_SSH}" ]]; then
      IFS=',' read -r -a mgmt_cidrs <<< "${MGMT_ALLOWED_DIRECT_SSH}"
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
export BYOBU_TTY="${BYOBU_TTY:-}"
if [[ -f /etc/profile.d/consolepi.sh ]]; then
  set +u
  # shellcheck disable=SC1091
  source /etc/profile.d/consolepi.sh
  set -u
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
