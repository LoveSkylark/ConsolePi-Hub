#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
RENDER_SCRIPT="${SCRIPT_DIR}/render-spoke-config.sh"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPO_URL="${CONSOLEPI_HUB_REPO_URL:-https://github.com/LoveSkylark/ConsolePi-Hub}"
REPO_REF="${CONSOLEPI_HUB_REPO_REF:-main}"
RAW_BASE="${REPO_URL/github.com/raw.githubusercontent.com}/${REPO_REF}"
NEW_KEY_REQUESTED="false"
CONSOLEPI_PRESEED_DIR="${SCRIPT_DIR}/consolepi-stage"
CONSOLEPI_PRESEED_FILE="${CONSOLEPI_PRESEED_DIR}/install.conf"
CONSOLEPI_PASSWORD=""

usage() {
  cat <<EOF
Usage: ./install-spoke.sh [options]

Options:
  --new-key  Generate a new spoke private key after warning prompt
  --help     Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --new-key)
      NEW_KEY_REQUESTED="true"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Run as root or install sudo." >&2
    exit 1
  fi
fi

prompt_default() {
  local label="$1"
  local default_value="$2"
  local reply

  read -r -p "${label} [${default_value}]: " reply
  if [[ -z "${reply}" ]]; then
    printf '%s' "${default_value}"
  else
    printf '%s' "${reply}"
  fi
}

download_repo_file() {
  local repo_path="$1"
  local target_path="$2"
  local url="${RAW_BASE}/${repo_path}"

  mkdir -p "$(dirname "${target_path}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${target_path}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "${url}" -O "${target_path}"
  else
    echo "Need curl or wget to pull missing files from ${REPO_URL}." >&2
    return 1
  fi
}

ensure_repo_asset() {
  local local_path="$1"
  local repo_path="$2"

  if [[ ! -f "${local_path}" ]]; then
    echo "Missing ${local_path}; pulling ${repo_path} from ${REPO_URL}@${REPO_REF}"
    download_repo_file "${repo_path}" "${local_path}"
  fi
}

prompt_required() {
  local label="$1"
  local default_value="${2:-}"
  local reply

  while true; do
    if [[ -n "${default_value}" ]]; then
      read -r -p "${label} [${default_value}]: " reply
      reply="${reply:-${default_value}}"
    else
      read -r -p "${label}: " reply
    fi

    if [[ -n "${reply}" ]]; then
      printf '%s' "${reply}"
      return 0
    fi

    echo "A value is required."
  done
}

prompt_yes_no() {
  local label="$1"
  local default_value="$2"
  local reply

  while true; do
    read -r -p "${label} [${default_value}]: " reply
    reply="${reply:-${default_value}}"
    case "${reply}" in
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      *)
        echo "Answer y or n."
        ;;
    esac
  done
}

validate_ipv4() {
  local ip="$1"
  local octet

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "${ip}"
  for octet in "${octets[@]}"; do
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

validate_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

prompt_ipv4() {
  local label="$1"
  local default_value="$2"
  local reply

  while true; do
    reply="$(prompt_required "${label}" "${default_value}")"
    if validate_ipv4 "${reply}"; then
      printf '%s' "${reply}"
      return 0
    fi
    echo "Enter a valid IPv4 address."
  done
}

prompt_port() {
  local label="$1"
  local default_value="$2"
  local reply

  while true; do
    reply="$(prompt_required "${label}" "${default_value}")"
    if validate_port "${reply}"; then
      printf '%s' "${reply}"
      return 0
    fi
    echo "Enter a valid port number."
  done
}

install_consolepi() {
  local installer="/tmp/ConsolePi-install-${TIMESTAMP}.sh"
  local system_timezone
  local system_hostname

  system_timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  system_timezone="${system_timezone:-UTC}"
  system_hostname="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo consolepi)"

  mkdir -p "${CONSOLEPI_PRESEED_DIR}"
  cat > "${CONSOLEPI_PRESEED_FILE}" <<EOF
hostname=${system_hostname}
tz=${system_timezone}
wlan_country=US
locale=us
auto_launch=true
no_users=true
no_ipv6=true
do_blue=false
doapt=true
dopip=true
EOF
printf 'consolepi_pass=%q\n' "${CONSOLEPI_PASSWORD}" >> "${CONSOLEPI_PRESEED_FILE}"

  if command -v wget >/dev/null 2>&1; then
    wget -q https://raw.githubusercontent.com/Pack3tL0ss/ConsolePi/master/installer/install.sh -O "${installer}"
  else
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y curl
    curl -fsSL https://raw.githubusercontent.com/Pack3tL0ss/ConsolePi/master/installer/install.sh -o "${installer}"
  fi

  ${SUDO} bash "${installer}" -C "${CONSOLEPI_PRESEED_FILE}" --silent -p "${CONSOLEPI_PASSWORD}"
  rm -f "${installer}"
}

configure_consolepi_remote_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "Skipping ConsolePi service management: systemctl not available."
    return 0
  fi

  # API must be reachable by the HUB to populate remote adapters.
  if systemctl list-unit-files | grep -q '^consolepi-api\.service'; then
    ${SUDO} systemctl enable --now consolepi-api >/dev/null 2>&1 || true
  fi

  # API-only mode: disable mDNS advertise/browse services.
  ${SUDO} systemctl disable --now consolepi-mdnsreg consolepi-mdnsbrowse >/dev/null 2>&1 || true
}

echo "ConnectPi spoke installer"
echo

ensure_repo_asset "${RENDER_SCRIPT}" "SPOKE/render-spoke-config.sh"
chmod +x "${RENDER_SCRIPT}"
ensure_repo_asset "${SCRIPT_DIR}/.env.example" "SPOKE/.env.example"

while true; do
  SPOKE_PROFILE="$(prompt_required "Profile class (trusted/untrusted)" "untrusted")"
  case "${SPOKE_PROFILE}" in
    trusted|untrusted)
      break
      ;;
    *)
      echo "Profile must be trusted or untrusted."
      ;;
  esac
done

if [[ "${SPOKE_PROFILE}" == "trusted" ]]; then
  DEFAULT_PORT="51821"
  DEFAULT_HUB_IP="10.99.99.1"
  DEFAULT_SPOKE_IP="10.99.99.11"
else
  DEFAULT_PORT="51820"
  DEFAULT_HUB_IP="10.99.98.1"
  DEFAULT_SPOKE_IP="10.99.98.11"
fi

HUB_ENDPOINT="$(prompt_required "Hub endpoint hostname or public IP" "change-me.example.com")"
HUB_PORT="$(prompt_port "Hub WireGuard port" "${DEFAULT_PORT}")"
HUB_TUNNEL_IP="$(prompt_ipv4 "Hub tunnel IP" "${DEFAULT_HUB_IP}")"
SPOKE_TUNNEL_IP="$(prompt_ipv4 "This spoke tunnel IP" "${DEFAULT_SPOKE_IP}")"
HUB_PUBLIC_KEY="$(prompt_required "Hub public key")"
PERSISTENT_KEEPALIVE="$(prompt_port "Persistent keepalive seconds" "25")"

GENERATE_PRIVATE_KEY="false"
if [[ "${NEW_KEY_REQUESTED}" == "true" ]]; then
  echo "WARNING: --new-key will rotate the spoke private/public keypair."
  echo "You must update the HUB peer public key entry for this spoke or the tunnel will fail."
  if ! prompt_yes_no "Continue with new spoke key generation?" "n"; then
    echo "Spoke key rotation cancelled."
    exit 1
  fi
  GENERATE_PRIVATE_KEY="true"
  SPOKE_PRIVATE_KEY=""
else
  if prompt_yes_no "Generate a new WireGuard private key for this spoke?" "y"; then
    GENERATE_PRIVATE_KEY="true"
    SPOKE_PRIVATE_KEY=""
  else
    SPOKE_PRIVATE_KEY="$(prompt_required "Existing spoke private key")"
  fi
fi

INSTALL_CONSOLEPI="false"
if prompt_yes_no "Install ConsolePi on this box?" "y"; then
  INSTALL_CONSOLEPI="true"
  CONSOLEPI_PASSWORD="$(prompt_required "ConsolePi user password")"
fi

${SUDO} apt-get update
${SUDO} apt-get install -y wireguard

if [[ "${GENERATE_PRIVATE_KEY}" == "true" ]]; then
  SPOKE_PRIVATE_KEY="$(wg genkey)"
fi
SPOKE_PUBLIC_KEY="$(printf '%s' "${SPOKE_PRIVATE_KEY}" | wg pubkey)"

mkdir -p "${SCRIPT_DIR}/rendered"
SPOKE_PRIVATE_KEY_FILE="${SCRIPT_DIR}/rendered/spoke.privatekey"
SPOKE_PUBLIC_KEY_FILE="${SCRIPT_DIR}/rendered/spoke.publickey"
printf '%s\n' "${SPOKE_PRIVATE_KEY}" > "${SPOKE_PRIVATE_KEY_FILE}"
printf '%s\n' "${SPOKE_PUBLIC_KEY}" > "${SPOKE_PUBLIC_KEY_FILE}"
chmod 600 "${SPOKE_PRIVATE_KEY_FILE}" "${SPOKE_PUBLIC_KEY_FILE}"

if [[ "${GENERATE_PRIVATE_KEY}" == "true" ]]; then
  echo "Generated new spoke keypair."
  echo "Spoke public key: ${SPOKE_PUBLIC_KEY}"
  echo "Store this on the HUB for the matching peer slot."
fi

if [[ -f "${ENV_FILE}" ]]; then
  cp "${ENV_FILE}" "${ENV_FILE}.bak.${TIMESTAMP}"
fi

cat > "${ENV_FILE}" <<EOF
# Generated by install-spoke.sh on ${TIMESTAMP}
SPOKE_PROFILE=${SPOKE_PROFILE}
HUB_ENDPOINT=${HUB_ENDPOINT}
HUB_PORT=${HUB_PORT}
HUB_TUNNEL_IP=${HUB_TUNNEL_IP}
SPOKE_TUNNEL_IP=${SPOKE_TUNNEL_IP}
SPOKE_PRIVATE_KEY=${SPOKE_PRIVATE_KEY}
HUB_PUBLIC_KEY=${HUB_PUBLIC_KEY}
PERSISTENT_KEEPALIVE=${PERSISTENT_KEEPALIVE}
EOF

bash "${RENDER_SCRIPT}"

${SUDO} mkdir -p /etc/wireguard
if [[ -f /etc/wireguard/wg0.conf ]]; then
  ${SUDO} cp /etc/wireguard/wg0.conf "/etc/wireguard/wg0.conf.bak.${TIMESTAMP}"
fi
${SUDO} cp "${SCRIPT_DIR}/rendered/wg0.conf" /etc/wireguard/wg0.conf
${SUDO} cp "${SPOKE_PRIVATE_KEY_FILE}" /etc/wireguard/wg0.privatekey
${SUDO} cp "${SPOKE_PUBLIC_KEY_FILE}" /etc/wireguard/wg0.publickey
${SUDO} chmod 600 /etc/wireguard/wg0.conf
${SUDO} chmod 600 /etc/wireguard/wg0.privatekey /etc/wireguard/wg0.publickey

${SUDO} systemctl enable wg-quick@wg0
if ${SUDO} systemctl is-active --quiet wg-quick@wg0; then
  ${SUDO} systemctl restart wg-quick@wg0
else
  ${SUDO} systemctl start wg-quick@wg0
fi

if [[ "${INSTALL_CONSOLEPI}" == "true" ]]; then
  install_consolepi
fi

configure_consolepi_remote_services

echo
echo "Install complete."
echo "Spoke public key: ${SPOKE_PUBLIC_KEY}"
echo "Spoke private key file: ${SPOKE_PRIVATE_KEY_FILE}"
echo "Spoke public key file: ${SPOKE_PUBLIC_KEY_FILE}"
echo "ConsolePi preseed file: ${CONSOLEPI_PRESEED_FILE}"
echo "WireGuard config: /etc/wireguard/wg0.conf"
echo "Deployed public key file: /etc/wireguard/wg0.publickey"
echo "Rendered summary: ${SCRIPT_DIR}/rendered/summary.txt"
echo "ConsolePi API check: curl -s http://127.0.0.1:5000/api/v1.0/details | head"
echo
echo "Next check: ${SUDO} wg show"