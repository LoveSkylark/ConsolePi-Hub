#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
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
  if [[ ! -f "${SCRIPT_DIR}/.env.example" ]]; then
    echo "Missing ${SCRIPT_DIR}/.env.example; pulling from ${REPO_URL}@${REPO_REF}"
    download_repo_file "SPOKE/.env.example" "${SCRIPT_DIR}/.env.example" || true
  fi
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${SPOKE_PROFILE:?SPOKE_PROFILE must be set}"
: "${HUB_ENDPOINT:?HUB_ENDPOINT must be set}"
: "${HUB_PORT:?HUB_PORT must be set}"
: "${HUB_TUNNEL_IP:?HUB_TUNNEL_IP must be set}"
: "${SPOKE_TUNNEL_IP:?SPOKE_TUNNEL_IP must be set}"
: "${SPOKE_PRIVATE_KEY:?SPOKE_PRIVATE_KEY must be set}"
: "${HUB_PUBLIC_KEY:?HUB_PUBLIC_KEY must be set}"
: "${PERSISTENT_KEEPALIVE:?PERSISTENT_KEEPALIVE must be set}"

case "${SPOKE_PROFILE}" in
  trusted|untrusted)
    ;;
  *)
    echo "SPOKE_PROFILE must be 'trusted' or 'untrusted'" >&2
    exit 1
    ;;
esac

SPOKE_PROFILE_LABEL="$(printf '%s' "${SPOKE_PROFILE}" | tr '[:lower:]' '[:upper:]')"

mkdir -p "${SCRIPT_DIR}/profiles" "${SCRIPT_DIR}/rendered"

cat > "${SCRIPT_DIR}/profiles/wg0.conf.example" <<EOF
# ${SPOKE_PROFILE_LABEL} spoke template

[Interface]
Address = ${SPOKE_TUNNEL_IP}/32
PrivateKey = ${SPOKE_PRIVATE_KEY}

[Peer]
PublicKey = ${HUB_PUBLIC_KEY}
Endpoint = ${HUB_ENDPOINT}:${HUB_PORT}
AllowedIPs = ${HUB_TUNNEL_IP}/32
PersistentKeepalive = ${PERSISTENT_KEEPALIVE}
EOF

cp "${SCRIPT_DIR}/profiles/wg0.conf.example" "${SCRIPT_DIR}/rendered/wg0.conf"

cat > "${SCRIPT_DIR}/rendered/summary.txt" <<EOF
Rendered spoke profile: ${SPOKE_PROFILE}
Spoke address: ${SPOKE_TUNNEL_IP}/32
Hub endpoint: ${HUB_ENDPOINT}:${HUB_PORT}
AllowedIPs: ${HUB_TUNNEL_IP}/32
Output config: ${SCRIPT_DIR}/rendered/wg0.conf
EOF

echo "Rendered ${SPOKE_PROFILE} spoke config at ${SCRIPT_DIR}/rendered/wg0.conf"
