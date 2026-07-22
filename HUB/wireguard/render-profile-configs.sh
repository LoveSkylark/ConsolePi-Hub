#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${HUB_DIR}/.env"
REPO_URL="${CONSOLEPI_HUB_REPO_URL:-https://github.com/LoveSkylark/ConsolePi-Hub}"
REPO_REF="${CONSOLEPI_HUB_REPO_REF:-main}"
RAW_BASE="${REPO_URL/github.com/raw.githubusercontent.com}/${REPO_REF}"

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

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ ! -f "${HUB_DIR}/.env.example" ]]; then
    echo "Missing ${HUB_DIR}/.env.example; pulling from ${REPO_URL}@${REPO_REF}"
    download_repo_file "HUB/.env.example" "${HUB_DIR}/.env.example" || true
  fi
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

validate_peer_list() {
  local label="$1"
  local raw_list="$2"
  local value="$3"

  IFS=',' read -r -a in_array <<< "$raw_list"
  ((${#in_array[@]} > 0)) || {
    echo "${label} must contain at least one IP" >&2
    exit 1
  }

  local seen=" "
  local out_array=()
  for i in "${!in_array[@]}"; do
    local ip="${in_array[i]//[[:space:]]/}"
    [[ -n "$ip" ]] || {
      echo "${label} contains an empty entry" >&2
      exit 1
    }
    is_valid_ipv4 "$ip" || {
      echo "${label} contains invalid IPv4 value: ${ip}" >&2
      exit 1
    }
    case "$seen" in
      *" ${ip} "*)
        echo "${label} contains duplicate IP value: ${ip}" >&2
        exit 1
        ;;
    esac
    seen="${seen}${ip} "
    out_array+=("$ip")
  done

  local joined
  IFS=',' joined="${out_array[*]}"
  printf -v "$value" '%s' "$joined"
}

: "${WG_TRUSTED_SUBNET:?WG_TRUSTED_SUBNET must be set in .env}"
: "${WG_UNTRUSTED_SUBNET:?WG_UNTRUSTED_SUBNET must be set in .env}"
: "${WG_TRUSTED_HUB_IP:?WG_TRUSTED_HUB_IP must be set in .env}"
: "${WG_UNTRUSTED_HUB_IP:?WG_UNTRUSTED_HUB_IP must be set in .env}"
: "${WG_TRUSTED_PEER_IPS:?WG_TRUSTED_PEER_IPS must be set in .env}"
: "${WG_UNTRUSTED_PEER_IPS:?WG_UNTRUSTED_PEER_IPS must be set in .env}"
: "${WG_TRUSTED_PORT:?WG_TRUSTED_PORT must be set in .env}"
: "${WG_UNTRUSTED_PORT:?WG_UNTRUSTED_PORT must be set in .env}"

WG_TRUSTED_PREFIX="${WG_TRUSTED_SUBNET#*/}"
WG_UNTRUSTED_PREFIX="${WG_UNTRUSTED_SUBNET#*/}"

validate_peer_list "WG_TRUSTED_PEER_IPS" "${WG_TRUSTED_PEER_IPS}" trusted_ips_csv
validate_peer_list "WG_UNTRUSTED_PEER_IPS" "${WG_UNTRUSTED_PEER_IPS}" untrusted_ips_csv

IFS=',' read -r -a trusted_ips <<< "${trusted_ips_csv}"
IFS=',' read -r -a untrusted_ips <<< "${untrusted_ips_csv}"

mkdir -p "${SCRIPT_DIR}/trusted/config/wg_confs" "${SCRIPT_DIR}/untrusted/config/wg_confs" "${SCRIPT_DIR}/profiles"

cat > "${SCRIPT_DIR}/trusted/config/wg_confs/wg-trusted.conf.example" <<EOF
# Trusted profile tunnel
# Peers in this profile are allowed to access ConsolePi SSH.

[Interface]
Address = ${WG_TRUSTED_HUB_IP}/${WG_TRUSTED_PREFIX}
ListenPort = 51820
PrivateKey = <HUB_TRUSTED_PRIVATE_KEY>
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -o %i -j DROP
PostDown = iptables -D FORWARD -i %i -o %i -j DROP
EOF

for i in "${!trusted_ips[@]}"; do
  peer_num=$((i + 1))
  peer_ip="${trusted_ips[i]//[[:space:]]/}"
  [[ -z "${peer_ip}" ]] && continue
  cat >> "${SCRIPT_DIR}/trusted/config/wg_confs/wg-trusted.conf.example" <<EOF

[Peer]
# Trusted peer ${peer_num}
PublicKey = <TRUSTED_PEER_${peer_num}_PUBLIC_KEY>
AllowedIPs = ${peer_ip}/32
PersistentKeepalive = 25
EOF
done

cat > "${SCRIPT_DIR}/untrusted/config/wg_confs/wg-untrusted.conf.example" <<EOF
# Untrusted profile tunnel
# Peers in this profile should NOT access ConsolePi SSH.

[Interface]
Address = ${WG_UNTRUSTED_HUB_IP}/${WG_UNTRUSTED_PREFIX}
ListenPort = 51820
PrivateKey = <HUB_UNTRUSTED_PRIVATE_KEY>
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -o %i -j DROP
PostDown = iptables -D FORWARD -i %i -o %i -j DROP
EOF

for i in "${!untrusted_ips[@]}"; do
  peer_num=$((i + 1))
  peer_ip="${untrusted_ips[i]//[[:space:]]/}"
  [[ -z "${peer_ip}" ]] && continue
  cat >> "${SCRIPT_DIR}/untrusted/config/wg_confs/wg-untrusted.conf.example" <<EOF

[Peer]
# Untrusted peer ${peer_num}
PublicKey = <UNTRUSTED_PEER_${peer_num}_PUBLIC_KEY>
AllowedIPs = ${peer_ip}/32
PersistentKeepalive = 25
EOF
done

for i in "${!untrusted_ips[@]}"; do
  peer_num=$((i + 1))
  peer_ip="${untrusted_ips[i]//[[:space:]]/}"
  [[ -z "${peer_ip}" ]] && continue
  cat > "${SCRIPT_DIR}/profiles/profile-A${peer_num}-untrusted.conf.example" <<EOF
# Profile A${peer_num} (UNTRUSTED)
# Use this for peers that should form VPN connectivity but NOT access ConsolePi SSH.

[Interface]
Address = ${peer_ip}/32
PrivateKey = <UNTRUSTED_PEER_${peer_num}_PRIVATE_KEY>

[Peer]
PublicKey = <HUB_PUBLIC_KEY>
Endpoint = <PUBLIC_IP_OR_DDNS>:${WG_UNTRUSTED_PORT}
AllowedIPs = ${WG_UNTRUSTED_HUB_IP}/32
PersistentKeepalive = 25
EOF
done

for i in "${!trusted_ips[@]}"; do
  peer_num=$((i + 1))
  peer_ip="${trusted_ips[i]//[[:space:]]/}"
  [[ -z "${peer_ip}" ]] && continue
  cat > "${SCRIPT_DIR}/profiles/profile-B${peer_num}-trusted.conf.example" <<EOF
# Profile B${peer_num} (TRUSTED)
# Use this for peers that are allowed to SSH into ConsolePi over the tunnel.

[Interface]
Address = ${peer_ip}/32
PrivateKey = <TRUSTED_PEER_${peer_num}_PRIVATE_KEY>

[Peer]
PublicKey = <HUB_PUBLIC_KEY>
Endpoint = <PUBLIC_IP_OR_DDNS>:${WG_TRUSTED_PORT}
AllowedIPs = ${WG_TRUSTED_HUB_IP}/32
PersistentKeepalive = 25
EOF
done

rm -f "${SCRIPT_DIR}/profiles/profile-A-untrusted.conf.example" "${SCRIPT_DIR}/profiles/profile-B-trusted.conf.example"

echo "Rendered WireGuard profile templates from ${ENV_FILE}."
