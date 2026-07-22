#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
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
