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

validate_public_key() {
  local key="$1"
  [[ "${key}" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  ((${#key} >= 40))
}

derive_peer_ip_from_subnet() {
  local subnet="$1"
  local peer_index="$2"
  local base_ip
  local prefix
  local o1
  local o2
  local o3
  local o4
  local host_octet

  base_ip="${subnet%/*}"
  prefix="${subnet#*/}"

  if [[ "${prefix}" != "24" ]]; then
    echo "Only /24 subnets are supported for derived peer IPs: ${subnet}" >&2
    exit 1
  fi

  is_valid_ipv4 "${base_ip}" || {
    echo "Invalid subnet base IP: ${base_ip}" >&2
    exit 1
  }

  IFS='.' read -r o1 o2 o3 o4 <<< "${base_ip}"
  host_octet=$((10 + peer_index))
  if ((host_octet < 11 || host_octet > 254)); then
    echo "Derived host octet out of range for peer index ${peer_index}: ${host_octet}" >&2
    exit 1
  fi

  printf '%s.%s.%s.%s' "${o1}" "${o2}" "${o3}" "${host_octet}"
}

append_hub_peer_stanzas() {
  local target_file="$1"
  local profile_label="$2"
  local subnet="$3"
  local key_var_prefix="$4"
  local profile_kind="$5"
  local profile_letter="$6"
  local endpoint_port="$7"
  local hub_ip="$8"
  local indexes=()
  local var_name
  local peer_index
  local key_var
  local peer_key
  local peer_ip
  local profile_path
  local spoke_private_placeholder
  local key_count=0

  while IFS= read -r var_name; do
    peer_index="${var_name##*_}"
    [[ "${peer_index}" =~ ^[0-9]+$ ]] || continue
    indexes+=("${peer_index}")
  done < <(compgen -A variable "${key_var_prefix}_")

  if ((${#indexes[@]} == 0)); then
    return 0
  fi

  IFS=$'\n' indexes=($(printf '%s\n' "${indexes[@]}" | sort -n -u))

  for peer_index in "${indexes[@]}"; do
    key_var="${key_var_prefix}_${peer_index}"
    peer_key="${!key_var:-}"
    peer_key="${peer_key//[[:space:]]/}"
    [[ -n "${peer_key}" ]] || continue

    validate_public_key "${peer_key}" || {
      echo "Invalid public key format in ${key_var}" >&2
      exit 1
    }

    peer_ip="$(derive_peer_ip_from_subnet "${subnet}" "${peer_index}")"

    cat >> "${target_file}" <<EOF

[Peer]
  # ${profile_label} peer ${peer_index}
PublicKey = ${peer_key}
AllowedIPs = ${peer_ip}/32
PersistentKeepalive = 25
EOF

    spoke_private_placeholder="<${profile_label}_PEER_${peer_index}_PRIVATE_KEY>"
    profile_path="${SCRIPT_DIR}/profiles/profile-${profile_letter}${peer_index}-${profile_kind}.conf.example"
    cat > "${profile_path}" <<EOF
# Profile ${profile_letter}${peer_index} (${profile_label})
  # Generated from ${key_var}.

[Interface]
Address = ${peer_ip}/32
PrivateKey = ${spoke_private_placeholder}

[Peer]
PublicKey = <HUB_PUBLIC_KEY>
Endpoint = <PUBLIC_IP_OR_DDNS>:${endpoint_port}
AllowedIPs = ${hub_ip}/32
PersistentKeepalive = 25
EOF

    key_count=$((key_count + 1))
  done

  if ((key_count == 0)); then
    echo "No keys found for ${profile_label} peers (${key_var_prefix}_N)."
  fi
}

: "${WG_TRUSTED_SUBNET:?WG_TRUSTED_SUBNET must be set in .env}"
: "${WG_UNTRUSTED_SUBNET:?WG_UNTRUSTED_SUBNET must be set in .env}"
: "${WG_TRUSTED_HUB_IP:?WG_TRUSTED_HUB_IP must be set in .env}"
: "${WG_UNTRUSTED_HUB_IP:?WG_UNTRUSTED_HUB_IP must be set in .env}"
: "${WG_TRUSTED_PORT:?WG_TRUSTED_PORT must be set in .env}"
: "${WG_UNTRUSTED_PORT:?WG_UNTRUSTED_PORT must be set in .env}"

WG_TRUSTED_PREFIX="${WG_TRUSTED_SUBNET#*/}"
WG_UNTRUSTED_PREFIX="${WG_UNTRUSTED_SUBNET#*/}"

mkdir -p "${SCRIPT_DIR}/trusted/config/wg_confs" "${SCRIPT_DIR}/untrusted/config/wg_confs" "${SCRIPT_DIR}/profiles"
rm -f "${SCRIPT_DIR}/profiles"/profile-A*-untrusted.conf.example "${SCRIPT_DIR}/profiles"/profile-B*-trusted.conf.example

cat > "${SCRIPT_DIR}/trusted/config/wg_confs/wg-trusted.conf.example" <<EOF
# Trusted profile tunnel
# Peers in this profile are allowed to access ConsolePi SSH.

[Interface]
Address = ${WG_TRUSTED_HUB_IP}/${WG_TRUSTED_PREFIX}
ListenPort = ${WG_TRUSTED_PORT}
PrivateKey = <HUB_TRUSTED_PRIVATE_KEY>
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -o %i -j DROP
PostDown = iptables -D FORWARD -i %i -o %i -j DROP
EOF

append_hub_peer_stanzas \
  "${SCRIPT_DIR}/trusted/config/wg_confs/wg-trusted.conf.example" \
  "TRUSTED" \
  "${WG_TRUSTED_SUBNET}" \
  "WG_TRUSTED_PEER_KEY" \
  "trusted" \
  "B" \
  "${WG_TRUSTED_PORT}" \
  "${WG_TRUSTED_HUB_IP}"

cat > "${SCRIPT_DIR}/untrusted/config/wg_confs/wg-untrusted.conf.example" <<EOF
# Untrusted profile tunnel
# Peers in this profile should NOT access ConsolePi SSH.

[Interface]
Address = ${WG_UNTRUSTED_HUB_IP}/${WG_UNTRUSTED_PREFIX}
ListenPort = ${WG_UNTRUSTED_PORT}
PrivateKey = <HUB_UNTRUSTED_PRIVATE_KEY>
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -o %i -j DROP
PostDown = iptables -D FORWARD -i %i -o %i -j DROP
EOF

append_hub_peer_stanzas \
  "${SCRIPT_DIR}/untrusted/config/wg_confs/wg-untrusted.conf.example" \
  "UNTRUSTED" \
  "${WG_UNTRUSTED_SUBNET}" \
  "WG_UNTRUSTED_PEER_KEY" \
  "untrusted" \
  "A" \
  "${WG_UNTRUSTED_PORT}" \
  "${WG_UNTRUSTED_HUB_IP}"

echo "Rendered WireGuard profile templates from ${ENV_FILE}."
