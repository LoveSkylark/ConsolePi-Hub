#!/usr/bin/env bash
set -euo pipefail

CONSOLEPI_HOME="/etc/ConsolePi"
RUNTIME_DIR="/data/runtime"
TRUSTED_SSH_INTERFACE="${TRUSTED_SSH_INTERFACE:-wg0}"
UNTRUSTED_SSH_INTERFACE="${UNTRUSTED_SSH_INTERFACE:-}"
MGMT_SSH_ALLOW_CIDRS="${MGMT_SSH_ALLOW_CIDRS:-}"

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

# Harden SSH daemon for key-only access to the consolepi user.
if [[ -f /etc/ssh/sshd_config ]]; then
  grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
  grep -q '^PermitRootLogin no' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
  grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
  grep -q '^AllowUsers consolepi' /etc/ssh/sshd_config || echo 'AllowUsers consolepi' >> /etc/ssh/sshd_config
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

exec "$@"
